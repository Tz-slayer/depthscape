//! The end-to-end analysis pipeline: wallpaper in, occlusion mask out.

use crate::cache::{self, CacheEntry};
use crate::config::{
    Paths, GUIDED_FILTER_EPSILON, GUIDED_FILTER_RADIUS, REFINEMENT_MAX_DIMENSION,
};
use crate::depth::DepthModel;
use crate::imageops;
use crate::model;
use anyhow::{bail, Context, Result};
use image::{DynamicImage, ImageFormat, RgbImage, RgbaImage};
use std::fs;
use std::io::Cursor;
use std::os::unix::io::AsRawFd;
use std::path::PathBuf;
use std::time::Instant;

/// A single analysis request, mirroring the V1 CLI surface.
#[derive(Debug, Clone)]
pub struct AnalyzeRequest {
    pub wallpaper: PathBuf,
    /// Normalised depth cutoff in `0.0..=1.0`.
    pub threshold: f32,
    /// Symmetric transition half-width in `0.0..=0.5`.
    pub feather: f32,
}

#[derive(Debug, Clone)]
pub struct AnalyzeOutcome {
    pub mask_path: PathBuf,
    pub wallpaper_path: PathBuf,
    pub width: u32,
    pub height: u32,
    pub depth_cache_hit: bool,
    pub refined_cache_hit: bool,
    pub mask_cache_hit: bool,
    pub elapsed_ms: u128,
}

/// Exclusive advisory lock, released when the process exits.
///
/// Held for the whole generate step so that a manual CLI run cannot interleave
/// with the daemon's own invocation and corrupt a cache entry.
struct GenerateLock {
    _file: fs::File,
}

impl GenerateLock {
    fn acquire(paths: &Paths) -> Result<Self> {
        let file = fs::File::create(paths.lock_file())
            .with_context(|| format!("cannot open {}", paths.lock_file().display()))?;
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
        if result != 0 {
            bail!("cannot acquire the generate lock");
        }
        Ok(Self { _file: file })
    }
}

/// Clamp user-facing parameters into the ranges the pipeline expects.
pub fn sanitise(threshold: f32, feather: f32) -> (f32, f32) {
    (
        threshold.clamp(0.0, 1.0),
        feather.clamp(0.0, 0.5),
    )
}

pub fn analyze(paths: &Paths, request: &AnalyzeRequest) -> Result<AnalyzeOutcome> {
    let started = Instant::now();
    if !request.wallpaper.is_file() {
        bail!(
            "wallpaper is missing or unreadable: {}",
            request.wallpaper.display()
        );
    }
    if model::state(paths)? != model::ModelState::Ready {
        bail!("model is missing or failed verification; run `setup` first");
    }

    let (threshold, feather) = sanitise(request.threshold, request.feather);
    paths.ensure()?;
    let _lock = GenerateLock::acquire(paths)?;

    let wallpaper_hash = cache::hash_file(&request.wallpaper)?;
    let entry = CacheEntry::resolve(paths, &wallpaper_hash, threshold, feather);

    let source = image::open(&request.wallpaper)
        .with_context(|| format!("cannot decode {}", request.wallpaper.display()))?;
    let (source_width, source_height) = (source.width(), source.height());
    if source_width == 0 || source_height == 0 {
        bail!("wallpaper has invalid dimensions");
    }
    let source_rgb: RgbImage = source.to_rgb8();

    let (model_width, model_height) = imageops::inference_size(source_width, source_height);

    // --- depth tier -------------------------------------------------------
    let (depth, depth_cache_hit) = match fs::read(&entry.depth_path)
        .ok()
        .and_then(|bytes| cache::decode_depth(&bytes, model_width, model_height).ok())
    {
        Some(cached) => (cached, true),
        None => {
            let resized = image::imageops::resize(
                &source_rgb,
                model_width,
                model_height,
                image::imageops::FilterType::Triangle,
            );
            let mut depth_model = DepthModel::load(&model::model_path(paths))?;
            let predicted = depth_model.infer(resized.as_raw(), model_width, model_height)?;
            cache::atomic_write(
                &entry.depth_path,
                &cache::encode_depth(model_width, model_height, &predicted),
            )?;
            (predicted, false)
        }
    };

    // --- refined tier -----------------------------------------------------
    // Refinement depends only on the wallpaper and the depth field, never on
    // threshold or feather. Caching it here is what makes the sliders feel
    // instant: without it, every nudge would pay for a full guided filter.
    let (refinement_width, refinement_height) = refinement_size(source_width, source_height);
    let refined = match fs::read(&entry.refined_path)
        .ok()
        .and_then(|bytes| cache::decode_refined(&bytes, refinement_width, refinement_height).ok())
    {
        Some(cached) => (cached, true),
        None => {
            let computed = refine_at_resolution(
                &source_rgb,
                &depth,
                model_width,
                model_height,
                refinement_width,
                refinement_height,
            )?;
            cache::atomic_write(
                &entry.refined_path,
                &cache::encode_refined(refinement_width, refinement_height, &computed),
            )?;
            (computed, false)
        }
    };
    let (refined, refined_cache_hit) = refined;

    // --- mask tier --------------------------------------------------------
    let mask_cache_hit = entry.mask_path.is_file();
    if !mask_cache_hit {
        let full_resolution = if (refinement_width, refinement_height) == (source_width, source_height)
        {
            refined
        } else {
            imageops::resize_bilinear(
                &refined,
                refinement_width,
                refinement_height,
                source_width,
                source_height,
            )
        };
        let alpha =
            imageops::foreground_alpha(&full_resolution, threshold, feather, crate::depth::NEAR_IS_HIGH);
        let buffer = encode_mask_png(source_width, source_height, &imageops::alpha_to_u8(&alpha))?;
        cache::atomic_write(&entry.mask_path, &buffer)?;
    }

    cache::prune_all(paths)?;

    Ok(AnalyzeOutcome {
        mask_path: entry.mask_path,
        wallpaper_path: request.wallpaper.clone(),
        width: source_width,
        height: source_height,
        depth_cache_hit,
        refined_cache_hit,
        mask_cache_hit,
        elapsed_ms: started.elapsed().as_millis(),
    })
}

/// Encode an 8-bit mask as a PNG whose **alpha channel** carries the coverage.
///
/// Emitted as RGBA rather than greyscale on purpose: the QML side masks the
/// foreground layer with MultiEffect, which reads the alpha channel. A
/// greyscale PNG arrives with alpha = 1 everywhere and would occlude the entire
/// screen. RGB is set to white so the file reads correctly as an overlay.
fn encode_mask_png(width: u32, height: u32, alpha: &[u8]) -> Result<Vec<u8>> {
    let mut rgba = Vec::with_capacity(alpha.len() * 4);
    for value in alpha {
        rgba.extend_from_slice(&[255, 255, 255, *value]);
    }
    let image: RgbaImage =
        RgbaImage::from_raw(width, height, rgba).context("cannot build the mask image")?;
    let mut buffer = Vec::new();
    DynamicImage::ImageRgba8(image)
        .write_to(&mut Cursor::new(&mut buffer), ImageFormat::Png)
        .context("cannot encode the mask as PNG")?;
    Ok(buffer)
}

/// Resolution at which the guided filter runs.
///
/// Capped so a 5K wallpaper does not pay for a full-resolution filter; the depth
/// field carries no detail above this anyway.
fn refinement_size(source_width: u32, source_height: u32) -> (u32, u32) {
    let scale = f64::min(
        1.0,
        REFINEMENT_MAX_DIMENSION as f64 / source_width.max(source_height) as f64,
    );
    (
        ((source_width as f64 * scale).round() as u32).max(1),
        ((source_height as f64 * scale).round() as u32).max(1),
    )
}

/// Upsample the depth field to the refinement resolution while snapping its
/// edges to the wallpaper's own luminance edges.
///
/// Order matters: the coarse depth is upsampled first, then filtered. Filtering
/// at source resolution would be far more expensive for no visible gain, because
/// the depth field carries no detail above the refinement cap.
fn refine_at_resolution(
    source_rgb: &RgbImage,
    depth: &[f32],
    model_width: u32,
    model_height: u32,
    refinement_width: u32,
    refinement_height: u32,
) -> Result<Vec<f32>> {
    let (source_width, source_height) = (source_rgb.width(), source_rgb.height());
    let luma = DynamicImage::ImageRgb8(source_rgb.clone()).to_luma8();
    let guide_image = if (refinement_width, refinement_height) == (source_width, source_height) {
        luma
    } else {
        image::imageops::resize(
            &luma,
            refinement_width,
            refinement_height,
            image::imageops::FilterType::Lanczos3,
        )
    };
    let guide: Vec<f32> = guide_image
        .as_raw()
        .iter()
        .map(|value| *value as f32 / 255.0)
        .collect();

    let coarse = imageops::resize_bilinear(
        depth,
        model_width,
        model_height,
        refinement_width,
        refinement_height,
    );
    Ok(imageops::guided_filter(
        &guide,
        &coarse,
        refinement_width,
        refinement_height,
        GUIDED_FILTER_RADIUS,
        GUIDED_FILTER_EPSILON,
    ))
}

/// Remove every cached artefact. Model files are untouched.
pub fn clear_cache(paths: &Paths) -> Result<usize> {
    let mut removed = 0;
    for directory in [paths.depth_cache(), paths.refined_cache(), paths.mask_cache()] {
        if let Ok(entries) = fs::read_dir(&directory) {
            for entry in entries.flatten() {
                if entry.path().is_file() && fs::remove_file(entry.path()).is_ok() {
                    removed += 1;
                }
            }
        }
    }
    Ok(removed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitise_clamps_out_of_range_parameters() {
        assert_eq!(sanitise(-1.0, -1.0), (0.0, 0.0));
        assert_eq!(sanitise(2.0, 2.0), (1.0, 0.5));
        assert_eq!(sanitise(0.3, 0.08), (0.3, 0.08));
    }

    #[test]
    fn feather_stays_symmetric_around_the_threshold() {
        let (threshold, feather) = sanitise(0.4, 0.1);
        let half = feather * 0.5;
        let alpha = imageops::smoothstep(&[0.35, 0.4, 0.45], threshold - half, threshold + half);
        assert_eq!(alpha[0], 0.0);
        assert!((alpha[1] - 0.5).abs() < 1e-6);
        assert_eq!(alpha[2], 1.0);
    }

    #[test]
    fn mask_png_carries_coverage_in_the_alpha_channel() {
        let encoded = encode_mask_png(2, 2, &[0, 128, 255, 64]).unwrap();
        let decoded = image::load_from_memory(&encoded).unwrap().to_rgba8();
        assert_eq!(decoded.dimensions(), (2, 2));
        let alphas: Vec<u8> = decoded.pixels().map(|pixel| pixel.0[3]).collect();
        assert_eq!(alphas, vec![0, 128, 255, 64]);
        for pixel in decoded.pixels() {
            assert_eq!(&pixel.0[0..3], &[255, 255, 255], "RGB must stay white");
        }
    }

    #[test]
    fn refinement_size_caps_the_long_edge() {
        assert_eq!(refinement_size(1920, 1080), (1920, 1080));
        assert_eq!(refinement_size(960, 540), (960, 540));
        let (width, height) = refinement_size(5120, 2880);
        assert_eq!(width, REFINEMENT_MAX_DIMENSION);
        assert_eq!(height, 1080);
        assert_eq!(width as f64 / height as f64, 5120.0 / 2880.0);
    }

    #[test]
    fn refine_returns_a_field_at_the_requested_resolution() {
        let source = RgbImage::from_fn(64, 48, |x, y| {
            image::Rgb([(x * 4) as u8, (y * 5) as u8, 128])
        });
        let depth = vec![0.5f32; 32 * 32];
        let refined = refine_at_resolution(&source, &depth, 32, 32, 64, 48).unwrap();
        assert_eq!(refined.len(), 64 * 48);
    }

    #[test]
    fn refine_is_independent_of_the_mask_parameters() {
        // The refined field must not be a function of threshold or feather,
        // otherwise caching it under the depth key alone would be unsound.
        let source = RgbImage::from_fn(32, 32, |x, y| image::Rgb([x as u8 * 8, y as u8 * 8, 64]));
        let depth: Vec<f32> = (0..16 * 16).map(|index| index as f32 / 255.0).collect();
        let first = refine_at_resolution(&source, &depth, 16, 16, 32, 32).unwrap();
        let second = refine_at_resolution(&source, &depth, 16, 16, 32, 32).unwrap();
        assert_eq!(first, second);
    }
}
