//! Paths, model pinning, and pipeline constants.
//!
//! Every value that can invalidate a cache entry lives here so that changing
//! it is a deliberate, reviewable act.

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

/// Upstream model revision. Used to build the download URL.
pub const MODEL_REVISION: &str = "4472b7362082ad9968fee890ca0f1e5aca36b93d";

/// SHA-256 published for the upstream artifact.
///
/// Deliberately SHA-256 rather than BLAKE3: it is the value users can verify
/// against the Hugging Face page by hand. Internal cache keys use BLAKE3.
pub const MODEL_SHA256: &str = "afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c";

/// Exact byte size of the upstream artifact.
pub const MODEL_SIZE: u64 = 99_060_839;

pub const MODEL_URL: &str = "https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/4472b7362082ad9968fee890ca0f1e5aca36b93d/onnx/model.onnx?download=true";

/// Short fingerprint mixed into every cache key.
pub const MODEL_FINGERPRINT: &str = "afb6a5c28f3b6bf1";

/// Model input is padded to a multiple of the ViT patch size.
pub const INPUT_SIZE: u32 = 518;
pub const PATCH_SIZE: u32 = 14;

/// Bump when the depth post-processing changes (invalidates depth + refined).
pub const DEPTH_PIPELINE_VERSION: u32 = 1;
/// Bump when the split output changes (invalidates foreground + background).
///
/// v1: the engine emits a pair of images — `foreground.png` (straight-alpha
/// RGBA, subject only) and `background.png` (the wallpaper with the subject
/// region filled in) — instead of a single occlusion mask.
///
/// v2: the pair is emitted at the wallpaper's own resolution instead of being
/// capped at `REFINEMENT_MAX_DIMENSION`. The cap never bought what its comment
/// claimed — the alpha field does carry structure above 1920, because the guided
/// filter transfers the wallpaper's own luminance edges onto it — and it cost a
/// second, coarser resample on the GPU at composite time.
pub const SPLIT_PIPELINE_VERSION: u32 = 2;

/// The resolution the emitted images are produced at.
///
/// * `Original` — the wallpaper's own size. One resample from source to output,
///   then a 1:1 blit for an output whose resolution matches the wallpaper. This
///   is the default: it is the only setting that does not throw away detail the
///   refine step went to the trouble of recovering.
/// * `Capped(n)` — never larger than `n` on the long edge, and never larger than
///   the wallpaper. For a machine where the PNG encode or the resident texture
///   is the binding constraint rather than quality.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputSize {
    Original,
    Capped(u32),
}

impl OutputSize {
    /// Resolve against a wallpaper's dimensions.
    pub fn resolve(self, source_width: u32, source_height: u32) -> (u32, u32) {
        let (width, height) = (source_width.max(1), source_height.max(1));
        let cap = match self {
            OutputSize::Original => return (width, height),
            OutputSize::Capped(cap) => cap,
        };
        let scale = f64::min(1.0, cap as f64 / width.max(height) as f64);
        (
            ((width as f64 * scale).round() as u32).max(1),
            ((height as f64 * scale).round() as u32).max(1),
        )
    }
}

/// Default output size.
///
/// Overridable at runtime through `$DEPTHSCAPE_OUTPUT_MAX_DIMENSION`, which
/// selects `Capped(n)` — the escape hatch for a machine where the PNG encode or
/// the resident GPU texture is the binding constraint rather than quality.
/// There is deliberately no way to ask for *more* than the wallpaper.
pub fn output_size() -> OutputSize {
    match std::env::var_os("DEPTHSCAPE_OUTPUT_MAX_DIMENSION") {
        Some(value) => match value.to_string_lossy().parse::<u32>() {
            Ok(cap) if cap > 0 => OutputSize::Capped(cap),
            _ => OutputSize::Original,
        },
        None => OutputSize::Original,
    }
}

/// Guided-filter refinement is capped at this long edge to bound cost.
///
/// This is a *cost* ceiling on the refine step, NOT a ceiling on the emitted
/// images — those follow `OUTPUT_SIZE`. Raising it makes the refinement slower
/// in exchange for a guide image with more real resolution to snap edges to;
/// lowering it does not shrink the output, only the fidelity of the edges.
///
/// Kept at 1920 so that the common case — a wallpaper no larger than this —
/// runs the filter at exactly the resolution it will be displayed at.
pub const REFINEMENT_MAX_DIMENSION: u32 = 1920;
pub const GUIDED_FILTER_RADIUS: u32 = 8;
pub const GUIDED_FILTER_EPSILON: f32 = 0.001;

/// Radius, as a fraction of the image's short edge, of the blur that fills in
/// the region the subject was cut out of.
///
/// Large on purpose: the fill has to read as out-of-focus background, not as a
/// smeared copy of the subject. At 6% of a 1080px short edge the radius is 65px,
/// which is far wider than any feature the subject could leave behind.
pub const FILL_BLUR_FRACTION: f32 = 0.06;

/// Number of box-filter passes used to approximate a Gaussian.
///
/// Three passes converge to within ~3% of a true Gaussian, which is invisible
/// here — the fill is deliberately low-detail, so approximating it is free.
pub const FILL_BLUR_PASSES: u32 = 3;

/// Iterations of the dilation that grows the cut-out region before it is filled.
///
/// The fill reads only from pixels *outside* the subject, so the region it
/// replaces has to be grown first: at the subject's own boundary the alpha ramp
/// is half-transparent, and filling right up to it would let the blur average in
/// the very pixels being removed — a bright halo tracing the subject.
pub const FILL_DILATE_PIXELS: u32 = 4;

/// LRU retention for the cache tiers.
///
/// The split pair is by far the largest per entry (two full images at refinement
/// resolution), so it is kept smallest.
pub const DEPTH_CACHE_LIMIT: usize = 8;
pub const REFINED_CACHE_LIMIT: usize = 4;
pub const SPLIT_CACHE_LIMIT: usize = 8;

/// Relative layout inside the plugin data directory.
pub const DIR_MODEL: &str = "models/depth-anything-v2-small";
pub const DIR_DEPTH_CACHE: &str = "cache/depth";
pub const DIR_REFINED_CACHE: &str = "cache/refined";
pub const DIR_SPLIT_CACHE: &str = "cache/split";
pub const DIR_RUNTIME: &str = "runtime";

/// Resolved filesystem layout for one engine invocation.
#[derive(Debug, Clone)]
pub struct Paths {
    root: PathBuf,
}

impl Paths {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// `$XDG_DATA_HOME/depthscape`, falling back to `~/.local/share/depthscape`.
    pub fn default_root() -> Result<PathBuf> {
        if let Some(value) = std::env::var_os("DEPTHSCAPE_DATA_DIR") {
            return Ok(PathBuf::from(value));
        }
        if let Some(value) = std::env::var_os("XDG_DATA_HOME") {
            return Ok(PathBuf::from(value).join("depthscape"));
        }
        let home = std::env::var_os("HOME").context("HOME is not set")?;
        Ok(PathBuf::from(home).join(".local/share/depthscape"))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn model(&self) -> PathBuf {
        self.root.join(DIR_MODEL).join("model.onnx")
    }

    pub fn depth_cache(&self) -> PathBuf {
        self.root.join(DIR_DEPTH_CACHE)
    }

    pub fn refined_cache(&self) -> PathBuf {
        self.root.join(DIR_REFINED_CACHE)
    }

    pub fn split_cache(&self) -> PathBuf {
        self.root.join(DIR_SPLIT_CACHE)
    }

    pub fn runtime(&self) -> PathBuf {
        self.root.join(DIR_RUNTIME)
    }

    pub fn lock_file(&self) -> PathBuf {
        self.runtime().join("generate.lock")
    }

    pub fn ensure(&self) -> Result<()> {
        for dir in [
            self.root.join(DIR_MODEL),
            self.depth_cache(),
            self.refined_cache(),
            self.split_cache(),
            self.runtime(),
        ] {
            std::fs::create_dir_all(&dir)
                .with_context(|| format!("cannot create {}", dir.display()))?;
        }
        Ok(())
    }
}
