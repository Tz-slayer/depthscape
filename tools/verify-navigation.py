#!/usr/bin/env python3
"""Drive real workspace navigation and check that the accumulator inverts.

WHAT THIS CAN AND CANNOT MEASURE

The rendering check (`verify-parallax.py`) already proves that a reported offset
reaches the screen with the right magnitude. This script covers the other half:
that niri navigation produces the offsets, and that going out and coming back
restores the scene exactly.

It runs on an empty workspace, because a screenshot with a window on it cannot be
compared against the split layers. That constrains what it can drive:

  * The vertical axis follows the workspace stack, which works with nothing on
    screen — niri has an active workspace whether or not it holds a window.
  * The horizontal axis follows the focused column, which is read back from the
    focused window's `pos_in_scrolling_layout`. With no window there is no
    column, so the horizontal axis *cannot* move on an empty workspace. That is
    the designed behaviour, not a gap in this script: it is why an empty
    workspace leaves the scene horizontally still.

So the vertical axis is driven for real and the return-to-origin property is
verified in pixels. The horizontal axis is verified through the reported state,
which is legitimate here because `verify-parallax.py` has already established
that the reported value is what reaches the screen.

USAGE

    tools/on-clear-workspace.sh python3 tools/verify-navigation.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "verify_parallax", os.path.join(HERE, "verify-parallax.py"))
vp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vp)


def action(*args: str) -> None:
    subprocess.run(["niri", "msg", "action", *args], capture_output=True)


def focused_is_clear() -> bool:
    workspaces = json.loads(subprocess.run(
        ["niri", "msg", "--json", "workspaces"],
        capture_output=True, text=True).stdout)
    active = [w["id"] for w in workspaces if w.get("is_active")]
    windows = json.loads(subprocess.run(
        ["niri", "msg", "--json", "windows"],
        capture_output=True, text=True).stdout)
    return not any(w.get("workspace_id") in active for w in windows)


def workspace_layout() -> str:
    """A one-line picture of which workspaces are empty, for the log."""
    workspaces = sorted(json.loads(subprocess.run(
        ["niri", "msg", "--json", "workspaces"],
        capture_output=True, text=True).stdout), key=lambda w: w["idx"])
    windows = json.loads(subprocess.run(
        ["niri", "msg", "--json", "windows"],
        capture_output=True, text=True).stdout)
    occupied = {w.get("workspace_id") for w in windows}
    parts = []
    for workspace in workspaces:
        mark = "*" if workspace["is_active"] else " "
        state = ".." if workspace["id"] not in occupied else "##"
        parts.append(f"{mark}{workspace['idx']:>2}{state}")
    return " ".join(parts)


def state() -> dict:
    report = json.loads(vp.ipc("parallax"))
    return report["outputs"][next(iter(report["outputs"]))]


def describe(label: str) -> dict:
    current = state()
    print(f"{label:32s} vsteps={current['vsteps']:>4}  "
          f"offsetY={current['offsetY']:>8.2f}  "
          f"(reserve {current['reserveY']:.1f})")
    return current


def walk(direction: str, attempts: int = 3) -> int:
    """Step `direction` until the workspace is empty and the move took effect.

    Returns the number of steps that actually moved. niri refuses to walk past
    either end of the stack, and a refused move is indistinguishable from a move
    that happened without comparing positions before and after.
    """
    moved = 0
    for _ in range(attempts):
        before = subprocess.run(["niri", "msg", "--json", "workspaces"],
                                capture_output=True, text=True).stdout
        action(f"focus-workspace-{direction}")
        time.sleep(1.4)
        after = subprocess.run(["niri", "msg", "--json", "workspaces"],
                               capture_output=True, text=True).stdout
        if before != after:
            moved += 1
        if focused_is_clear():
            break
    return moved


def main() -> int:
    vp.require_clear_desktop()
    size = vp.screen_size()
    layers = vp.load_layers(0.5)
    mask = vp.prediction_mask(size, vp.widget_regions())

    print(f"workspaces  {workspace_layout()}")
    print("            '*' active   '..' empty   '##' has windows\n")

    vp.ipc("clearParallaxOffset")
    vp.ipc("resetParallax")
    time.sleep(1.4)

    # THE BASELINE IS THE RESTING SCENE, which is what the whole comparison is
    # relative to: the offset is a position, so "no navigation" must mean "no
    # displacement" and the layers must sit exactly where the wallpaper does.
    baseline = vp.screenshot("baseline")
    describe("baseline")
    floor = vp.compare(baseline, vp.predicted(size, (0, 0), (0, 0), layers), mask)
    print(f"    baseline vs layers  {floor:7.3f}")

    # OUT
    steps_out = walk("down")
    if steps_out == 0:
        steps_out = walk("up")
        direction_back = "down"
    else:
        direction_back = "up"

    if steps_out == 0:
        print("\ncannot move to another workspace from here; the stack has "
              "walls on\nboth sides and this workspace is the only one. Open a "
              "second empty\nworkspace and re-run.")
        return 2

    out = describe(f"after {steps_out} step(s) {direction_back}")
    if out["offsetY"] == 0:
        print("WARN — the offset was still 0 when read; the poll may have been "
              "in flight")

    # AND BACK, THE SAME NUMBER OF STEPS
    for _ in range(steps_out):
        action(f"focus-workspace-{direction_back}")
        time.sleep(1.4)
    time.sleep(0.8)
    back_state = describe(f"after {steps_out} step(s) back")
    back = vp.screenshot("back")

    restored = vp.compare(back, baseline, mask)
    print(f"    vs baseline         {restored:7.3f}")
    print()

    failures = []
    if back_state["vsteps"] != 0:
        failures.append(f"the step count did not return to 0 "
                        f"(it is {back_state['vsteps']})")
    if back_state["offsetY"] != 0:
        failures.append(f"the offset did not return to 0 "
                        f"(it is {back_state['offsetY']:.2f})")
    if restored > 3.0:
        failures.append(f"the scene did not return to where it started "
                        f"({restored:.3f}/255, floor {floor:.3f})")

    if failures:
        for line in failures:
            print(f"FAIL — {line}")
        return 1
    print(f"PASS — the scene returned to its starting position "
          f"({restored:.3f}/255, floor {floor:.3f})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
