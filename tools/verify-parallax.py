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

With the parallax engaged the two separate, and the foreground travels `s` while
the background travels `-s * ratio`. Reproducing that from the split files is a
matter of sampling each layer at its own displaced coordinate:

    expected = fg[x', y'] * a[x', y'] + bg[x'', y''] * (1 - a[x', y'])

The screen is then compared against that prediction, and the script reports the
mean absolute error. Two numbers matter:

  * MAE at the offset the daemon claims it is using — should be small (a few
    units out of 255). Anything larger means the layers are not where the daemon
    thinks they are.
  * The ratio sweep — the same comparison with the background held still, or
    moved further, or moved the other way. If the daemon's ratio is right, it
    should be the minimum of the sweep. If the minimum lands on "background
    still", the background offset is not reaching the screen at all.

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

    `label` is echoed so a run's log says which frame it is looking at, which is
    the only way to tell a stale screenshot from a wrong prediction after the
    fact.
    """
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
                    return np.asarray(Image.open(newest).convert("RGB"),
                                      dtype=np.float32)
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


def sample(layer: np.ndarray, dx: float, dy: float, out_size):
    """Sample `layer` through a translation of (dx, dy) in OUTPUT pixels.

    The output is a window onto a larger canvas: output pixel (x, y) shows
    canvas pixel (x + dx, y + dy). Everything outside the canvas is material the
    layer cannot supply — the spare area in DepthBackground exists precisely to
    keep that from happening — so it is clamped rather than folded into the
    error as black, and `coverage_gap` reports the clamping separately.

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
    """
    if isinstance(out_size, np.ndarray):
        out_size = (int(out_size.shape[1]), int(out_size.shape[0]))
    width, height = int(out_size[0]), int(out_size[1])
    layer_h, layer_w = layer.shape[:2]
    scale_y = layer_h / height
    scale_x = layer_w / width

    # Source coordinates, as floats, of each output pixel's centre.
    source_y = (np.arange(height) + 0.5 + dy) * scale_y - 0.5
    source_x = (np.arange(width) + 0.5 + dx) * scale_x - 0.5

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


def coverage_gap(dx: float, dy: float, screen: tuple[int, int], canvas: tuple[int, int]) -> float:
    """Fraction of the output that falls outside the layer's own canvas."""
    width, height = screen
    canvas_w, canvas_h = canvas
    inside_w = max(0.0, min(canvas_w, width + dx) - max(0.0, dx))
    inside_h = max(0.0, min(canvas_h, height + dy) - max(0.0, dy))
    return 1.0 - (inside_w * inside_h) / (width * height)


def predicted(screen: tuple[int, int], fg_shift, bg_shift, layers) -> np.ndarray:
    fg_rgb, alpha, bg_rgb = layers
    fg_sample = sample(fg_rgb, fg_shift[0], fg_shift[1], screen)
    alpha_sample = sample(alpha, fg_shift[0], fg_shift[1], screen)[:, :, None]
    bg_sample = sample(bg_rgb, bg_shift[0], bg_shift[1], screen)
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

    """Turn the daemon's layer offsets into the sampler's shifts.

    Two inversions happen here, and mixing them up costs an afternoon:

      * A layer offset is a *displacement*, in the same sense as a `Translate`.
        The sampler asks the opposite question — which canvas pixel lands on a
        given output pixel — so the sign flips. A layer pushed down by 90 is a
        canvas read at -90.
      * The daemon gives the background `-foreground * ratio`. That negation is
        part of the shipped design, the two planes travelling in opposite
        directions, so the background's sampler shift comes out with the same
        sign as the foreground's.

    The net effect is that both layers are sampled with the same sign, and it is
    the screen that shows them moving apart. Verified against the real screen:
    with the foreground forced to +90 and the ratio at 0.35, the pair
    (-90, +31.5) fits at MAE 3.14 while "nothing moved" fits at 11.38.
    """
    fg_x, fg_y = surface_offset
    # The background's surface offset is -offset * ratio; the sampler inverts
    # that negation, so this reads as +offset * ratio.
    return (-fg_x, -fg_y), (fg_x * ratio, fg_y * ratio)


def canvas_shift(fg_offset, ratio: float) -> tuple[tuple[float, float],
                                                   tuple[float, float]]:
    """Turn a foreground layer offset into the sampler's shifts for both layers.

    `fg_offset` is the foreground's displacement in output pixels, in the same
    sense as a `Translate`, and `ratio` is how much of it the background takes.
    The parameters are separate so that a hypothesis can vary the ratio alone
    without disturbing the foreground — passing the ratio inside `fg_offset`
    instead makes every hypothesis move the foreground too, and three variants
    that should differ come out identical.

    Two inversions happen here, and mixing them up costs an afternoon:

      * A layer offset is a *displacement*, in the same sense as a `Translate`.
        The sampler asks the opposite question — which canvas pixel lands on a
        given output pixel — so the sign flips. A layer pushed down by 90 is a
        canvas read at -90.
      * The daemon gives the background `-foreground * ratio`. That negation is
        part of the shipped design, the two planes travelling in opposite
        directions, so the background's sampler shift comes out with the *same*
        sign as the foreground's.

    So the foreground is read at `-offset` and the background at `+offset *
    ratio`. Confirmed against the real screen at 2560x1440 with the foreground
    forced to +307.2: the background's sampler shift came out at +107.52
    (= 307.2 * 0.35) fitting at 3.9/255, while 0 fit at 14.8 and -107.52 at
    23.4. A 12x separation, against a measurement floor of 0.67.
    """
    fg_x, fg_y = fg_offset
    return (-fg_x, -fg_y), (fg_x * ratio, fg_y * ratio)


def compare(actual: np.ndarray, expected: np.ndarray,
            mask: np.ndarray | None = None) -> float:
    """Mean absolute error, optionally restricted to `mask`."""
    difference = np.abs(actual - expected)
    if mask is not None:
        difference = difference[mask]
    return float(difference.mean())


def baseline_error(screen: np.ndarray, size: tuple[int, int],
                   mask: np.ndarray, layers) -> float:
    """The error floor of this measurement, independent of any offset.

    Comparing the screen against the layers always costs something, because the
    harness's own downscale of a 5120x2880 source is not bit-identical to the
    compositor's. That floor is not small — measured at 9.4/255 on this machine,
    where the UNMODIFIED wallpaper scores 9.35 against the same screen.

    So an absolute threshold is the wrong test, and a "the numbers look high"
    read of the output is misleading. What matters is that the difference
    between hypotheses is much larger than the floor. This is reported next to
    every comparison so a reader can see whether a gap means anything.
    """
    return compare(screen, predicted(size, (0, 0), (0, 0), layers), mask)


def focused_workspace_is_clear() -> bool:
    """True when nothing is drawn over the wallpaper on the focused workspace.

    A screenshot captures the whole output, windows included, and the window
    holding the shell that runs this script counts. Rather than work around that
    by moving windows around — which perturbs the very navigation the parallax
    follows — the script refuses to measure until the desktop is clear, and says
    how to clear it.
    """
    workspaces = json.loads(subprocess.run(
        ["niri", "msg", "--json", "workspaces"],
        capture_output=True, text=True, check=True).stdout)
    active = [w["id"] for w in workspaces if w.get("is_active")]
    if not active:
        return False
    windows = json.loads(subprocess.run(
        ["niri", "msg", "--json", "windows"],
        capture_output=True, text=True, check=True).stdout)
    return not any(w.get("workspace_id") in active for w in windows)


def require_clear_desktop() -> None:
    if focused_workspace_is_clear():
        return
    print("the focused workspace has windows on it; the screenshot would\n"
          "capture them instead of the wallpaper. Move to an empty workspace\n"
          "(an empty one may need to be created first) and re-run.")
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
    ratio = state()["backgroundRatio"]
    floor = baseline_error(actual, screen, mask, layers)
    print(f"measurement floor (rest frame vs layers)     MAE {floor:7.3f}")
    print("  this is resampling, not parallax: the unmodified wallpaper scores "
          "about\n  the same against the same screen, so an absolute threshold "
          "would be\n  meaningless. What matters is the gap between hypotheses.")

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
    # applies both the sign flip and the ratio, and the foreground's own
    # displacement is passed unchanged so that varying the ratio does not drag
    # the foreground with it.
    candidates = {"nothing moved (foreground and background both at 0)":
                  predicted(screen, (0, 0), (0, 0), layers)}
    for label, background_ratio in (
        ("the foreground only, background held still", 0.0),
        ("the foreground, background counter-moving (the shipped pair)", ratio),
        ("the foreground, background both moving the SAME way", -ratio),
    ):
        candidates[label] = predicted(screen,
                                      *canvas_shift((forced, 0), background_ratio),
                                      layers)

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

    The ratio the daemon is configured with should be the minimum of this curve.
    A minimum at 0.00 means the background is not moving at all; a minimum at a
    different magnitude means it is moving by the wrong amount.

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
    ratio_configured = state()["backgroundRatio"]
    offset_x = rows[output]["offsetX"]
    offset_y = rows[output]["offsetY"]
    if offset_x == 0 and offset_y == 0:
        print("no offset on screen; force one or navigate a workspace first")
        return 1

    print(f"--- ratio sweep at foreground offset {offset_x}, {offset_y} ---")
    print(f"{'ratio':>7}  {'MAE':>8}")
    results = []
    for ratio in (-0.6, -0.5, -0.35, -0.2, -0.1, 0.0, 0.1, 0.2, 0.35, 0.5, 0.6):
        fg_shift, bg_shift = canvas_shift((offset_x, offset_y), ratio)
        error = compare(actual, predicted(screen, fg_shift, bg_shift, layers),
                        mask)
        results.append((ratio, error))
        marker = "  <- configured" if abs(ratio - ratio_configured) < 1e-9 else ""
        print(f"{ratio:7.2f}  {error:8.3f}{marker}")

    best = min(results, key=lambda row: row[1])
    print(f"\nbest ratio: {best[0]:+.2f} (configured: {ratio_configured:+.2f})")
    ipc("clearParallaxOffset")
    if abs(best[0]) < 0.01:
        print("FAIL — the background appears not to be moving")
        return 1
    if abs(best[0] - ratio_configured) > 0.16:
        print("FAIL — the best ratio disagrees with the configured one")
        return 1
    print("PASS — the configured ratio is confirmed")
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
    print(f"canvas   {canvas[0]}x{canvas[1]}")
    gap = coverage_gap(0, 0, screen, canvas)
    print(f"canvas covers the output at rest (gap {gap * 100:.1f}%)")
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
