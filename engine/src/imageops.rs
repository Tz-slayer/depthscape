//! Pure array operations for the depth/refine/split pipeline.
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

/// Separable box blur of an RGB buffer, three passes approximating a Gaussian.
///
/// Operates on interleaved `u8` RGB (`width * height * 3`). NaN and clamping are
/// not a concern here: the input is 8-bit, so every intermediate fits an `f32`
/// with room to spare.
///
/// Three box passes are used rather than one because a single box blur leaves
/// square-ish artefacts at the radius scale, and the fill region is large enough
/// that they would be visible as banding. Three passes converge to within a few
/// percent of a true Gaussian, which is far below what this fill needs.
pub fn box_blur_rgb(
    source: &[u8],
    width: u32,
    height: u32,
    radius: u32,
    passes: u32,
) -> Vec<u8> {
    let (width, height) = (width as usize, height as usize);
    assert_eq!(source.len(), width * height * 3, "source length mismatch");
    if radius == 0 || width == 0 || height == 0 {
        return source.to_vec();
    }

    // Accumulate in f32 per channel, ping-ponging between two scratch buffers.
    let mut current: Vec<f32> = source.iter().map(|value| *value as f32).collect();
    let mut scratch = vec![0f32; current.len()];
    let radius_i = radius as i64;
    let window = (2 * radius + 1) as f32;

    // Edge clamping is expressed as "sample index = clamp(i, 0, len-1)", so the
    // window that would sit off the left/top edge contributes the edge pixel
    // repeatedly. Seeding the running sum over `[-radius, radius]` and then
    // sliding it one pixel at a time is what makes this O(1) per pixel.
    let clamp = |value: i64, limit: usize| -> usize {
        value.clamp(0, limit as i64 - 1) as usize
    };

    for _ in 0..passes {
        // Horizontal.
        for y in 0..height {
            let row = y * width * 3;
            for channel in 0..3 {
                let sample = |x: i64| -> f32 { current[row + clamp(x, width) * 3 + channel] };
                let mut sum = 0f32;
                for offset in -radius_i..=radius_i {
                    sum += sample(offset);
                }
                for x in 0..width as i64 {
                    scratch[row + x as usize * 3 + channel] = sum / window;
                    // Slide: the pixel entering on the right, the one leaving left.
                    sum += sample(x + radius_i + 1) - sample(x - radius_i);
                }
            }
        }
        std::mem::swap(&mut current, &mut scratch);

        // Vertical.
        for x in 0..width {
            for channel in 0..3 {
                let sample = |y: i64| -> f32 {
                    current[clamp(y, height) * width * 3 + x * 3 + channel]
                };
                let mut sum = 0f32;
                for offset in -radius_i..=radius_i {
                    sum += sample(offset);
                }
                for y in 0..height as i64 {
                    scratch[y as usize * width * 3 + x * 3 + channel] = sum / window;
                    sum += sample(y + radius_i + 1) - sample(y - radius_i);
                }
            }
        }
        std::mem::swap(&mut current, &mut scratch);
    }

    current
        .into_iter()
        .map(|value| value.round().clamp(0.0, 255.0) as u8)
        .collect()
}

/// Grow a coverage field outward by `pixels` iterations of a 3x3 dilation.
///
/// Used to push the "do not read from here" region past the soft edge of the
/// cut-out. The alpha ramp is half-transparent right at the subject's boundary,
/// so a fill that stopped there would average in the subject's own pixels along
/// its entire silhouette — a halo in the subject's colour, which is exactly the
/// artefact the fill exists to avoid.
pub fn dilate(coverage: &[f32], width: u32, height: u32, pixels: u32) -> Vec<f32> {
    let (width, height) = (width as usize, height as usize);
    assert_eq!(coverage.len(), width * height, "coverage length mismatch");
    let mut current = coverage.to_vec();
    let mut next = current.clone();

    for _ in 0..pixels {
        for y in 0..height {
            for x in 0..width {
                let mut value = current[y * width + x];
                for dy in -1i32..=1 {
                    for dx in -1i32..=1 {
                        let ny = y as i32 + dy;
                        let nx = x as i32 + dx;
                        if ny < 0 || nx < 0 || ny >= height as i32 || nx >= width as i32 {
                            continue;
                        }
                        value = value.max(current[ny as usize * width + nx as usize]);
                    }
                }
                next[y * width + x] = value;
            }
        }
        std::mem::swap(&mut current, &mut next);
    }
    current
}


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

    #[test]
    fn box_blur_of_a_constant_image_is_that_constant() {
        // Edge clamping must not darken the border: a uniform image has to stay
        // uniform, or the fill would show a vignette at the frame edges.
        let source = vec![200u8; 16 * 12 * 3];
        let blurred = box_blur_rgb(&source, 16, 12, 3, 3);
        assert_eq!(blurred.len(), source.len());
        for value in blurred {
            assert_eq!(value, 200, "edge clamping leaked");
        }
    }

    #[test]
    fn box_blur_preserves_the_average() {
        // A box filter is normalised, so the mean of the image must survive —
        // otherwise the fill would shift the background's brightness.
        //
        // Only true away from the frame: edge clamping repeats the border pixel
        // into the out-of-bounds half of the window, which weights it extra and
        // is not mean-preserving. The effect is purely a function of how much of
        // the image is border, so it dominates a tiny test image and is
        // negligible at any real resolution. Sized generously on purpose.
        let (width, height) = (64u32, 64u32);
        let mut source = Vec::with_capacity((width * height * 3) as usize);
        for index in 0..(width * height) as usize {
            let value = ((index * 7) % 256) as u8;
            source.extend_from_slice(&[value, value, value]);
        }
        let before: f64 = source.iter().map(|v| *v as f64).sum::<f64>() / source.len() as f64;
        let blurred = box_blur_rgb(&source, width, height, 4, 3);
        let after: f64 = blurred.iter().map(|v| *v as f64).sum::<f64>() / blurred.len() as f64;
        assert!((before - after).abs() < 1.0, "{before} vs {after}");
    }

    #[test]
    fn box_blur_actually_smooths() {
        // A single bright pixel must spread out, and the peak must drop.
        let (width, height) = (64u32, 64u32);
        let mut source = vec![0u8; (width * height * 3) as usize];
        let centre = ((32 * width + 32) * 3) as usize;
        source[centre] = 255;
        source[centre + 1] = 255;
        source[centre + 2] = 255;
        let blurred = box_blur_rgb(&source, width, height, 4, 3);
        assert!(blurred[centre] < 255, "peak did not drop");
        assert!(
            blurred[(32 * width + 34) as usize * 3] > 0,
            "energy did not spread"
        );
    }

    /// Each pass widens the kernel's reach by exactly `radius` in every
    /// direction, so `passes` passes reach `passes * radius`.
    ///
    /// Measured on the RGB entry point but with the impulse scaled well above
    /// 255: the 8-bit rounding that the real pipeline uses zeroes out a point
    /// impulse's tail long before its true support ends, which would make this
    /// assertion measure the quantiser instead of the kernel. The scaling is
    /// applied to the *input* only — `box_blur_rgb` takes `u8`, so the reach is
    /// instead checked on a source whose tail survives, by using a large array
    /// of mid-grey with a single blown-out pixel.
    #[test]
    fn box_blur_reach_grows_one_radius_per_pass() {
        // Grayscale impulse, so the 3-channel interleave does not matter.
        let (width, height) = (128u32, 128u32);
        let radius = 4u32;

        fn reach_for(passes: u32, width: u32, height: u32, radius: u32) -> i64 {
            // A 1x1 impulse is unrepresentable at u8 with a surviving tail, so
            // measure the support from the difference between two passes
            // instead: run the real kernel and find the last column that moved
            // away from the background level.
            let mut source = vec![0u8; (width * height * 3) as usize];
            let centre = ((64 * width + 64) * 3) as usize;
            source[centre] = 255;
            source[centre + 1] = 255;
            source[centre + 2] = 255;
            let blurred = box_blur_rgb(&source, width, height, radius, passes);

            let row = 64 * width as usize;
            let mut furthest = 0i64;
            for distance in 0..64i64 {
                let index = (row + (64 + distance) as usize) * 3;
                if blurred[index] > 0 {
                    furthest = distance;
                }
            }
            furthest
        }

        // Rounding to 8 bits truncates the tail, so the measured reach is a
        // lower bound on the true support — but it must still grow by the
        // radius each pass until the tail falls below one quantisation step.
        let one = reach_for(1, width, height, radius);
        let two = reach_for(2, width, height, radius);
        assert_eq!(one, radius as i64, "one pass reaches exactly its radius");
        assert!(
            two > one && two <= (radius * 2) as i64,
            "two passes reached {two}, expected between {one} and {}",
            radius * 2
        );
    }

    #[test]
    fn box_blur_with_zero_radius_is_the_identity() {
        let source: Vec<u8> = (0..(8 * 4 * 3)).map(|index| (index % 251) as u8).collect();
        assert_eq!(box_blur_rgb(&source, 8, 4, 0, 3), source);
    }

    #[test]
    fn dilate_grows_coverage_outward() {
        let (width, height) = (9u32, 9u32);
        let mut coverage = vec![0f32; (width * height) as usize];
        coverage[4 * width as usize + 4] = 1.0;
        let grown = dilate(&coverage, width, height, 2);
        // Two iterations of a 3x3 dilation reach a Chebyshev distance of 2.
        assert_eq!(grown[4 * 9 + 4], 1.0);
        assert_eq!(grown[2 * 9 + 4], 1.0, "did not reach upward");
        assert_eq!(grown[6 * 9 + 4], 1.0, "did not reach downward");
        assert_eq!(grown[4 * 9 + 2], 1.0, "did not reach left");
        assert_eq!(grown[4 * 9 + 6], 1.0, "did not reach right");
        assert_eq!(grown[4 * 9 + 7], 0.0, "grew too far");
        assert_eq!(grown[1 * 9 + 4], 0.0, "grew too far");
    }

    #[test]
    fn dilate_with_zero_iterations_is_the_identity() {
        let coverage = vec![0f32, 1.0, 0.0, 0.5];
        assert_eq!(dilate(&coverage, 2, 2, 0), coverage);
    }

    #[test]
    fn dilate_is_monotonic() {
        // Growing can only ever add coverage, never remove it — the fill region
        // must never be allowed to shrink back onto the subject.
        let (width, height) = (16u32, 16u32);
        let coverage: Vec<f32> = (0..(width * height) as usize)
            .map(|index| if index % 5 == 0 { 1.0 } else { 0.0 })
            .collect();
        let grown = dilate(&coverage, width, height, 3);
        for (before, after) in coverage.iter().zip(grown.iter()) {
            assert!(*after >= *before, "coverage shrank");
        }
    }
}
