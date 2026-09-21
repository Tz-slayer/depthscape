#!/usr/bin/env bash
# Run every Depthscape check that does not need a hand-prepared desktop.
#
# The order here is deliberate: the cheap, pure checks run first, so a broken
# curve or a stale cache key is caught in about a second rather than after the
# live tests have moved windows around. The live tests come last and are the
# only part that touches the compositor.
#
# WHAT NEEDS THE DESKTOP
#
# The parallax checks screenshot the focused output, so they need a workspace
# with no windows on it -- see `on-clear-workspace.sh` for why. This script
# arranges that itself and re-runs each live check in place, so an unattended
# run does not silently degrade into "everything failed".
#
# WHAT IS NOT COVERED
#
# Nothing here rebuilds the engine or re-runs the split; `cargo test` covers the
# pipeline and `bench.py` covers the timings. This is the shell-side suite.

set -uo pipefail

cd "$(dirname "$0")/.."

pass=0
fail=0

report() {
    local name="$1" code="$2"
    if [ "$code" -eq 0 ]; then
        printf '  \033[32mPASS\033[0m  %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  \033[31mFAIL\033[0m  %s\n' "$name"
        fail=$((fail + 1))
    fi
}

echo "=== static checks ==="

dms_qml_root=$(ls -d /run/user/"$(id -u)"/danklinux-shell/*/ 2>/dev/null | head -1)
if [ -n "$dms_qml_root" ]; then
    qmllint -I "$dms_qml_root" qml/*.qml
    report "qmllint ($(ls qml/*.qml | wc -l) files)" $?
else
    echo "  SKIP  qmllint (DMS is not running, so its QML root cannot be found)"
fi

node test/depthscrollmath.test.js >/dev/null 2>&1
report "depthscrollmath.test.js" $?

# The settings page and the daemon have to agree on every key, or a control
# silently does nothing. This is a one-line grep because the keys are literal.
python3 - <<'PY'
import re, sys, pathlib
ui = set(re.findall(r'settingKey:\s*"([^"]+)"',
                    pathlib.Path("qml/DepthSettings.qml").read_text()))
daemon = set(re.findall(r'pluginData\.([A-Za-z0-9_]+)',
                        pathlib.Path("qml/DepthDaemon.qml").read_text()))
orphans = sorted(ui - daemon)
if orphans:
    print("settings keys the daemon never reads:", ", ".join(orphans))
    sys.exit(1)
PY
report "settings keys match the daemon" $?

echo
echo "=== engine ==="

if command -v cargo >/dev/null; then
    (cd engine && cargo test --quiet >/dev/null 2>&1)
    report "cargo test" $?
else
    echo "  SKIP  cargo test (cargo not on PATH)"
fi

echo
echo "=== live checks (these move the desktop) ==="

if [ -z "$dms_qml_root" ]; then
    echo "  SKIP  DMS is not running"
else
    tools/on-clear-workspace.sh python3 tools/verify-parallax.py --self-test \
        >/tmp/depthscape-self-test.log 2>&1
    report "parallax reaches the screen" $?

    tools/on-clear-workspace.sh python3 tools/verify-parallax.py --sweep \
        >/tmp/depthscape-sweep.log 2>&1
    report "background ratio confirmed" $?

    tools/on-clear-workspace.sh python3 tools/verify-navigation.py \
        >/tmp/depthscape-navigation.log 2>&1
    report "navigation round-trips" $?
fi

echo
printf '=== %d passed, %d failed ===\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    echo
    echo "logs: /tmp/depthscape-{self-test,sweep,navigation}.log"
    exit 1
fi
