//! Three-tier cache: raw depth maps, refined fields, and occlusion masks are
//! keyed separately.
//!
//! The three tiers are deliberately independent. Refinement is a property of the
//! depth field alone, and the mask is the only tier that reads the threshold and
//! feather, so dragging a slider re-runs the mask and nothing else. All tiers
//! use BLAKE3.

use crate::config::{
    Paths, DEPTH_CACHE_LIMIT, DEPTH_PIPELINE_VERSION, INPUT_SIZE, MASK_CACHE_LIMIT,
    MASK_PIPELINE_VERSION, MODEL_FINGERPRINT, PALETTE_CACHE_LIMIT, PALETTE_PIPELINE_VERSION,
    REFINED_CACHE_LIMIT, SPATIAL_CACHE_LIMIT, SPATIAL_FOREGROUND_FEATHER,
    SPATIAL_FOREGROUND_THRESHOLD, SPATIAL_PIPELINE_VERSION,
};
use anyhow::{bail, Context, Result};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// BLAKE3 of a file's contents, hex encoded.
pub fn hash_file(path: &Path) -> Result<String> {
    let mut hasher = blake3::Hasher::new();
    let mut file =
        fs::File::open(path).with_context(|| format!("cannot open {}", path.display()))?;
    std::io::copy(&mut file, &mut hasher)
        .with_context(|| format!("cannot read {}", path.display()))?;
    Ok(hasher.finalize().to_hex().to_string())
}

pub fn depth_key_with_fingerprint(wallpaper_hash: &str, fingerprint: &str) -> String {
    format!("{wallpaper_hash}-{fingerprint}-d{DEPTH_PIPELINE_VERSION}-i{INPUT_SIZE}")
}

/// Cache key for the expensive model output.
///
/// Depends on wallpaper contents, model fingerprint, pipeline version and the
/// inference resolution — everything that would change the depth tensor.
#[allow(dead_code)]
pub fn depth_key(wallpaper_hash: &str) -> String {
    depth_key_with_fingerprint(wallpaper_hash, MODEL_FINGERPRINT)
}

/// Cache key for the occlusion mask, derived from a depth key plus the sliders.
///
/// The mask is a function of the depth field and the two sliders (the refined
/// field is not part of the key because it is itself derived from the depth key
/// alone).
pub fn mask_key(depth_key: &str, threshold: f32, feather: f32) -> String {
    format!("{depth_key}-m{MASK_PIPELINE_VERSION}-t{threshold:.4}-f{feather:.4}")
}

/// Cache key for the wallpaper's colour palette.
///
/// Deliberately keyed on the wallpaper alone, not on model or sliders: the
/// palette is a pure property of the image, so a threshold nudge must not
/// regenerate it. Bumping `PALETTE_PIPELINE_VERSION` is the only way to
/// invalidate it short of deleting the cache.
pub fn palette_key(wallpaper_hash: &str) -> String {
    format!("{wallpaper_hash}-p{PALETTE_PIPELINE_VERSION}")
}

pub fn spatial_key(depth_key: &str, segment_fingerprint: &str) -> String {
    format!(
        "{depth_key}-seg{segment_fingerprint}-s{SPATIAL_PIPELINE_VERSION}-t{SPATIAL_FOREGROUND_THRESHOLD:.4}-f{SPATIAL_FOREGROUND_FEATHER:.4}",
    )
}

/// Write bytes to `path` via a temporary file in the same directory.
///
/// A reader either sees the previous complete file or the new complete file,
/// never a partial one.
pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .with_context(|| format!("{} has no parent directory", path.display()))?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(
        ".{}.tmp",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("depthscape")
    ));
    {
        let mut file = fs::File::create(&temporary)
            .with_context(|| format!("cannot create {}", temporary.display()))?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&temporary, path)
        .with_context(|| format!("cannot move temporary file onto {}", path.display()))?;
    Ok(())
}

/// Delete all but the `keep` most recently modified files in `directory`.
///
/// Returns the number of removed entries.
pub fn prune(directory: &Path, keep: usize) -> Result<usize> {
    if !directory.is_dir() {
        return Ok(0);
    }
    let mut entries: Vec<(std::time::SystemTime, PathBuf)> = fs::read_dir(directory)?
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.path().is_file())
        .filter_map(|entry| {
            let modified = entry.metadata().ok()?.modified().ok()?;
            Some((modified, entry.path()))
        })
        .collect();
    entries.sort_by(|left, right| right.0.cmp(&left.0));
    let mut removed = 0;
    for (_, path) in entries.into_iter().skip(keep) {
        if fs::remove_file(&path).is_ok() {
            removed += 1;
        }
    }
    Ok(removed)
}

const DEPTH_MAGIC: &[u8; 4] = b"DSDP";
const DEPTH_FORMAT_VERSION: u32 = 1;

/// Magic for the refined-depth tier.
const REFINED_MAGIC: &[u8; 4] = b"DSRF";

/// Serialise a depth map as a small self-describing binary blob.
///
/// Chosen over a generic format because the only consumer is this engine, and
/// because the shape must travel with the data: a stale cache entry written at
/// a different inference resolution has to be detectable, not silently used.
pub fn encode_depth(width: u32, height: u32, data: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(16 + data.len() * 4);
    out.extend_from_slice(DEPTH_MAGIC);
    out.extend_from_slice(&DEPTH_FORMAT_VERSION.to_le_bytes());
    out.extend_from_slice(&width.to_le_bytes());
    out.extend_from_slice(&height.to_le_bytes());
    for value in data {
        out.extend_from_slice(&value.to_le_bytes());
    }
    out
}

/// Decode a depth blob, rejecting anything whose shape does not match.
pub fn decode_depth(bytes: &[u8], expected_width: u32, expected_height: u32) -> Result<Vec<f32>> {
    decode_f32_field(bytes, DEPTH_MAGIC, expected_width, expected_height)
}

/// Serialise a refined depth field as quantised `u16`.
///
/// This tier lives at refinement resolution (capped at 1920 on the long edge),
/// so the payload is a few megabytes rather than tens. `u16` halves that again
/// and costs nothing: the field is a smooth `0.0..=1.0` signal, so 16 bits is
/// far more precision than the mask threshold can resolve.
pub fn encode_refined(width: u32, height: u32, data: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(16 + data.len() * 2);
    out.extend_from_slice(REFINED_MAGIC);
    out.extend_from_slice(&DEPTH_FORMAT_VERSION.to_le_bytes());
    out.extend_from_slice(&width.to_le_bytes());
    out.extend_from_slice(&height.to_le_bytes());
    for value in data {
        let quantised = (value.clamp(0.0, 1.0) * 65535.0).round() as u16;
        out.extend_from_slice(&quantised.to_le_bytes());
    }
    out
}

pub fn decode_refined(bytes: &[u8], expected_width: u32, expected_height: u32) -> Result<Vec<f32>> {
    let (width, height, payload) = split_header(bytes, REFINED_MAGIC)?;
    if width != expected_width || height != expected_height {
        bail!(
            "refined cache entry is {width}x{height}, expected {expected_width}x{expected_height}"
        );
    }
    if payload.len() != (width as usize) * (height as usize) * 2 {
        bail!("refined cache entry payload has the wrong length");
    }
    Ok(payload
        .chunks_exact(2)
        .map(|chunk| u16::from_le_bytes(chunk.try_into().unwrap()) as f32 / 65535.0)
        .collect())
}

fn split_header<'a>(bytes: &'a [u8], magic: &[u8; 4]) -> Result<(u32, u32, &'a [u8])> {
    if bytes.len() < 16 {
        bail!("cache entry is truncated");
    }
    if &bytes[0..4] != magic {
        bail!("cache entry has a bad magic number");
    }
    let version = u32::from_le_bytes(bytes[4..8].try_into().unwrap());
    if version != DEPTH_FORMAT_VERSION {
        bail!("cache entry uses unsupported format version {version}");
    }
    let width = u32::from_le_bytes(bytes[8..12].try_into().unwrap());
    let height = u32::from_le_bytes(bytes[12..16].try_into().unwrap());
    if width == 0 || height == 0 {
        bail!("cache entry declares an empty field");
    }
    Ok((width, height, &bytes[16..]))
}

fn decode_f32_field(
    bytes: &[u8],
    magic: &[u8; 4],
    expected_width: u32,
    expected_height: u32,
) -> Result<Vec<f32>> {
    let (width, height, payload) = split_header(bytes, magic)?;
    if width != expected_width || height != expected_height {
        bail!("cache entry is {width}x{height}, expected {expected_width}x{expected_height}");
    }
    if payload.len() != (width as usize) * (height as usize) * 4 {
        bail!("cache entry payload has the wrong length");
    }
    Ok(payload
        .chunks_exact(4)
        .map(|chunk| f32::from_le_bytes(chunk.try_into().unwrap()))
        .collect())
}

/// Resolve the on-disk paths for one analysis request.
pub struct CacheEntry {
    pub depth_path: PathBuf,
    pub refined_path: PathBuf,
    pub mask_path: PathBuf,
}

pub struct SpatialCacheEntry {
    pub background_path: PathBuf,
    pub foreground_path: PathBuf,
    pub depth_path: PathBuf,
    pub matte_path: PathBuf,
    pub influence_path: PathBuf,
    pub complete_path: PathBuf,
}

impl SpatialCacheEntry {
    pub fn resolve(paths: &Paths, depth_key: &str, segment_fingerprint: &str) -> Self {
        let key = spatial_key(depth_key, segment_fingerprint);
        Self {
            background_path: paths.spatial_cache().join(format!("{key}-background.png")),
            foreground_path: paths.spatial_cache().join(format!("{key}-foreground.png")),
            depth_path: paths.spatial_cache().join(format!("{key}-depth.png")),
            matte_path: paths.spatial_cache().join(format!("{key}-matte.png")),
            influence_path: paths.spatial_cache().join(format!("{key}-influence.png")),
            complete_path: paths.spatial_cache().join(format!("{key}-complete")),
        }
    }

    pub fn is_cached(&self) -> bool {
        self.complete_path.is_file()
            && self.background_path.is_file()
            && self.foreground_path.is_file()
            && self.depth_path.is_file()
            && self.matte_path.is_file()
            && self.influence_path.is_file()
    }
}

impl CacheEntry {
    #[allow(dead_code)]
    pub fn resolve(paths: &Paths, wallpaper_hash: &str, threshold: f32, feather: f32) -> Self {
        Self::resolve_with_fingerprint(paths, wallpaper_hash, MODEL_FINGERPRINT, threshold, feather)
    }

    pub fn resolve_with_fingerprint(
        paths: &Paths,
        wallpaper_hash: &str,
        fingerprint: &str,
        threshold: f32,
        feather: f32,
    ) -> Self {
        let depth = depth_key_with_fingerprint(wallpaper_hash, fingerprint);
        let mask = mask_key(&depth, threshold, feather);
        Self {
            refined_path: paths
                .refined_cache()
                .join(format!("{depth}-r{DEPTH_PIPELINE_VERSION}.dsr")),
            depth_path: paths.depth_cache().join(format!("{depth}.dsc")),
            mask_path: paths.mask_cache().join(format!("{mask}.png")),
        }
    }

    /// Whether the cached mask is present.
    ///
    /// One file, so there is no half-written pair to worry about beyond what
    /// `atomic_write` already guarantees.
    pub fn mask_is_cached(&self) -> bool {
        self.mask_path.is_file()
    }
}

/// Trim all cache tiers to their configured retention.
pub fn prune_all(paths: &Paths) -> Result<usize> {
    Ok(prune(&paths.depth_cache(), DEPTH_CACHE_LIMIT)?
        + prune(&paths.refined_cache(), REFINED_CACHE_LIMIT)?
        + prune(&paths.mask_cache(), MASK_CACHE_LIMIT)?
        + prune(&paths.palette_cache(), PALETTE_CACHE_LIMIT)?
        + prune(&paths.spatial_cache(), SPATIAL_CACHE_LIMIT * 6)?)
}

/// Remove every cached artefact across the four tiers. Model files untouched.
///
/// Kept separate from `prune_all`, which only trims down to the retention
/// limits: the CLI's `clearCache` subcommand and the daemon's cacheProcess both
/// want the destructive variant, and a user asking to "clear the cache" should
/// not get back the last N entries.
pub fn clear_all(paths: &Paths) -> Result<usize> {
    let mut removed = 0;
    for directory in [
        paths.depth_cache(),
        paths.refined_cache(),
        paths.mask_cache(),
        paths.palette_cache(),
        paths.spatial_cache(),
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
    fn mask_key_changes_with_parameters_but_depth_key_does_not() {
        let depth = depth_key("abc");
        assert_eq!(depth, depth_key("abc"));
        assert_ne!(mask_key(&depth, 0.3, 0.08), mask_key(&depth, 0.4, 0.08));
        assert_ne!(mask_key(&depth, 0.3, 0.08), mask_key(&depth, 0.3, 0.16));
    }

    #[test]
    fn depth_roundtrip_preserves_values_and_shape() {
        let data: Vec<f32> = (0..12).map(|index| index as f32 / 12.0).collect();
        let encoded = encode_depth(4, 3, &data);
        let decoded = decode_depth(&encoded, 4, 3).unwrap();
        assert_eq!(decoded, data);
    }

    #[test]
    fn depth_decode_rejects_mismatched_shape() {
        let encoded = encode_depth(4, 3, &[0.0; 12]);
        assert!(decode_depth(&encoded, 3, 4).is_err());
        assert!(decode_depth(b"nope", 4, 3).is_err());
    }

    #[test]
    fn prune_keeps_the_most_recent_entries() {
        let dir = std::env::temp_dir().join(format!("depthscape-prune-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        for index in 0..5 {
            let path = dir.join(format!("entry-{index}.bin"));
            fs::write(&path, b"x").unwrap();
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert_eq!(prune(&dir, 2).unwrap(), 3);
        let remaining = fs::read_dir(&dir).unwrap().count();
        assert_eq!(remaining, 2);
        fs::remove_dir_all(&dir).unwrap();
    }
}
