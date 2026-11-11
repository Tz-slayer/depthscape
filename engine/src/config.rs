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
    SpatialIsNet,
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

/// Only three depth estimators are offered: the Depth Anything V2 family.
/// V3 and BiRefNet are not depth-model options for this plugin; the BiRefNet
/// descriptors below exist solely as optional spatial foreground segmenters.
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

/// The spatial foreground model is independent from the selected depth model.
pub const SPATIAL_ISNET_GENERAL: ModelDescriptor = ModelDescriptor {
    id: "spatial-isnet",
    name: "IS-Net General (170 MiB)",
    kind: ModelKind::SpatialIsNet,
    size: 178_648_008,
    sha256: "60920e99c45464f2ba57bee2ad08c919a52bbf852739e96947fbb4358c0d964a",
    fingerprint: "60920e99c45464f2",
    url: "https://github.com/danielgatis/rembg/releases/download/v0.0.0/isnet-general-use.onnx",
    directory: "models/isnet-general",
    filename: "isnet-general-use.onnx",
    extra_file: None,
};

pub const SPATIAL_ISNET_ANIME: ModelDescriptor = ModelDescriptor {
    id: "spatial-isnet-anime",
    name: "IS-Net Anime (168 MiB)",
    kind: ModelKind::SpatialIsNet,
    size: 176_069_933,
    sha256: "f15622d853e8260172812b657053460e20806f04b9e05147d49af7bed31a6e99",
    fingerprint: "f15622d853e82601",
    url: "https://github.com/danielgatis/rembg/releases/download/v0.0.0/isnet-anime.onnx",
    directory: "models/isnet-anime",
    filename: "isnet-anime.onnx",
    extra_file: None,
};

/// The complete set of depth estimators this plugin offers. `status` reports
/// exactly these, `setup` only downloads these (plus spatial foreground
/// models), and the settings page must expose nothing else.
pub const ALL_MODELS: &[ModelDescriptor] = &[MODEL_SMALL, MODEL_BASE, MODEL_LARGE];

pub fn default_model() -> &'static ModelDescriptor {
    &MODEL_SMALL
}

/// Resolve any model that can be fetched with `setup --model <id>`.
///
/// Depth models come first and are limited to the three V2 variants. Spatial
/// foreground segmenters are not depth estimators — they never appear in the
/// depth-model picker — but they still have to be downloadable on demand for
/// the optional spatial mode.
pub fn find_model(id: &str) -> Option<&'static ModelDescriptor> {
    ALL_MODELS
        .iter()
        .find(|m| m.id.eq_ignore_ascii_case(id))
        .or_else(|| find_spatial_model(id))
}

/// Foreground models that may produce the spatial matte. The depth models are
/// deliberately excluded: they estimate a field, they do not cut a subject.
pub const SPATIAL_MODELS: &[&ModelDescriptor] = &[
    &SPATIAL_ISNET_GENERAL,
    &SPATIAL_ISNET_ANIME,
    &MODEL_BIREFNET_LITE,
    &MODEL_BIREFNET,
];

pub fn find_spatial_model(id: &str) -> Option<&'static ModelDescriptor> {
    let id = if id.eq_ignore_ascii_case("isnet-anime") {
        SPATIAL_ISNET_ANIME.id
    } else if id.eq_ignore_ascii_case("isnet") || id.eq_ignore_ascii_case("isnet-general") {
        SPATIAL_ISNET_GENERAL.id
    } else {
        id
    };
    SPATIAL_MODELS
        .iter()
        .copied()
        .find(|model| model.id.eq_ignore_ascii_case(id))
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
///
/// v2: non-finite model samples are replaced with neutral mid-depth values and
/// extreme finite ranges are normalised without overflowing.
pub const DEPTH_PIPELINE_VERSION: u32 = 2;
/// Bump when the emitted mask changes.
///
/// The engine produces exactly one artefact per wallpaper: a single-channel
/// 8-bit grayscale occlusion mask at the wallpaper's own resolution. There is no
/// foreground/background pair — the mask is applied by the consumer, which draws
/// the wallpaper once and erases the desktop widgets where the mask says the
/// scene is near. That is the same division of labour the reference
/// implementation uses, and it removes the inpainting step that a two-image
/// split required.
///
/// The version is deliberately restarted at 1 rather than continuing the retired
/// `SPLIT_PIPELINE_VERSION` sequence: the artefact changed *shape*, so there is
/// no cache entry from the old numbering that this could be confused with.
pub const MASK_PIPELINE_VERSION: u32 = 1;
/// Bump when any cached spatial wallpaper texture or field changes.
pub const SPATIAL_PIPELINE_VERSION: u32 = 9;
/// Bound spatial textures so two additional layers do not duplicate a 4K source.
pub const SPATIAL_MAX_DIMENSION: u32 = 2560;
/// Spatial cutout controls are independent from the desktop-widget occlusion sliders.
pub const SPATIAL_FOREGROUND_THRESHOLD: f32 = 0.58;
pub const SPATIAL_FOREGROUND_FEATHER: f32 = 0.08;
pub const SPATIAL_CACHE_LIMIT: usize = 16;

/// Bump when the wallpaper-derived palette changes shape or colour rules.
///
/// The palette is keyed on the wallpaper's own hash (not on model, not on
/// threshold / feather) because it is a pure colour property of the image.
/// Keeping the version separate from `MASK_PIPELINE_VERSION` lets the mask
/// pipeline iterate without regenerating every cached palette sidecar, and
/// vice versa.
///
/// v2: added the 16×16 relative-luminance grid (`luminanceGrid` /
/// `gridSize`) the Clock widget samples per-region, and switched `isDark`
/// from HSL lightness to WCAG relative luminance. Older v1 sidecars lack the
/// grid and are regenerated on the next generate.
pub const PALETTE_PIPELINE_VERSION: u32 = 2;

/// Guided-filter refinement is capped at this long edge to bound cost.
///
/// This is a *cost* ceiling on the refine step, NOT a ceiling on the emitted
/// mask — the mask is always produced at the wallpaper's own resolution. Raising
/// this makes the refinement slower in exchange for a guide image with more real
/// resolution to snap edges to; lowering it does not shrink the output, only the
/// fidelity of the edges.
///
/// Kept at 1920 so that the common case — a wallpaper no larger than this —
/// runs the filter at exactly the resolution it will be displayed at.
pub const REFINEMENT_MAX_DIMENSION: u32 = 1920;
pub const GUIDED_FILTER_RADIUS: u32 = 8;
pub const GUIDED_FILTER_EPSILON: f32 = 0.001;

/// LRU retention for the cache tiers.
///
/// The mask is the tier the user actually sees, and it is the one the sliders
/// regenerate, so it is kept far deeper than the intermediates it is derived
/// from — matching the retention the reference implementation settled on.
pub const DEPTH_CACHE_LIMIT: usize = 8;
pub const REFINED_CACHE_LIMIT: usize = 8;
pub const MASK_CACHE_LIMIT: usize = 32;
// Palettes are small JSON sidecars (~500 bytes) keyed by the wallpaper's
// hash, so retention can be deep without a real disk cost. Matched to the
// mask tier so every wallpaper that still has a mask also has a palette.
pub const PALETTE_CACHE_LIMIT: usize = 32;

/// Relative layout inside the plugin data directory.
#[allow(dead_code)]
pub const DIR_MODEL: &str = "models/depth-anything-v2-small";
pub const DIR_DEPTH_CACHE: &str = "cache/depth";
pub const DIR_REFINED_CACHE: &str = "cache/refined";
pub const DIR_MASK_CACHE: &str = "cache/masks";
pub const DIR_PALETTE_CACHE: &str = "cache/palettes";
pub const DIR_SPATIAL_CACHE: &str = "cache/spatial";
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
        self.root
            .join(descriptor.directory)
            .join(descriptor.filename)
    }

    pub fn depth_cache(&self) -> PathBuf {
        self.root.join(DIR_DEPTH_CACHE)
    }

    pub fn refined_cache(&self) -> PathBuf {
        self.root.join(DIR_REFINED_CACHE)
    }

    pub fn mask_cache(&self) -> PathBuf {
        self.root.join(DIR_MASK_CACHE)
    }

    pub fn palette_cache(&self) -> PathBuf {
        self.root.join(DIR_PALETTE_CACHE)
    }

    pub fn spatial_cache(&self) -> PathBuf {
        self.root.join(DIR_SPATIAL_CACHE)
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
            self.mask_cache(),
            self.palette_cache(),
            self.spatial_cache(),
            self.runtime(),
        ] {
            std::fs::create_dir_all(&dir)
                .with_context(|| format!("cannot create {}", dir.display()))?;
        }
        Ok(())
    }
}
