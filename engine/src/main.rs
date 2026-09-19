//! `depthscape-engine` — offline depth/mask producer for the Depthscape plugin.
//!
//! One invocation does one job and prints one JSON object. The engine never
//! renders and never talks to the compositor; it only turns a wallpaper into
//! the artefacts the QML side needs.

mod cache;
mod config;
mod depth;
mod imageops;
mod model;
mod pipeline;
mod protocol;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use config::Paths;
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "depthscape-engine",
    version,
    about = "Generate depth-aware occlusion masks for Depthscape"
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
    Status,

    /// Download and verify the model if it is not already present.
    Setup {
        /// Re-download even when a verified model is already installed.
        #[arg(long)]
        force: bool,
    },

    /// Analyse a wallpaper and emit an occlusion mask.
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
    },

    /// Delete every cached depth map and mask.
    ClearCache,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let root = match cli.data_dir {
        Some(directory) => directory,
        None => Paths::default_root()?,
    };
    let paths = Paths::new(root);

    match cli.command {
        Command::Status => {
            emit(&protocol::status(&paths)?)?;
        }
        Command::Setup { force } => {
            paths.ensure()?;
            let already_ready = model::state(&paths)? == model::ModelState::Ready;
            if force || !already_ready {
                model::download(&paths)?;
            }
            if model::state(&paths)? != model::ModelState::Ready {
                bail!("model is still not usable after setup");
            }
            emit(&protocol::setup(&paths, force || !already_ready)?)?;
        }
        Command::Analyze {
            wallpaper,
            threshold,
            feather,
        } => {
            let request = pipeline::AnalyzeRequest {
                wallpaper: wallpaper
                    .canonicalize()
                    .with_context(|| format!("cannot resolve {}", wallpaper.display()))?,
                threshold,
                feather,
            };
            let outcome = pipeline::analyze(&paths, &request)?;
            emit(&protocol::AnalyzeReport::from(outcome))?;
        }
        Command::ClearCache => {
            let removed = pipeline::clear_cache(&paths)?;
            emit(&protocol::ClearReport { removed })?;
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
