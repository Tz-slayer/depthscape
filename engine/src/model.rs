//! Model provisioning: download once, verify, then never trust it blindly.

use crate::cache;
use crate::config::{Paths, MODEL_SHA256, MODEL_SIZE, MODEL_URL};
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
///
/// The size check runs first because it is free and rejects the common case of
/// an interrupted download without hashing 99 MB.
pub fn verify(path: &Path) -> Result<bool> {
    if !path.is_file() {
        return Ok(false);
    }
    let metadata = fs::metadata(path)?;
    if metadata.len() != MODEL_SIZE {
        return Ok(false);
    }
    Ok(sha256_file(path)? == MODEL_SHA256)
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

fn write_memo(path: &Path, size: u64, mtime: u128) -> Result<()> {
    let line = format!("{size} {mtime} {MODEL_SHA256}\n");
    cache::atomic_write(&memo_path(path), line.as_bytes())
}

/// Whether a recorded verification describes exactly this file state.
///
/// Kept separate from [`verify_cached`] so the decision can be tested without a
/// 99 MB fixture.
fn memo_is_current(memo: Option<(u64, u128, String)>, size: u64, mtime: u128) -> bool {
    matches!(
        memo,
        Some((memo_size, memo_mtime, digest))
            if memo_size == size && memo_mtime == mtime && digest == MODEL_SHA256
    )
}

/// [`verify`], reusing the digest of an earlier run when the file is provably
/// the same one.
///
/// Hashing 99 MB costs ~40 ms, and `analyze` paid it on *every* invocation —
/// including a pure cache hit that did no other work, and including the
/// sliders' fast path. The checksum stays the authority; the sidecar only
/// records which file contents it was computed for, so an untouched file skips
/// the hash. Truncation, replacement, or any edit moves the size or the mtime
/// and forces a full re-verification.
pub fn verify_cached(path: &Path) -> Result<bool> {
    let Ok(metadata) = fs::metadata(path) else {
        return Ok(false);
    };
    let (size, mtime) = (metadata.len(), mtime_ns(&metadata));
    if size != MODEL_SIZE {
        return Ok(false);
    }
    if memo_is_current(read_memo(path), size, mtime) {
        return Ok(true);
    }
    if !verify(path)? {
        return Ok(false);
    }
    let _ = write_memo(path, size, mtime);
    Ok(true)
}

pub fn state(paths: &Paths) -> Result<ModelState> {
    if verify_cached(&paths.model())? {
        Ok(ModelState::Ready)
    } else {
        Ok(ModelState::Missing)
    }
}

/// Download the model through `curl` and place it atomically.
///
/// Shelling out to `curl` instead of embedding an HTTP client keeps the
/// dependency graph small for what is a one-off, user-initiated setup step, and
/// `curl` is present on essentially every Linux desktop. The download is
/// verified before it is allowed to replace a previous file, so a truncated or
/// tampered response can never become the active model.
pub fn download(paths: &Paths) -> Result<()> {
    let destination = paths.model();
    let parent = destination
        .parent()
        .context("model path has no parent directory")?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join("model.onnx.part");
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
        .arg(MODEL_URL)
        .status()
        .context("cannot run curl; install curl to download the model")?;
    if !status.success() {
        let _ = fs::remove_file(&temporary);
        bail!("model download failed with {status}");
    }

    let metadata = fs::metadata(&temporary).context("downloaded file is missing")?;
    if metadata.len() != MODEL_SIZE {
        let actual = metadata.len();
        let _ = fs::remove_file(&temporary);
        bail!("model size mismatch: expected {MODEL_SIZE} bytes, received {actual}");
    }
    let actual = sha256_file(&temporary)?;
    if actual != MODEL_SHA256 {
        let _ = fs::remove_file(&temporary);
        bail!("model checksum mismatch: expected {MODEL_SHA256}, received {actual}");
    }

    fs::rename(&temporary, &destination).with_context(|| {
        format!("cannot move the verified model onto {}", destination.display())
    })?;

    // Record the verification that just happened, so the first `analyze` after
    // setup does not immediately repeat it.
    let metadata = fs::metadata(&destination)?;
    write_memo(&destination, metadata.len(), mtime_ns(&metadata))?;
    Ok(())
}

pub fn model_path(paths: &Paths) -> PathBuf {
    paths.model()
}

#[cfg(test)]
mod tests {
    use super::*;

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
        assert!(!verify(&path).unwrap());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn verify_reports_missing_files_as_not_ready() {
        let path = std::env::temp_dir().join("depthscape-model-does-not-exist.onnx");
        let _ = fs::remove_file(&path);
        assert!(!verify(&path).unwrap());
    }

    #[test]
    fn memo_is_only_current_for_the_exact_file_state() {
        let fresh = Some((MODEL_SIZE, 42u128, MODEL_SHA256.to_string()));
        assert!(memo_is_current(fresh.clone(), MODEL_SIZE, 42));
        // A different mtime means the file was touched.
        assert!(!memo_is_current(fresh.clone(), MODEL_SIZE, 43));
        // A different size means it was replaced or truncated.
        assert!(!memo_is_current(fresh.clone(), MODEL_SIZE - 1, 42));
        // A digest that is not the pinned one is never trusted.
        assert!(!memo_is_current(
            Some((MODEL_SIZE, 42, "0".repeat(64))),
            MODEL_SIZE,
            42
        ));
        // No memo at all is never trusted.
        assert!(!memo_is_current(None, MODEL_SIZE, 42));
    }

    #[test]
    fn memo_round_trips_through_the_sidecar() {
        let dir = std::env::temp_dir().join(format!("depthscape-memo-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let model = dir.join("model.onnx");

        write_memo(&model, MODEL_SIZE, 7).unwrap();
        assert_eq!(
            read_memo(&model),
            Some((MODEL_SIZE, 7, MODEL_SHA256.to_string()))
        );
        assert!(memo_is_current(read_memo(&model), MODEL_SIZE, 7));

        // A garbage sidecar must read as "no memo" rather than panic.
        fs::write(memo_path(&model), "not a memo").unwrap();
        assert_eq!(read_memo(&model), None);
        assert!(!memo_is_current(read_memo(&model), MODEL_SIZE, 7));

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn verify_cached_rejects_a_file_of_the_wrong_size_without_hashing() {
        let dir = std::env::temp_dir().join(format!("depthscape-cached-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("model.onnx");
        fs::write(&path, b"not a model").unwrap();
        assert!(!verify_cached(&path).unwrap());
        // Nothing was verified, so nothing should have been recorded.
        assert!(!memo_path(&path).exists());
        fs::remove_dir_all(&dir).unwrap();
    }
}
