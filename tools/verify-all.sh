#!/usr/bin/env bash
# Run every Depthscape check that does not need a hand-prepared desktop.
#
# The order here is deliberate: the cheap, pure checks run first, so a broken
# curve or a stale cache key is caught in about a second rather than after the
# live tests have moved windows around. The live tests come last and are the
# only part that touches the compositor.
#
# WHAT IS COVERED
#
# Everything here is static or offline: QML lint, the settings/daemon key
# agreement, the cache-version agreement, and the engine's own test suite. There
# are deliberately no live pixel checks any more -- the ones this script used to
# run belonged to the navigation-parallax feature, which has been removed.
#
# WHAT IS NOT COVERED
#
# The mask itself is never regenerated here; `cargo test` covers the pipeline and
# `bench.py` covers the timings. A debug engine binary *is* built for the CLI
# contract checks (incremental, seconds) because "no implicit downloads" is an
# invariant worth asserting against the real executable, not just the source.

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

# The niri layer-rule parser is pure JS, so its regression tests run under node
# with no QML environment at all.
if command -v node >/dev/null; then
    node test/compositorrules.test.js >/dev/null 2>&1
    report "compositor config rule check (node)" $?
else
    echo "  SKIP  node regression tests (node not on PATH)"
fi

dms_qml_root=$(ls -d /run/user/"$(id -u)"/dms-shell/*/ /run/user/"$(id -u)"/danklinux-shell/*/ 2>/dev/null | head -1)
# Newer DMS builds run Quickshell directly from a source tree instead of the
# generated runtime root. Ask the running process where its shell root is.
if [ -z "$dms_qml_root" ]; then
    dms_qml_root=$(pgrep -af 'qs -p ' 2>/dev/null | sed -n 's/.*qs -p \([^ ]*\).*/\1/p' | head -1)
fi
if [ -z "$dms_qml_root" ] && [ -d "/home/tz/Downloads/github/dux-shell/quickshell" ]; then
    dms_qml_root="/home/tz/Downloads/github/dux-shell/quickshell"
fi
if [ -n "$dms_qml_root" ]; then
    qmllint -I "$dms_qml_root" -I qml/widgets qml/*.qml qml/widgets/*.qml
    report "qmllint ($(ls qml/*.qml qml/widgets/*.qml | wc -l) files)" $?
else
    echo "  SKIP  qmllint (DMS is not running, so its QML root cannot be found)"
fi

# The settings page and the daemon have to agree on every key, or a control
# silently does nothing. Both sides are grepped across `qml/*.qml` so a future
# split of the daemon into cooperating files does not turn this invariant into
# a false pass: any file that reads `pluginData.<key>` counts as daemon surface,
# and any file whose name carries "Settings" contributes `settingKey:` rows.
python3 - <<'PY'
import re, sys, pathlib, glob
ui, daemon = set(), set()
for path in sorted(glob.glob("qml/*.qml")):
    text = pathlib.Path(path).read_text()
    if "Settings" in path:
        ui.update(re.findall(r'settingKey:\s*"([^"]+)"', text))
    else:
        daemon.update(re.findall(r'pluginData\.([A-Za-z0-9_]+)', text))
# These keys persist presentation state local to the settings page. They are
# intentionally not runtime inputs consumed by the daemon.
ui_only = {"ipcCommandsExpanded", "usageGuideExpanded", "targetScreen"}
orphans = sorted(ui - daemon - ui_only)
if orphans:
    print("settings keys the daemon never reads:", ", ".join(orphans))
    sys.exit(1)
PY
report "settings keys match the daemon" $?

# Persisted output paths bypass the engine entirely on shell restart. The QML
# cache key must therefore advance whenever the Rust depth pipeline does, or an
# upgraded plugin can keep restoring PNGs produced by an older pipeline.
python3 - <<'PY'
import re, sys, pathlib, glob
rust = pathlib.Path("engine/src/config.rs").read_text()
qml_text = "\n".join(pathlib.Path(p).read_text() for p in sorted(glob.glob("qml/*.qml")))
# Both versions gate the QML cache key, so both have to agree. Walk every QML
# file so the constants survive a daemon split.
for const, prop in (("DEPTH_PIPELINE_VERSION", "depthPipelineVersion"),
                    ("MASK_PIPELINE_VERSION", "maskPipelineVersion")):
    rust_match = re.search(const + r':\s*u32\s*=\s*(\d+)', rust)
    qml_match = re.search(prop + r':\s*(\d+)', qml_text)
    if not rust_match or not qml_match:
        print(f"{const} / {prop} is missing from Rust or QML")
        sys.exit(1)
    if rust_match.group(1) != qml_match.group(1):
        print(f"{const} mismatch: Rust {rust_match.group(1)}, QML {qml_match.group(1)}")
        sys.exit(1)
PY
report "pipeline cache versions match" $?

echo
echo "=== data root ==="

sh -n tools/resolve-data-root.sh
report "data root script syntax" $?
sh -n tools/download-engine.sh
report "download engine script syntax" $?

# A fresh install keeps models inside the plugin directory so DMS's uninstall
# removes them. Every engine call must therefore go through engineArgs(), or a
# stale command would silently use the engine's own default directory.
python3 - <<'PY'
import pathlib, re, sys
text = pathlib.Path("qml/DepthDaemon.qml").read_text()
direct = re.findall(r'(?:command|args)\s*=\s*\[\s*enginePath\b', text)
if direct:
    print("engine commands bypassing the resolved data root:", len(direct))
    sys.exit(1)
if len(re.findall(r'\bengineArgs\s*\(', text)) < 6:
    print("expected engineArgs definition + one call per engine process")
    sys.exit(1)
PY
report "every engine call carries the resolved data root" $?

tmp=$(mktemp -d)
plugin="$tmp/plugin"; xdg="$tmp/xdg"
mkdir -p "$plugin"
fresh=$(XDG_DATA_HOME="$xdg" sh tools/resolve-data-root.sh "$plugin")
mkdir -p "$xdg/depthscape"
legacy=$(XDG_DATA_HOME="$xdg" sh tools/resolve-data-root.sh "$plugin")
override=$(XDG_DATA_HOME="$xdg" DEPTHSCAPE_DATA_DIR="$tmp/custom" sh tools/resolve-data-root.sh "$plugin")
fallback=$(XDG_DATA_HOME="$tmp/xdg2" sh tools/resolve-data-root.sh "$tmp/missing")
if [ "$fresh" = "$plugin/.data" ] && [ "$legacy" = "$xdg/depthscape" ] \
    && [ "$override" = "$tmp/custom" ] && [ "$fallback" = "$tmp/xdg2/depthscape" ]; then
    report "data root: fresh / legacy / override / fallback" 0
else
    printf '  fresh=%s legacy=%s override=%s fallback=%s\n' "$fresh" "$legacy" "$override" "$fallback"
    report "data root: fresh / legacy / override / fallback" 1
fi
[ -n "$tmp" ] && [ -d "$tmp" ] && rm -rf -- "$tmp"

echo
echo "=== model download policy ==="

# The plugin offers exactly three depth estimators. The engine's ALL_MODELS and
# the settings page's modelIds must agree, or `status` would advertise models
# the dropdown cannot show (or the dropdown would offer ones the engine rejects).
python3 - <<'PY'
import pathlib, re, sys
rust = pathlib.Path("engine/src/config.rs").read_text()
qml = pathlib.Path("qml/DepthSettings.qml").read_text()
m = re.search(r'ALL_MODELS: &\[ModelDescriptor\] = &\[(.*?)\];', rust, re.S)
items = re.findall(r'MODEL_[A-Z_]+', m.group(1)) if m else []
if items != ["MODEL_SMALL", "MODEL_BASE", "MODEL_LARGE"]:
    print("ALL_MODELS must be exactly MODEL_SMALL, MODEL_BASE, MODEL_LARGE; got:", items)
    sys.exit(1)
qm = re.search(r'modelIds:\s*\[(.*?)\]', qml, re.S)
ids = re.findall(r'"([^"]+)"', qm.group(1)) if qm else []
if ids != ["small", "base", "large"]:
    print("settings page modelIds must be exactly small, base, large; got:", ids)
    sys.exit(1)
PY
report "depth model catalogue is V2-only" $?

# `setup` is the one and only download entry point. A `model::download` call
# anywhere else means a wallpaper change, a shell start or a spatial effect
# silently fetches hundreds of megabytes the user never asked for.
python3 - <<'PY'
import glob, pathlib, re, sys
hits = []
for path in sorted(glob.glob("engine/src/*.rs")):
    if path.endswith("main.rs"):
        continue
    for n, line in enumerate(pathlib.Path(path).read_text().splitlines(), 1):
        if re.search(r'\bmodel::download\s*\(', line):
            hits.append(f"{path}:{n}: {line.strip()}")
if hits:
    print("implicit downloads found outside the setup command:")
    print("\n".join(hits))
    sys.exit(1)
main = pathlib.Path("engine/src/main.rs").read_text()
if len(re.findall(r'\bmodel::download\s*\(', main)) != 1:
    print("expected exactly one download callsite in main.rs (the setup command)")
    sys.exit(1)
PY
report "models download only via setup" $?

if command -v cargo >/dev/null; then
    (cd engine && cargo build --quiet --bin depthscape-engine >/dev/null 2>&1)
    build_ok=$?
    cli="engine/target/debug/depthscape-engine"
    if [ "$build_ok" -eq 0 ] && [ -x "$cli" ]; then
        tmp=$(mktemp -d)
        out=$(DEPTHSCAPE_DATA_DIR="$tmp" "$cli" analyze --wallpaper assets/screenshot.png --model small 2>&1)
        rc=$?
        leftovers=$(find "$tmp" -type f -print -quit)
        if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "not installed" && [ -z "$leftovers" ]; then
            report "analyze never downloads a missing model" 0
        else
            printf '  rc=%s output=%s leftover=%s\n' "$rc" "$out" "$leftovers"
            report "analyze never downloads a missing model" 1
        fi

        # A custom data root may contain user files. `uninstall` must remove
        # only Depthscape's own subtrees and leave everything else in place.
        mkdir -p "$tmp/models/demo" "$tmp/cache/masks"
        printf model > "$tmp/models/demo/model.onnx"
        printf mask > "$tmp/cache/masks/a.png"
        printf keep > "$tmp/keep.txt"
        DEPTHSCAPE_DATA_DIR="$tmp" "$cli" uninstall >/dev/null 2>&1
        if [ ! -e "$tmp/models" ] && [ ! -e "$tmp/cache" ] && [ -f "$tmp/keep.txt" ]; then
            report "uninstall removes only Depthscape data" 0
        else
            report "uninstall removes only Depthscape data" 1
        fi
        [ -n "$tmp" ] && [ -d "$tmp" ] && rm -rf -- "$tmp"

        # End-to-end fresh install: the resolved root must be *inside* the
        # plugin directory, the engine must be pointed at it with --data-dir,
        # and the whole thing must disappear on uninstall while the plugin's
        # own files survive. This is what makes an uninstall remove the models.
        plugin_tmp=$(mktemp -d)
        mkdir -p "$plugin_tmp/plugin"
        printf manifest > "$plugin_tmp/plugin/plugin.json"
        fresh_root=$(XDG_DATA_HOME="$plugin_tmp/xdg" sh tools/resolve-data-root.sh "$plugin_tmp/plugin")
        mkdir -p "$fresh_root/models/demo" "$fresh_root/cache/masks"
        printf model > "$fresh_root/models/demo/model.onnx"
        printf mask > "$fresh_root/cache/masks/mask.png"
        "$cli" --data-dir "$fresh_root" uninstall >/dev/null 2>&1
        if [ "$fresh_root" = "$plugin_tmp/plugin/.data" ] \
            && [ ! -e "$fresh_root" ] \
            && [ -f "$plugin_tmp/plugin/plugin.json" ]; then
            report "fresh install data lives and dies with the plugin dir" 0
        else
            printf '  root=%s rootStillThere=%s\n' "$fresh_root" "$(test -e "$fresh_root" && echo yes || echo no)"
            report "fresh install data lives and dies with the plugin dir" 1
        fi
        [ -n "$plugin_tmp" ] && [ -d "$plugin_tmp" ] && rm -rf -- "$plugin_tmp"
    else
        echo "  SKIP  engine CLI contract (debug binary could not be built)"
    fi
else
    echo "  SKIP  engine CLI contract (cargo not on PATH)"
fi

echo
echo "=== engine ==="

if command -v cargo >/dev/null; then
    (cd engine && cargo test --quiet >/dev/null 2>&1)
    report "cargo test" $?
else
    echo "  SKIP  cargo test (cargo not on PATH)"
fi

echo
echo
printf '=== %d passed, %d failed ===\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    echo
    echo "logs: /tmp/depthscape-{self-test,sweep,navigation}.log"
    exit 1
fi
