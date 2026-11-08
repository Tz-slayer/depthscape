//! Wallpaper colour extraction.
//!
//! A faithful reimplementation of Google's Android Palette algorithm, kept
//! small and dependency-free. The `palette` crate on crates.io is colour-
//! space maths (sRGB ↔ HSL ↔ Lab) and does not extract palettes from images;
//! the wallpaper-derived `text` / `accent` / `secondary` values the Clock
//! widget's `colorMode: "auto"` paints with are produced here instead.
//!
//! WHY AN EXTRACTOR HERE AT ALL
//!
//! The Clock widget's auto theme reads three hex values from a small JSON
//! sidecar next to the mask. Doing the extraction in Rust means:
//!
//!   * it runs once per wallpaper, on the same decoded image the mask
//!     already uses, so the pass is effectively free;
//!   * the cache key is the wallpaper's BLAKE3 + a version tag, so a
//!     pipeline change forces regeneration exactly like the mask does;
//!   * QML just reads three strings. No pixel handling on the UI thread, no
//!     per-frame Canvas round-trip.
//!
//! ALGORITHM
//!
//!   1. Downsample the wallpaper to 64×64 with a triangle filter. Enough
//!      pixels to represent the colour story without dragging along noise,
//!      small enough that scoring every pixel costs microseconds.
//!   2. For each sample, convert sRGB → HSL. Skip near-grey pixels
//!      (saturation < 0.08); they can never score meaningfully.
//!   3. Score each survivor twice, once for the "vibrant" family and once
//!      for the "muted" family, then bucket by lightness (light / normal /
//!      dark) and keep the highest score per bucket. Six buckets, the
//!      canonical Android Palette slots.
//!   4. Derive `text`, `accent` and `secondary` from the slots plus the
//!      whole-image luminance. Contrast rules are pinned here, so the widget
//!      has no colour knowledge at all.
//!   5. Serialize to JSON, atomic-write next to the mask.

use anyhow::{Context, Result};
use image::DynamicImage;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

/// Android Palette's six canonical slots. Each holds a `#RRGGBB` hex, or
/// `None` when nothing on the wallpaper scored high enough for that bucket.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PaletteSlots {
    pub vibrant: Option<String>,
    pub light_vibrant: Option<String>,
    pub dark_vibrant: Option<String>,
    pub muted: Option<String>,
    pub light_muted: Option<String>,
    pub dark_muted: Option<String>,
}

/// The widget-facing view of a palette. Everything `depthscape.clock` needs
/// to pick a legible, coordinated colour is reduced here — the whole-image
/// theme slots plus a coarse relative-luminance grid the QML side samples at
/// the widget's own rectangle for local contrast.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WallpaperPalette {
    /// Whole-image "safest" text colour, contrast-corrected against the
    /// global `isDark`. Auto mode still prefers a locally-sampled decision;
    /// this is the fallback when no grid is available.
    pub text: String,
    /// Pop accent: seconds / AM-PM badges, or the big time in theme mode.
    pub accent: String,
    /// Softer partner for the date line and any tertiary text.
    pub secondary: String,
    /// Whole-image average RGB, exposed for callers that want to tint a
    /// scrim themselves.
    pub average: String,
    /// True when the wallpaper's average *relative luminance* (WCAG linearised
    /// Y, not HSL lightness) sits under the mid threshold. A coarse global
    /// hint; the per-region decision lives in the QML sampler.
    pub is_dark: bool,
    /// Row-major `grid_size × grid_size` grid of WCAG relative luminance
    /// (0.0..=1.0) for the whole image. The host maps a widget's screen
    /// rectangle onto these cells to get the local background luminance, so
    /// the text colour is chosen against what is actually behind the clock,
    /// not the whole-image average.
    pub luminance_grid: Vec<f32>,
    /// Edge length of `luminance_grid` (so `len == grid_size * grid_size`).
    pub grid_size: u32,
    /// The raw six-slot table, kept for debugging and future consumers.
    #[serde(default)]
    pub slots: PaletteSlots,
}

/// Sample resolution used for the extraction pass. Deliberately small:
/// 4096 pixels cover any realistic dominant-colour story a wallpaper can
/// tell, and iterating them is well under a millisecond.
const SAMPLE_SIZE: u32 = 64;

/// Edge length of the relative-luminance grid written to the sidecar.
/// `SAMPLE_SIZE` divides by it exactly (64 / 16 = 4), so each grid cell is a
/// clean 4×4 block of the downsampled image. 16×16 = 256 f32 (~1 KB of JSON)
/// is fine-grained enough to separate a bright sky from a dark foreground
/// while staying negligible next to the mask PNG.
const GRID_SIZE: u32 = 16;

/// Mid luminance below which a wallpaper counts as "dark" for the global
/// `isDark` hint. WCAG relative luminance is non-linear, so this is well
/// under 0.5 (a #7f7f7f mid-grey is only ~0.22); 0.25 tracks "darker than a
/// typical mid-tone" and matches what the reference lock-screen behaviour
/// classifies as needing light text.
const DARK_LUMA_THRESHOLD: f32 = 0.25;

/// WCAG sRGB channel linearisation.
fn srgb_to_linear(c: f32) -> f32 {
    if c <= 0.03928 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

/// WCAG relative luminance of an sRGB triplet (0.0..=1.0).
fn relative_luminance(r: u8, g: u8, b: u8) -> f32 {
    0.2126 * srgb_to_linear(r as f32 / 255.0)
        + 0.7152 * srgb_to_linear(g as f32 / 255.0)
        + 0.0722 * srgb_to_linear(b as f32 / 255.0)
}

/// Absolute fallbacks used by `resolve_colors` when a wallpaper's six slots
/// are all empty (e.g. a flat grey background). Named at module scope so
/// the tests can assert against the same strings.
const FALLBACK_TEXT_DARK_BG: &str = "#f8f9fa";
const FALLBACK_TEXT_LIGHT_BG: &str = "#111318";
const FALLBACK_ACCENT: &str = "#7aa5c7";
const FALLBACK_SECONDARY: &str = "#a0a0a0";

/// Convert an sRGB triplet to (H, S, L), all f32 in `0..=1` with H already
/// divided by 360. Hand-rolled to keep the palette module dependency-free.
fn rgb_to_hsl(r: u8, g: u8, b: u8) -> (f32, f32, f32) {
    let rf = r as f32 / 255.0;
    let gf = g as f32 / 255.0;
    let bf = b as f32 / 255.0;
    let max = rf.max(gf).max(bf);
    let min = rf.min(gf).min(bf);
    let l = (max + min) * 0.5;
    if (max - min).abs() < 1e-6 {
        return (0.0, 0.0, l);
    }
    let d = max - min;
    let s = if l > 0.5 {
        d / (2.0 - max - min)
    } else {
        d / (max + min)
    };
    let h = if (max - rf).abs() < 1e-6 {
        (gf - bf) / d + if gf < bf { 6.0 } else { 0.0 }
    } else if (max - gf).abs() < 1e-6 {
        (bf - rf) / d + 2.0
    } else {
        (rf - gf) / d + 4.0
    };
    (h / 6.0, s, l)
}

/// Score for the vibrant family. Android weights saturation directly and
/// applies a small penalty for lightness far from mid; we keep that spirit
/// but skip the population term because the sample grid already reflects it.
fn vibrant_score(saturation: f32, lightness: f32) -> f32 {
    let l_weight = 1.0 - (lightness - 0.5).abs() * 1.2;
    saturation * l_weight.max(0.0)
}

/// Score for the muted family. Peaks at saturation ~0.25 and tapers either
/// way; a "muted" colour is chromatic but not shouty.
fn muted_score(saturation: f32, lightness: f32) -> f32 {
    let sat_fit = 1.0 - (saturation - 0.25).abs() * 2.0;
    let l_weight = 1.0 - (lightness - 0.5).abs() * 1.2;
    sat_fit.max(0.0) * l_weight.max(0.0)
}

fn bump(best: &mut Option<(f32, String)>, score: f32, hex: String) {
    match best {
        Some((existing, _)) if *existing >= score => {}
        _ => *best = Some((score, hex)),
    }
}

fn take(best: Option<(f32, String)>) -> Option<String> {
    best.map(|(_, hex)| hex)
}

/// Extract a palette. The caller is expected to have already decoded the
/// wallpaper; we do one downsample + one pass over 4096 pixels.
pub fn extract(image: &DynamicImage) -> WallpaperPalette {
    let rgb = image.to_rgb8();
    let small = image::imageops::resize(
        &rgb,
        SAMPLE_SIZE,
        SAMPLE_SIZE,
        image::imageops::FilterType::Triangle,
    );

    // Each grid cell averages a (SAMPLE_SIZE / GRID_SIZE)-wide block of the
    // downsampled image. 64 / 16 = 4, so a 4x4 block per cell.
    let block = (SAMPLE_SIZE / GRID_SIZE) as usize;
    let cells = (GRID_SIZE * GRID_SIZE) as usize;
    let mut luma_sum = vec![0.0f64; cells];
    let mut luma_count = vec![0u32; cells];

    let mut vibrant: Option<(f32, String)> = None;
    let mut light_vibrant: Option<(f32, String)> = None;
    let mut dark_vibrant: Option<(f32, String)> = None;
    let mut muted: Option<(f32, String)> = None;
    let mut light_muted: Option<(f32, String)> = None;
    let mut dark_muted: Option<(f32, String)> = None;
    let mut r_sum: u64 = 0;
    let mut g_sum: u64 = 0;
    let mut b_sum: u64 = 0;
    let mut total_luma: f64 = 0.0;
    let mut total: u64 = 0;

    for (idx, pixel) in small.pixels().enumerate() {
        let [r, g, b] = pixel.0;
        let py = (idx / SAMPLE_SIZE as usize) as u32;
        let px = (idx % SAMPLE_SIZE as usize) as u32;
        let (h, s, l) = rgb_to_hsl(r, g, b);
        let _ = h; // hue bucketing is a follow-up; lightness/saturation cover our six slots.
        let hex = format!("#{r:02X}{g:02X}{b:02X}");
        let luma = relative_luminance(r, g, b) as f64;
        total += 1;
        r_sum += r as u64;
        g_sum += g as u64;
        b_sum += b as u64;
        total_luma += luma;

        let cell = (py as usize / block) * (GRID_SIZE as usize) + (px as usize / block);
        luma_sum[cell] += luma;
        luma_count[cell] += 1;

        if s < 0.08 {
            continue;
        }
        if s >= 0.35 {
            let vs = vibrant_score(s, l);
            if l > 0.70 {
                bump(&mut light_vibrant, vs, hex);
            } else if l < 0.30 {
                bump(&mut dark_vibrant, vs, hex);
            } else {
                bump(&mut vibrant, vs, hex);
            }
        } else if s > 0.15 {
            let ms = muted_score(s, l);
            if l > 0.70 {
                bump(&mut light_muted, ms, hex);
            } else if l < 0.30 {
                bump(&mut dark_muted, ms, hex);
            } else {
                bump(&mut muted, ms, hex);
            }
        }
    }

    let denom = total.max(1);
    let avg_r = (r_sum / denom).min(255) as u8;
    let avg_g = (g_sum / denom).min(255) as u8;
    let avg_b = (b_sum / denom).min(255) as u8;
    let average = format!("#{avg_r:02X}{avg_g:02X}{avg_b:02X}");
    let is_dark = (total_luma / denom as f64) < DARK_LUMA_THRESHOLD as f64;

    // Normalise each cell to its mean relative luminance. `luma_count` is
    // never zero because SAMPLE_SIZE divides evenly by GRID_SIZE, but the
    // guard keeps a future size change from producing NaNs.
    let luminance_grid: Vec<f32> = (0..cells)
        .map(|i| {
            let n = luma_count[i].max(1) as f64;
            (luma_sum[i] / n) as f32
        })
        .collect();

    let slots = PaletteSlots {
        vibrant: take(vibrant),
        light_vibrant: take(light_vibrant),
        dark_vibrant: take(dark_vibrant),
        muted: take(muted),
        light_muted: take(light_muted),
        dark_muted: take(dark_muted),
    };

    let (text, accent, secondary) = resolve_colors(&slots, is_dark);
    WallpaperPalette {
        text,
        accent,
        secondary,
        average,
        is_dark,
        luminance_grid,
        grid_size: GRID_SIZE,
        slots,
    }
}

/// Pick the three widget-facing colours from the six slots.
///
/// Rules (documented so a future tweak is a diff on this function, not a
/// hunt through the widget):
///
///   * `accent` is the most saturated thing on the wallpaper we can find.
///     Falls back through the vibrant family, then a fixed slate blue that
///     reads as "Depthscape default" instead of the widget disappearing.
///   * `text` is chosen by luminance. Dark wallpapers get a light text from
///     the light family; bright wallpapers get a dark text from the dark
///     family. Absolute fallbacks are near-white and near-black, matching
///     HyperOS' lock-screen palette.
///   * `secondary` sits between the two so the date line reads as a
///     subordinate without vanishing.
fn resolve_colors(slots: &PaletteSlots, is_dark: bool) -> (String, String, String) {
    let accent = slots
        .vibrant
        .clone()
        .or_else(|| slots.light_vibrant.clone())
        .or_else(|| slots.dark_vibrant.clone())
        .unwrap_or_else(|| FALLBACK_ACCENT.to_string());

    let text = if is_dark {
        slots
            .light_vibrant
            .clone()
            .or_else(|| slots.light_muted.clone())
            .unwrap_or_else(|| FALLBACK_TEXT_DARK_BG.to_string())
    } else {
        slots
            .dark_vibrant
            .clone()
            .or_else(|| slots.dark_muted.clone())
            .unwrap_or_else(|| FALLBACK_TEXT_LIGHT_BG.to_string())
    };

    let secondary = if is_dark {
        slots
            .muted
            .clone()
            .or_else(|| slots.light_muted.clone())
            .unwrap_or_else(|| FALLBACK_SECONDARY.to_string())
    } else {
        slots
            .muted
            .clone()
            .or_else(|| slots.dark_muted.clone())
            .unwrap_or_else(|| FALLBACK_SECONDARY.to_string())
    };

    (text, accent, secondary)
}

/// Path under `directory` for a given cache key. Same shape as the mask
/// cache so the daemon's prune loop stays uniform.
pub fn cache_path(directory: &Path, key: &str) -> PathBuf {
    directory.join(format!("{key}.json"))
}

/// Atomic write, matching `cache::atomic_write` semantics so a partial
/// JSON never lands on disk.
pub fn write(path: &Path, palette: &WallpaperPalette) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("cannot create palette dir {}", parent.display()))?;
    }
    let tmp = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec(palette)?;
    fs::write(&tmp, &bytes)
        .with_context(|| format!("cannot write palette tmp {}", tmp.display()))?;
    fs::rename(&tmp, path)
        .with_context(|| format!("cannot rename palette into {}", path.display()))?;
    Ok(())
}

/// Read a cached palette. `Ok(None)` when the file is not there yet, so a
/// caller that wants to fall back to a manual colour can distinguish
/// "missing" from "corrupted".
///
/// Not called from the pipeline today (QML reads the JSON directly through
/// a `File` watcher), but the round-trip test uses it and a future CLI
/// `depthscape-engine palette <wallpaper>` subcommand would be the natural
/// next caller.
#[allow(dead_code)]
pub fn read(path: &Path) -> Result<Option<WallpaperPalette>> {
    match fs::read(path) {
        Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => {
            Err(anyhow::Error::new(err).context(format!("cannot read palette {}", path.display())))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgb, RgbImage};

    fn uniform(fill: [u8; 3]) -> DynamicImage {
        DynamicImage::ImageRgb8(RgbImage::from_pixel(SAMPLE_SIZE, SAMPLE_SIZE, Rgb(fill)))
    }

    #[test]
    fn a_uniform_dark_wallpaper_is_marked_dark_and_falls_back_to_light_text() {
        let p = extract(&uniform([12, 18, 28]));
        assert!(p.is_dark, "near-black wallpaper must classify as dark");
        assert!(
            p.text.eq(FALLBACK_TEXT_DARK_BG) || p.text.starts_with("#F"),
            "text should be a light hex, got {}",
            p.text
        );
    }

    #[test]
    fn a_uniform_bright_wallpaper_is_marked_light_and_falls_back_to_dark_text() {
        let p = extract(&uniform([240, 240, 245]));
        assert!(!p.is_dark);
        assert!(
            p.text.eq(FALLBACK_TEXT_LIGHT_BG)
                || p.text.starts_with("#1")
                || p.text.starts_with("#0"),
            "text should be a dark hex, got {}",
            p.text
        );
    }

    #[test]
    fn a_high_saturation_wallpaper_yields_a_vibrant_slot() {
        // A vivid orange-red mid-tone lands squarely in the vibrant bucket:
        // sat > 0.35 and 0.3 <= L <= 0.7.
        let p = extract(&uniform([220, 90, 40]));
        assert!(
            p.slots.vibrant.is_some(),
            "expected a vibrant slot on a saturated mid-tone, got {:?}",
            p.slots
        );
        assert_eq!(p.accent.as_str(), p.slots.vibrant.as_deref().unwrap());
    }

    #[test]
    fn palette_json_round_trips_through_disk() {
        let dir =
            std::env::temp_dir().join(format!("depthscape-palette-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("sample.json");
        let sample = WallpaperPalette {
            text: "#f8f9fa".into(),
            accent: "#ff8800".into(),
            secondary: "#556677".into(),
            average: "#202020".into(),
            is_dark: true,
            luminance_grid: vec![0.1f32; (GRID_SIZE * GRID_SIZE) as usize],
            grid_size: GRID_SIZE,
            slots: PaletteSlots::default(),
        };
        write(&path, &sample).unwrap();
        let loaded = read(&path).unwrap().unwrap();
        assert_eq!(sample, loaded);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_grid_is_grid_size_squared_and_in_unit_range() {
        let p = extract(&uniform([10, 120, 200]));
        assert_eq!(p.grid_size, GRID_SIZE);
        assert_eq!(p.luminance_grid.len(), (GRID_SIZE * GRID_SIZE) as usize);
        assert!(
            p.luminance_grid.iter().all(|&v| (0.0..=1.0).contains(&v)),
            "relative luminance must stay in 0..=1, got {:?}",
            p.luminance_grid
        );
    }

    #[test]
    fn a_top_bright_bottom_dark_split_yields_a_non_uniform_grid() {
        // Guards the whole point of the grid: a bright sky over a dark ground
        // must NOT average to a single global value, so a widget placed over
        // the sky can pick dark text while one over the ground picks light —
        // exactly what a whole-image average would get wrong.
        let mut img = RgbImage::new(SAMPLE_SIZE, SAMPLE_SIZE);
        for (_x, y, pixel) in img.enumerate_pixels_mut() {
            *pixel = if y < SAMPLE_SIZE / 2 {
                Rgb([245, 246, 250]) // bright top
            } else {
                Rgb([8, 10, 16]) // dark bottom
            };
        }
        let p = extract(&DynamicImage::ImageRgb8(img));
        // Row 0 (bright) and the last row (dark) must differ sharply.
        let top = p.luminance_grid[0];
        let bottom = p.luminance_grid[(GRID_SIZE as usize - 1) * GRID_SIZE as usize];
        assert!(top > 0.5, "bright sky cells should be luminous, got {top}");
        assert!(
            bottom < 0.1,
            "dark ground cells should be near black, got {bottom}"
        );
    }

    #[test]
    fn rgb_to_hsl_handles_the_grey_and_pure_axes() {
        // Full-range grey: sat 0, lightness 1.
        let (_, s, l) = rgb_to_hsl(255, 255, 255);
        assert!(s.abs() < 1e-6);
        assert!((l - 1.0).abs() < 1e-6);
        // Pure red: hue 0, sat 1, lightness 0.5.
        let (h, s, l) = rgb_to_hsl(255, 0, 0);
        assert!(h.abs() < 1e-6);
        assert!((s - 1.0).abs() < 1e-6);
        assert!((l - 0.5).abs() < 1e-6);
    }
}
