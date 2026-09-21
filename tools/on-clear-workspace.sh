#!/usr/bin/env bash
# Run a command after finding a workspace with nothing on it.
#
# WHY THIS EXISTS
#
# The verification scripts screenshot the focused output, and any window on the
# focused workspace lands in the frame: the mean-absolute-error comparison
# against the split layers then comes out between 30 and 80 out of 255 instead
# of near 1, and every hypothesis looks equally bad.
#
# Moving the terminal from inside its own shell does not help, because niri keeps
# the terminal focused as it follows the workspace switch. Walking to a workspace
# that already has nothing on it does work, provided the walk stops as soon as it
# finds one.
#
# WHAT IT DOES NOT DO
#
# It does not try to move windows out of the way. `move-window-to-workspace`
# addresses workspaces by *index*, and an index that does not exist yet is
# created — so a batch of moves spreads the windows across a column of fresh
# workspaces instead of collecting them on one, which is worse than leaving them
# alone. Set PARK_WORKSPACE if you want to opt in to that and see for yourself.

set -euo pipefail

workspace_is_clear() {
    python3 -c '
import json, subprocess, sys
ws = json.loads(subprocess.run(["niri", "msg", "--json", "workspaces"],
                               capture_output=True, text=True).stdout)
active = [w["id"] for w in ws if w.get("is_active")]
wins = json.loads(subprocess.run(["niri", "msg", "--json", "windows"],
                                 capture_output=True, text=True).stdout)
sys.exit(0 if not any(w.get("workspace_id") in active for w in wins) else 1)
'
}

# Walk to a workspace with nothing on it. `focus-workspace-down` walks rather
# than jumping, because a direct index silently fails on a workspace that does
# not exist yet.
for step in $(seq 1 12); do
    if workspace_is_clear; then
        echo "clear workspace found after $((step - 1)) step(s)"
        exec "$@"
    fi
    niri msg action focus-workspace-down >/dev/null 2>&1 || {
        echo "no more workspaces to walk to; open an empty one and re-run" >&2
        exit 2
    }
    sleep 0.35
done

echo "no empty workspace within 12 steps; open one and re-run" >&2
exit 2
