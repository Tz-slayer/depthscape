//! Model provisioning: download once, verify, then never trust it blindly.

use crate::config::{Paths, MODEL_SHA256, MODEL_SIZE, MODEL_URL};
use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

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

pub fn state(paths: &Paths) -> Result<ModelState> {
    if verify(&paths.model())? {
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
}
