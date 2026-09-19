//! Pure array operations for the depth/mask pipeline.
//!
//! Everything here is deterministic, allocation-friendly and free of I/O so it
//! can be unit tested without a model or a wallpaper.

use crate::config::{INPUT_SIZE, PATCH_SIZE};

/// Largest integer `value` rounded to a multiple of `multiple`.
fn round_to_multiple(value: f64, multiple: u32) -> u32 {
    let multiple = multiple as f64;
    ((value / multiple).round() * multiple).max(multiple) as u32
}

/// Inference resolution that preserves the wallpaper's aspect ratio.
///
/// The short edge is scaled up to at least `INPUT_SIZE`, then both edges are
/// aligned to the ViT patch size — feeding a non-multiple shape makes ONNX
/// Runtime reject the tensor. Aspect ratio is preserved so the depth field is
/// not distorted; the letterbox alternative would waste model capacity.
pub fn inference_size(source_width: u32, source_height: u32) -> (u32, u32) {
    let width = source_width.max(1) as f64;
    let height = source_height.max(1) as f64;
    let scale = f64::max(INPUT_SIZE as f64 / width, INPUT_SIZE as f64 / height);
    (
        round_to_multiple(width * scale, PATCH_SIZE).max(INPUT_SIZE),
        round_to_multiple(height * scale, PATCH_SIZE).max(INPUT_SIZE),
    )
}

/// Box filter of radius `radius` using an integral image.
///
/// O(1) per pixel regardless of radius, which is what makes a guided filter at
/// radius 8 on a 1440p image affordable. Edges are handled by clamping.
pub fn box_mean(source: &[f32], width: u32, height: u32, radius: u32) -> Vec<f32> {
    let (width, height, radius) = (width as usize, height as usize, radius as usize);
    assert_eq!(source.len(), width * height, "source length mismatch");
    if width == 0 || height == 0 {
        return Vec::new();
    }

    let padded_width = width + 2 * radius;
    let padded_height = height + 2 * radius;
    let stride = padded_width + 1;

    // Integral image of the edge-clamped source.
    let mut integral = vec![0f64; (padded_height + 1) * stride];
    for y in 0..padded_height {
        let source_y = y.saturating_sub(radius).min(height - 1);
        let row_base = source_y * width;
        let mut running = 0f64;
        for x in 0..padded_width {
            let source_x = x.saturating_sub(radius).min(width - 1);
            running += source[row_base + source_x] as f64;
            integral[(y + 1) * stride + (x + 1)] = integral[y * stride + (x + 1)] + running;
        }
    }

    let window = (2 * radius + 1) as f64;
    let normaliser = 1.0 / (window * window);
    let mut output = vec![0f32; width * height];
    for y in 0..height {
        let (top, bottom) = (y, y + 2 * radius + 1);
        for x in 0..width {
            let (left, right) = (x, x + 2 * radius + 1);
            let sum = integral[bottom * stride + right] - integral[top * stride + right]
                - integral[bottom * stride + left]
                + integral[top * stride + left];
            output[y * width + x] = (sum * normaliser) as f32;
        }
    }
    output
}

/// Guided filter (He et al.) using the wallpaper luminance as the guide.
///
/// This is what keeps edges crisp without a segmentation model: the depth
/// prediction is smooth and low resolution, but the guide image has real edges,
/// so the filter transfers them onto the depth field. Everything after this
/// step inherits that alignment.
pub fn guided_filter(
    guide: &[f32],
    coarse: &[f32],
    width: u32,
    height: u32,
    radius: u32,
    epsilon: f32,
) -> Vec<f32> {
    let count = (width as usize) * (height as usize);
    assert_eq!(guide.len(), count);
    assert_eq!(coarse.len(), count);

    let mean_guide = box_mean(guide, width, height, radius);
    let mean_coarse = box_mean(coarse, width, height, radius);

    let guide_squared: Vec<f32> = guide.iter().map(|value| value * value).collect();
    let cross: Vec<f32> = guide
        .iter()
        .zip(coarse.iter())
        .map(|(guide, coarse)| guide * coarse)
        .collect();
    let correlation_guide = box_mean(&guide_squared, width, height, radius);
    let correlation_cross = box_mean(&cross, width, height, radius);

    let mut coefficient_a = vec![0f32; count];
    let mut coefficient_b = vec![0f32; count];
    for index in 0..count {
        let variance = correlation_guide[index] - mean_guide[index] * mean_guide[index];
        let covariance = correlation_cross[index] - mean_guide[index] * mean_coarse[index];
        let a = covariance / (variance + epsilon);
        coefficient_a[index] = a;
        coefficient_b[index] = mean_coarse[index] - a * mean_guide[index];
    }

    let mean_a = box_mean(&coefficient_a, width, height, radius);
    let mean_b = box_mean(&coefficient_b, width, height, radius);

    (0..count)
        .map(|index| (mean_a[index] * guide[index] + mean_b[index]).clamp(0.0, 1.0))
        .collect()
}

/// Separable bilinear resample of a scalar field.
///
/// A plain bilinear kernel is enough here because the depth field is inherently
/// low frequency — the guided filter, not the resampler, is responsible for
/// edge quality.
pub fn resize_bilinear(source: &[f32], source_width: u32, source_height: u32, width: u32, height: u32) -> Vec<f32> {
    let (source_width, source_height) = (source_width as usize, source_height as usize);
    let (width, height) = (width as usize, height as usize);
    if source_width == width && source_height == height {
        return source.to_vec();
    }
    let mut output = vec![0f32; width * height];
    let scale_x = source_width as f32 / width as f32;
    let scale_y = source_height as f32 / height as f32;
    for y in 0..height {
        let sample_y = ((y as f32 + 0.5) * scale_y - 0.5).max(0.0);
        let y0 = sample_y.floor() as usize;
        let y1 = (y0 + 1).min(source_height - 1);
        let weight_y = sample_y - y0 as f32;
        for x in 0..width {
            let sample_x = ((x as f32 + 0.5) * scale_x - 0.5).max(0.0);
            let x0 = sample_x.floor() as usize;
            let x1 = (x0 + 1).min(source_width - 1);
            let weight_x = sample_x - x0 as f32;
            let top = source[y0 * source_width + x0] * (1.0 - weight_x)
                + source[y0 * source_width + x1] * weight_x;
            let bottom = source[y1 * source_width + x0] * (1.0 - weight_x)
                + source[y1 * source_width + x1] * weight_x;
            output[y * width + x] = top * (1.0 - weight_y) + bottom * weight_y;
        }
    }
    output
}

/// Smooth transition across `[low, high]`, returned as alpha in `0.0..=1.0`.
///
/// The feather is applied symmetrically around the threshold, so the slider
/// widens the transition without moving its centre.
pub fn smoothstep(values: &[f32], low: f32, high: f32) -> Vec<f32> {
    if high <= low {
        return values
            .iter()
            .map(|value| if *value >= high { 1.0 } else { 0.0 })
            .collect();
    }
    values
        .iter()
        .map(|value| {
            let scaled = ((value - low) / (high - low)).clamp(0.0, 1.0);
            scaled * scaled * (3.0 - 2.0 * scaled)
        })
        .collect()
}

/// Convert `0.0..=1.0` alpha into 8-bit samples.
pub fn alpha_to_u8(alpha: &[f32]) -> Vec<u8> {
    alpha
        .iter()
        .map(|value| (value * 255.0).round().clamp(0.0, 255.0) as u8)
        .collect()
}

/// Build the foreground alpha from a depth field.
///
/// `near_is_high` states the model's convention: whether a larger depth value
/// means "closer to the camera". Depth Anything emits relative inverse depth, so
/// foreground pixels are the *high* ones and the threshold selects everything
/// above it. Getting this backwards would invert the entire effect, so it is an
/// explicit parameter rather than an inline assumption.
pub fn foreground_alpha(depth: &[f32], threshold: f32, feather: f32, near_is_high: bool) -> Vec<f32> {
    let half = feather * 0.5;
    let alpha = smoothstep(depth, threshold - half, threshold + half);
    if near_is_high {
        alpha
    } else {
        alpha.into_iter().map(|value| 1.0 - value).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inference_size_is_patch_aligned_and_preserves_aspect() {
        let (width, height) = inference_size(1920, 1080);
        assert_eq!(width % PATCH_SIZE, 0);
        assert_eq!(height % PATCH_SIZE, 0);
        assert_eq!(height, INPUT_SIZE);
        let ratio = width as f64 / height as f64;
        assert!((ratio - 1920.0 / 1080.0).abs() < 0.05, "ratio drifted: {ratio}");

        let (portrait_width, portrait_height) = inference_size(1080, 1920);
        assert_eq!(portrait_width, INPUT_SIZE);
        assert!(portrait_height >= INPUT_SIZE);
    }

    #[test]
    fn inference_size_never_shrinks_below_input_size() {
        let (width, height) = inference_size(64, 48);
        assert!(width >= INPUT_SIZE && height >= INPUT_SIZE);
        assert_eq!(width % PATCH_SIZE, 0);
    }

    #[test]
    fn box_mean_of_a_constant_field_is_that_constant() {
        let source = vec![0.42f32; 20 * 10];
        let mean = box_mean(&source, 20, 10, 3);
        assert_eq!(mean.len(), 200);
        for value in mean {
            assert!((value - 0.42).abs() < 1e-5, "got {value}");
        }
    }

    #[test]
    fn box_mean_preserves_a_global_average() {
        let mut source = vec![0f32; 16 * 16];
        for (index, value) in source.iter_mut().enumerate() {
            *value = (index % 7) as f32 / 7.0;
        }
        let expected: f32 = source.iter().sum::<f32>() / source.len() as f32;
        let mean = box_mean(&source, 16, 16, 2);
        let actual: f32 = mean.iter().sum::<f32>() / mean.len() as f32;
        assert!((actual - expected).abs() < 1e-4, "{actual} vs {expected}");
    }

    #[test]
    fn smoothstep_is_clamped_and_monotonic() {
        let values = vec![0.0f32, 0.2, 0.4, 0.5, 0.6, 0.8, 1.0];
        let alpha = smoothstep(&values, 0.4, 0.6);
        assert_eq!(alpha[0], 0.0);
        assert_eq!(alpha[2], 0.0, "the lower bound maps to zero");
        assert_eq!(alpha[4], 1.0, "the upper bound maps to one");
        assert_eq!(alpha[6], 1.0);
        assert!((alpha[3] - 0.5).abs() < 1e-6, "midpoint should be 0.5");
        for pair in alpha.windows(2) {
            assert!(pair[1] >= pair[0], "not monotonic");
        }
    }

    #[test]
    fn smoothstep_with_zero_feather_is_a_hard_cut() {
        let alpha = smoothstep(&[0.1f32, 0.9], 0.5, 0.5);
        assert_eq!(alpha, vec![0.0, 1.0]);
    }

    /// A guided filter can only redistribute detail that the input already
    /// carries locally. A constant input therefore stays constant no matter how
    /// sharp the guide is — this is a property of the algorithm, not a bug, and
    /// it is why the coarse depth must be upsampled (not flattened) first.
    #[test]
    fn guided_filter_leaves_a_constant_field_untouched() {
        let (width, height) = (32u32, 8u32);
        let mut guide = vec![0f32; (width * height) as usize];
        for y in 0..height as usize {
            for x in 0..width as usize {
                if x >= width as usize / 2 {
                    guide[y * width as usize + x] = 1.0;
                }
            }
        }
        let coarse = vec![0.5f32; (width * height) as usize];
        let refined = guided_filter(&guide, &coarse, width, height, 4, 0.001);
        for value in refined {
            assert!((value - 0.5).abs() < 1e-4, "drifted to {value}");
        }
    }

    /// With a blurred edge in the input, the filter concentrates the transition
    /// onto the guide's edge while preserving the levels on both sides.
    #[test]
    fn guided_filter_sharpens_an_edge_defined_by_the_guide() {
        let (width, height) = (32u32, 8u32);
        let count = (width * height) as usize;
        let mut guide = vec![0f32; count];
        let mut coarse = vec![0f32; count];
        for y in 0..height as usize {
            for x in 0..width as usize {
                let index = y * width as usize + x;
                if x >= width as usize / 2 {
                    guide[index] = 1.0;
                }
                coarse[index] = 0.3 + 0.4 * (x as f32 / (width as f32 - 1.0));
            }
        }

        let refined = guided_filter(&guide, &coarse, width, height, 4, 0.001);
        for value in &refined {
            assert!((0.0..=1.0).contains(value), "out of range: {value}");
        }

        let row = 4 * width as usize;
        let coarse_step = (coarse[row + 16] - coarse[row + 15]).abs();
        let refined_step = (refined[row + 16] - refined[row + 15]).abs();
        assert!(
            refined_step > coarse_step * 1.5,
            "edge was not sharpened: coarse {coarse_step}, refined {refined_step}"
        );
        assert!(
            (refined[row + 2] - coarse[row + 2]).abs() < 0.1,
            "level left of the edge shifted"
        );
        assert!(
            (refined[row + 29] - coarse[row + 29]).abs() < 0.1,
            "level right of the edge shifted"
        );
    }

    #[test]
    fn foreground_alpha_selects_near_pixels_when_depth_is_inverse() {
        let depth = vec![0.1f32, 0.5, 0.9];
        let alpha = foreground_alpha(&depth, 0.5, 0.0, true);
        assert_eq!(alpha, vec![0.0, 1.0, 1.0]);
    }

    #[test]
    fn foreground_alpha_inverts_when_the_convention_flips() {
        let depth = vec![0.1f32, 0.5, 0.9];
        let alpha = foreground_alpha(&depth, 0.5, 0.0, false);
        assert_eq!(alpha, vec![1.0, 0.0, 0.0]);
    }

    #[test]
    fn resize_bilinear_is_identity_at_matching_size() {
        let source: Vec<f32> = (0..12).map(|index| index as f32).collect();
        assert_eq!(resize_bilinear(&source, 4, 3, 4, 3), source);
    }

    #[test]
    fn resize_bilinear_upscales_within_range() {
        let source = vec![0f32, 1.0, 0.0, 1.0];
        let upscaled = resize_bilinear(&source, 2, 2, 4, 4);
        assert_eq!(upscaled.len(), 16);
        for value in upscaled {
            assert!((0.0..=1.0).contains(&value), "out of range: {value}");
        }
    }
}
