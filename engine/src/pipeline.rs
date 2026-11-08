//! The end-to-end analysis pipeline: wallpaper in, an occlusion mask and an
//! optional spatial asset bundle out.
//!
//! The regular depth effect produces a grayscale mask at the wallpaper's own
//! resolution. Spatial mode additionally prepares bounded display textures and depth maps
//! using the same depth inference and its own cache key. Neither output changes
//! the other: widget occlusion still draws the original wallpaper, while the
//! spatial renderer uses a softly filled background under a depth-derived matte.

use crate::cache::{self, CacheEntry};
use crate::config::{Paths, GUIDED_FILTER_EPSILON, GUIDED_FILTER_RADIUS};
use crate::depth::DepthModel;
use crate::imageops;
use crate::model;
use crate::palette;
use anyhow::{bail, Context, Result};
use image::{DynamicImage, RgbImage};
use std::fs;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// A single analysis request, mirroring the V1 CLI surface.
#[derive(Debug, Clone)]
pub struct AnalyzeRequest {
    pub wallpaper: PathBuf,
    /// Normalised depth cutoff in `0.0..=1.0`.
    pub threshold: f32,
    /// Symmetric transition half-width in `0.0..=0.5`.
    pub feather: f32,
    /// Whether to prepare the independently rendered spatial wallpaper layers.
    pub spatial: bool,
    /// Foreground model used for the spatial matte.
    pub spatial_model: &'static crate::config::ModelDescriptor,
    pub model: &'static crate::config::ModelDescriptor,
}

#[derive(Debug, Clone)]
pub struct AnalyzeOutcome {
    /// The occlusion mask, at the wallpaper's own resolution.
    pub mask_path: PathBuf,
    pub wallpaper_path: PathBuf,
    /// Wallpaper-derived palette sidecar. Always present after a successful
    /// run: the pipeline either reused a cached JSON or wrote a new one.
    pub palette_path: PathBuf,
    pub spatial_background_path: Option<PathBuf>,
    pub spatial_foreground_path: Option<PathBuf>,
    pub spatial_depth_path: Option<PathBuf>,
    pub spatial_matte_path: Option<PathBuf>,
    pub spatial_influence_path: Option<PathBuf>,
    pub spatial_error: Option<String>,
    pub spatial_warning: Option<String>,
    /// Wallpaper dimensions — also the mask's, by construction.
    pub width: u32,
    pub height: u32,
    /// Bounding box `[min_x, min_y, max_x, max_y]` of non-zero foreground alpha.
    pub bbox: Option<[u32; 4]>,
    /// Whether each cache tier already held a usable artefact. A mask hit
    /// short-circuits the pipeline, so the other two report what the cache
    /// holds rather than what this run read.
    pub depth_cache_hit: bool,
    pub refined_cache_hit: bool,
    pub mask_cache_hit: bool,
    pub palette_cache_hit: bool,
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
    /// Palette sidecar: cache read, or downsample + score + JSON encode + write.
    pub palette_ms: u128,
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
    (threshold.clamp(0.0, 1.0), feather.clamp(0.0, 0.5))
}

/// Keep an offline GrabCut fallback usable without making a transient model
/// failure permanent. Retry sooner if the model was installed in the meantime.
///
/// The warning is built from the descriptor's *name*, which is
/// "IS-Net Anime (168 MiB) unavailable (...)"; matching the whole
/// "IS-Net Anime unavailable" phrase never matched a real warning. Anchor on
/// the model family prefix instead.
fn is_isnet_fallback_warning(warning: Option<&str>) -> bool {
    warning.is_some_and(|message| {
        message.starts_with("IS-Net Anime") && message.contains("unavailable")
    })
}

fn retry_isnet_fallback(warning: Option<&str>, model_ready: bool, age: Option<Duration>) -> bool {
    is_isnet_fallback_warning(warning)
        && (model_ready || age.is_some_and(|elapsed| elapsed >= Duration::from_secs(15 * 60)))
}

pub fn analyze(paths: &Paths, request: &AnalyzeRequest) -> Result<AnalyzeOutcome> {
    let started = Instant::now();
    if !request.wallpaper.is_file() {
        bail!(
            "wallpaper is missing or unreadable: {}",
            request.wallpaper.display()
        );
    }
    // Models are provisioned explicitly (settings page / `setup`), never as a
    // side effect of analysing a wallpaper. A missing model is a clear,
    // actionable error rather than a surprise multi-hundred-megabyte download.
    if model::state(paths, request.model)? != model::ModelState::Ready {
        bail!(
            "depth model '{}' is not installed; download it with `depthscape-engine setup --model {}` or from the plugin settings",
            request.model.id,
            request.model.id
        );
    }

    let (threshold, feather) = sanitise(request.threshold, request.feather);
    paths.ensure()?;
    let _lock = GenerateLock::acquire(paths)?;

    let mut timings = Timings::default();

    let stage = Instant::now();
    let wallpaper_hash = cache::hash_file(&request.wallpaper)?;
    let entry = CacheEntry::resolve_with_fingerprint(
        paths,
        &wallpaper_hash,
        request.model.fingerprint,
        threshold,
        feather,
    );
    timings.hash_ms = stage.elapsed().as_millis();

    // Dimensions come from the file header alone. A full decode of a 5K
    // wallpaper costs ~60 ms, and only the pixel-level tiers below need it —
    // which is exactly when no mask is cached.
    let (source_width, source_height) = image::ImageReader::open(&request.wallpaper)
        .with_context(|| format!("cannot open {}", request.wallpaper.display()))?
        .with_guessed_format()
        .with_context(|| format!("cannot identify format of {}", request.wallpaper.display()))?
        .into_dimensions()
        .with_context(|| format!("cannot read {}", request.wallpaper.display()))?;
    if source_width == 0 || source_height == 0 {
        bail!("wallpaper has invalid dimensions");
    }
    timings.decode_ms = stage.elapsed().as_millis();

    let (model_width, model_height) = match request.model.kind {
        crate::config::ModelKind::DepthAnything | crate::config::ModelKind::DepthAnythingV3 => {
            imageops::inference_size(source_width, source_height)
        }
        crate::config::ModelKind::BiRefNet | crate::config::ModelKind::SpatialIsNet => (
            crate::config::BIREFNET_INPUT_SIZE,
            crate::config::BIREFNET_INPUT_SIZE,
        ),
    };
    let (refine_width, refine_height) = imageops::refine_size(source_width, source_height);

    // --- the common case --------------------------------------------------
    // A cached mask is the entire answer. Nothing below reads the depth field
    // or decodes the wallpaper, so a hit costs one header read, one BLAKE3 of
    // the wallpaper, and one stat.
    let mask_cache_hit = entry.mask_is_cached();
    let bbox_path = entry.mask_path.with_extension("bbox");
    let mut bbox: Option<[u32; 4]> = if mask_cache_hit {
        fs::read_to_string(&bbox_path)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
    } else {
        None
    };
    let mut source_rgb: Option<RgbImage> = None;
    // Reported from what the cache holds rather than from what this run
    // happened to read: on a mask hit the other tiers are never consulted, and
    // `false` would read as "missed".
    let mut depth_cache_hit = entry.depth_path.is_file();
    let mut refined_cache_hit = entry.refined_path.is_file();

    let spatial_entry = cache::SpatialCacheEntry::resolve(
        paths,
        &cache::depth_key_with_fingerprint(&wallpaper_hash, request.model.fingerprint),
        request.spatial_model.fingerprint,
    );
    let cached_warning = fs::read_to_string(&spatial_entry.complete_path)
        .ok()
        .and_then(|value| value.strip_prefix("warning\n").map(str::to_owned));
    let has_transient_warning = is_isnet_fallback_warning(cached_warning.as_deref());
    let model_ready = has_transient_warning
        && model::state(paths, &crate::config::SPATIAL_ISNET_ANIME)
            .is_ok_and(|state| state == model::ModelState::Ready);
    let marker_age = fs::metadata(&spatial_entry.complete_path)
        .ok()
        .and_then(|meta| meta.modified().ok())
        .and_then(|modified| modified.elapsed().ok());
    let recoverable_cache =
        retry_isnet_fallback(cached_warning.as_deref(), model_ready, marker_age);
    let spatial_cache_hit = request.spatial && spatial_entry.is_cached() && !recoverable_cache;
    let mut spatial_ready = spatial_cache_hit;
    let mut spatial_error = None;
    let mut spatial_warning = if spatial_cache_hit {
        cached_warning
    } else {
        None
    };
    if !mask_cache_hit || (request.spatial && !spatial_cache_hit) {
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
                    // Bicubic, matching the reference implementation: this is the
                    // only resample that feeds the network, so it is the one
                    // where interpolation quality reaches the output.
                    image::imageops::FilterType::CatmullRom,
                );
                let mut depth_model =
                    DepthModel::load(&model::model_path(paths, request.model), request.model.kind)?;
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
        let (refined, hit) = match fs::read(&entry.refined_path)
            .ok()
            .and_then(|bytes| cache::decode_refined(&bytes, refine_width, refine_height).ok())
        {
            Some(cached) => (cached, true),
            None => {
                let computed = refine_at_resolution(
                    ensure_source(&mut source_rgb, &mut timings, &request.wallpaper)?,
                    &depth,
                    model_width,
                    model_height,
                    refine_width,
                    refine_height,
                )?;
                cache::atomic_write(
                    &entry.refined_path,
                    &cache::encode_refined(refine_width, refine_height, &computed),
                )?;
                (computed, false)
            }
        };
        refined_cache_hit = hit;
        timings.refine_ms = stage.elapsed().as_millis() - (timings.decode_ms - decoded_before);

        // --- mask tier ----------------------------------------------------
        // The only stage that produces the artefact the consumer sees, and the
        // only one that reads no wallpaper pixels: everything it needs is
        // already in the refined field.
        //
        // THRESHOLD AT THE MASK'S RESOLUTION, NOT AT THE REFINEMENT'S.
        //
        // The refined field is capped at REFINEMENT_MAX_DIMENSION; the mask is
        // not. So one of the two has to be resampled onto the other's grid, and
        // *which* one is the most consequential ordering decision in this file:
        //
        //   * Resample the ALPHA. The threshold runs at 1920, so its result is
        //     already a coverage decision; the resampler then has to invent the
        //     missing 2.67x, and it can only do that by turning every step into
        //     a ramp. Measured on a 5120x2880 wallpaper: a 2.5-3.4 px
        //     semi-transparent band along the whole contour, with the source
        //     grid's staircase magnified into visible jaggies. Partial coverage
        //     is also what turns the band grey, because it blends whatever is
        //     behind the masked layer into the edge.
        //
        //   * Resample the FIELD, then threshold once. What this does. The
        //     resampler now interpolates a smooth scalar field, which is what it
        //     is good at, and the threshold runs once at full resolution over the
        //     interpolated values. The crossing lands sub-pixel accurately, so a
        //     hard cut stays hard and a feathered edge gets the width it was
        //     asked for. Verified against the reference implementation, which
        //     resolves this the same way: its `refine_depth` resizes the filtered
        //     field back to the source size (bicubic) *before* `smoothstep`.
        //
        // Cubic (Catmull-Rom) rather than bilinear, again matching the
        // reference: the field is smooth, so a cubic reconstructs its curvature
        // instead of flattening every ramp into a straight line, and the
        // crossing that follows is correspondingly better placed.
        // `resize_cubic` clamps, so the usual objection to a cubic kernel — that
        // it overshoots at local extrema and invents crossings — does not apply.
        let stage = Instant::now();
        let refined_output = if (refine_width, refine_height) == (source_width, source_height) {
            refined
        } else {
            imageops::resize_cubic(
                &refined,
                refine_width,
                refine_height,
                source_width,
                source_height,
            )
        };
        let alpha = imageops::foreground_alpha(
            &refined_output,
            threshold,
            feather,
            crate::depth::NEAR_IS_HIGH,
        );
        let computed_bbox = imageops::compute_bounding_box(&alpha, source_width, source_height);
        bbox = computed_bbox;
        if !mask_cache_hit {
            if let Ok(json) = serde_json::to_string(&computed_bbox) {
                let _ = cache::atomic_write(&bbox_path, json.as_bytes());
            }
            cache::atomic_write(
                &entry.mask_path,
                &imageops::encode_mask_png(source_width, source_height, &alpha)?,
            )?;
            timings.mask_ms = stage.elapsed().as_millis();
        }

        if request.spatial && !spatial_cache_hit {
            let result = (|| -> Result<Option<String>> {
                // A failed replacement must never leave an old completion
                // marker beside a mixture of old and new files.
                if spatial_entry.complete_path.exists() {
                    fs::remove_file(&spatial_entry.complete_path)?;
                }
                let source = ensure_source(&mut source_rgb, &mut timings, &request.wallpaper)?;
                let spatial_depth = imageops::resize_cubic(
                    &depth,
                    model_width,
                    model_height,
                    source_width,
                    source_height,
                );
                let prepared = crate::spatial_assets::prepare(
                    paths,
                    source,
                    &spatial_depth,
                    request.spatial_model,
                )?;
                cache::atomic_write(&spatial_entry.background_path, &prepared.background)?;
                cache::atomic_write(&spatial_entry.foreground_path, &prepared.foreground)?;
                cache::atomic_write(&spatial_entry.depth_path, &prepared.depth)?;
                cache::atomic_write(&spatial_entry.matte_path, &prepared.matte)?;
                cache::atomic_write(&spatial_entry.influence_path, &prepared.influence)?;
                let marker = match &prepared.warning {
                    Some(warning) => format!("warning\n{warning}"),
                    None => "complete\n".to_string(),
                };
                cache::atomic_write(&spatial_entry.complete_path, marker.as_bytes())?;
                Ok(prepared.warning)
            })();
            match result {
                Ok(warning) => {
                    spatial_ready = true;
                    spatial_warning = warning;
                }
                Err(error) => {
                    let message = format!("{error:#}");
                    eprintln!("Depthscape: spatial assets unavailable: {message}");
                    spatial_error = Some(message);
                }
            }
        }
    }

    // --- palette sidecar --------------------------------------------------
    // The palette is keyed on wallpaper hash alone (no model, no threshold,
    // no feather), so a mask regeneration on a slider change does NOT pay
    // for it, and every consumer that wants theme colours gets them from
    // the same file. Decoding lazily through `ensure_source` means a mask
    // cache hit that already paid for the decode reuses the pixels; only
    // a first-time wallpaper triggers a full decode here.
    let palette_key = cache::palette_key(&wallpaper_hash);
    let palette_path = palette::cache_path(&paths.palette_cache(), &palette_key);
    let mut palette_cache_hit = palette_path.is_file();
    if !palette_cache_hit {
        let decoded_before = timings.decode_ms;
        let stage = Instant::now();
        let rgb = ensure_source(&mut source_rgb, &mut timings, &request.wallpaper)?;
        let extracted = palette::extract(&DynamicImage::ImageRgb8(rgb.clone()));
        palette::write(&palette_path, &extracted)?;
        timings.palette_ms = stage.elapsed().as_millis() - (timings.decode_ms - decoded_before);
        palette_cache_hit = false;
    }

    let stage = Instant::now();
    cache::prune_all(paths)?;
    timings.prune_ms = stage.elapsed().as_millis();

    Ok(AnalyzeOutcome {
        mask_path: entry.mask_path,
        wallpaper_path: request.wallpaper.clone(),
        palette_path,
        spatial_background_path: if spatial_ready {
            Some(spatial_entry.background_path)
        } else {
            None
        },
        spatial_foreground_path: if spatial_ready {
            Some(spatial_entry.foreground_path)
        } else {
            None
        },
        spatial_depth_path: if spatial_ready {
            Some(spatial_entry.depth_path)
        } else {
            None
        },
        spatial_matte_path: if spatial_ready {
            Some(spatial_entry.matte_path)
        } else {
            None
        },
        spatial_influence_path: if spatial_ready {
            Some(spatial_entry.influence_path)
        } else {
            None
        },
        spatial_error,
        spatial_warning,
        width: source_width,
        height: source_height,
        bbox,
        depth_cache_hit,
        refined_cache_hit,
        mask_cache_hit,
        palette_cache_hit,
        elapsed_ms: started.elapsed().as_millis(),
        timings,
    })
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
        let decoded = image::ImageReader::open(wallpaper)
            .with_context(|| format!("cannot open {}", wallpaper.display()))?
            .with_guessed_format()
            .with_context(|| format!("cannot identify format of {}", wallpaper.display()))?
            .decode()
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

    // Cubic, matching Noctalia's Wallpaper Depth. The guided filter can only
    // redistribute detail the input already carries locally, so how the coarse
    // field is lifted to the filter's resolution bounds what the filter has to
    // work with — a flatter input gives it less to sharpen.
    let coarse = imageops::resize_cubic(
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn isnet_download_fallback_retries_after_backoff_or_model_recovery() {
        let warning = Some(
            "IS-Net Anime unavailable (network error); using depth-guided foreground segmentation",
        );
        assert!(!retry_isnet_fallback(
            warning,
            false,
            Some(Duration::from_secs(899))
        ));
        assert!(retry_isnet_fallback(
            warning,
            false,
            Some(Duration::from_secs(900))
        ));
        assert!(retry_isnet_fallback(warning, true, Some(Duration::ZERO)));
        assert!(!retry_isnet_fallback(
            Some("IS-Net Anime subject did not pass depth validation"),
            true,
            Some(Duration::from_secs(3600))
        ));
        assert!(!retry_isnet_fallback(
            None,
            true,
            Some(Duration::from_secs(3600))
        ));
    }

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

    /// Guards the ordering that v3 of the split pipeline fixed.
    ///
    /// The refined field is capped at `REFINEMENT_MAX_DIMENSION` while the emitted
    /// pair is not, so one of the two has to be resampled onto the other's grid —
    /// and the two orders are not equivalent:
    ///
    ///   * threshold at the coarse resolution, then resample the *alpha*: every
    ///     step becomes a linear ramp, because bilinear can only invent the
    ///     missing resolution, and each ramp pixel is partial coverage;
    ///   * resample the *field*, then threshold once at the output resolution:
    ///     the cut stays hard, because the threshold sees the interpolated
    ///     values and its crossing lands between two output pixels.
    ///
    /// That difference is the whole of the grey-fringe/jaggies artefact — a
    /// 2.5-3.4 px semi-transparent band along every contour versus none — so it
    /// is worth a test that fails loudly if the two are ever swapped back.
    #[test]
    fn thresholding_after_the_resample_keeps_a_hard_cut_hard() {
        // An 8x8 field stepping at x == 4, emitted onto a 32x32 grid (4x).
        let (coarse_w, coarse_h) = (8u32, 8u32);
        let (output_w, output_h) = (32u32, 32u32);
        let coarse: Vec<f32> = (0..coarse_w * coarse_h)
            .map(|index| if index % coarse_w < 4 { 0.0 } else { 1.0 })
            .collect();

        // The rejected order: threshold first, then lift the alpha.
        let alpha_resampled = imageops::resize_bilinear(
            &imageops::foreground_alpha(&coarse, 0.5, 0.0, true),
            coarse_w,
            coarse_h,
            output_w,
            output_h,
        );

        // The order under test: lift the field, then threshold once.
        let field = imageops::resize_bilinear(&coarse, coarse_w, coarse_h, output_w, output_h);
        let alpha_native = imageops::foreground_alpha(&field, 0.5, 0.0, true);

        let partial = |alpha: &[f32]| alpha.iter().filter(|v| **v > 0.001 && **v < 0.999).count();

        assert!(
            partial(&alpha_resampled) > 0,
            "resampling a thresholded alpha is expected to leave a partial-coverage ramp"
        );
        assert_eq!(
            partial(&alpha_native),
            0,
            "thresholding at the output resolution must leave no partial coverage at all"
        );
    }

    /// The same ordering, seen through the feathered case: a soft edge must be
    /// the width the user asked for, not that width multiplied by the resample
    /// factor.
    #[test]
    fn the_resample_does_not_widen_a_feathered_edge() {
        let (coarse_w, coarse_h) = (8u32, 8u32);
        let (output_w, output_h) = (32u32, 32u32);
        let coarse: Vec<f32> = (0..coarse_w * coarse_h)
            .map(|index| if index % coarse_w < 4 { 0.0 } else { 1.0 })
            .collect();
        let feather = 0.25;

        let alpha_resampled = imageops::resize_bilinear(
            &imageops::foreground_alpha(&coarse, 0.5, feather, true),
            coarse_w,
            coarse_h,
            output_w,
            output_h,
        );
        let field = imageops::resize_bilinear(&coarse, coarse_w, coarse_h, output_w, output_h);
        let alpha_native = imageops::foreground_alpha(&field, 0.5, feather, true);

        let band = |alpha: &[f32]| alpha.iter().filter(|v| **v > 0.05 && **v < 0.95).count();
        assert!(
            band(&alpha_native) < band(&alpha_resampled),
            "thresholding after the resample must not widen the band: native {} vs resampled {}",
            band(&alpha_native),
            band(&alpha_resampled)
        );
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
