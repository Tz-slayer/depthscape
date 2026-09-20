# Depthscape

Depth-aware wallpapers for DankMaterialShell. A local depth model splits your
wallpaper into a subject and a background, and the subject is drawn above your
desktop widgets — so characters and scenery occlude your clock and cards, the
way an iOS depth-effect lock screen does.

![Depthscape in action](assets/screenshot.png)

The model runs once per wallpaper change. The desktop side is pure GPU
compositing, so nothing is inferred while you work.

## Features

- Local depth estimation with Depth Anything V2 Small — no network access after
  the one-time model download
- Three-tier cache: dragging the sliders re-runs the split only, never the model
- One wallpaper per monitor, split independently
- Click-through surfaces, so the widgets underneath stay usable
- Blurs itself in the niri overview, matching DMS's own wallpaper treatment
- Desktop status tile and a settings page

## Requirements

- DankMaterialShell 1.5.0 or newer
- Rust 1.88+ (to build the engine)
- `curl` (model download only)

No extra QML modules. Everything Depthscape imports ships with Quickshell.

## How it works

Depthscape is a **wallpaper replacement**, not an overlay. That is the part worth
understanding before installing it.

The engine emits a matched pair per wallpaper: `foreground.png` (the subject,
with coverage in the alpha channel) and `background.png` (the same scene with the
subject's region filled in by a blurred estimate of its surroundings). Both are
drawn on the compositor's `background` layer, with your widgets and the
foreground sandwiched in between.

A single-mask overlay cannot produce this effect, and it is worth saying why.
Drawing a cut-out over DMS's own wallpaper composites
`alpha * wallpaper + (1 - alpha) * wallpaper` — the *same* wallpaper — which is
algebraically just `wallpaper`. The subject region comes out pixel-identical
whether or not the overlay is drawn. Splitting the image into two layers is the
only way to get the subject in front of a widget.

The practical consequence: **when the effect is on, turn DMS's own wallpaper off**
(or point it at a flat colour). Two wallpapers would be drawn, and the one you see
would depend on map order.

## Build the engine

The plugin store installs the QML, not the engine. Build it once:

```bash
cd engine
cargo build --release
```

The binary is looked up in `$DEPTHSCAPE_ENGINE`, then
`<plugin dir>/engine/target/release`, then `debug`, then `PATH`. If none of them
exist, the startup check refuses to activate the plugin and prints this command.

## Install

From the plugin store, search for *Depthscape* under **Settings → Plugins →
Browse**.

From a local checkout:

```bash
ln -s "$(pwd)" ~/.config/DankMaterialShell/plugins/depthscape
dms restart
```

Then enable **Depthscape** under **Settings → Plugins**.

## First run

1. Open the plugin settings and press **Install model**. This downloads 99 MB
   from Hugging Face and verifies a pinned SHA-256.
2. Set an **image** wallpaper on each monitor, then turn DMS's wallpaper off —
   see *How it works* above. Solid colours are skipped.
3. The split is generated automatically. If the result is too aggressive or too
   subtle, adjust **Foreground threshold** and **Edge feather**.

## Widgets

Depthscape hosts its own desktop widgets, because DMS's are on a layer below the
subject and are repeated into every overview workspace card.

Layout lives in `$XDG_DATA_HOME/depthscape/widgets.json` (or
`$DEPTHSCAPE_DATA_DIR`):

```json
{
  "widgets": [
    {
      "id": "clock",
      "type": "clock",
      "x": 1100,
      "y": 850,
      "settings": { "showSeconds": false, "showDate": true }
    }
  ]
}
```

`x` and `y` are logical pixels from the top-left of the output; an optional
`screen` key restricts a widget to one monitor. The settings page has a
**Write example layout** button to get started.

Only widget types on a built-in allow-list can be loaded. The layout file lives
in your data directory, and letting it name an arbitrary QML file would make a
data file executable.

## Engine CLI

The engine also works standalone:

```bash
depthscape-engine status
depthscape-engine setup
depthscape-engine analyze --wallpaper a.png --threshold 0.30 --feather 0.08
depthscape-engine clear-cache
```

`analyze` prints a single line of JSON with the foreground and background paths,
the cache status, and a per-stage timing breakdown. `--threshold` (0.0–1.0) is the
depth cutoff — lower values bring more of the scene in front — and `--feather`
(0.0–0.5) is the transition width around it.

## Status

Working on niri. Hyprland is expected to work but is untested, which is why
`compositors` lists only niri. Occlusion has been verified pixel-by-pixel on a
single output so far. Planned: navigation-driven parallax, a depth shader, and
building the engine from inside the plugin.

## License

MIT. Depth Anything V2 Small is distributed by Hugging Face under Apache-2.0 and
downloaded on first use. All inference, depth maps and masks stay on your
machine; only the model download touches the network.
