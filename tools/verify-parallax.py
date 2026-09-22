#!/usr/bin/env python3
"""Measure the parallax against the screen, pixel for pixel.

The parallax is the one part of Depthscape that cannot be checked by reading
state: the daemon can report an offset while nothing on screen moves, because a
binding that never re-evaluates looks exactly like a correct one from the
inside. This script closes that gap by comparing what the screen *shows* with
what the two split layers say it should show.

THE MODEL

Depthscape draws the wallpaper as two stacked images: a background (the scene
with the subject cut out) and a foreground (the subject, with alpha). At rest
they are pixel-registered with the original wallpaper, so compositing them
reproduces it:

    composite = fg * a + bg * (1 - a)

With the parallax engaged the two layers move together as a single scene,
both traveling `s` while desktop widgets in between hold still. Reproducing
that from the split files is a matter of sampling each layer at its displaced
coordinate:

    expected = fg[x', y'] * a[x', y'] + bg[x', y'] * (1 - a[x', y'])

The screen is then compared against that prediction, and the script reports the
mean absolute error. Two numbers matter:

  * MAE at the offset the daemon claims it is using — should be small (a few
    units out of 255). Anything larger means the layers are not where the daemon
    thinks they are.
  * The ratio sweep — comparing the captured screen against a range of background
    ratios relative to the foreground. The expected ratio is +1.00 (both layers
    moving in lockstep); a minimum at 0.00 means the background is stuck, while
    -1.00 corresponds to the obsolete diverging layers bug.

WHY THE SWEEP IS NOT OPTIONAL

An earlier round of this work concluded the ratio was 0.00 — that is, that the
background should not move — because the daemon was reporting an offset its
surfaces were not honouring and the sweep found "no movement" fit best. The
sweep cannot tell "correct" from "not applied"; only the comparison against a
known-good forced offset can. Run `--self-test` first, which forces a large
offset through the IPC hook and asserts that the screen follows.

USAGE

    # busy a screenshot needs a clean desktop: switch to an empty workspace first
    niri msg action focus-workspace-down

    python3 tools/verify-parallax.py --self-test
    python3 tools/verify-parallax.py --sweep
"""

from __future__ import annotations

import argparse
import glob
import json
import math
import os
import subprocess
import sys
import time

try:
    from PIL import Image
    import numpy as np
except ImportError:
    sys.exit("needs pillow and numpy: pip install pillow numpy")


def data_dir() -> str:
    return os.environ.get("DEPTHSCAPE_DATA_DIR") or os.path.join(
        os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
        "depthscape")


def ipc(*args: str) -> str:
    """Call one of the plugin's IPC methods and return its raw reply.

    Declared early because the cache lookup below uses it: the daemon is the
    only thing that knows which cache entry is on screen.
    """
    result = subprocess.run(["dms", "ipc", "call", "depthscape", *args],
                            capture_output=True, text=True)
    return (result.stdout or result.stderr).strip()


def cache_dir() -> str:
    return os.path.join(data_dir(), "cache", "split")


def split_files() -> tuple[str, str]:
    """The split pair the running shell is actually showing.

    NOT the newest pair on disk. The cache holds one entry per wallpaper and per
    pipeline version, so the most recently written file usually belongs to a
    wallpaper that is not on screen — and comparing the screen against a
    different wallpaper's layers produces a large, plausible-looking error with
    no hint as to the cause. Measured: 11.2/255 instead of 2.1/255.

    The daemon's own `debug` dump is the authority, so its paths are used
    directly where they exist. Falling back to the newest file keeps the script
    usable against a daemon that is not running.
    """
    try:
        report = json.loads(ipc("debug"))
        screens = report.get("screens") or {}
        if screens:
            first = screens[next(iter(screens))]
            foreground = first.get("foreground") or ""
            background = first.get("background") or ""
            if foreground and background:
                return foreground, background
    except (ValueError, KeyError, StopIteration):
        pass

    directory = cache_dir()
    foregrounds = sorted(glob.glob(os.path.join(directory, "*-fg.png")),
                         key=os.path.getmtime)
    if not foregrounds:
        sys.exit(f"no split images in {directory}; run the engine first")
    newest = foregrounds[-1]
    return newest, newest[:-len("-fg.png")] + "-bg.png"


def focused_output() -> str | None:
    """The name of the output `screenshot-screen` will capture.

    Read once and used for both the size and the emptiness check, so the two
    cannot disagree about which monitor is being measured — see the note on
    `focused_workspace_is_clear` for what that costs when they do.
    """
    out = subprocess.run(["niri", "msg", "focused-output"],
                         capture_output=True, text=True, check=True).stdout
    first = out.splitlines()[0] if out.splitlines() else ""
    # `Output "Some Vendor Name 0x00000001" (DP-3)` — the connector name is in
    # the parentheses, not the first bare word, which is part of the make.
    if "(" in first and first.rstrip().endswith(")"):
        return first.rstrip()[:-1].rsplit("(", 1)[1]
    return None


def screen_size() -> tuple[int, int]:
    out = subprocess.run(["niri", "msg", "focused-output"],
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if "Logical size:" in line:
            size = line.split(":", 1)[1].strip()
            width, height = size.split("x")
            return int(width), int(height)
    sys.exit("cannot read the focused output's logical size")


def screenshot(label: str = "") -> np.ndarray:
    """Grab the focused output and return it as float RGB.

    `screenshot-screen` writes into ~/Data/Pictures with a name containing
    spaces, so the newest file is found by mtime rather than by shell globbing.
    The write is asynchronous, so the file is polled for and then re-read until
    it opens cleanly — a partially flushed PNG raises rather than returning a
    wrong picture, but reading it a moment too early is the common case.

    EVERY CAPTURE RECHECKS THAT THE DESKTOP IS STILL CLEAR, and that is not
    belt-and-braces. Checking once at startup is not enough: the check and the
    capture are separated by however long the previous phase took, and anything
    that takes focus in between — a chat window, a notification, the shell that
    launched this — puts itself in the frame. The failure is silent and looks
    like a catastrophe: the layers are compared against a screenshot of a browser
    and the error comes out around 120/255, which reads as "the rendering is
    broken" rather than as "the camera moved".

    Measured: a run that passed the startup check reported a clean frame, and the
    very next capture, four seconds later, was a full-screen window. A wrong
    number that you cannot tell apart from a real regression is worse than a
    crash, so this refuses rather than measures.

    `label` is echoed so a run's log says which frame it is looking at, which is
    the only way to tell a stale screenshot from a wrong prediction after the
    fact.
    """
    if not focused_workspace_is_clear() and not overview_is_open():
        print(f"  [screenshot{(' ' + label) if label else ''}] REFUSED — the "
              f"focused output ({focused_output()}) is no longer clear;\n"
              "    something took focus since the run started. Re-run from an "
              "empty workspace.")
        sys.exit(2)
    before = set(glob.glob(os.path.expanduser("~/Data/Pictures/*.png")))
    subprocess.run(["niri", "msg", "action", "screenshot-screen"],
                   capture_output=True, text=True, check=True)
    deadline = time.time() + 8.0
    while time.time() < deadline:
        candidates = set(glob.glob(os.path.expanduser("~/Data/Pictures/*.png"))) - before
        if candidates:
            newest = max(candidates, key=os.path.getmtime)
            for _ in range(30):
                try:
                    with Image.open(newest) as probe:
                        probe.load()
                    print(f"  [screenshot{(' ' + label) if label else ''}] "
                          f"{os.path.basename(newest)}")
                    frame = np.asarray(Image.open(newest).convert("RGB"),
                                       dtype=np.float32)
                    require_no_windows_in_frame(frame, label)
                    return frame
                except Exception:
                    time.sleep(0.1)
        time.sleep(0.1)
    sys.exit("the screenshot never appeared in ~/Data/Pictures")


def load_layers(scale: float):
    """The split pair, downscaled by `scale` and split into colour and alpha."""
    fg_path, bg_path = split_files()
    alpha_img = Image.open(fg_path).convert("RGBA")
    fg_rgb = np.asarray(alpha_img.convert("RGB"), dtype=np.float32)
    alpha = np.asarray(alpha_img.split()[-1], dtype=np.float32) / 255.0
    bg_rgb = np.asarray(Image.open(bg_path).convert("RGB"), dtype=np.float32)

    if scale != 1.0:
        size = (int(fg_rgb.shape[1] * scale), int(fg_rgb.shape[0] * scale))
        fg_rgb = np.asarray(Image.fromarray(fg_rgb.astype(np.uint8)).resize(size, Image.BILINEAR), dtype=np.float32)
        bg_rgb = np.asarray(Image.fromarray(bg_rgb.astype(np.uint8)).resize(size, Image.BILINEAR), dtype=np.float32)
        alpha = np.asarray(Image.fromarray((alpha * 255).astype(np.uint8)).resize(size, Image.BILINEAR), dtype=np.float32) / 255.0
    return fg_rgb, alpha, bg_rgb


def sample(layer: np.ndarray, dx: float, dy: float, out_size, overscan: float = 0.0):
    """Sample `layer` as the compositor would, given a translation (dx, dy).

    `overscan` is the spare area the surface carries on every side, in output
    pixels. It is not a detail of the harness: both layers now size their Image
    to a canvas `overscan` larger than the viewport on each side, so the whole
    source image is stretched across `out_size + 2 * overscan` and the viewport
    sits in the middle of that. Ignoring it scales every prediction wrongly —
    measurably: the scene is drawn about 25 % larger than the viewport, so a
    model that assumes a 1:1 fit is wrong everywhere by more than the offsets
    being tested.

    The output is a window onto that canvas: output pixel (x, y) shows canvas
    pixel (x + overscan + dx, y + overscan + dy). Everything outside the canvas
    is material the layer cannot supply, so it is clamped rather than folded
    into the error as black, and `coverage_gap` reports the clamping separately.

    INTERPOLATION MATTERS MORE THAN IT LOOKS. Rounding to the nearest source
    pixel quantises the shift: with the layers pre-downscaled by two, a 107 px
    displacement lands on the same sample points as a 108 px one, and a sweep
    over the background ratio comes out as an exact three-way tie. Bilinear
    interpolation on the source grid keeps sub-pixel differences visible, which
    is the whole point of the measurement.

    `out_size` is (width, height). A numpy screen array is accepted as well and
    read as (height, width, ...), because passing an array where a size was
    meant is an easy mistake and unpacking it silently produces a wrong shape
    instead of an error.

    .. warning::

       This is the OLD model and it is kept only for `baseline_error`. It sizes
       the source independently in x and y — `scale_x = layer_w / (width + 2 *
       overscan)` — which is a stretch, not a crop. `PreserveAspectCrop` cannot
       stretch, and the difference is not subtle: on a 5120x2880 source in a
       3192x2072 canvas the true vertical scale is fixed by the *height* and the
       horizontal overflow is thrown away, while this model compresses x and y by
       different factors. Measured against a real frame it scores 26.4 where the
       faithful model scores 1.51 — it cannot tell a correct composite from a
       broken one, which is exactly the failure that made an afternoon of
       searching for a rendering bug that did not exist. Use `resample` for
       anything that has to discriminate between hypotheses.
    """
    if isinstance(out_size, np.ndarray):
        out_size = (int(out_size.shape[1]), int(out_size.shape[0]))
    width, height = int(out_size[0]), int(out_size[1])
    layer_h, layer_w = layer.shape[:2]
    scale_y = layer_h / (height + 2 * overscan)
    scale_x = layer_w / (width + 2 * overscan)

    # Source coordinates, as floats, of each output pixel's centre.
    source_y = (np.arange(height) + 0.5 + overscan + dy) * scale_y - 0.5
    source_x = (np.arange(width) + 0.5 + overscan + dx) * scale_x - 0.5

    y0 = np.floor(source_y).astype(np.int64)
    x0 = np.floor(source_x).astype(np.int64)
    wy = (source_y - y0)[:, None]
    wx = (source_x - x0)[None, :]

    y0c = np.clip(y0, 0, layer_h - 1)
    y1c = np.clip(y0 + 1, 0, layer_h - 1)
    x0c = np.clip(x0, 0, layer_w - 1)
    x1c = np.clip(x0 + 1, 0, layer_w - 1)

    if layer.ndim == 2:
        wy = wy[:, 0][:, None]
        wx = wx[0][None, :]
    else:
        wy = wy[:, :, None]
        wx = wx[:, :, None]

    top = layer[np.ix_(y0c, x0c)] * (1 - wx) + layer[np.ix_(y0c, x1c)] * wx
    bottom = layer[np.ix_(y1c, x0c)] * (1 - wx) + layer[np.ix_(y1c, x1c)] * wx
    return top * (1 - wy) + bottom * wy


def resample(layer: np.ndarray, canvas: tuple[int, int], spare: float,
             dx: float, dy: float, out_size) -> np.ndarray:
    """Render `layer` the way the compositor does, into an output-sized window.

    THE FAITHFUL MODEL — this is the one to use. `sample` below sizes the source
    independently in x and y, which is a stretch; a Wayland surface with
    `fillMode: PreserveAspectCrop` cannot stretch. What it does instead:

      1. The container is `viewport + 2 * spare` on every side, positioned at
         `(-spare, -spare)` relative to the viewport.
      2. The image is drawn to *cover* that container. One scale factor, the
         larger of the two ratios, applied to both axes.
      3. Whatever overflows the container is cropped, centred: an image
         `(dw - cw)` wider than the container loses half that on each side.
      4. The whole container is translated by `(dx, dy)`.

    Step 3 is the part that is easy to leave out and impossible to notice without
    measuring. This output has a 5120x2880 source (16:9) and a canvas of
    3192x2072 (1.54:1), so the height is what binds: the drawn image is 3683.6
    wide on a 3192 canvas, and 245.8 px of picture hang off *each* side. Drop
    that centring term and the prediction is displaced horizontally by a quarter
    of the offset being tested, which is enough to make a correct composite score
    worse than a static one.

    `canvas` is (width, height) of the container, `spare` its margin in output
    pixels, and `out_size` the (width, height) of the window to read out.
    """
    if isinstance(out_size, np.ndarray):
        out_size = (int(out_size.shape[1]), int(out_size.shape[0]))
    width, height = int(out_size[0]), int(out_size[1])
    canvas_w, canvas_h = int(canvas[0]), int(canvas[1])
    layer_h, layer_w = layer.shape[:2]

    scale = max(canvas_w / layer_w, canvas_h / layer_h)
    drawn_w, drawn_h = layer_w * scale, layer_h * scale

    # Container origin, then the centring of the cropped overflow inside it.
    left = -spare + dx - (drawn_w - canvas_w) / 2.0
    top = -spare + dy - (drawn_h - canvas_h) / 2.0

    # Output pixel (x, y) samples source pixel ((x - left) / scale, ...).
    source_y = (np.arange(height) + 0.5 - top) / scale - 0.5
    source_x = (np.arange(width) + 0.5 - left) / scale - 0.5

    y0f = np.floor(source_y)
    x0f = np.floor(source_x)
    y0 = np.clip(y0f.astype(np.int64), 0, layer_h - 1)
    y1 = np.clip(y0 + 1, 0, layer_h - 1)
    x0 = np.clip(x0f.astype(np.int64), 0, layer_w - 1)
    x1 = np.clip(x0 + 1, 0, layer_w - 1)
    wy = (source_y - y0f)[:, None]
    wx = (source_x - x0f)[None, :]

    if layer.ndim == 2:
        wy = wy[:, 0][:, None]
        wx = wx[0][None, :]
    else:
        wy = wy[:, :, None]
        wx = wx[:, :, None]

    top_row = layer[np.ix_(y0, x0)] * (1 - wx) + layer[np.ix_(y0, x1)] * wx
    bottom_row = layer[np.ix_(y1, x0)] * (1 - wx) + layer[np.ix_(y1, x1)] * wx
    return top_row * (1 - wy) + bottom_row * wy


def coverage_gap(dx: float, dy: float, screen: tuple[int, int],
                 canvas: tuple[int, int], overscan: float = 0.0) -> float:
    """Fraction of the output that falls outside the layer's own canvas.

    `overscan` shifts and grows the drawn rect exactly as the surfaces do: the
    image spans `screen + 2 * overscan` on each side, so at a viewport of (0, 0)
    it starts at -overscan rather than at 0. Without that term this reported a
    healthy 0 % while the image was in fact 25 % larger than the viewport.
    """
    width, height = screen
    canvas_w, canvas_h = canvas
    left = -overscan + dx
    top = -overscan + dy
    inside_w = max(0.0, min(left + canvas_w, width) - max(0.0, left))
    inside_h = max(0.0, min(top + canvas_h, height) - max(0.0, top))
    return 1.0 - (inside_w * inside_h) / (width * height)


def predicted(screen: tuple[int, int], fg_shift, bg_shift, layers,
              overscan: float = 0.0) -> np.ndarray:
    """The composite the compositor should be showing, at two layer offsets.

    `screen` is (width, height); `fg_shift` and `bg_shift` are *displacements* in
    output pixels for the foreground and the background respectively, in the same
    sense as a `Translate`. Both callers build them from `canvas_shift`, which
    negates them into sampler shifts — so the values arriving here are already
    "where to read from".

    The over-large canvas is `screen + 2 * overscan` and the source covers it,
    which is what `resample` models. This replaced an older implementation that
    stretched the source to the canvas in each axis independently; see the
    warning on `sample` for the measured cost of the difference.
    """
    fg_rgb, alpha, bg_rgb = layers
    canvas = (int(screen[0]) + 2 * overscan, int(screen[1]) + 2 * overscan)
    # `canvas_shift` has already inverted these into sampler coordinates, so the
    # sign is undone here: `resample` takes a container displacement.
    fg_sample = resample(fg_rgb, canvas, overscan, -fg_shift[0], -fg_shift[1], screen)
    alpha_sample = resample(alpha, canvas, overscan, -fg_shift[0], -fg_shift[1],
                            screen)[:, :, None]
    bg_sample = resample(bg_rgb, canvas, overscan, -bg_shift[0], -bg_shift[1], screen)
    return fg_sample * alpha_sample + bg_sample * (1.0 - alpha_sample)


def widget_regions() -> list[tuple[int, int, int, int]]:
    """Screen rectangles that the layer model cannot predict.

    Two kinds of thing sit on top of the wallpaper and are not part of what the
    split layers describe:

      * Depthscape's own desktop widgets. They are drawn on the wallpaper by
        design, so they are a difference the two-layer model cannot explain.
        Leaving the clock in raises the error floor from about 2/255 to about
        12/255 — larger than the difference between the hypotheses being tested.
      * DMS's status bar, which is a separate surface entirely.

    Read the widget coordinates from the layout file rather than hardcoding
    them, so the measurement keeps working when the clock is moved. The margins
    are generous: the point is to exclude the pixels, not to hug the glyphs, and
    a rectangle slightly too large costs nothing but a little statistical power.

    The bar height is a fixed 40 logical pixels in DMS's default theme; there is
    no exported size to read it from, so it is measured rather than configured.
    """
    regions: list[tuple[int, int, int, int]] = []

    path = os.path.join(data_dir(), "widgets.json")
    try:
        with open(path) as handle:
            document = json.load(handle)
    except (OSError, ValueError):
        document = None
    rows = document.get("widgets") if isinstance(document, dict) else document
    if isinstance(rows, list):
        for row in rows:
            if not isinstance(row, dict):
                continue
            try:
                x = float(row.get("x", 0))
                y = float(row.get("y", 0))
            except (TypeError, ValueError):
                continue
            # The clock's shadow reaches well beyond the glyphs, so the box is
            # generous: 420x280 around the configured origin rather than a
            # tight-fitting rect.
            regions.append((int(x) - 40, int(y) - 40, 420, 280))

    width, _ = screen_size()
    regions.append((0, 0, width, 44))
    return regions


def prediction_mask(size: tuple[int, int], regions) -> np.ndarray:
    """Boolean mask of the pixels the layer model is expected to explain."""
    width, height = size
    mask = np.ones((height, width), dtype=bool)
    for x, y, w, h in regions:
        x0, y0 = max(0, x), max(0, y)
        x1, y1 = min(width, x + w), min(height, y + h)
        if x0 < x1 and y0 < y1:
            mask[y0:y1, x0:x1] = False
    return mask


def canvas_shift(fg_offset, ratio: float) -> tuple[tuple[float, float],
                                                   tuple[float, float]]:
    """Turn a layer offset into the sampler's shifts for both layers.

    `fg_offset` is the displacement in output pixels, in the same sense as a
    `Translate`, and `ratio` is how much of it the background takes *in the same
    direction*. `ratio = 1` is the shipped behaviour: both layers shift
    identically. The parameters are separate so that a hypothesis can vary the
    ratio alone without disturbing the foreground — passing the ratio inside
    `fg_offset` instead makes every hypothesis move the foreground too, and three
    variants that should differ come out identical.

    One inversion happens here, and mixing it up costs an afternoon: a layer
    offset is a *displacement*, but the sampler asks the opposite question —
    which canvas pixel lands on a given output pixel. A layer pushed down by 90
    is a canvas read at -90. Both layers are displacements, so both flip the
    same way; there is no second sign to track.

    `ratio` therefore only scales the background's shift: `+1` is the pair
    moving together, `0` is a pinned background, and `-1` is the two moving
    apart — which was the earlier design and is now kept as a hypothesis
    precisely so that a regression into it is detectable.
    """
    fg_x, fg_y = fg_offset
    return (-fg_x, -fg_y), (-fg_x * ratio, -fg_y * ratio)


def compare(actual: np.ndarray, expected: np.ndarray,
            mask: np.ndarray | None = None) -> float:
    """Mean absolute error, optionally restricted to `mask`."""
    difference = np.abs(actual - expected)
    if mask is not None:
        difference = difference[mask]
    return float(difference.mean())


def overscan() -> float:
    """The spare area each surface carries on every side, in output pixels.

    Read from the daemon rather than recomputed from the travel setting, because
    the surface derives it from the tracker's reserve and rounds it up — a
    hand-rolled copy of that arithmetic would be right until the first time one
    side changed. Must match DepthBackground's and DepthForeground's
    `overscan` property exactly, or every prediction is scaled wrong.
    """
    rows = state()["outputs"]
    output = next(iter(rows))
    reserve = max(rows[output]["reserveX"], rows[output]["reserveY"])
    return math.ceil(reserve) + 8


def baseline_error(screen: np.ndarray, size: tuple[int, int],
                   mask: np.ndarray, layers, overscan: float = 0.0) -> float:
    """The error floor of this measurement, independent of any offset.

    Comparing the screen against the layers always costs something, because the
    harness's own downscale of a 5120x2880 source is not bit-identical to the
    compositor's. That floor is not nothing, and it is reported next to every
    comparison so a reader can see whether a gap means anything.

    IT IS NOT A THRESHOLD, and reading it as one is the mistake this docstring
    exists to prevent. The floor and the hypotheses are measured against the same
    frame, so what decides an experiment is the spread *between* the hypotheses —
    the shipped configuration scores 1.2 while every wrong one scores 33 or more,
    which is a gap two orders of magnitude wider than any resampling noise.

    The value itself is a rest-frame comparison and is therefore only meaningful
    when the scene happens to be at rest. It is printed for context, not used as
    a pass/fail bound.
    """
    return compare(screen, predicted(size, (0, 0), (0, 0), layers, overscan),
                   mask)


def overview_is_open() -> bool:
    """Whether the compositor is showing the overview.

    Read from the compositor's own single-line reply rather than from the
    daemon's polled copy, because this is used to *decide how to judge a
    screenshot* and a stale copy would decide wrongly for one whole poll
    interval. niri answers `Overview is open.` / `Overview is closed.`; the
    `--json` form is `{"is_open": true}` and is used instead so the parse does
    not depend on the human-readable wording.
    """
    out = subprocess.run(["niri", "msg", "--json", "overview-state"],
                         capture_output=True, text=True).stdout.strip()
    try:
        return bool(json.loads(out).get("is_open"))
    except ValueError:
        return False


def frames_count_as_clear(active_ids, windows) -> bool:
    """The bookkeeping test: no window lives on any currently-active workspace."""
    return not any(w.get("workspace_id") in active_ids for w in windows)


def focused_workspace_is_clear() -> bool:
    """True when nothing is drawn over the wallpaper on the focused output.

    A screenshot captures the whole output, windows included, and the window
    holding the shell that runs this script counts. Rather than work around that
    by moving windows around — which perturbs the very navigation the parallax
    follows — the script refuses to measure until the desktop is clear.

    ON THE ACTIVE WORKSPACE *PER OUTPUT*, and that is the whole point. `is_active`
    in niri's workspace list is a global flag: exactly one workspace in the entire
    session has it, and `screenshot-screen` captures the *focused output*. So
    reading the global flag answers a question about whatever output holds focus —
    not about the output being captured. With one monitor the two coincide and the
    bug is invisible; the moment there are two, this can report "clear" about the
    monitor the user is looking at while the capture is of the other one, and the
    screenshot comes back full of windows with an MAE of 120-something that looks
    like a broken wallpaper rather than like a mis-aimed camera.

    Asking each workspace which output it is on, and each window which workspace
    it is on, answers the question that was actually meant.

    IN THE OVERVIEW THIS QUESTION DOES NOT APPLY, and answering it anyway is worse
    than not asking. The overview draws every workspace's windows at once, not
    just the focused workspace's, so a session with windows anywhere at all fails
    this test no matter which workspace holds focus. Measured: opening the
    overview focuses workspace index 1, the focused workspace there is empty, this
    function returns True, and the capture comes back showing eight windows from
    the other workspace — an MAE around 44 where the floor is under 2, which reads
    as a broken composite rather than as a torn camera. So the caller is told the
    truth instead: in the overview the pixels are judged, not the bookkeeping.
    """
    workspaces = json.loads(subprocess.run(
        ["niri", "msg", "--json", "workspaces"],
        capture_output=True, text=True, check=True).stdout)
    focus = focused_output()
    if focus is None:
        return False
    active = [w["id"] for w in workspaces
              if w.get("output") == focus and w.get("is_active")]
    if not active:
        return False
    windows = json.loads(subprocess.run(
        ["niri", "msg", "--json", "windows"],
        capture_output=True, text=True, check=True).stdout)
    return frames_count_as_clear(active, windows)


def require_clear_desktop() -> None:
    if focused_workspace_is_clear():
        return
    print(f"the focused output ({focused_output()}) has windows on its active\n"
          "workspace; the screenshot would capture them instead of the\n"
          "wallpaper. Move to an empty workspace and re-run.")
    sys.exit(2)


def looks_like_a_capture_of_windows(frame: np.ndarray) -> bool:
    """Whether a captured frame is mostly window rather than wallpaper.

    THE CHECK THAT ACTUALLY WORKS, and it exists because the bookkeeping one does
    not. Anything that reasons about which workspace is focused is reasoning about
    the wrong thing in the overview, where niri draws every workspace at once, and
    it is also defeated by anything that takes focus between the check and the
    capture. What cannot lie is the frame itself.

    The wallpaper is overwhelmingly red: this scene is `[173, 12, 42]` field against
    a pale moon, so the great majority of rows have most of their pixels with a
    large red-over-green gap. A window — a terminal, a browser, an editor — is
    neither red nor uniform. Measured on this arrangement: a clean frame scores
    0.66..0.93 on the fraction of red pixels per row, and a frame with a horizontal
    band of windows scores 0.002 across that band.

    Deliberately coarse and deliberately biased towards refusing: a false refusal
    costs a re-run, a false acceptance costs a wrong number that is indistinguishable
    from a real regression.
    """
    red = (frame[..., 0] > 120) & (frame[..., 1] < 90) & (frame[..., 2] < 120)
    rows = red.mean(axis=1)
    return bool((rows < 0.35).mean() > 0.10)


def require_no_windows_in_frame(frame: np.ndarray, label: str) -> None:
    if not looks_like_a_capture_of_windows(frame):
        return
    print(f"  [screenshot{(' ' + label) if label else ''}] REFUSED — the frame "
          "is not a picture of the wallpaper;\n"
          "    a large part of it is window content. Something with windows is "
          "in shot —\n"
          "    in the overview that is expected if any workspace anywhere has "
          "windows.")
    sys.exit(2)


def state() -> dict:
    return json.loads(ipc("parallax"))


def run_self_test(screen: tuple[int, int], layers, mask) -> int:
    """Force a displacement and check the screen follows it.

    This is the test that catches the failure mode that is invisible from inside
    the daemon: an offset reported as applied but never bound to the surfaces.

    It compares against the UNFORCED screenshot rather than an absolute
    threshold, because the palette of any given wallpaper makes absolute numbers
    hard to read. Two screenshots of the same desktop differ only by the offset,
    so the pair is a clean experiment.

    THE HORIZONTAL AXIS IS THE ONE THAT DECIDES. It travels further (12% of 2560
    against 12% of 1440), so a displacement there is a larger fraction of the
    frame and stands clear of the measurement floor. On this machine the vertical
    axis at its full reserve, the horizontal axis at its full reserve, and the
    shipped ratio were all tested; see the numbers in the docstring of
    `canvas_shift`.
    """
    print("--- self-test: forcing the scene to the end of its travel ---")

    ipc("clearParallaxOffset")
    time.sleep(1.2)
    actual = screenshot("at rest")
    spare = overscan()
    print(f"overscan {spare} px per side (canvas is "
          f"{screen[0] + 2 * spare}x{screen[1] + 2 * spare})")

    # The floor is measured where it is actually meaningful: the scene is at
    # rest, so a zero-offset prediction is a like-for-like comparison. Reading it
    # AFTER the offset has been forced — which this used to do — compares a
    # moved frame against a still one and reports the travel as "floor", which
    # is how a correct composite once came out looking like a broken renderer.
    resting = state()["outputs"]
    resting_output = next(iter(resting))
    rest_x = resting[resting_output]["offsetX"]
    rest_y = resting[resting_output]["offsetY"]
    floor = compare(actual,
                    predicted(screen, *canvas_shift((rest_x, rest_y), 1.0),
                              layers, spare),
                    mask)
    print(f"measurement floor (rest frame vs the pair at rest)   MAE {floor:7.3f}")
    print("  resampling and nothing else: the same wallpaper rescaled by the\n"
          "  harness scores about the same. Not a threshold — the spread between\n"
          "  the hypotheses below is what decides the experiment.")

    # The displacement is pushed in and read back before the screenshot, so a
    # `Process` that never ran and a binding that never fired cannot be confused
    # for one another.
    ipc("shiftParallaxHorizontal")
    time.sleep(1.5)
    reported = state()["outputs"]
    output = next(iter(reported))
    forced = reported[output]["offsetX"]
    print(f"daemon reports offset ({forced}, {reported[output]['offsetY']})")
    moved = screenshot("with the forced offset")

    # The hypotheses differ only in what they assume is broken. `canvas_shift`
    # applies the sign flip and the ratio, and the foreground's own displacement
    # is passed unchanged so that varying the ratio does not drag the foreground
    # with it.
    #
    # The shipped behaviour is ratio +1: both layers shift identically, because
    # they are one scene and the background is the foreground's own subject
    # region filled in. The -1 case is the earlier, wrong design — kept here so
    # that slipping back into it shows up as a failure rather than as a taste
    # question.
    candidates = {"nothing moved (foreground and background both at 0)":
                  predicted(screen, (0, 0), (0, 0), layers, spare)}
    for label, background_ratio in (
        ("the foreground only, background held still", 0.0),
        ("both layers moving together (the shipped pair)", 1.0),
        ("the two layers still moving APART (the old bug)", -1.0),
        ("the background moving twice as far as the subject", 2.0),
    ):
        candidates[label] = predicted(screen,
                                      *canvas_shift((forced, 0), background_ratio),
                                      layers, spare)

    print("screen with the forced offset vs hypotheses:")
    results = []
    for label, expectation in candidates.items():
        error = compare(moved, expectation, mask)
        results.append((label, error))
        print(f"  {label:58s} MAE {error:7.3f}")

    ipc("clearParallaxOffset")
    time.sleep(0.8)

    ordered = sorted(results, key=lambda row: row[1])
    best, runner_up = ordered[0], ordered[1]
    margin = runner_up[1] - best[1]
    print(f"\nbest fit: {best[0]}")
    print(f"margin over the next hypothesis: {margin:6.3f} "
          f"(floor is {floor:.3f})")
    if best[0].startswith("nothing moved"):
        print("FAIL — the offset did not reach the screen; the bindings are stale")
        return 1
    if margin < 1.5:
        print("FAIL — the hypotheses are not separable; the measurement is "
              "inconclusive")
        return 1
    print("PASS — the offset reaches the screen, and the pair is distinguishable")
    return 0


def run_sweep(screen: tuple[int, int], layers, mask) -> int:
    """Report the MAE for a range of background ratios at the live offset.

    The two layers are supposed to move by exactly the same amount, so the
    minimum should sit at +1.00. A minimum at 0.00 means the background is not
    moving at all; a minimum anywhere else means the pair has come apart, which
    is the failure this sweep exists to catch.

    The offset has to be non-zero for any of this to mean anything, and the
    daemon holds zero at rest -- so the offset is forced here rather than left
    to the caller to arrange. A sweep at rest has no signal to fit and would
    report a spurious minimum at whatever the resampling error happens to be.
    """
    ipc("shiftParallaxHorizontal")
    time.sleep(1.5)
    actual = screenshot("for the sweep")
    rows = state()["outputs"]
    output = next(iter(rows))
    offset_x = rows[output]["offsetX"]
    offset_y = rows[output]["offsetY"]
    if offset_x == 0 and offset_y == 0:
        print("no offset on screen; force one or navigate a workspace first")
        return 1

    spare = overscan()
    print(f"--- ratio sweep at layer offset {offset_x}, {offset_y} ---")
    print("  (how far the background travels with the foreground; +1.00 is "
          "the pair moving as one)")
    print(f"{'ratio':>7}  {'MAE':>8}")
    results = []
    for ratio in (-1.0, -0.5, -0.2, 0.0, 0.2, 0.5, 0.8, 1.0, 1.2, 1.5, 2.0):
        fg_shift, bg_shift = canvas_shift((offset_x, offset_y), ratio)
        error = compare(actual,
                        predicted(screen, fg_shift, bg_shift, layers, spare),
                        mask)
        results.append((ratio, error))
        marker = "  <- expected" if abs(ratio - 1.0) < 1e-9 else ""
        print(f"{ratio:7.2f}  {error:8.3f}{marker}")

    best = min(results, key=lambda row: row[1])
    print(f"\nbest ratio: {best[0]:+.2f} (expected: +1.00)")
    ipc("clearParallaxOffset")
    if abs(best[0] - 1.0) > 0.21:
        if abs(best[0]) < 0.01:
            print("FAIL — the background is not moving with the foreground")
        else:
            print("FAIL — the two layers are not moving together")
        return 1
    print("PASS — the two layers move as one")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="force an offset and assert the screen follows")
    parser.add_argument("--sweep", action="store_true",
                        help="report the MAE across a range of background ratios")
    parser.add_argument("--scale", type=float, default=0.5,
                        help="downscale factor for the comparison (default 0.5; "
                             "the layers are 5120x2880 and halving them still "
                             "resolves a 90 px shift to within a pixel while "
                             "quartering the work)")
    parser.add_argument("--include-widgets", action="store_true",
                        help="do not mask out the desktop widgets (they are "
                             "drawn over the wallpaper and the layer model "
                             "cannot predict them, so leaving them in raises the "
                             "error floor to about 12/255)")
    args = parser.parse_args()

    if not (args.self_test or args.sweep):
        parser.error("choose --self-test or --sweep")

    require_clear_desktop()

    screen = screen_size()
    fg_path, _ = split_files()
    with Image.open(fg_path) as probe:
        canvas = probe.size
    fg_rgb, alpha, bg_rgb = load_layers(args.scale)
    layers = (fg_rgb, alpha, bg_rgb)

    regions = [] if args.include_widgets else widget_regions()
    mask = prediction_mask(screen, regions)

    print(f"output   {screen[0]}x{screen[1]}")
    print(f"source   {canvas[0]}x{canvas[1]} (the split PNGs)")
    # The check that matters is the one at the far end of the travel, not at
    # rest: at rest any extra material is invisible by construction, so a 0 %
    # gap at rest says nothing about whether a shift will pull a border on
    # screen. This is what catches a canvas that is oversized but empty.
    spare = overscan()
    drifted = coverage_gap(spare, 0, screen, canvas, spare)
    print(f"canvas covers the output at full horizontal travel "
          f"(gap {drifted * 100:.1f}%)")
    if regions:
        excluded = 1.0 - mask.mean()
        print(f"widgets  {len(regions)} region(s), {excluded * 100:.1f}% of the "
              f"frame excluded")
    print()

    if args.self_test:
        return run_self_test(screen, layers, mask)
    return run_sweep(screen, layers, mask)


if __name__ == "__main__":
    sys.exit(main())
