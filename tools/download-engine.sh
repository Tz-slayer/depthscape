#!/usr/bin/env sh
set -eu

plugin_dir="${1:-$(dirname "$0")/..}"
mode="${2:-download}"
target_dir="$plugin_dir/bin"
target_bin="$target_dir/depthscape-engine"
marker="$target_bin.version"

if ! IFS= read -r required_version < "$plugin_dir/engine-version"; then
    echo "Cannot read required engine version." >&2
    exit 1
fi
case "$required_version" in
    v[0-9]* ) ;;
    *) echo "Invalid required engine version." >&2; exit 1 ;;
esac
case "$required_version" in
    *[!a-zA-Z0-9._-]* ) echo "Invalid required engine version." >&2; exit 1 ;;
esac

if [ "$mode" = "--check" ]; then
    if [ ! -x "$target_bin" ] || [ ! -f "$marker" ]; then
        exit 1
    fi
    # Avoid reading a marker and binary from different update generations.
    exec 9>"$target_dir/.depthscape-engine.lock"
    flock -s -w 630 9 || { echo "Timed out waiting for another engine update." >&2; exit 1; }
    IFS=' ' read -r installed_version installed_hash < "$marker" || exit 1
    [ "$installed_version" = "$required_version" ] || exit 1
    [ "${#installed_hash}" -eq 64 ] || exit 1
    case "$installed_hash" in *[!0-9a-f]*) exit 1 ;; esac
    actual_hash=$(sha256sum "$target_bin") || exit 1
    [ "${actual_hash%% *}" = "$installed_hash" ]
    exit $?
fi
[ "$mode" = "download" ] || { echo "Unknown engine operation." >&2; exit 1; }

arch=$(uname -m)
case "$arch" in
    x86_64) target_triple="x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) target_triple="aarch64-unknown-linux-gnu" ;;
    *) echo "Unsupported architecture: $arch. Please build from source." >&2; exit 1 ;;
esac
asset="depthscape-engine-${target_triple}"
url="https://github.com/Tz-slayer/depthscape/releases/download/${required_version}/${asset}"
mkdir -p "$target_dir"
tmp_dir=$(mktemp -d "$target_dir/.engine-update.XXXXXXXX")
marker_changed=0
installed=0
cleanup() {
    if [ "$marker_changed" = 1 ] && [ "$installed" = 0 ]; then
        if [ -f "$tmp_dir/previous-marker" ]; then
            mv -f "$tmp_dir/previous-marker" "$marker" || :
        else
            rm -f "$marker"
        fi
    fi
    rm -f "$tmp_dir/engine" "$tmp_dir/checksum" "$tmp_dir/marker" "$tmp_dir/previous-marker"
    rmdir "$tmp_dir" 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Serialize replacements without leaving stale locks after a crash. flock is
# available in util-linux on supported Linux distributions.
exec 9>"$target_dir/.depthscape-engine.lock"
flock -w 630 9 || { echo "Timed out waiting for another engine update." >&2; exit 1; }

echo "Downloading depth engine ${required_version} for $arch..." >&2
curl -fsSL --connect-timeout 15 --max-time 300 "$url" -o "$tmp_dir/engine"
curl -fsSL --connect-timeout 15 --max-time 300 "$url.sha256" -o "$tmp_dir/checksum"
IFS=' ' read -r expected_hash checksum_name < "$tmp_dir/checksum" || { echo "Invalid engine checksum." >&2; exit 1; }
[ "${#expected_hash}" -eq 64 ] || { echo "Invalid engine checksum." >&2; exit 1; }
case "$expected_hash" in *[!0-9a-f]*) echo "Invalid engine checksum." >&2; exit 1 ;; esac
[ "$checksum_name" = "$asset" ] || { echo "Engine checksum names a different file." >&2; exit 1; }
printf '%s  %s\n' "$expected_hash" "$tmp_dir/engine" | sha256sum -c - >/dev/null || { echo "Engine checksum verification failed." >&2; exit 1; }
chmod +x "$tmp_dir/engine"
printf '%s %s\n' "$required_version" "$expected_hash" > "$tmp_dir/marker"
if [ -f "$marker" ]; then
    cp -p "$marker" "$tmp_dir/previous-marker"
fi
# The marker is installed first: an interruption between renames produces a
# hash mismatch, never a false version match. Restore it if the binary rename
# fails; the old binary remains untouched until the last rename.
mv -f "$tmp_dir/marker" "$marker"
marker_changed=1
mv -f "$tmp_dir/engine" "$target_bin"
installed=1
printf '%s\n' ok
