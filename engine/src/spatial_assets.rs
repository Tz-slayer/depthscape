//! Spatial asset preparation through the OpenCV helper.

use anyhow::{bail, Context, Result};
use image::{DynamicImage, GrayImage, ImageBuffer, Luma, RgbImage, RgbaImage};
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, ExitStatus, Stdio},
    thread,
    time::{Duration, Instant},
};

use crate::{
    config::{ModelDescriptor, Paths, SPATIAL_MAX_DIMENSION},
    spatial_segment,
};

pub struct Prepared {
    pub background: Vec<u8>,
    pub foreground: Vec<u8>,
    pub depth: Vec<u8>,
    pub matte: Vec<u8>,
    pub influence: Vec<u8>,
    pub warning: Option<String>,
}

struct Scratch(PathBuf);
impl Drop for Scratch {
    fn drop(&mut self) {
        if std::env::var_os("DEPTHSCAPE_KEEP_SPATIAL_SCRATCH").is_none() {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
}

fn helper_path() -> Result<PathBuf> {
    let path = match std::env::var_os("DEPTHSCAPE_SPATIAL_HELPER") {
        Some(path) => PathBuf::from(path),
        None => std::env::current_exe()?
            .parent()
            .context("engine executable has no directory")?
            .join("depthscape-spatial-assets"),
    };
    if !path.is_file() {
        bail!("spatial asset helper is missing at {}; install OpenCV development files and run tools/build-spatial-assets.sh", path.display());
    }
    Ok(path)
}

fn write_png(
    path: &Path,
    image: &impl image::GenericImageView<Pixel = image::Rgb<u8>>,
) -> Result<()> {
    let mut buffer = RgbImage::new(image.width(), image.height());
    for (x, y, pixel) in image.pixels() {
        buffer.put_pixel(x, y, pixel);
    }
    buffer
        .save(path)
        .with_context(|| format!("cannot write {}", path.display()))
}

/// Drain both output pipes while the child runs and bound its lifetime.
fn run_helper(command: &mut Command, timeout: Duration) -> Result<(ExitStatus, Vec<u8>, Vec<u8>)> {
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("cannot start spatial asset helper")?;
    let stdout = child
        .stdout
        .take()
        .context("cannot read spatial helper stdout")?;
    let stderr = child
        .stderr
        .take()
        .context("cannot read spatial helper stderr")?;
    let read_pipe = |pipe: Box<dyn Read + Send>| {
        thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = pipe.take(64 * 1024).read_to_end(&mut bytes);
            bytes
        })
    };
    let stdout_reader = read_pipe(Box::new(stdout));
    let stderr_reader = read_pipe(Box::new(stderr));
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if started.elapsed() < timeout => thread::sleep(Duration::from_millis(50)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = stdout_reader.join();
                let _ = stderr_reader.join();
                bail!(
                    "spatial asset helper timed out after {} seconds",
                    timeout.as_secs()
                );
            }
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = stdout_reader.join();
                let _ = stderr_reader.join();
                return Err(error).context("cannot wait for spatial asset helper");
            }
        }
    };
    let stdout = stdout_reader
        .join()
        .map_err(|_| anyhow::anyhow!("spatial helper stdout reader failed"))?;
    let stderr = stderr_reader
        .join()
        .map_err(|_| anyhow::anyhow!("spatial helper stderr reader failed"))?;
    Ok((status, stdout, stderr))
}

pub fn prepare(
    paths: &Paths,
    source: &RgbImage,
    depth: &[f32],
    segment_model: &'static ModelDescriptor,
) -> Result<Prepared> {
    let (sw, sh) = source.dimensions();
    if depth.len() != sw as usize * sh as usize {
        bail!("spatial depth dimensions do not match the wallpaper");
    }
    let scale = (SPATIAL_MAX_DIMENSION as f64 / sw.max(sh) as f64).min(1.0);
    let (w, h) = (
        ((sw as f64 * scale).round() as u32).max(1),
        ((sh as f64 * scale).round() as u32).max(1),
    );
    let photo = image::imageops::resize(source, w, h, image::imageops::FilterType::Triangle);
    let depth_full = ImageBuffer::<Luma<u16>, Vec<u16>>::from_raw(
        sw,
        sh,
        depth
            .iter()
            .map(|x| (x.clamp(0.0, 1.0) * 65535.0).round() as u16)
            .collect(),
    )
    .context("cannot build spatial depth image")?;
    let depth_image =
        image::imageops::resize(&depth_full, w, h, image::imageops::FilterType::Triangle);
    let scratch = Scratch(
        paths
            .root()
            .join("runtime")
            .join(format!("spatial-assets-{}", std::process::id())),
    );
    fs::create_dir_all(&scratch.0).context("cannot create spatial asset scratch directory")?;
    let photo_path = scratch.0.join("photo.png");
    let depth_path = scratch.0.join("depth.png");
    let model_path = scratch.0.join("model.png");
    let background_path = scratch.0.join("background.png");
    let matte_path = scratch.0.join("matte.png");
    let influence_path = scratch.0.join("influence.png");
    write_png(&photo_path, &photo)?;
    depth_image
        .save(&depth_path)
        .context("cannot write spatial depth input")?;
    let helper = helper_path()?;
    let mut warning = None;
    let has_model = match spatial_segment::predict(paths, segment_model, &photo, w, h) {
        Ok(confidence) => {
            confidence
                .save(&model_path)
                .context("cannot write foreground model output")?;
            true
        }
        Err(error) => {
            let message = format!(
                "{} unavailable ({error:#}); using depth-guided foreground segmentation",
                segment_model.name
            );
            eprintln!("Depthscape: {message}");
            warning = Some(message);
            false
        }
    };
    let mut command = Command::new(&helper);
    command
        .arg(&photo_path)
        .arg(&depth_path)
        .arg(if has_model {
            model_path.as_os_str()
        } else {
            std::ffi::OsStr::new("-")
        })
        .arg(&background_path)
        .arg(&matte_path)
        .arg(&influence_path)
        // Keep the helper CLI's final reserved slot for compatibility with
        // already-built helper binaries; no user edit data is passed here.
        .arg("-");
    let local_lib = helper
        .parent()
        .unwrap_or(Path::new("."))
        .join("spatial-lib");
    if local_lib.is_dir() {
        let mut dirs = vec![local_lib];
        if let Some(existing) = std::env::var_os("LD_LIBRARY_PATH") {
            dirs.extend(std::env::split_paths(&existing));
        }
        command.env("LD_LIBRARY_PATH", std::env::join_paths(dirs)?);
    }
    let (status, stdout, stderr) = run_helper(&mut command, Duration::from_secs(120))
        .with_context(|| format!("cannot run spatial asset helper {}", helper.display()))?;
    if !status.success() {
        let helper_error = String::from_utf8_lossy(&stderr).trim().to_owned();
        if let Some(message) = &warning {
            bail!("{message}; spatial asset helper failed: {helper_error}");
        }
        bail!("spatial asset helper failed: {helper_error}");
    }
    if has_model && stdout.starts_with(b"depth") {
        let message = "IS-Net Anime subject did not pass depth validation; using depth-guided foreground segmentation".to_string();
        eprintln!("Depthscape: {message}");
        warning = Some(message);
    }
    let matte: GrayImage = image::open(&matte_path)
        .context("cannot read spatial matte")?
        .to_luma8();
    if matte.dimensions() != (w, h) {
        bail!("spatial helper returned a matte of the wrong size");
    }
    let foreground = RgbaImage::from_fn(w, h, |x, y| {
        let rgb = photo.get_pixel(x, y);
        image::Rgba([rgb[0], rgb[1], rgb[2], matte.get_pixel(x, y)[0]])
    });
    let mut bytes = std::io::Cursor::new(Vec::new());
    DynamicImage::ImageRgba8(foreground).write_to(&mut bytes, image::ImageFormat::Png)?;
    Ok(Prepared {
        background: fs::read(background_path)?,
        foreground: bytes.into_inner(),
        depth: fs::read(depth_path)?,
        matte: fs::read(matte_path)?,
        influence: fs::read(influence_path)?,
        warning,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn helper_timeout_kills_the_worker_and_returns_an_error() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "exec sleep 5"]);
        let started = Instant::now();
        let error = run_helper(&mut command, Duration::from_millis(100)).unwrap_err();
        assert!(error.to_string().contains("timed out"));
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn helper_collects_stdout_and_stderr() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "printf ok; printf warning >&2"]);
        let (status, stdout, stderr) = run_helper(&mut command, Duration::from_secs(2)).unwrap();
        assert!(status.success());
        assert_eq!(stdout, b"ok");
        assert_eq!(stderr, b"warning");
    }
}
