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
use std::path::{Path, PathBuf};
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
    /// Wallpaper dimensions.
    pub width: u32,
    pub height: u32,
    /// Mask dimensions. Never larger than the wallpaper; smaller whenever the
    /// depth field is, which is the usual case for a high-resolution wallpaper.
    pub mask_width: u32,
    pub mask_height: u32,
    /// Whether each cache tier already held a usable artefact. A mask hit
    /// short-circuits the pipeline, so the other two report what the cache
    /// holds rather than what this run read.
    pub depth_cache_hit: bool,
    pub refined_cache_hit: bool,
    pub mask_cache_hit: bool,
    pub elapsed_ms: u128,
    pub timings: Timings,
}

/// Per-stage wall-clock cost of one analysis, in milliseconds.
///
/// Reported alongside the result so that a slow run can be attributed without
/// rebuilding the engine with instrumentation. The stages are mutually
/// exclusive and add up to `total_ms` minus process startup.
#[derive(Debug, Clone, Default)]
pub struct Timings {
    /// Hashing the wallpaper to build the cache key.
    pub hash_ms: u128,
    /// Reading the wallpaper: the header for its dimensions, plus a full decode
    /// if and only if a pixel-level stage ran. Accumulates, because the decode
    /// is deferred until something asks for it.
    pub decode_ms: u128,
    /// Depth tier: cache read, or resize + inference + cache write.
    pub depth_ms: u128,
    /// Refined tier: cache read, or guided filter + cache write.
    pub refine_ms: u128,
    /// Mask tier: threshold, PNG encode, cache write.
    pub mask_ms: u128,
    /// Pruning the caches down to their retention limits.
    pub prune_ms: u128,
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

    let mut timings = Timings::default();

    let stage = Instant::now();
    let wallpaper_hash = cache::hash_file(&request.wallpaper)?;
    let entry = CacheEntry::resolve(paths, &wallpaper_hash, threshold, feather);
    timings.hash_ms = stage.elapsed().as_millis();

    // Dimensions come from the file header alone. A full decode of a 5K
    // wallpaper costs ~60 ms, and only the pixel-level tiers below need it —
    // which is exactly when no mask is cached.
    let stage = Instant::now();
    let (source_width, source_height) = image::image_dimensions(&request.wallpaper)
        .with_context(|| format!("cannot read {}", request.wallpaper.display()))?;
    if source_width == 0 || source_height == 0 {
        bail!("wallpaper has invalid dimensions");
    }
    timings.decode_ms = stage.elapsed().as_millis();

    let (model_width, model_height) = imageops::inference_size(source_width, source_height);
    let (refinement_width, refinement_height) = refinement_size(source_width, source_height);
    let (mask_width, mask_height) = mask_size(source_width, source_height);

    // --- the common case --------------------------------------------------
    // A cached mask is the entire answer. Nothing below reads the depth field
    // or decodes the wallpaper, so a hit costs one header read, one BLAKE3 of
    // the wallpaper, and a stat.
    let mask_cache_hit = entry.mask_path.is_file();
    let mut source_rgb: Option<RgbImage> = None;
    // Reported from what the cache holds rather than from what this run
    // happened to read: on a mask hit the other tiers are never consulted, and
    // `false` would read as "missed".
    let mut depth_cache_hit = entry.depth_path.is_file();
    let mut refined_cache_hit = entry.refined_path.is_file();

    if !mask_cache_hit {
        // --- depth tier ---------------------------------------------------
        // A lazy decode is charged to `decode_ms`, not to the tier that
        // happened to need it, so the stages stay mutually exclusive.
        let decoded_before = timings.decode_ms;
        let stage = Instant::now();
        let (depth, hit) = match fs::read(&entry.depth_path)
            .ok()
            .and_then(|bytes| cache::decode_depth(&bytes, model_width, model_height).ok())
        {
            Some(cached) => (cached, true),
            None => {
                let resized = image::imageops::resize(
                    ensure_source(&mut source_rgb, &mut timings, &request.wallpaper)?,
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
        depth_cache_hit = hit;
        timings.depth_ms = stage.elapsed().as_millis() - (timings.decode_ms - decoded_before);

        // --- refined tier -------------------------------------------------
        // Refinement depends only on the wallpaper and the depth field, never
        // on threshold or feather. Caching it here is what makes the sliders
        // feel instant: without it, every nudge would pay for a full guided
        // filter.
        let decoded_before = timings.decode_ms;
        let stage = Instant::now();
        let (refined, hit) = match fs::read(&entry.refined_path).ok().and_then(|bytes| {
            cache::decode_refined(&bytes, refinement_width, refinement_height).ok()
        }) {
            Some(cached) => (cached, true),
            None => {
                let computed = refine_at_resolution(
                    ensure_source(&mut source_rgb, &mut timings, &request.wallpaper)?,
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
        refined_cache_hit = hit;
        timings.refine_ms = stage.elapsed().as_millis() - (timings.decode_ms - decoded_before);

        // --- mask tier ----------------------------------------------------
        // Straight from the refined field: it already carries every bit of
        // detail the mask can express, so there is nothing to upsample.
        let stage = Instant::now();
        let alpha =
            imageops::foreground_alpha(&refined, threshold, feather, crate::depth::NEAR_IS_HIGH);
        let buffer = encode_mask_png(mask_width, mask_height, &imageops::alpha_to_u8(&alpha))?;
        cache::atomic_write(&entry.mask_path, &buffer)?;
        timings.mask_ms = stage.elapsed().as_millis();
    }

    let stage = Instant::now();
    cache::prune_all(paths)?;
    timings.prune_ms = stage.elapsed().as_millis();

    Ok(AnalyzeOutcome {
        mask_path: entry.mask_path,
        wallpaper_path: request.wallpaper.clone(),
        width: source_width,
        height: source_height,
        mask_width,
        mask_height,
        depth_cache_hit,
        refined_cache_hit,
        mask_cache_hit,
        elapsed_ms: started.elapsed().as_millis(),
        timings,
    })
}

/// Encode an 8-bit mask as a PNG whose **alpha channel** carries the coverage.
///
/// Emitted as RGBA rather than greyscale on purpose: the QML side masks the
/// foreground layer with MultiEffect, which reads the alpha channel. A
/// greyscale PNG arrives with alpha = 1 everywhere and would occlude the entire
/// screen. RGB is set to white so the file reads correctly as an overlay.
fn encode_mask_png(width: u32, height: u32, alpha: &[u8]) -> Result<Vec<u8>> {
    if alpha.len() != width as usize * height as usize {
        bail!(
            "mask buffer holds {} samples, expected {width}x{height}",
            alpha.len()
        );
    }
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

/// Resolution at which the occlusion mask is emitted.
///
/// The mask is a pointwise function of the refined depth field, so it cannot
/// carry detail that field does not have. Emitting it at the wallpaper's own
/// resolution therefore buys nothing and costs a great deal: on a 5K wallpaper
/// the mask was seven times the pixels of the field it came from, all of it
/// upsampled, PNG-encoded, written to disk, read back and uploaded to the GPU.
/// The consumer scales the mask to the output regardless, and does it on the
/// GPU for free, so the mask follows the depth field instead.
fn mask_size(source_width: u32, source_height: u32) -> (u32, u32) {
    refinement_size(source_width, source_height)
}

/// Decode the wallpaper to RGB, at most once per invocation.
///
/// Deferred rather than eager because a full decode is the most expensive step
/// a cache hit would otherwise still pay for. Only the depth and refinement
/// tiers read wallpaper pixels, and neither runs when the mask is cached — nor
/// when the refined field is, which is the sliders' fast path.
fn ensure_source<'a>(
    slot: &'a mut Option<RgbImage>,
    timings: &mut Timings,
    wallpaper: &Path,
) -> Result<&'a RgbImage> {
    if slot.is_none() {
        let stage = Instant::now();
        let decoded = image::open(wallpaper)
            .with_context(|| format!("cannot decode {}", wallpaper.display()))?;
        *slot = Some(decoded.to_rgb8());
        timings.decode_ms += stage.elapsed().as_millis();
    }
    Ok(slot.as_ref().expect("filled just above"))
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
    fn mask_never_out_resolves_the_depth_field_it_comes_from() {
        // Above the cap the mask follows the refinement size, so a 5K wallpaper
        // stops paying for a 5K PNG.
        assert_eq!(mask_size(5120, 2880), (REFINEMENT_MAX_DIMENSION, 1080));
        // Below the cap nothing is dropped: the mask is the wallpaper.
        assert_eq!(mask_size(1920, 1080), (1920, 1080));
        assert_eq!(mask_size(1280, 720), (1280, 720));
    }

    #[test]
    fn mask_keeps_the_wallpaper_aspect_ratio() {
        // The consumer scales the mask to the output with PreserveAspectCrop,
        // so a mask that is not the wallpaper's shape would be cropped wrongly.
        for (width, height) in [(5120, 2880), (3840, 1600), (1000, 1000), (4096, 512)] {
            let (mask_width, mask_height) = mask_size(width, height);
            let expected = width as f64 / height as f64;
            let actual = mask_width as f64 / mask_height as f64;
            assert!(
                (actual - expected).abs() < 0.002,
                "{width}x{height} produced {mask_width}x{mask_height}"
            );
        }
    }

    #[test]
    fn ensure_source_decodes_at_most_once() {
        let dir = std::env::temp_dir().join(format!("depthscape-source-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("wall.png");
        RgbImage::from_fn(4, 3, |x, y| image::Rgb([x as u8, y as u8, 7]))
            .save(&path)
            .unwrap();

        let mut slot = None;
        let mut timings = Timings::default();
        ensure_source(&mut slot, &mut timings, &path).unwrap();

        // Deleting the file proves the second call never goes back to disk.
        fs::remove_file(&path).unwrap();
        let again = ensure_source(&mut slot, &mut timings, &path).unwrap();
        assert_eq!(again.dimensions(), (4, 3));
        assert_eq!(again.as_raw().len(), 4 * 3 * 3);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn mask_encoding_rejects_a_buffer_that_does_not_match_its_dimensions() {
        // Guards the mask_size / alpha-length coupling: a mismatch would
        // otherwise produce a silently corrupted PNG.
        assert!(encode_mask_png(2, 2, &[0, 128, 255, 64]).is_ok());
        assert!(encode_mask_png(2, 2, &[0, 128, 255]).is_err());
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
