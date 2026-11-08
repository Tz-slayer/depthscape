#!/usr/bin/env sh
# Decide where Depthscape keeps its models and caches.
#
# DMS 2.x deletes the plugin directory on uninstall but offers no callback a
# plugin could use. A fresh install therefore keeps all of its data *inside*
# that directory: removing the plugin removes the downloaded models with it.
# An existing XDG data directory is left exactly where it is — silently moving
# gigabytes of models during an upgrade would be worse than the cleanup it buys.
#
# Usage: resolve-data-root.sh <plugin-dir>
set -u

plugin_dir="${1:-}"

# 1. An explicit override always wins (also useful for packaging / testing).
if [ -n "${DEPTHSCAPE_DATA_DIR:-}" ]; then
    printf '%s\n' "$DEPTHSCAPE_DATA_DIR"
    exit 0
fi

if [ -n "${XDG_DATA_HOME:-}" ]; then
    legacy="$XDG_DATA_HOME/depthscape"
else
    legacy="${HOME:-/tmp}/.local/share/depthscape"
fi

# 2. Pre-existing installation: keep the old location, no migration.
if [ -d "$legacy" ]; then
    printf '%s\n' "$legacy"
    exit 0
fi

# 3. Fresh install: live inside the plugin directory so an uninstall is a
#    complete cleanup. A read-only plugin directory (system-wide installs)
#    falls back to the user data directory instead of failing to download.
if [ -n "$plugin_dir" ] && [ -d "$plugin_dir" ] && [ -w "$plugin_dir" ]; then
    printf '%s\n' "$plugin_dir/.data"
    exit 0
fi

printf '%s\n' "$legacy"
