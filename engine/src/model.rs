//! Model provisioning: download once, verify, then never trust it blindly.

use crate::cache;
use crate::config::{ModelDescriptor, Paths};
use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::UNIX_EPOCH;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModelState {
    /// Present and matching both the pinned size and checksum.
    Ready,
    /// Absent, or present but failing verification.
    Missing,
}

pub fn hex_digest(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// SHA-256 of a file, hex encoded.
pub fn sha256_file(path: &Path) -> Result<String> {
    let mut hasher = Sha256::new();
    let mut file = fs::File::open(path).with_context(|| format!("cannot open {}", path.display()))?;
    std::io::copy(&mut file, &mut hasher)?;
    Ok(hex_digest(&hasher.finalize()))
}

/// Check the model against the pinned size *and* checksum.
pub fn verify(path: &Path, descriptor: &ModelDescriptor) -> Result<bool> {
    if !path.is_file() {
        return Ok(false);
    }
    let metadata = fs::metadata(path)?;
    if metadata.len() != descriptor.size {
        return Ok(false);
    }
    Ok(sha256_file(path)? == descriptor.sha256)
}

/// Sidecar recording the last successful verification.
fn memo_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".verified");
    path.with_file_name(name)
}

/// Modification time in nanoseconds since the Unix epoch, or 0 if unavailable.
fn mtime_ns(metadata: &fs::Metadata) -> u128 {
    metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|age| age.as_nanos())
        .unwrap_or(0)
}

/// Read `(size, mtime_ns, sha256)` back from the sidecar.
fn read_memo(path: &Path) -> Option<(u64, u128, String)> {
    let text = fs::read_to_string(memo_path(path)).ok()?;
    let mut fields = text.split_whitespace();
    Some((
        fields.next()?.parse().ok()?,
        fields.next()?.parse().ok()?,
        fields.next()?.to_string(),
    ))
}

fn write_memo(path: &Path, descriptor: &ModelDescriptor, size: u64, mtime: u128) -> Result<()> {
    let line = format!("{size} {mtime} {}\n", descriptor.sha256);
    cache::atomic_write(&memo_path(path), line.as_bytes())
}

/// Whether a recorded verification describes exactly this file state.
fn memo_is_current(
    memo: Option<(u64, u128, String)>,
    descriptor: &ModelDescriptor,
    size: u64,
    mtime: u128,
) -> bool {
    matches!(
        memo,
        Some((memo_size, memo_mtime, digest))
            if memo_size == size && memo_mtime == mtime && digest == descriptor.sha256
    )
}

pub fn verify_cached(path: &Path, descriptor: &ModelDescriptor) -> Result<bool> {
    let Ok(metadata) = fs::metadata(path) else {
        return Ok(false);
    };
    let (size, mtime) = (metadata.len(), mtime_ns(&metadata));
    if size != descriptor.size {
        return Ok(false);
    }
    if memo_is_current(read_memo(path), descriptor, size, mtime) {
        return Ok(true);
    }
    if !verify(path, descriptor)? {
        return Ok(false);
    }
    let _ = write_memo(path, descriptor, size, mtime);
    Ok(true)
}

pub fn state(paths: &Paths, descriptor: &ModelDescriptor) -> Result<ModelState> {
    let path = paths.model_for(descriptor);
    if verify_cached(&path, descriptor)? {
        Ok(ModelState::Ready)
    } else {
        Ok(ModelState::Missing)
    }
}

/// Download the model through `curl` and place it atomically.
pub fn download(paths: &Paths, descriptor: &ModelDescriptor) -> Result<()> {
    let destination = paths.model_for(descriptor);
    let parent = destination
        .parent()
        .context("model path has no parent directory")?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(".{}.part", descriptor.filename));
    let _ = fs::remove_file(&temporary);

    let status = Command::new("curl")
        .args([
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            "--retry",
            "3",
            "--output",
        ])
        .arg(&temporary)
        .arg(descriptor.url)
        .status()
        .context("cannot run curl; install curl to download the model")?;
    if !status.success() {
        let _ = fs::remove_file(&temporary);
        bail!("model download failed with {status}");
    }

    let metadata = fs::metadata(&temporary).context("downloaded file is missing")?;
    if metadata.len() != descriptor.size {
        let actual = metadata.len();
        let _ = fs::remove_file(&temporary);
        bail!(
            "model size mismatch: expected {} bytes, received {actual}",
            descriptor.size
        );
    }
    let actual = sha256_file(&temporary)?;
    if actual != descriptor.sha256 {
        let _ = fs::remove_file(&temporary);
        bail!(
            "model checksum mismatch: expected {}, received {actual}",
            descriptor.sha256
        );
    }

    fs::rename(&temporary, &destination).with_context(|| {
        format!("cannot move the verified model onto {}", destination.display())
    })?;

    // Record the verification that just happened, so the first `analyze` after
    // setup does not immediately repeat it.
    let metadata = fs::metadata(&destination)?;
    write_memo(&destination, descriptor, metadata.len(), mtime_ns(&metadata))?;
    Ok(())
}

pub fn model_path(paths: &Paths, descriptor: &ModelDescriptor) -> PathBuf {
    paths.model_for(descriptor)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::default_model;

    #[test]
    fn hex_digest_matches_known_vector() {
        // SHA-256 of the empty string.
        let digest = hex_digest(&Sha256::digest(b""));
        assert_eq!(
            digest,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn verify_rejects_a_file_of_the_wrong_size() {
        let dir = std::env::temp_dir().join(format!("depthscape-model-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("model.onnx");
        fs::write(&path, b"not a model").unwrap();
        assert!(!verify(&path, default_model()).unwrap());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn verify_reports_missing_files_as_not_ready() {
        let path = std::env::temp_dir().join("depthscape-model-does-not-exist.onnx");
        let _ = fs::remove_file(&path);
        assert!(!verify(&path, default_model()).unwrap());
    }

    #[test]
    fn memo_is_only_current_for_the_exact_file_state() {
        let descriptor = default_model();
        let fresh = Some((descriptor.size, 42u128, descriptor.sha256.to_string()));
        assert!(memo_is_current(fresh.clone(), descriptor, descriptor.size, 42));
        // A different mtime means the file was touched.
        assert!(!memo_is_current(fresh.clone(), descriptor, descriptor.size, 43));
        // A different size means it was replaced or truncated.
        assert!(!memo_is_current(fresh.clone(), descriptor, descriptor.size - 1, 42));
        // A digest that is not the pinned one is never trusted.
        assert!(!memo_is_current(
            Some((descriptor.size, 42, "0".repeat(64))),
            descriptor,
            descriptor.size,
            42
        ));
        // No memo at all is never trusted.
        assert!(!memo_is_current(None, descriptor, descriptor.size, 42));
    }

    #[test]
    fn memo_round_trips_through_the_sidecar() {
        let dir = std::env::temp_dir().join(format!("depthscape-memo-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let model = dir.join("model.onnx");
        let descriptor = default_model();

        write_memo(&model, descriptor, descriptor.size, 7).unwrap();
        assert_eq!(
            read_memo(&model),
            Some((descriptor.size, 7, descriptor.sha256.to_string()))
        );
        assert!(memo_is_current(read_memo(&model), descriptor, descriptor.size, 7));

        // A garbage sidecar must read as "no memo" rather than panic.
        fs::write(memo_path(&model), "not a memo").unwrap();
        assert_eq!(read_memo(&model), None);
        assert!(!memo_is_current(read_memo(&model), descriptor, descriptor.size, 7));

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn verify_cached_rejects_a_file_of_the_wrong_size_without_hashing() {
        let dir = std::env::temp_dir().join(format!("depthscape-cached-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("model.onnx");
        fs::write(&path, b"not a model").unwrap();
        assert!(!verify_cached(&path, default_model()).unwrap());
        // Nothing was verified, so nothing should have been recorded.
        assert!(!memo_path(&path).exists());
        fs::remove_dir_all(&dir).unwrap();
    }
}
