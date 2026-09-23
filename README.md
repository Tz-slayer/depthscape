# Depthscape

Depth-aware wallpapers for DankMaterialShell. A local depth model splits your
wallpaper into a subject and a background, and the subject is drawn above
Depthscape's desktop widgets — so characters and scenery occlude its clock and
cards the way an iOS depth-effect lock screen does. Ordinary application windows
remain above the wallpaper, as they should.

![Depthscape in action](assets/screenshot.png)

The model runs once per wallpaper change. The desktop side is pure GPU
compositing, so nothing is inferred while you work.

## Features

- Local depth estimation with Depth Anything V2 Small — no network access after
  the one-time model download
- Three-tier cache: dragging the sliders re-runs the split only, never the model
- One wallpaper per monitor, split independently
- Click-through surfaces, so the widgets underneath stay usable
- Navigation parallax: moving between workspaces and columns slides the scene
  (subject and background together) over stationary desktop widgets, and
  stepping back returns the scene exactly where it started
- Owns the niri overview backdrop, so the workspace cards share one continuous
  wallpaper instead of repeating a copy per card
- Desktop status tile and a settings page

## Requirements

- DankMaterialShell 1.5.0 or newer
- niri 25.05 or newer (for `place-within-backdrop` layer rules)
- Rust 1.88+ (to build the engine)
- `curl` (model download only)

No extra QML modules. Everything Depthscape imports ships with Quickshell.

## One required niri setting

Depthscape's three surfaces sit on the `background` layer, but **that alone is not
enough**. niri only puts a surface into the overview's *shared backdrop* — the one
image spanning every workspace card and the gaps between them — when a layer rule
carrying `place-within-backdrop true` matches it. Without the rule the surfaces are
ordinary background surfaces, and niri clones them into *every* workspace card:
you get one copy of the wallpaper per card, each cropped to its own geometry.

Add this to your niri config (e.g. `~/.config/niri/dms/local/custom.kdl`) and
reload:

```kdl
// Put Depthscape inside the overview backdrop.
layer-rule {
    match namespace="^depthscape:"
    place-within-backdrop true
}
```

`^depthscape:` is a prefix match, so one rule covers all three surfaces
(`:background`, `:widgets`, `:foreground`). A plugin cannot add a layer rule on
its own — this has to be done by hand.

## How it works

Depthscape draws its own wallpaper and layers your widgets in the middle. That is
the part worth understanding before installing it.

The engine emits a matched pair per wallpaper: `foreground.png` (the subject,
with coverage in the alpha channel) and `background.png` (the same scene with the
subject's region filled in by a blurred estimate of its surroundings). Both are
drawn on the compositor's `background` layer, with Depthscape's widgets
sandwiched between them.

A single-mask overlay cannot produce this effect, and it is worth saying why.
Drawing a cut-out over DMS's own wallpaper composites
`alpha * wallpaper + (1 - alpha) * wallpaper` — the *same* wallpaper — which is
algebraically just `wallpaper`. The subject region comes out pixel-identical
whether or not the overlay is drawn. Splitting the image into two layers is the
only way to get the subject in front of a widget.

**Keeping DMS's own wallpaper on is optional.** Depthscape provides the overview
backdrop itself, so the wallpaper behind the workspace cards is ours — one
continuous image, blurred to match the setting DMS applies to its own wallpaper
(`blurWallpaperOnOverview`). DMS's wallpaper still helps as a fallback: it covers
the moment before the split images have decoded, so switching wallpapers does not
flash. If you would rather not draw two copies of the same image, point DMS's
wallpaper at a flat colour.

Because the backdrop is a single image shared by every card, the widgets and the
subject fade out there — a wallpaper is one image per screen and should read as
one. All three layers stay mapped and dim together; unmapping the subject instead
would leave the overview marginally cleaner but pops, because the compositor has
to rebuild the backdrop in a single frame.

Depthscape and DMS's wallpaper end up in the *same* backdrop, and niri renders a
backdrop in map order (last mapped draws on top), so Depthscape re-asserts its
stack a few times after startup. Anyone touching the surface code should read
§14.1 and §14.6 of the design notes first — the ordering is subtler than the layer
names suggest.

## Parallax

Moving between workspaces and columns slides the whole scene — the subject and
the background together, by exactly the same amount. They are a matched pair of
one image: the background is the same scene with the subject's region infilled,
so anything less than an identical shift would pull the subject away from the hole
it covers and expose the inpainting artifacts. The depth comes from the pair
moving together against desktop widgets (like the clock and cards), which hold
still: they are what the subject stands in front of and therefore the reference
frame the depth is read against.

The offset is *cumulative*, not a per-keypress animation: each step moves the
scene by a little less than the one before, and stepping back retraces the same
path. Step away and step back and the scene lands exactly where it started. The
whole thing is bounded by **Total travel**, which is the asymptote those steps
approach rather than a distance ever reached.

Both layers are drawn on a canvas larger than the screen — 12% of the longer edge
for each of the two directions it can travel — so there is always image under the
viewport, and the extra is never visible at rest.

If a layer ever looks *inside-out*, misaligned, or noticeably sharper than it
should be at rest, the canvas has been scaled instead of enlarged. Scaling
resamples about the image's own centre, which displaces a static scene by half the
scale factor — larger than the parallax travel itself.

There is one thing parallax cannot do. The horizontal axis reads the focused
window's column, because niri emits no column event of its own — so on an empty
workspace there is no column to read and the horizontal axis holds still. That is
by design, not a bug.

Two controls are worth knowing about. **Invert direction** flips the sense of
travel. **Background travel** sets how much of the foreground's movement the
background echoes; at zero the subject looks pasted on, and past about 60% the
two layers stop reading as separate planes.

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

1. Open the plugin settings and select your preferred **Depth model variant**:
   - **Small** (~99 MB, fast & lightweight, default)
   - **Base** (~389 MB, balanced precision & sharper edges)
   - **Large** (~1.34 GB, top depth accuracy & fine subject contours)
   The engine automatically downloads and verifies the model on demand, or you can click **Install model**.
2. Set an **image** wallpaper on each monitor. Solid colours are skipped.
3. The split is generated automatically. If the result is too aggressive or too
   subtle, adjust **Foreground threshold** and **Edge feather**.

## Widgets

Depthscape hosts its own desktop widgets, because DMS's are instantiated once per
workspace card and would repeat the same clock in every one.

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

## Verification

```bash
tools/verify-all.sh
```

Runs the static checks (QML lint, the scroll-math unit tests, and a check that
every settings control has a key the daemon reads), the engine's `cargo test`,
and three live pixel-level checks: that a forced parallax offset reaches the
screen in preference to the three ways it could fail to, that the background is
moving by the configured fraction, and that navigating away and back returns the
scene to where it started.

The live checks screenshot the focused output, so they need a workspace with
nothing on it and will walk to one — expect the desktop to move for a few
seconds. Measured error floor is about 0.7/255 against a clean frame; the
parallax check's margin over the next-best explanation is about 10.

## Status

Working on niri. Hyprland is expected to work but is untested, which is why
`compositors` lists only niri. Occlusion and parallax have both been verified
pixel-by-pixel on a single output so far. Planned: a depth shader and building
the engine from inside the plugin.

## License

MIT. Depth Anything V2 Small is distributed by Hugging Face under Apache-2.0 and
downloaded on first use. All inference, depth maps and masks stay on your
machine; only the model download touches the network.
