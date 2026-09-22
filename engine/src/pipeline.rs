//! The end-to-end analysis pipeline: wallpaper in, a foreground/background pair out.

use crate::cache::{self, CacheEntry};
use crate::config::{
    Paths, FILL_BLUR_FRACTION, FILL_BLUR_PASSES, FILL_DILATE_PIXELS,
    GUIDED_FILTER_EPSILON, GUIDED_FILTER_RADIUS, REFINEMENT_MAX_DIMENSION,
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
    pub model: &'static crate::config::ModelDescriptor,
}

#[derive(Debug, Clone)]
pub struct AnalyzeOutcome {
    pub foreground_path: PathBuf,
    pub background_path: PathBuf,
    pub wallpaper_path: PathBuf,
    /// Wallpaper dimensions.
    pub width: u32,
    pub height: u32,
    /// Dimensions of the emitted pair. Never larger than the wallpaper; smaller
    /// whenever the depth field is, which is the usual case for a high-resolution
    /// wallpaper.
    pub output_width: u32,
    pub output_height: u32,
    /// Whether each cache tier already held a usable artefact. A split hit
    /// short-circuits the pipeline, so the other two report what the cache
    /// holds rather than what this run read.
    pub depth_cache_hit: bool,
    pub refined_cache_hit: bool,
    pub split_cache_hit: bool,
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
    /// Split tier: fill, composite, PNG encode, cache writes.
    pub split_ms: u128,
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
    if model::state(paths, request.model)? != model::ModelState::Ready {
        // Auto-download when missing!
        model::download(paths, request.model)
            .with_context(|| format!("auto-download failed for model {}", request.model.id))?;
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
        crate::config::ModelKind::BiRefNet => (crate::config::BIREFNET_INPUT_SIZE, crate::config::BIREFNET_INPUT_SIZE),
    };
    let (output_width, output_height) = refinement_size(source_width, source_height);
    let (refine_width, refine_height) = refine_size(output_width, output_height);

    // --- the common case --------------------------------------------------
    // A cached pair is the entire answer. Nothing below reads the depth field
    // or decodes the wallpaper, so a hit costs one header read, one BLAKE3 of
    // the wallpaper, and two stats.
    let split_cache_hit = entry.split_is_cached();
    let mut source_rgb: Option<RgbImage> = None;
    // Reported from what the cache holds rather than from what this run
    // happened to read: on a split hit the other tiers are never consulted, and
    // `false` would read as "missed".
    let mut depth_cache_hit = entry.depth_path.is_file();
    let mut refined_cache_hit = entry.refined_path.is_file();

    if !split_cache_hit {
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
                let mut depth_model = DepthModel::load(&model::model_path(paths, request.model), request.model.kind)?;
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
            cache::decode_refined(&bytes, refine_width, refine_height).ok()
        }) {
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

        // --- split tier ---------------------------------------------------
        // The only stage that reads wallpaper pixels at the output resolution,
        // and therefore the only one that pays for the full decode.
        let decoded_before = timings.decode_ms;
        let stage = Instant::now();
        let source = ensure_source(&mut source_rgb, &mut timings, &request.wallpaper)?;
        let resized = if (source.width(), source.height()) == (output_width, output_height) {
            source.clone()
        } else {
            image::imageops::resize(
                source,
                output_width,
                output_height,
                image::imageops::FilterType::Lanczos3,
            )
        };
        let alpha =
            imageops::foreground_alpha(&refined, threshold, feather, crate::depth::NEAR_IS_HIGH);
        // The refined field is capped at REFINEMENT_MAX_DIMENSION; the pair is
        // not. When the two differ the alpha has to be lifted to the output
        // resolution, and bilinear is the right kernel for it: the field is a
        // smooth coverage signal, so a sharper one would only invent ringing
        // along the contour.
        let alpha = if (refine_width, refine_height) == (output_width, output_height) {
            alpha
        } else {
            imageops::resize_bilinear(
                &alpha,
                refine_width,
                refine_height,
                output_width,
                output_height,
            )
        };
        let (foreground, background) = split_at_resolution(&resized, &alpha);
        cache::atomic_write(
            &entry.foreground_path,
            &encode_foreground_png(output_width, output_height, &foreground)?,
        )?;
        cache::atomic_write(
            &entry.background_path,
            &encode_background_png(output_width, output_height, &background)?,
        )?;
        timings.split_ms =
            stage.elapsed().as_millis() - (timings.decode_ms - decoded_before);
    }

    let stage = Instant::now();
    cache::prune_all(paths)?;
    timings.prune_ms = stage.elapsed().as_millis();

    Ok(AnalyzeOutcome {
        foreground_path: entry.foreground_path,
        background_path: entry.background_path,
        wallpaper_path: request.wallpaper.clone(),
        width: source_width,
        height: source_height,
        output_width,
        output_height,
        depth_cache_hit,
        refined_cache_hit,
        split_cache_hit,
        elapsed_ms: started.elapsed().as_millis(),
        timings,
    })
}

/// Split an RGB image into an RGBA foreground and a filled-in RGB background.
///
/// The two outputs are complementary by construction: for every pixel,
/// `alpha * foreground + (1 - alpha) * background` reconstructs the original
/// image exactly, up to the fill's own approximation error inside the cut-out
/// region. That identity is what makes the pair safe to draw on separate layer
/// surfaces — any error in `alpha` shows up as a seam where the two layers meet,
/// but the composite is self-consistent everywhere else.
///
/// STRAIGHT ALPHA, NOT PREMULTIPLIED
///
/// The foreground carries the subject's own colour unchanged, with coverage in
/// the alpha channel. It is deliberately *not* premultiplied, even though that is
/// the more common interchange convention, because the consumer is QML's `Image`
/// and that samples a straight-alpha source and multiplies by alpha itself.
///
/// Measured: emitting premultiplied data makes QML apply the alpha twice, so the
/// subject renders washed out and semi-transparent — the clock behind it stays
/// visible through the silhouette instead of being occluded.
///
/// THE BACKGROUND IS FORCED, NOT CHOSEN
///
/// Straight alpha fixes the background almost everywhere. Solving the identity
/// above for `C_bg` with `C_fg == C_src` gives `C_bg == C_src` for every
/// `alpha < 1`. Only where `alpha == 1` is the equation degenerate — the
/// foreground covers completely, so any background value works. That sliver of
/// freedom is the entire point of the split: the blurred fill hides *under* the
/// opaque part of the subject.
///
/// So the fill is mixed in with a hard step at full coverage, never with the
/// soft alpha. Mixing softly reintroduces the subject into the background all
/// along the feathered rim, and the composite then adds the subject to itself —
/// measured at 37/255 of drift at half coverage, which reads as a bright halo
/// tracing the silhouette.
///
/// The background is deliberately *not* `source * (1 - alpha)`: that would leave
/// the background layer transparent wherever the subject is, so the desktop below
/// would show through and the effect would read as a hole punched in the screen.
/// Replacing the subject's region with a blurred estimate keeps the background
/// layer fully opaque, so a modest parallax offset never exposes a blank edge.
pub fn split_at_resolution(source: &RgbImage, alpha: &[f32]) -> (Vec<u8>, Vec<u8>) {
    let (width, height) = (source.width(), source.height());
    let count = (width as usize) * (height as usize);
    debug_assert_eq!(alpha.len(), count, "alpha must match the image");

    // --- the fill ---------------------------------------------------------
    // Blur before masking, not after: the region to be replaced has to be
    // sourced from pixels that are *not* the subject, so the subject is cut out
    // first and the hole is closed by blurring across it from its surroundings.
    let coverage = imageops::dilate(alpha, width, height, FILL_DILATE_PIXELS);
    let blur_radius = ((width.min(height) as f32 * FILL_BLUR_FRACTION).round() as u32).max(1);
    let blurred = imageops::box_blur_rgb(source.as_raw(), width, height, blur_radius, FILL_BLUR_PASSES);

    let mut foreground = Vec::with_capacity(count * 4);
    let mut background = Vec::with_capacity(count * 3);

    for index in 0..count {
        let pixel = &source.as_raw()[index * 3..index * 3 + 3];
        let value = alpha[index].clamp(0.0, 1.0);
        // The fill uses the dilated coverage, so it stays clear of the soft
        // edge where alpha is neither 0 nor 1.
        let filled = coverage[index].clamp(0.0, 1.0);

        // Straight alpha: the subject's colour is stored verbatim and the
        // coverage travels alongside it. See the note above — premultiplying
        // here would be applied a second time by the consumer.
        foreground.extend_from_slice(pixel);
        foreground.push((value * 255.0).round().clamp(0.0, 255.0) as u8);

        // The background's value is forced wherever the composite has to hold:
        //
        //     alpha * C_fg + (1 - alpha) * C_bg = C_src   and   C_fg = C_src
        //     =>  C_bg = C_src    for every alpha < 1
        //
        // At alpha == 1 the equation is degenerate — the foreground covers
        // completely, so any background value works. That freedom is the entire
        // point of splitting the image: the blurred fill hides *under* the
        // opaque part of the subject.
        //
        // Hence the fill is mixed in with a hard step at full coverage, never
        // with the soft alpha. Mixing softly (by `alpha` itself) reintroduces
        // the subject into the background all along the feathered rim, and the
        // composite then adds the subject to itself — measured at 37/255 of
        // drift at half coverage, which reads as a bright halo tracing the
        // silhouette.
        let covered = f32::from(filled >= 1.0);
        for channel in 0..3 {
            let source_value = pixel[channel] as f32;
            let blurred_value = blurred[index * 3 + channel] as f32;
            background.push(
                (source_value * (1.0 - covered) + blurred_value * covered)
                    .round()
                    .clamp(0.0, 255.0) as u8,
            );
        }
    }

    (foreground, background)
}

/// Encode the foreground as straight-alpha RGBA PNG.
fn encode_foreground_png(width: u32, height: u32, rgba: &[u8]) -> Result<Vec<u8>> {
    if rgba.len() != width as usize * height as usize * 4 {
        bail!(
            "foreground buffer holds {} samples, expected {width}x{height}x4",
            rgba.len()
        );
    }
    let image =
        RgbaImage::from_raw(width, height, rgba.to_vec()).context("cannot build the foreground")?;
    encode_png(DynamicImage::ImageRgba8(image))
}

/// Encode the filled-in background as RGB PNG.
///
/// RGB rather than RGBA on purpose: the background layer is fully opaque by
/// construction, and dropping the alpha channel saves a quarter of the bytes on
/// the larger of the two files.
fn encode_background_png(width: u32, height: u32, rgb: &[u8]) -> Result<Vec<u8>> {
    if rgb.len() != width as usize * height as usize * 3 {
        bail!(
            "background buffer holds {} samples, expected {width}x{height}x3",
            rgb.len()
        );
    }
    let image =
        RgbImage::from_raw(width, height, rgb.to_vec()).context("cannot build the background")?;
    encode_png(DynamicImage::ImageRgb8(image))
}

fn encode_png(image: DynamicImage) -> Result<Vec<u8>> {
    let mut buffer = Vec::new();
    image
        .write_to(&mut Cursor::new(&mut buffer), ImageFormat::Png)
        .context("cannot encode the image as PNG")?;
    Ok(buffer)
}

/// Resolution at which the split pair is emitted.
///
/// Follows `config::output_size()`, which defaults to the wallpaper's own
/// resolution. See that function for why the previous cap was removed.
fn refinement_size(source_width: u32, source_height: u32) -> (u32, u32) {
    crate::config::output_size().resolve(source_width, source_height)
}

/// Resolution at which the guided filter runs.
///
/// Bounded by `REFINEMENT_MAX_DIMENSION` and by the output size, because
/// refining above the resolution the pair is emitted at would be work whose
/// result is discarded. When the output is the wallpaper (the default) this is
/// the wallpaper itself, capped.
fn refine_size(output_width: u32, output_height: u32) -> (u32, u32) {
    let (width, height) = (output_width.max(1), output_height.max(1));
    let scale = f64::min(
        1.0,
        REFINEMENT_MAX_DIMENSION as f64 / width.max(height) as f64,
    );
    (
        ((width as f64 * scale).round() as u32).max(1),
        ((height as f64 * scale).round() as u32).max(1),
    )
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
    for directory in [
        paths.depth_cache(),
        paths.refined_cache(),
        paths.split_cache(),
    ] {
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
    fn split_carries_coverage_in_the_foreground_alpha() {
        let source = RgbImage::from_fn(2, 2, |x, y| {
            image::Rgb([(x * 100 + 10) as u8, (y * 40 + 20) as u8, 7])
        });
        let (foreground, _) = split_at_resolution(&source, &[0.0, 0.5, 1.0, 1.0]);

        assert_eq!(foreground.len(), 2 * 2 * 4);
        let alphas: Vec<u8> = foreground.chunks_exact(4).map(|p| p[3]).collect();
        assert_eq!(alphas, vec![0, 128, 255, 255]);

        // Straight alpha: every pixel keeps its own colour, including the fully
        // transparent one. Premultiplying here — the obvious-looking choice —
        // makes QML apply the alpha a second time and washes the subject out.
        // The colour must be the source's own, at *every* coverage — including
        // the half-covered pixel and the fully transparent one. Under the
        // premultiplied convention the transparent pixel would read [0, 0, 0]
        // and the half-covered one would read half its colour; that is exactly
        // the signature the consumer then applies alpha to a second time.
        for (index, expected) in [
            (0usize, [10u8, 20, 7]),
            (1, [110, 20, 7]),
            (2, [10, 60, 7]),
            (3, [110, 60, 7]),
        ] {
            assert_eq!(
                &foreground[index * 4..index * 4 + 3],
                &expected,
                "pixel {index} colour was altered"
            );
            assert_eq!(
                &foreground[index * 4 + 3],
                &alphas[index],
                "pixel {index} alpha moved"
            );
        }
    }

    #[test]
    fn split_reconstructs_the_source_when_recomposited() {
        // The defining property of the pair, stated in the convention the pair
        // actually uses: a straight-alpha foreground composited over the opaque
        // background with the standard over-operator returns the source.
        //
        //     alpha * foreground + (1 - alpha) * background == source
        //
        // Outside the fill the background is the source verbatim, so this holds
        // by construction; the test is here to catch a regression that breaks
        // the pairing — for instance mixing the fill with the soft alpha rather
        // than the hard coverage, which leaves the subject in the background and
        // double-counts it along every feathered edge.
        //
        // The fill legitimately covers more than the subject: it reads only from
        // pixels outside, so the region it overwrites is the alpha field grown by
        // `FILL_DILATE_PIXELS`. A test that demanded an exact match right up to
        // the subject's boundary would be asserting the opposite of what the
        // dilation exists to do.
        let (width, height) = (64u32, 40u32);
        let source = RgbImage::from_fn(width, height, |x, y| {
            image::Rgb([(x * 4) as u8, (y * 6) as u8, 128])
        });
        // Subject on the right half; the margin below accounts for the dilation
        // plus the blur radius (6% of 40, rounded up to 3).
        let boundary = 32usize;
        let margin = FILL_DILATE_PIXELS as usize + 4;
        let alpha: Vec<f32> = (0..(width * height) as usize)
            .map(|index| if (index % width as usize) >= boundary { 1.0 } else { 0.0 })
            .collect();
        let (foreground, background) = split_at_resolution(&source, &alpha);

        for index in 0..(width * height) as usize {
            let x = index % width as usize;
            if x + margin >= boundary && x < boundary + margin {
                // Inside the fill's reach: the background is the blurred
                // estimate there, so the identity does not apply.
                continue;
            }
            let a = alpha[index];
            for channel in 0..3 {
                let fg = foreground[index * 4 + channel] as f32;
                let bg = background[index * 3 + channel] as f32;
                let rebuilt = a * fg + (1.0 - a) * bg;
                let original = source.as_raw()[index * 3 + channel] as f32;
                assert!(
                    (rebuilt - original).abs() <= 1.5,
                    "pixel {index} (x={x}) channel {channel}: rebuilt {rebuilt} vs {original}"
                );
            }
        }
    }

    #[test]
    fn the_background_never_retains_the_subject_under_a_soft_edge() {
        // Regression for the pairing bug this file shipped once already.
        //
        // With a straight-alpha foreground the composite is
        // `alpha * fg + (1 - alpha) * bg`, so the background is forced to the
        // source value wherever `alpha < 1`. Blending the fill in by the soft
        // alpha leaves the subject sitting in the background along the feathered
        // rim; the composite then adds the subject to itself and a bright halo
        // traces the silhouette.
        //
        // A hard-edged alpha cannot see this — every pixel is 0 or 1 and the two
        // formulations coincide. The stimulus has to be a soft ramp.
        let (width, height) = (64u32, 32u32);
        let source = RgbImage::from_fn(width, height, |x, _| {
            image::Rgb([(x * 4).min(255) as u8, 30, 200])
        });
        // A one-pixel-wide feather at x == 32: 0 below, 1 above, half in between.
        let alpha: Vec<f32> = (0..(width * height) as usize)
            .map(|index| {
                let x = index % width as usize;
                match x {
                    32 => 0.5,
                    x if x > 32 => 1.0,
                    _ => 0.0,
                }
            })
            .collect();
        let (foreground, background) = split_at_resolution(&source, &alpha);

        // At the feathered column the composite must still be the source. Under
        // the soft-blend formulation the background there is a mix of the source
        // and the fill, so this drifts by O(half the local contrast).
        let index = 16 * width as usize + 32;
        assert_eq!(alpha[index], 0.5, "test premise: pixel is feathered");
        let fg = foreground[index * 4] as f32;
        let bg = background[index * 3] as f32;
        let rebuilt = 0.5 * fg + 0.5 * bg;
        let original = source.as_raw()[index * 3] as f32;
        assert!(
            (rebuilt - original).abs() <= 1.0,
            "feathered pixel rebuilt as {rebuilt}, source is {original} \
             — the background kept the subject"
        );
    }

    #[test]
    fn fill_uses_the_dilated_alpha_not_the_raw_one() {
        // At the subject's own boundary alpha is 1, so a fill keyed on it would
        // contribute nothing and the background would keep the subject exactly.
        // Keyed on the dilation it must differ from the source there.
        //
        // The source has to be something a blur cannot reproduce, or the check
        // passes vacuously: a linear ramp, for instance, is a blur fixed point,
        // so blurring it changes nothing and both formulations look identical.
        // A hard step edge is the right stimulus.
        let (width, height) = (64u32, 64u32);
        let source = RgbImage::from_fn(width, height, |x, _| {
            if x % 8 < 4 {
                image::Rgb([20, 30, 200])
            } else {
                image::Rgb([230, 210, 40])
            }
        });
        let alpha: Vec<f32> = (0..(width * height) as usize)
            .map(|index| if (index % width as usize) >= 32 { 1.0 } else { 0.0 })
            .collect();
        let (_, background) = split_at_resolution(&source, &alpha);

        // A pixel just inside the subject: alpha is 1, but the dilated coverage
        // reaches here, so the background must have been repainted.
        let index = 40 * width as usize + 34;
        assert_eq!(alpha[index], 1.0, "test premise: pixel is subject");
        assert_ne!(
            &background[index * 3..index * 3 + 3],
            &source.as_raw()[index * 3..index * 3 + 3],
            "the fill did not reach past the subject boundary"
        );
    }

    #[test]
    fn background_is_untouched_where_there_is_no_subject() {
        let (width, height) = (16u32, 16u32);
        let source = RgbImage::from_fn(width, height, |x, y| {
            image::Rgb([(x * 16) as u8, (y * 16) as u8, 200])
        });
        // Subject confined to the left eighth; the fill's dilation plus blur
        // radius reach well past it, but nowhere near the right eighth.
        let alpha: Vec<f32> = (0..(width * height) as usize)
            .map(|index| if (index % width as usize) < 2 { 1.0 } else { 0.0 })
            .collect();
        let (_, background) = split_at_resolution(&source, &alpha);

        for y in 0..height as usize {
            for x in 12..width as usize {
                let index = y * width as usize + x;
                assert_eq!(
                    &background[index * 3..index * 3 + 3],
                    &source.as_raw()[index * 3..index * 3 + 3],
                    "the fill leaked into pixel ({x},{y})"
                );
            }
        }
    }

    #[test]
    fn split_rejects_a_buffer_that_does_not_match_its_dimensions() {
        // Guards the size coupling: a mismatch would otherwise produce a
        // silently corrupted PNG.
        assert!(encode_foreground_png(2, 2, &[0u8; 16]).is_ok());
        assert!(encode_foreground_png(2, 2, &[0u8; 15]).is_err());
        assert!(encode_background_png(2, 2, &[0u8; 12]).is_ok());
        assert!(encode_background_png(2, 2, &[0u8; 11]).is_err());
    }

    #[test]
    fn foreground_png_round_trips_its_alpha() {
        let encoded = encode_foreground_png(2, 2, &[
            10, 20, 30, 0, 40, 50, 60, 128, 70, 80, 90, 255, 1, 2, 3, 64,
        ])
        .unwrap();
        let decoded = image::load_from_memory(&encoded).unwrap().to_rgba8();
        assert_eq!(decoded.dimensions(), (2, 2));
        let alphas: Vec<u8> = decoded.pixels().map(|pixel| pixel.0[3]).collect();
        assert_eq!(alphas, vec![0, 128, 255, 64]);
        // Unlike the old mask tier, the colour channels must survive: they are
        // the subject itself, not a placeholder.
        assert_eq!(decoded.get_pixel(1, 0).0, [40, 50, 60, 128]);
    }

    #[test]
    fn background_png_is_opaque_rgb() {
        // RGB, not RGBA: an alpha channel here would be a quarter more bytes
        // for a value that is 255 by construction.
        let encoded = encode_background_png(2, 1, &[10, 20, 30, 40, 50, 60]).unwrap();
        let decoded = image::load_from_memory(&encoded).unwrap();
        assert_eq!(decoded.color(), image::ColorType::Rgb8);
        assert_eq!(decoded.to_rgb8().get_pixel(1, 0).0, [40, 50, 60]);
    }

    #[test]
    fn the_output_keeps_the_wallpaper_resolution() {
        // The default. The pair carries structure above the old 1920 cap — the
        // guided filter transfers the wallpaper's luminance edges onto the
        // alpha — so capping it threw away detail the refine step recovered.
        assert_eq!(refinement_size(5120, 2880), (5120, 2880));
        assert_eq!(refinement_size(3840, 2160), (3840, 2160));
        assert_eq!(refinement_size(1920, 1080), (1920, 1080));
        assert_eq!(refinement_size(1280, 720), (1280, 720));
    }

    #[test]
    fn a_capped_output_shrinks_but_never_grows() {
        let capped = crate::config::OutputSize::Capped(1920);
        // Above the cap: follows the cap, aspect intact.
        assert_eq!(capped.resolve(5120, 2880), (1920, 1080));
        // Below the cap: untouched — the cap is a ceiling, not a target.
        assert_eq!(capped.resolve(1280, 720), (1280, 720));
        assert_eq!(capped.resolve(1920, 1080), (1920, 1080));
    }

    #[test]
    fn refinement_is_bounded_by_both_the_cap_and_the_output() {
        // The guided filter never runs above the cap, and never above the
        // resolution the pair is emitted at — refining past the output is work
        // whose result would be discarded.
        let (width, height) = refine_size(5120, 2880);
        assert_eq!(width, REFINEMENT_MAX_DIMENSION);
        assert_eq!(height, 1080);

        // An output inside the cap refines at exactly the output size, so the
        // alpha needs no lift before the split.
        assert_eq!(refine_size(1280, 720), (1280, 720));
        assert_eq!(refine_size(1920, 1080), (1920, 1080));
    }

    #[test]
    fn output_keeps_the_wallpaper_aspect_ratio() {
        // The consumer scales both images to the output with PreserveAspectCrop,
        // so a pair that is not the wallpaper's shape would be cropped wrongly —
        // and, worse, cropped differently from the other one.
        for (width, height) in [(5120, 2880), (3840, 1600), (1000, 1000), (4096, 512)] {
            let (output_width, output_height) = refinement_size(width, height);
            let expected = width as f64 / height as f64;
            let actual = output_width as f64 / output_height as f64;
            assert!(
                (actual - expected).abs() < 0.002,
                "{width}x{height} produced {output_width}x{output_height}"
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
