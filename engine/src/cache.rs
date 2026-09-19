//! Two-tier cache: raw depth maps and generated masks are keyed separately.
//!
//! Dragging the threshold slider must never re-run the model, so the mask key
//! extends the depth key with the mask parameters. Both tiers use BLAKE3.

use crate::config::{
    Paths, DEPTH_CACHE_LIMIT, DEPTH_PIPELINE_VERSION, INPUT_SIZE, MASK_CACHE_LIMIT,
    MASK_PIPELINE_VERSION, MODEL_FINGERPRINT, REFINED_CACHE_LIMIT,
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

/// Cache key for the expensive model output.
///
/// Depends on wallpaper contents, model fingerprint, pipeline version and the
/// inference resolution — everything that would change the depth tensor.
pub fn depth_key(wallpaper_hash: &str) -> String {
    format!(
        "{wallpaper_hash}-{MODEL_FINGERPRINT}-d{DEPTH_PIPELINE_VERSION}-i{INPUT_SIZE}"
    )
}

/// Cache key for a mask, derived from a depth key plus the user's parameters.
pub fn mask_key(depth_key: &str, threshold: f32, feather: f32) -> String {
    format!(
        "{depth_key}-v{MASK_PIPELINE_VERSION}-t{threshold:.4}-f{feather:.4}"
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
        bail!(
            "cache entry is {width}x{height}, expected {expected_width}x{expected_height}"
        );
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

impl CacheEntry {
    pub fn resolve(paths: &Paths, wallpaper_hash: &str, threshold: f32, feather: f32) -> Self {
        let depth = depth_key(wallpaper_hash);
        Self {
            refined_path: paths
                .refined_cache()
                .join(format!("{depth}-r{DEPTH_PIPELINE_VERSION}.dsr")),
            depth_path: paths.depth_cache().join(format!("{depth}.dsc")),
            mask_path: paths
                .mask_cache()
                .join(format!("{}.png", mask_key(&depth, threshold, feather))),
        }
    }
}

/// Trim all three cache tiers to their configured retention.
pub fn prune_all(paths: &Paths) -> Result<usize> {
    Ok(prune(&paths.depth_cache(), DEPTH_CACHE_LIMIT)?
        + prune(&paths.refined_cache(), REFINED_CACHE_LIMIT)?
        + prune(&paths.mask_cache(), MASK_CACHE_LIMIT)?)
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
