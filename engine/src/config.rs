//! Paths, model pinning, and pipeline constants.
//!
//! Every value that can invalidate a cache entry lives here so that changing
//! it is a deliberate, reviewable act.

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

/// Upstream model revision. Used to build the download URL.
pub const MODEL_REVISION: &str = "main";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelKind {
    DepthAnything,
    DepthAnythingV3,
    BiRefNet,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExtraFile {
    pub filename: &'static str,
    pub url: &'static str,
    pub size: u64,
    pub sha256: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ModelDescriptor {
    pub id: &'static str,
    pub name: &'static str,
    pub kind: ModelKind,
    pub size: u64,
    pub sha256: &'static str,
    pub fingerprint: &'static str,
    pub url: &'static str,
    pub directory: &'static str,
    pub filename: &'static str,
    pub extra_file: Option<ExtraFile>,
}

impl ModelDescriptor {
    pub fn total_size(&self) -> u64 {
        self.size + self.extra_file.map(|e| e.size).unwrap_or(0)
    }
}

pub const MODEL_V3_SMALL: ModelDescriptor = ModelDescriptor {
    id: "v3-small",
    name: "Depth Anything V3 Small (105MB)",
    kind: ModelKind::DepthAnythingV3,
    size: 640_691,
    sha256: "396008798244a074297fd88e450433b1357fc687f534939375c804ded86e7b2a",
    fingerprint: "396008798244a074",
    url: "https://huggingface.co/onnx-community/depth-anything-v3-small/resolve/main/onnx/model.onnx?download=true",
    directory: "models/depth-anything-v3-small",
    filename: "model.onnx",
    extra_file: Some(ExtraFile {
        filename: "model.onnx_data",
        url: "https://huggingface.co/onnx-community/depth-anything-v3-small/resolve/main/onnx/model.onnx_data?download=true",
        size: 104_702_464,
        sha256: "802bb24741e67f5bb2b369fc64d40afe11439cc895d676d658d65cfb75c9860f",
    }),
};

pub const MODEL_V3_BASE: ModelDescriptor = ModelDescriptor {
    id: "v3-base",
    name: "Depth Anything V3 Base (413MB)",
    kind: ModelKind::DepthAnythingV3,
    size: 646_912,
    sha256: "d9e7775d8b0340ce9416cfdb4356651ef72abab75eb1485f0aeefa352d78255c",
    fingerprint: "d9e7775d8b0340ce",
    url: "https://huggingface.co/onnx-community/depth-anything-v3-base/resolve/main/onnx/model.onnx?download=true",
    directory: "models/depth-anything-v3-base",
    filename: "model.onnx",
    extra_file: Some(ExtraFile {
        filename: "model.onnx_data",
        url: "https://huggingface.co/onnx-community/depth-anything-v3-base/resolve/main/onnx/model.onnx_data?download=true",
        size: 412_068_352,
        sha256: "09de4dcff3fefe48b04fedbf146151f3339e6115416a72bf9b36dee3aafd03bd",
    }),
};

pub const MODEL_V3_LARGE: ModelDescriptor = ModelDescriptor {
    id: "v3-large",
    name: "Depth Anything V3 Large (1.38GB)",
    kind: ModelKind::DepthAnythingV3,
    size: 1_093_118,
    sha256: "2c02d70b301b4b51c357e7f04c371e27b5d4a5520a0ef11b8c657627e86b4a7e",
    fingerprint: "2c02d70b301b4b51",
    url: "https://huggingface.co/onnx-community/depth-anything-v3-large/resolve/main/onnx/model.onnx?download=true",
    directory: "models/depth-anything-v3-large",
    filename: "model.onnx",
    extra_file: Some(ExtraFile {
        filename: "model.onnx_data",
        url: "https://huggingface.co/onnx-community/depth-anything-v3-large/resolve/main/onnx/model.onnx_data?download=true",
        size: 1_381_741_568,
        sha256: "3aee647d45b208cbff14f4a738737a4bd9f9e5fbce2c48e7a6db311ea807060c",
    }),
};

pub const MODEL_SMALL: ModelDescriptor = ModelDescriptor {
    id: "small",
    name: "Depth Anything V2 Small (99MB)",
    kind: ModelKind::DepthAnything,
    size: 99_060_839,
    sha256: "afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c",
    fingerprint: "afb6a5c28f3b6bf1",
    url: "https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/main/onnx/model.onnx?download=true",
    directory: "models/depth-anything-v2-small",
    filename: "model.onnx",
    extra_file: None,
};

pub const MODEL_BASE: ModelDescriptor = ModelDescriptor {
    id: "base",
    name: "Depth Anything V2 Base (389MB)",
    kind: ModelKind::DepthAnything,
    size: 388_917_010,
    sha256: "dab40f67d5ead5e0ed52acfae41a717a708b02bc57f6cb761c5de828f26a7289",
    fingerprint: "dab40f67d5ead5e0",
    url: "https://huggingface.co/onnx-community/depth-anything-v2-base/resolve/main/onnx/model.onnx?download=true",
    directory: "models/depth-anything-v2-base",
    filename: "model.onnx",
    extra_file: None,
};

pub const MODEL_LARGE: ModelDescriptor = ModelDescriptor {
    id: "large",
    name: "Depth Anything V2 Large (1.34GB)",
    kind: ModelKind::DepthAnything,
    size: 1_336_922_232,
    sha256: "a93aa89b5e92e30e0afbe0f7c3ec692b35cfca791ae9004a190fb0ca2010e905",
    fingerprint: "a93aa89b5e92e30e",
    url: "https://huggingface.co/onnx-community/depth-anything-v2-large/resolve/main/onnx/model.onnx?download=true",
    directory: "models/depth-anything-v2-large",
    filename: "model.onnx",
    extra_file: None,
};

pub const MODEL_BIREFNET_LITE: ModelDescriptor = ModelDescriptor {
    id: "birefnet-lite",
    name: "BiRefNet Lite (224MB)",
    kind: ModelKind::BiRefNet,
    size: 224_005_088,
    sha256: "5600024376f572a557870a5eb0afb1e5961636bef4e1e22132025467d0f03333",
    fingerprint: "5600024376f572a5",
    url: "https://huggingface.co/onnx-community/BiRefNet_lite-ONNX/resolve/main/onnx/model.onnx?download=true",
    directory: "models/birefnet-lite",
    filename: "model.onnx",
    extra_file: None,
};

pub const MODEL_BIREFNET: ModelDescriptor = ModelDescriptor {
    id: "birefnet",
    name: "BiRefNet General (973MB)",
    kind: ModelKind::BiRefNet,
    size: 972_666_916,
    sha256: "58f621f00f5d756097615970a88a791584600dcf7c45b18a0a6267535a1ebd3c",
    fingerprint: "58f621f00f5d7560",
    url: "https://huggingface.co/onnx-community/BiRefNet-ONNX/resolve/main/onnx/model.onnx?download=true",
    directory: "models/birefnet",
    filename: "model.onnx",
    extra_file: None,
};

pub const ALL_MODELS: &[ModelDescriptor] = &[
    MODEL_V3_SMALL,
    MODEL_V3_BASE,
    MODEL_V3_LARGE,
    MODEL_SMALL,
    MODEL_BASE,
    MODEL_LARGE,
    MODEL_BIREFNET_LITE,
    MODEL_BIREFNET,
];

pub fn default_model() -> &'static ModelDescriptor {
    &MODEL_SMALL
}

pub fn find_model(id: &str) -> Option<&'static ModelDescriptor> {
    if id.eq_ignore_ascii_case("v3") {
        return Some(&MODEL_V3_SMALL);
    }
    ALL_MODELS.iter().find(|m| m.id.eq_ignore_ascii_case(id))
}

#[allow(dead_code)]
pub const MODEL_SHA256: &str = MODEL_SMALL.sha256;
#[allow(dead_code)]
pub const MODEL_SIZE: u64 = MODEL_SMALL.size;
#[allow(dead_code)]
pub const MODEL_URL: &str = MODEL_SMALL.url;
#[allow(dead_code)]
pub const MODEL_FINGERPRINT: &str = MODEL_SMALL.fingerprint;

/// Model input is padded to a multiple of the ViT patch size.
pub const INPUT_SIZE: u32 = 518;
pub const PATCH_SIZE: u32 = 14;
pub const BIREFNET_INPUT_SIZE: u32 = 1024;

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
#[allow(dead_code)]
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

    #[allow(dead_code)]
    pub fn model(&self) -> PathBuf {
        self.model_for(default_model())
    }

    pub fn model_for(&self, descriptor: &ModelDescriptor) -> PathBuf {
        self.root.join(descriptor.directory).join(descriptor.filename)
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
        for m in ALL_MODELS {
            let dir = self.root.join(m.directory);
            std::fs::create_dir_all(&dir)
                .with_context(|| format!("cannot create {}", dir.display()))?;
        }
        for dir in [
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
