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

/// Bump when the depth post-processing changes (invalidates depth + mask).
pub const DEPTH_PIPELINE_VERSION: u32 = 1;
/// Bump when only mask generation changes (invalidates masks, keeps depth).
pub const MASK_PIPELINE_VERSION: u32 = 1;

/// Guided-filter refinement is capped at this long edge to bound cost.
pub const REFINEMENT_MAX_DIMENSION: u32 = 1920;
pub const GUIDED_FILTER_RADIUS: u32 = 8;
pub const GUIDED_FILTER_EPSILON: f32 = 0.001;

/// LRU retention for the three cache tiers.
///
/// The refined tier is the largest per entry (full refinement resolution), so it
/// is kept smallest.
pub const DEPTH_CACHE_LIMIT: usize = 8;
pub const REFINED_CACHE_LIMIT: usize = 4;
pub const MASK_CACHE_LIMIT: usize = 32;

/// Relative layout inside the plugin data directory.
pub const DIR_MODEL: &str = "models/depth-anything-v2-small";
pub const DIR_DEPTH_CACHE: &str = "cache/depth";
pub const DIR_REFINED_CACHE: &str = "cache/refined";
pub const DIR_MASK_CACHE: &str = "cache/masks";
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

    pub fn mask_cache(&self) -> PathBuf {
        self.root.join(DIR_MASK_CACHE)
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
            self.mask_cache(),
            self.runtime(),
        ] {
            std::fs::create_dir_all(&dir)
                .with_context(|| format!("cannot create {}", dir.display()))?;
        }
        Ok(())
    }
}
