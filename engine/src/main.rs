//! `depthscape-engine` — offline depth, widget-mask and spatial-layer producer for Depthscape.
//!
//! One invocation does one job and prints one JSON object. The engine never
//! renders and never talks to the compositor; it only turns a wallpaper into
//! the artefacts the QML side needs.

mod cache;
mod config;
mod depth;
mod imageops;
mod model;
mod palette;
mod pipeline;
mod protocol;
mod spatial_assets;
mod spatial_segment;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use config::Paths;
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "depthscape-engine",
    version,
    about = "Prepare depth-aware masks and optional spatial wallpaper layers"
)]
struct Cli {
    /// Plugin data directory. Defaults to $XDG_DATA_HOME/depthscape.
    #[arg(long, global = true, value_name = "DIR")]
    data_dir: Option<PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Report model and cache state.
    Status {
        /// Model ID to query (e.g. small, base, large). Defaults to small.
        #[arg(long, default_value = "small")]
        model: String,
    },

    /// Download and verify the model if it is not already present.
    Setup {
        /// Model ID to set up (e.g. small, base, large). Defaults to small.
        #[arg(long, default_value = "small")]
        model: String,

        /// Re-download even when a verified model is already installed.
        #[arg(long)]
        force: bool,
    },

    /// Analyse a wallpaper and emit the foreground/background pair.
    Analyze {
        #[arg(long, value_name = "PATH")]
        wallpaper: PathBuf,

        /// Normalised depth cutoff, 0.0-1.0. Lower values put more of the
        /// scene in front of desktop widgets.
        #[arg(long, default_value_t = 0.3)]
        threshold: f32,

        /// Symmetric transition half-width, 0.0-0.5.
        #[arg(long, default_value_t = 0.08)]
        feather: f32,

        /// Model ID to use (e.g. small, base, large). Defaults to small.
        #[arg(long, default_value = "small")]
        model: String,

        /// Prepare foreground/background textures for spatial wallpaper rendering.
        #[arg(long, default_value_t = false)]
        spatial: bool,

        /// Foreground model for the spatial layers (isnet-anime, birefnet-lite, birefnet).
        #[arg(long, default_value = "isnet-anime")]
        spatial_model: String,
    },

    /// Delete every cached depth, mask, palette, and spatial asset.
    ClearCache,

    /// Remove all downloaded models and generated data (used when the plugin
    /// is uninstalled). This is the only destructive command; it never touches
    /// anything outside Depthscape's own data directory.
    Uninstall,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let root = match cli.data_dir {
        Some(directory) => directory,
        None => Paths::default_root()?,
    };
    let paths = Paths::new(root);

    let model_err = |m: &str| {
        let available = config::ALL_MODELS
            .iter()
            .map(|desc| desc.id)
            .collect::<Vec<_>>()
            .join(", ");
        anyhow::anyhow!("unknown model '{m}'; available: {available}")
    };

    match cli.command {
        Command::Status { model } => {
            let descriptor = config::find_model(&model).ok_or_else(|| model_err(&model))?;
            emit(&protocol::status(&paths, descriptor)?)?;
        }
        Command::Setup { model, force } => {
            let descriptor = config::find_model(&model).ok_or_else(|| model_err(&model))?;
            paths.ensure()?;
            let already_ready = model::state(&paths, descriptor)? == model::ModelState::Ready;
            if force || !already_ready {
                model::download(&paths, descriptor)?;
            }
            if model::state(&paths, descriptor)? != model::ModelState::Ready {
                bail!("model {} is still not usable after setup", descriptor.id);
            }
            emit(&protocol::setup(
                &paths,
                descriptor,
                force || !already_ready,
            )?)?;
        }
        Command::Analyze {
            wallpaper,
            threshold,
            feather,
            model,
            spatial,
            spatial_model,
        } => {
            let descriptor = config::find_model(&model).ok_or_else(|| model_err(&model))?;
            let segment_descriptor =
                config::find_spatial_model(&spatial_model).ok_or_else(|| {
                    let available = config::SPATIAL_MODELS
                        .iter()
                        .map(|desc| desc.id)
                        .collect::<Vec<_>>()
                        .join(", ");
                    anyhow::anyhow!(
                        "unknown spatial model '{spatial_model}'; available: {available}"
                    )
                })?;
            let wallpaper = wallpaper
                .canonicalize()
                .with_context(|| format!("cannot resolve {}", wallpaper.display()))?;
            let request = pipeline::AnalyzeRequest {
                wallpaper,
                threshold,
                feather,
                spatial,
                spatial_model: segment_descriptor,
                model: descriptor,
            };
            let outcome = pipeline::analyze(&paths, &request)?;
            emit(&protocol::AnalyzeReport::from(outcome))?;
        }
        Command::ClearCache => {
            let removed = cache::clear_all(&paths)?;
            emit(&protocol::ClearReport { removed })?;
        }
        Command::Uninstall => {
            emit(&model::uninstall(&paths)?)?;
        }
    }
    Ok(())
}

/// Print one compact JSON object, then flush.
///
/// The QML side reads a single line, so nothing else may be written to stdout.
fn emit<T: serde::Serialize>(value: &T) -> Result<()> {
    use std::io::Write;
    let mut stdout = std::io::stdout().lock();
    serde_json::to_writer(&mut stdout, value)?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(())
}
