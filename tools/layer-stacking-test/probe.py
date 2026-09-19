#!/usr/bin/env python3
"""Decide whether the depth foreground is in front of a same-layer widget.

`niri msg layers` cannot answer this: it lists layer surfaces in raw
reverse-stacking order, and that order is not a reliable z-order oracle. The
only trustworthy oracle is pixels, so this script reads a screenshot and tests
two competing hypotheses over the whole widget rect:

    H_fg     the foreground is on top, so the pixel is
                 alpha * wallpaper + (1 - alpha) * widget_colour
    H_widget the widget is on top, so the pixel is just widget_colour

Whichever hypothesis has the lower mean absolute error wins. The error is in
0..255 units, and on a correct compositing the winning hypothesis lands around
1, while the loser lands around 100.

Usage:
    probe.py --screenshot shot.png --mask mask.png --wallpaper wall.jpg

Everything else has defaults matching shell.qml in this directory.
"""

from __future__ import annotations

import argparse
import sys

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None

# Panels as declared in shell.qml, in logical screen coordinates.
PANELS = [
    # label,          x,     y,   size, colour
    ("W2 cyan", 1960, 330, 400, (0, 255, 255)),
    ("W1 magenta", 410, 550, 400, (255, 0, 255)),
]


def parse_size(text: str) -> tuple[int, int]:
    width, _, height = text.partition("x")
    return int(width), int(height)


def sample(mask: np.ndarray, wallpaper: np.ndarray, xs: np.ndarray, ys: np.ndarray):
    """Nearest-neighbour sample of the mask alpha and wallpaper at screenshot px."""
    height, width = mask.shape[:2]
    ix = np.clip((xs * (width / _surface_w)).round().astype(int), 0, width - 1)
    iy = np.clip((ys * (height / _surface_h)).round().astype(int), 0, height - 1)
    alpha = mask[iy[:, None], ix[None, :], 3].astype(np.float32) / 255.0
    rgb = wallpaper[iy[:, None], ix[None, :], :].astype(np.float32)
    return alpha, rgb


_surface_w = 3840
_surface_h = 2160


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--screenshot", required=True)
    parser.add_argument("--mask", required=True)
    parser.add_argument("--wallpaper", required=True)
    parser.add_argument("--logical", default="2560x1440",
                        help="logical size of the output the screenshot came from")
    args = parser.parse_args()

    global _surface_w, _surface_h

    shot = np.array(Image.open(args.screenshot).convert("RGB")).astype(np.float32)
    _surface_h, _surface_w = shot.shape[:2]

    logical_w, logical_h = parse_size(args.logical)
    scale = _surface_w / logical_w

    mask = np.array(Image.open(args.mask))
    wallpaper = np.array(Image.open(args.wallpaper).convert("RGB"))

    print(f"screenshot {_surface_w}x{_surface_h}  logical {logical_w}x{logical_h}  scale {scale}")
    channels = mask.shape[2] if mask.ndim == 3 else 1
    if channels != 4:
        print(f"error: mask has {channels} channels, expected 4 (RGBA)", file=sys.stderr)
        return 2
    print(f"mask {mask.shape[1]}x{mask.shape[0]}  RGBA")
    print()

    verdicts: dict[str, str] = {}

    for label, x, y, size, colour in PANELS:
        x0, y0 = round(x * scale), round(y * scale)
        x1, y1 = round((x + size) * scale), round((y + size) * scale)
        widget = np.array(colour, dtype=np.float32)

        observed = shot[y0:y1, x0:x1]
        alpha, rgb = sample(mask, wallpaper, np.arange(x0, x1), np.arange(y0, y1))

        a3 = alpha[:, :, None]
        h_fg = a3 * rgb + (1.0 - a3) * widget
        h_widget = np.broadcast_to(widget, observed.shape).copy()

        err_fg = float(np.abs(observed - h_fg).mean())
        err_widget = float(np.abs(observed - h_widget).mean())

        top = "FOREGROUND" if err_fg < err_widget else "WIDGET"
        verdicts[label] = top

        print(f"{label:11s} rect {x0},{y0}..{x1},{y1}")
        print(f"  MAE[foreground on top] {err_fg:7.2f}")
        print(f"  MAE[widget on top]     {err_widget:7.2f}")
        print(f"  -> {top} is on top")
        print()

    return 0 if "WIDGET" not in verdicts.values() else 1


if __name__ == "__main__":
    sys.exit(main())
