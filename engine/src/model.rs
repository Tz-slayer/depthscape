//! Model provisioning: download once, verify, then never trust it blindly.

use crate::cache;
use crate::config::{ModelDescriptor, Paths};
use crate::protocol::UninstallReport;
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
    let mut file =
        fs::File::open(path).with_context(|| format!("cannot open {}", path.display()))?;
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
    if sha256_file(path)? != descriptor.sha256 {
        return Ok(false);
    }
    if let Some(extra) = descriptor.extra_file {
        let extra_path = path.with_file_name(extra.filename);
        if !extra_path.is_file() {
            return Ok(false);
        }
        let extra_meta = fs::metadata(&extra_path)?;
        if extra_meta.len() != extra.size {
            return Ok(false);
        }
        if sha256_file(&extra_path)? != extra.sha256 {
            return Ok(false);
        }
    }
    Ok(true)
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
    if let Some(extra) = descriptor.extra_file {
        let extra_path = path.with_file_name(extra.filename);
        let Ok(extra_meta) = fs::metadata(&extra_path) else {
            return Ok(false);
        };
        if extra_meta.len() != extra.size {
            return Ok(false);
        }
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

    download_file(
        descriptor.url,
        &temporary,
        descriptor.size,
        descriptor.sha256,
    )?;

    let mut extra_temp = None;
    if let Some(extra) = descriptor.extra_file {
        let temp_extra = parent.join(format!(".{}.part", extra.filename));
        let _ = fs::remove_file(&temp_extra);
        download_file(extra.url, &temp_extra, extra.size, extra.sha256)?;
        extra_temp = Some((temp_extra, parent.join(extra.filename)));
    }

    fs::rename(&temporary, &destination).with_context(|| {
        format!(
            "cannot move the verified model onto {}",
            destination.display()
        )
    })?;

    if let Some((src, dst)) = extra_temp {
        fs::rename(&src, &dst).with_context(|| {
            format!("cannot move the verified extra file onto {}", dst.display())
        })?;
    }

    // Record the verification that just happened, so the first `analyze` after
    // setup does not immediately repeat it.
    let metadata = fs::metadata(&destination)?;
    write_memo(
        &destination,
        descriptor,
        metadata.len(),
        mtime_ns(&metadata),
    )?;
    Ok(())
}

fn download_file(
    url: &str,
    destination: &Path,
    expected_size: u64,
    expected_sha256: &str,
) -> Result<()> {
    let status = Command::new("curl")
        .args([
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            "--connect-timeout",
            "15",
            "--max-time",
            if expected_size > 512 * 1024 * 1024 {
                "900"
            } else {
                "300"
            },
            "--retry",
            "2",
            "--retry-max-time",
            "60",
            "--output",
        ])
        .arg(destination)
        .arg(url)
        .status()
        .context("cannot run curl; install curl to download the model")?;
    if !status.success() {
        let _ = fs::remove_file(destination);
        bail!("download from {url} failed with {status}");
    }

    let metadata = fs::metadata(destination).context("downloaded file is missing")?;
    if metadata.len() != expected_size {
        let actual = metadata.len();
        let _ = fs::remove_file(destination);
        bail!("size mismatch for {url}: expected {expected_size} bytes, received {actual}");
    }
    let actual = sha256_file(destination)?;
    if actual != expected_sha256 {
        let _ = fs::remove_file(destination);
        bail!("checksum mismatch for {url}: expected {expected_sha256}, received {actual}");
    }
    Ok(())
}

pub fn model_path(paths: &Paths, descriptor: &ModelDescriptor) -> PathBuf {
    paths.model_for(descriptor)
}

#[derive(Default)]
struct Removal {
    files: usize,
    bytes: u64,
}

/// Recursively remove one of Depthscape's own subtrees.
///
/// `symlink_metadata` is deliberate: a symlink planted inside the data
/// directory is unlinked, never followed into whatever it points at.
fn remove_tree(path: &Path, state: &mut Removal) -> Result<()> {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return Ok(());
    };
    if metadata.is_dir() {
        for entry in fs::read_dir(path)
            .with_context(|| format!("cannot list {}", path.display()))?
            .flatten()
        {
            remove_tree(&entry.path(), state)?;
        }
        fs::remove_dir(path).with_context(|| format!("cannot remove {}", path.display()))?;
    } else {
        fs::remove_file(path).with_context(|| format!("cannot remove {}", path.display()))?;
        state.files += 1;
        state.bytes += metadata.len();
    }
    Ok(())
}

/// Delete all downloaded models and generated data.
///
/// This is the counterpart of `setup`: models are downloaded only on explicit
/// request and are removed when the user removes the plugin (or asks for the
/// data to be purged). Only the three subtrees Depthscape itself creates are
/// touched, plus the legacy `widgets.json*` sidecars that pre-0.3.0 releases
/// kept in the data root. Any other file in a custom `DEPTHSCAPE_DATA_DIR` is
/// left alone, and the root directory is removed only when it ends up empty.
pub fn uninstall(paths: &Paths) -> Result<UninstallReport> {
    let root = paths.root();
    let mut state = Removal::default();
    for child in ["models", "cache", "runtime"] {
        remove_tree(&root.join(child), &mut state)?;
    }
    if let Ok(entries) = fs::read_dir(root) {
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            if !path.is_file() || !name.starts_with("widgets.json") {
                continue;
            }
            let size = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            if fs::remove_file(&path).is_ok() {
                state.files += 1;
                state.bytes += size;
            }
        }
    }
    // Fails harmlessly when the caller keeps unrelated files in the root.
    let removed_root = fs::remove_dir(root).is_ok();
    Ok(UninstallReport {
        dataDir: root.display().to_string(),
        removedFiles: state.files,
        removedBytes: state.bytes,
        removedRoot: removed_root,
    })
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
        assert!(memo_is_current(
            fresh.clone(),
            descriptor,
            descriptor.size,
            42
        ));
        // A different mtime means the file was touched.
        assert!(!memo_is_current(
            fresh.clone(),
            descriptor,
            descriptor.size,
            43
        ));
        // A different size means it was replaced or truncated.
        assert!(!memo_is_current(
            fresh.clone(),
            descriptor,
            descriptor.size - 1,
            42
        ));
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
        assert!(memo_is_current(
            read_memo(&model),
            descriptor,
            descriptor.size,
            7
        ));

        // A garbage sidecar must read as "no memo" rather than panic.
        fs::write(memo_path(&model), "not a memo").unwrap();
        assert_eq!(read_memo(&model), None);
        assert!(!memo_is_current(
            read_memo(&model),
            descriptor,
            descriptor.size,
            7
        ));

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn uninstall_removes_only_depthscape_owned_subtrees() {
        use crate::config::Paths;
        use std::io::Write;

        let root = std::env::temp_dir().join(format!("depthscape-purge-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for dir in ["models/depth-anything-v2-small", "cache/masks", "runtime"] {
            fs::create_dir_all(root.join(dir)).unwrap();
        }
        let mut model =
            fs::File::create(root.join("models/depth-anything-v2-small/model.onnx")).unwrap();
        model.write_all(&[7u8; 32]).unwrap();
        drop(model);
        fs::write(root.join("cache/masks/mask.png"), b"mask").unwrap();
        fs::write(root.join("runtime/generate.lock"), b"lock").unwrap();
        fs::write(root.join("widgets.json"), b"{}").unwrap();
        fs::write(root.join("keep.txt"), b"user data").unwrap();

        let report = uninstall(&Paths::new(&root)).unwrap();
        assert_eq!(report.removedFiles, 4);
        assert_eq!(report.removedBytes, 32 + 4 + 4 + 2);
        assert!(
            !report.removedRoot,
            "a root containing unrelated files must survive"
        );
        assert!(!root.join("models").exists());
        assert!(!root.join("cache").exists());
        assert!(!root.join("runtime").exists());
        assert!(!root.join("widgets.json").exists());
        assert_eq!(
            fs::read_to_string(root.join("keep.txt")).unwrap(),
            "user data"
        );
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn uninstall_removes_an_empty_data_root() {
        use crate::config::Paths;

        let root =
            std::env::temp_dir().join(format!("depthscape-purge-empty-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("models")).unwrap();
        fs::write(root.join("models/model.onnx"), b"model").unwrap();

        let report = uninstall(&Paths::new(&root)).unwrap();
        assert!(report.removedRoot);
        assert!(!root.exists());
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
