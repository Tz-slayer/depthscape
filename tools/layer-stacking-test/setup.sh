#!/usr/bin/env bash
# Stage the harness so that `qs -p` can resolve the plugin's own imports.
#
# The plugin's QML files import `qs.Common`, `qs.Services`, `qs.Modules.Plugins`
# and friends, which only exist inside a DankMaterialShell source tree. This
# script symlinks that tree (plus the plugin's own QML) next to shell.qml, so the
# *real* DepthDaemon.qml / DepthForeground.qml are what gets exercised.
#
# Usage:  ./setup.sh [dms-quickshell-dir]
#
# Default source order:
#   1. $1
#   2. $DMS_QML_DIR
#   3. the staged copy of the running shell, /run/user/$UID/danklinux-shell/*/
#   4. /home/tz/Downloads/github/DankMaterialShell/quickshell

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin="$(cd "$here/../.." && pwd)"

source_dir="${1:-${DMS_QML_DIR:-}}"

if [[ -z "$source_dir" ]]; then
    for candidate in /run/user/"$(id -u)"/danklinux-shell/*/; do
        [[ -d "$candidate" ]] && source_dir="$candidate" && break
    done
fi

if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
    source_dir=/home/tz/Downloads/github/DankMaterialShell/quickshell
fi

if [[ ! -d "$source_dir/Common" ]]; then
    echo "error: $source_dir does not look like a DankMaterialShell quickshell tree" >&2
    exit 1
fi

echo "DMS imports  : $source_dir"
echo "plugin QML   : $plugin/qml"

for dir in Common Services Modules Widgets DankCommon Modals Shaders assets; do
    [[ -e "$source_dir/$dir" ]] || continue
    ln -sfn "$source_dir/$dir" "$here/$dir"
done

for file in "$plugin"/qml/*.qml; do
    ln -sfn "$file" "$here/$(basename "$file")"
done

echo
echo "staged. run the harness with:"
echo
echo "  export DEPTHSCAPE_ENGINE=$plugin/engine/target/release/depthscape-engine"
echo "  qs -p $here"
echo
echo "then follow README.md."
