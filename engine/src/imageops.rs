//! Pure array operations and image encoding for the depth/refine/mask pipeline.
//!
//! Everything here is deterministic, allocation-friendly and free of filesystem
//! I/O so it can be unit tested without a model or a wallpaper. PNG encoding is
//! a byte-buffer transform, not a write, so it lives alongside the array ops
//! that produce its input.

use crate::config::{INPUT_SIZE, PATCH_SIZE, REFINEMENT_MAX_DIMENSION};
use anyhow::{bail, Context, Result};
use image::{DynamicImage, ImageFormat, LumaA};
use rayon::prelude::*;
use std::io::Cursor;

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
    output
        .par_chunks_mut(width)
        .enumerate()
        .for_each(|(y, row)| {
            let (top, bottom) = (y, y + 2 * radius + 1);
            let top_offset = top * stride;
            let bottom_offset = bottom * stride;
            for (x, out_pixel) in row.iter_mut().enumerate() {
                let (left, right) = (x, x + 2 * radius + 1);
                let sum = integral[bottom_offset + right]
                    - integral[top_offset + right]
                    - integral[bottom_offset + left]
                    + integral[top_offset + left];
                *out_pixel = (sum * normaliser) as f32;
            }
        });
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

    let (mean_guide, mean_coarse) = rayon::join(
        || box_mean(guide, width, height, radius),
        || box_mean(coarse, width, height, radius),
    );

    let (guide_squared, cross) = rayon::join(
        || {
            guide
                .par_iter()
                .map(|&value| value * value)
                .collect::<Vec<f32>>()
        },
        || {
            guide
                .par_iter()
                .zip(coarse.par_iter())
                .map(|(&g, &c)| g * c)
                .collect::<Vec<f32>>()
        },
    );

    let (correlation_guide, correlation_cross) = rayon::join(
        || box_mean(&guide_squared, width, height, radius),
        || box_mean(&cross, width, height, radius),
    );

    let mut coefficient_a = vec![0f32; count];
    let mut coefficient_b = vec![0f32; count];

    coefficient_a
        .par_iter_mut()
        .zip(coefficient_b.par_iter_mut())
        .enumerate()
        .for_each(|(index, (a, b))| {
            let variance = correlation_guide[index] - mean_guide[index] * mean_guide[index];
            let covariance = correlation_cross[index] - mean_guide[index] * mean_coarse[index];
            let coef_a = covariance / (variance + epsilon);
            *a = coef_a;
            *b = mean_coarse[index] - coef_a * mean_guide[index];
        });

    let (mean_a, mean_b) = rayon::join(
        || box_mean(&coefficient_a, width, height, radius),
        || box_mean(&coefficient_b, width, height, radius),
    );

    (0..count)
        .into_par_iter()
        .map(|index| (mean_a[index] * guide[index] + mean_b[index]).clamp(0.0, 1.0))
        .collect()
}

/// Separable bilinear resample of a scalar field.
///
/// Production code uses [`resize_cubic`] instead, to match the kernel the
/// reference implementation uses. This is kept because it is what the
/// threshold-ordering tests need: they demonstrate the rejected "threshold
/// first, then resample the alpha" order against a plain bilinear lift, and a
/// test that silently used a different kernel from the one being argued about
/// would prove nothing.
#[cfg_attr(not(test), allow(dead_code))]
pub fn resize_bilinear(
    source: &[f32],
    source_width: u32,
    source_height: u32,
    width: u32,
    height: u32,
) -> Vec<f32> {
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

/// Separable bicubic (Catmull-Rom) resample of a scalar field.
///
/// Matches Pillow's `Image.Resampling.BICUBIC`, which is the kernel Noctalia's
/// Wallpaper Depth uses for every depth-field resample. The difference against
/// `resize_bilinear` is not cosmetic: a cubic kernel reconstructs a smooth ramp
/// with its original curvature rather than a straight line, so a threshold
/// crossing taken afterwards lands closer to where the underlying field really
/// crosses.
///
/// Deliberately not a hand-rolled kernel — `image`'s `CatmullRom` clamps to the
/// channel's range, and that matters here. An unclamped cubic overshoots at
/// local extrema, and an overshoot in the depth field becomes a spurious
/// threshold crossing: a wiggle along the contour, which is precisely the
/// artefact the current threshold ordering exists to remove.
pub fn resize_cubic(
    source: &[f32],
    source_width: u32,
    source_height: u32,
    width: u32,
    height: u32,
) -> Vec<f32> {
    if source_width == width && source_height == height {
        return source.to_vec();
    }
    if source_width == 0 || source_height == 0 || width == 0 || height == 0 {
        return Vec::new();
    }
    let Some(buffer) = image::ImageBuffer::<image::Luma<f32>, Vec<f32>>::from_raw(
        source_width,
        source_height,
        source.to_vec(),
    ) else {
        return source.to_vec();
    };
    image::imageops::resize(
        &buffer,
        width,
        height,
        image::imageops::FilterType::CatmullRom,
    )
    .into_raw()
}

/// The feather is applied symmetrically around the threshold, so the slider
/// widens the transition without moving its centre.
pub fn smoothstep(values: &[f32], low: f32, high: f32) -> Vec<f32> {
    if high <= low {
        return values
            .par_iter()
            .map(|value| if *value >= high { 1.0 } else { 0.0 })
            .collect();
    }
    let inv_span = 1.0 / (high - low);
    values
        .par_iter()
        .map(|value| {
            let scaled = ((value - low) * inv_span).clamp(0.0, 1.0);
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
pub fn foreground_alpha(
    depth: &[f32],
    threshold: f32,
    feather: f32,
    near_is_high: bool,
) -> Vec<f32> {
    let half = feather * 0.5;
    let alpha = smoothstep(depth, threshold - half, threshold + half);
    if near_is_high {
        alpha
    } else {
        alpha.into_par_iter().map(|value| 1.0 - value).collect()
    }
}

/// Resolution at which the guided filter runs.
///
/// Bounded by `REFINEMENT_MAX_DIMENSION` and by the wallpaper's own size, because
/// refining above the resolution the mask is emitted at would be work whose
/// result is discarded. The mask is always emitted at the wallpaper's
/// resolution, so this is the wallpaper itself, capped.
pub fn refine_size(source_width: u32, source_height: u32) -> (u32, u32) {
    let (width, height) = (source_width.max(1), source_height.max(1));
    let scale = f64::min(
        1.0,
        REFINEMENT_MAX_DIMENSION as f64 / width.max(height) as f64,
    );
    (
        ((width as f64 * scale).round() as u32).max(1),
        ((height as f64 * scale).round() as u32).max(1),
    )
}

/// Encode the occlusion mask as an 8-bit grayscale+alpha PNG.
///
/// THE COVERAGE IS WRITTEN TO *BOTH* CHANNELS, and that is deliberate.
///
/// Gray alone is the obvious encoding — it is what the reference implementation
/// emits — but the consumer here is Qt's `MultiEffect`, and that masks on the
/// mask source's **alpha channel**, not its luminance. An `Image` loading a
/// single-channel PNG reports alpha = 255 everywhere, so a gray-only mask would
/// be uniformly opaque and the effect would silently do nothing at all. Writing
/// the coverage to alpha as well is what makes the file directly usable as a
/// `maskSource`.
///
/// Keeping gray equal to alpha costs one byte per pixel and buys two things:
/// the file is still a legible grayscale mask — so a luminance-based consumer
/// works too, and the image can be inspected in any viewer — and the two can
/// never disagree.
///
/// Two channels rather than four: at 5120x2880 this lands at roughly 0.4 MB,
/// against the ~25 MB of the foreground/background pair it replaces.
pub fn encode_mask_png(width: u32, height: u32, alpha: &[f32]) -> Result<Vec<u8>> {
    let count = width as usize * height as usize;
    if alpha.len() != count {
        bail!(
            "mask buffer holds {} samples, expected {width}x{height}",
            alpha.len()
        );
    }
    let mut pixels = vec![0u8; count * 2];
    pixels
        .par_chunks_exact_mut(2)
        .zip(alpha.par_iter())
        .for_each(|(chunk, &value)| {
            let byte = (value.clamp(0.0, 1.0) * 255.0).round() as u8;
            chunk[0] = byte;
            chunk[1] = byte;
        });
    let image = image::ImageBuffer::<LumaA<u8>, Vec<u8>>::from_raw(width, height, pixels)
        .context("cannot build the mask")?;
    encode_png(DynamicImage::ImageLumaA8(image))
}

/// Compute the bounding box `[min_x, min_y, max_x, max_y]` of non-zero alpha pixels.
/// Returns None if the entire alpha mask is empty (all values <= 0.003).
pub fn compute_bounding_box(alpha: &[f32], width: u32, height: u32) -> Option<[u32; 4]> {
    let (w, h) = (width as usize, height as usize);
    if alpha.len() != w * h || w == 0 || h == 0 {
        return None;
    }

    let row_bounds: Vec<Option<(u32, u32)>> = alpha
        .par_chunks_exact(w)
        .map(|row| {
            let mut first = None;
            let mut last = None;
            for (x, &val) in row.iter().enumerate() {
                if val > 0.003 {
                    if first.is_none() {
                        first = Some(x as u32);
                    }
                    last = Some(x as u32);
                }
            }
            first.map(|f| (f, last.unwrap()))
        })
        .collect();

    let mut min_x = u32::MAX;
    let mut max_x = 0;
    let mut min_y = u32::MAX;
    let mut max_y = 0;
    let mut has_any = false;

    for (y, bounds) in row_bounds.into_iter().enumerate() {
        if let Some((x0, x1)) = bounds {
            has_any = true;
            min_y = min_y.min(y as u32);
            max_y = max_y.max(y as u32);
            min_x = min_x.min(x0);
            max_x = max_x.max(x1);
        }
    }

    if has_any {
        Some([min_x, min_y, max_x, max_y])
    } else {
        None
    }
}

fn encode_png(image: DynamicImage) -> Result<Vec<u8>> {
    let mut buffer = Vec::new();
    image
        .write_to(&mut Cursor::new(&mut buffer), ImageFormat::Png)
        .context("cannot encode the image as PNG")?;
    Ok(buffer)
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
        assert!(
            (ratio - 1920.0 / 1080.0).abs() < 0.05,
            "ratio drifted: {ratio}"
        );

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
    fn mask_encoding_rejects_a_buffer_that_does_not_match_its_dimensions() {
        // Guards the size coupling: a mismatch would otherwise produce a
        // silently corrupted PNG.
        assert!(encode_mask_png(2, 2, &[0.0; 4]).is_ok());
        assert!(encode_mask_png(2, 2, &[0.0; 3]).is_err());
    }

    #[test]
    fn the_mask_carries_coverage_in_gray_and_alpha_alike() {
        // Gray alone would be the obvious encoding, but Qt's MultiEffect masks on
        // alpha - an Image reports alpha = 255 for a single-channel PNG, so a
        // gray-only mask would be uniformly opaque and the effect would do
        // nothing. Both channels must therefore carry the coverage, and they must
        // agree.
        let encoded = encode_mask_png(2, 1, &[0.0, 0.5]).unwrap();
        let decoded = image::load_from_memory(&encoded).unwrap();
        assert_eq!(decoded.color(), image::ColorType::La8);
        assert_eq!(decoded.to_luma_alpha8().get_pixel(1, 0).0, [128, 128]);
    }

    #[test]
    fn the_mask_carries_coverage_verbatim() {
        // The float coverage has to survive the round trip through 8 bits, or a
        // feathered edge would come out at a different width than the slider
        // asked for.
        let alpha = vec![0.0f32, 0.25, 0.5, 0.75, 1.0];
        let encoded = encode_mask_png(5, 1, &alpha).unwrap();
        let decoded = image::load_from_memory(&encoded).unwrap().to_luma_alpha8();
        let values: Vec<[u8; 2]> = decoded.pixels().map(|pixel| pixel.0).collect();
        assert_eq!(
            values,
            vec![[0, 0], [64, 64], [128, 128], [191, 191], [255, 255]]
        );
    }

    #[test]
    fn a_hard_cut_produces_a_binary_mask() {
        // With no feather there must be no intermediate values at all: partial
        // coverage is what turns a contour into a translucent band, so a mask
        // that is genuinely 0-or-255 cannot show one.
        let alpha = foreground_alpha(&[0.1f32, 0.5, 0.9], 0.5, 0.0, true);
        let encoded = encode_mask_png(3, 1, &alpha).unwrap();
        let decoded = image::load_from_memory(&encoded).unwrap().to_luma_alpha8();
        let values: Vec<[u8; 2]> = decoded.pixels().map(|pixel| pixel.0).collect();
        assert_eq!(values, vec![[0, 0], [255, 255], [255, 255]]);
    }

    #[test]
    fn refinement_is_capped_but_the_mask_is_not() {
        // The cap exists to bound the guided filter's cost. It must not reach the
        // emitted mask - that separation is the whole reason the threshold runs
        // *after* the field is lifted, so it is worth naming.
        assert_eq!(refine_size(5120, 2880), (REFINEMENT_MAX_DIMENSION, 1080));
        // Inside the cap the two coincide, so no lift happens at all.
        assert_eq!(refine_size(1280, 720), (1280, 720));
        assert_eq!(refine_size(1920, 1080), (1920, 1080));
    }

    #[test]
    fn lifting_the_field_lands_on_the_wallpaper_dimensions() {
        // The mask is always the wallpaper's own size, so the lift out of the
        // refinement cap has to produce exactly that - a mask one pixel off
        // would be scaled by the consumer and blur the whole contour.
        for (width, height) in [(5120, 2880), (3840, 1600), (1000, 1000), (4096, 512)] {
            let (refine_width, refine_height) = refine_size(width, height);
            let refined = vec![0.5f32; (refine_width * refine_height) as usize];
            let lifted = resize_cubic(&refined, refine_width, refine_height, width, height);
            assert_eq!(lifted.len(), (width * height) as usize, "{width}x{height}");
        }
    }

    #[test]
    fn compute_bounding_box_detects_subregion() {
        let mut alpha = vec![0.0f32; 10 * 10];
        alpha[2 * 10 + 3] = 0.5;
        alpha[5 * 10 + 7] = 1.0;
        let bbox = compute_bounding_box(&alpha, 10, 10);
        assert_eq!(bbox, Some([3, 2, 7, 5]));
    }

    #[test]
    fn compute_bounding_box_returns_none_for_empty() {
        let alpha = vec![0.0f32; 10 * 10];
        assert_eq!(compute_bounding_box(&alpha, 10, 10), None);
    }
}
