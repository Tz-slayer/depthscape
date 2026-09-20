//! JSON shapes exchanged with the QML side.
//!
//! V1 is a one-shot process: the engine prints exactly one JSON object on
//! stdout and exits. Keeping the schema in one place means the QML parser and
//! the engine cannot drift apart silently.
//!
//! Field names are camelCase on purpose — they are a wire format consumed by
//! JavaScript, so the Rust naming lint is deliberately waived.
#![allow(non_snake_case)]

use crate::config::Paths;
use crate::model::{self, ModelState};
use crate::pipeline::AnalyzeOutcome;
use serde::Serialize;

#[derive(Serialize)]
pub struct StatusReport {
    pub ready: bool,
    pub model: ModelInfo,
    pub cache: CacheInfo,
    pub dataDir: String,
}

#[derive(Serialize)]
pub struct ModelInfo {
    pub ready: bool,
    pub revision: String,
    pub sha256: String,
    pub size: u64,
    pub path: String,
}

#[derive(Serialize)]
pub struct CacheInfo {
    pub depthEntries: usize,
    pub refinedEntries: usize,
    pub maskEntries: usize,
}

#[derive(Serialize)]
pub struct AnalyzeReport {
    pub maskPath: String,
    pub wallpaperPath: String,
    /// Wallpaper dimensions.
    pub width: u32,
    pub height: u32,
    /// Mask dimensions. Equal to the wallpaper below the refinement cap, and
    /// smaller above it — see `pipeline::mask_size`.
    pub maskWidth: u32,
    pub maskHeight: u32,
    pub depthCacheHit: bool,
    pub refinedCacheHit: bool,
    pub maskCacheHit: bool,
    pub elapsedMs: u64,
    pub timings: TimingsReport,
}

/// Per-stage costs, so a slow run can be attributed without instrumentation.
#[derive(Serialize)]
pub struct TimingsReport {
    pub hashMs: u64,
    pub decodeMs: u64,
    pub depthMs: u64,
    pub refineMs: u64,
    pub maskMs: u64,
    pub pruneMs: u64,
}

#[derive(Serialize)]
pub struct SetupReport {
    pub ready: bool,
    pub downloaded: bool,
    pub model: ModelInfo,
}

#[derive(Serialize)]
pub struct ClearReport {
    pub removed: usize,
}

pub fn status(paths: &Paths) -> anyhow::Result<StatusReport> {
    let state = model::state(paths)?;
    Ok(StatusReport {
        ready: state == ModelState::Ready,
        model: ModelInfo {
            ready: state == ModelState::Ready,
            revision: crate::config::MODEL_REVISION.to_string(),
            sha256: crate::config::MODEL_SHA256.to_string(),
            size: crate::config::MODEL_SIZE,
            path: paths.model().display().to_string(),
        },
        cache: CacheInfo {
            depthEntries: count_files(&paths.depth_cache()),
            refinedEntries: count_files(&paths.refined_cache()),
            maskEntries: count_files(&paths.mask_cache()),
        },
        dataDir: paths.root().display().to_string(),
    })
}

pub fn setup(paths: &Paths, downloaded: bool) -> anyhow::Result<SetupReport> {
    Ok(SetupReport {
        ready: true,
        downloaded,
        model: ModelInfo {
            ready: true,
            revision: crate::config::MODEL_REVISION.to_string(),
            sha256: crate::config::MODEL_SHA256.to_string(),
            size: crate::config::MODEL_SIZE,
            path: paths.model().display().to_string(),
        },
    })
}

impl From<AnalyzeOutcome> for AnalyzeReport {
    fn from(outcome: AnalyzeOutcome) -> Self {
        Self {
            maskPath: outcome.mask_path.display().to_string(),
            wallpaperPath: outcome.wallpaper_path.display().to_string(),
            width: outcome.width,
            height: outcome.height,
            maskWidth: outcome.mask_width,
            maskHeight: outcome.mask_height,
            depthCacheHit: outcome.depth_cache_hit,
            refinedCacheHit: outcome.refined_cache_hit,
            maskCacheHit: outcome.mask_cache_hit,
            elapsedMs: outcome.elapsed_ms as u64,
            timings: TimingsReport {
                hashMs: outcome.timings.hash_ms as u64,
                decodeMs: outcome.timings.decode_ms as u64,
                depthMs: outcome.timings.depth_ms as u64,
                refineMs: outcome.timings.refine_ms as u64,
                maskMs: outcome.timings.mask_ms as u64,
                pruneMs: outcome.timings.prune_ms as u64,
            },
        }
    }
}

fn count_files(directory: &std::path::Path) -> usize {
    std::fs::read_dir(directory)
        .map(|entries| {
            entries
                .flatten()
                .filter(|entry| entry.path().is_file())
                .count()
        })
        .unwrap_or(0)
}
