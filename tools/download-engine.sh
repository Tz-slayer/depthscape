#!/usr/bin/env sh
set -eu

plugin_dir="${1:-$(dirname "$0")/..}"
target_dir="$plugin_dir/bin"
target_bin="$target_dir/depthscape-engine"

arch=$(uname -m)
case "$arch" in
    x86_64) target_triple="x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) target_triple="aarch64-unknown-linux-gnu" ;;
    *)
        echo "Unsupported architecture: $arch. Please build from source." >&2
        exit 1
        ;;
esac

url="https://github.com/Tz-slayer/depthscape/releases/latest/download/depthscape-engine-${target_triple}"

mkdir -p "$target_dir"
tmp_bin="${target_bin}.tmp.$$"

echo "Downloading prebuilt engine for $arch..." >&2
if curl -fSL "$url" -o "$tmp_bin"; then
    chmod +x "$tmp_bin"
    mv -f "$tmp_bin" "$target_bin"
    echo "ok"
    exit 0
else
    rm -f "$tmp_bin"
    echo "Failed to download prebuilt engine from $url" >&2
    exit 1
fi
