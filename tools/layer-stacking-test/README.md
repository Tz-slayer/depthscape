# Layer-stacking test

The plugin's whole visual effect rests on one claim: a full-screen surface on the
`bottom` layer can be made to render **in front of** the desktop widgets, which
live on the same layer. This directory is the harness that proves it, and
`probe.py` is the check that decides the outcome from pixels rather than from
reasoning.

Run it after touching anything in `qml/DepthForeground.qml` or the stacking part
of `qml/DepthDaemon.qml`.

## What is being tested

Two separate mechanisms:

1. **Occlusion.** Where the mask is opaque, the foreground must hide a widget
   that sits underneath it on the same layer.
2. **Re-raising.** DMS rebuilds its desktop-widget surfaces whenever the widget
   list changes (`Modules/DesktopWidgetLayer.qml`: `rebuildDebounce` 150 ms, then
   `rebuildApply` 32 ms). Rebuilt surfaces are mapped *after* ours, and layer
   surfaces stack by map order, so a rebuild silently puts the widgets back in
   front. `DepthDaemon.raiseForeground()` destroys and re-creates the foreground
   surfaces to claim the top of the layer again. This harness reproduces both the
   breakage and the fix.

## Layout

```
W1   magenta 400x400 @ logical (410,550)   mapped at t=0
FG   the real DepthDaemon                  mapped once the engine answers
W2   cyan    400x400 @ logical (1960,330)  mapped at t=14s
```

`W2` is the stand-in for "DMS rebuilt its widgets": a same-layer surface that
appears late.

## Running it

```sh
tools/layer-stacking-test/setup.sh
export DEPTHSCAPE_ENGINE=$PWD/engine/target/release/depthscape-engine
qs -p tools/layer-stacking-test
```

`setup.sh` symlinks the DankMaterialShell import roots and this plugin's QML next
to `shell.qml`, so the harness loads the real components. `qs -p` starts an
isolated Quickshell instance and does not disturb a running DMS.

The harness is meant to be pointed at an **empty workspace** — a screenshot of
an output covered by tiled windows shows the windows, not the `bottom` layer.
Focus that output before capturing:

```sh
niri msg action focus-monitor-left                 # or whichever has no windows
niri msg action screenshot-screen --path /tmp/a.png
```

Note that `niri msg action screenshot-screen` captures the *focused* output, and
that the file appears a moment after the command returns.

## Reading the result

`probe.py` does not sample a point. It tests two competing hypotheses over the
whole 400x400 rect, because the mask varies across a panel even when its centre
is a clean 0 or 1:

```
H_fg      alpha * wallpaper + (1 - alpha) * widget_colour
H_widget  widget_colour
```

Mean absolute error is in 0..255 units; a correct compositing lands near 1 and
the wrong hypothesis near 100. Exit status is 0 when the foreground wins both
panels, 1 otherwise.

```sh
python3 tools/layer-stacking-test/probe.py \
    --screenshot /tmp/a.png \
    --mask "$(ls ~/.local/share/depthscape/cache/masks/*.png | head -1)" \
    --wallpaper ~/Pictures/Wallpapers/frieren-beyond-5120x2880-25925.jpg
```

Add `--logical 2560x1440` if the output is not 2560x1440 logical.

## Measured result (2026-09-19, niri 26.04, DP-1 @ scale 1.5)

Capture taken 14 s in, i.e. after `W2` has been mapped on top of the foreground:

```
W2 cyan     MAE[foreground on top] 104.32   MAE[widget on top]   0.00  -> WIDGET
W1 magenta  MAE[foreground on top]   0.63   MAE[widget on top]  14.36  -> FOREGROUND
```

`0.00` on `W2` means the panel was pixel-for-pixel pure cyan — the late-mapped
widget was completely in front. The bug is real.

Then `qs ipc -i <instance> call depthscape raise`, wait ~2 s, capture again:

```
W2 cyan     MAE[foreground on top]   1.08   MAE[widget on top] 104.35  -> FOREGROUND
W1 magenta  MAE[foreground on top]   0.63   MAE[widget on top]  14.36  -> FOREGROUND
```

The foreground is back on top, and the observed pixels match the mask model to
within 1.08/255 — the residual wedge of cyan still visible in the lower-left of
the panel is the part of the mask that is genuinely transparent there, not a
failure. Checked against the mask directly: that rect is 21.76 % `alpha < 0.05`
and 26.21 % `alpha < 0.5`, while 23.74 % of it reads as pure cyan — between the
two, the difference being the semi-transparent fringe.

`W1` reports identical numbers in both states, which is the control: it sits in a
transparent part of the mask, so it is never occluded and must not change.

Two further checks worth repeating by hand:

* `niri msg layers` must show **exactly one** `dms:plugins:depthscape-foreground`
  surface per output after several raises — the `Loader` destroy/re-create must
  not leak surfaces.
* The shell log must contain no QML errors or binding-loop warnings across the
  raise cycle.

## What `niri msg layers` cannot tell you

Its listing order is not a z-order oracle. It iterates the compositor's raw
`layer_map.layers()`, and probes with identical listing order have produced
opposite topmost surfaces. Use it for presence and for the layer name, and use
`probe.py` for order.
