#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
plugin="$tmp/plugin"
mkdir -p "$plugin/bin" "$tmp/mock"
printf 'v0.6.0\n' > "$plugin/engine-version"
printf '#!/bin/sh\necho new\n' > "$tmp/new-engine"
chmod +x "$tmp/new-engine"
sha256sum "$tmp/new-engine" | sed 's|  .*|  depthscape-engine-x86_64-unknown-linux-gnu|' > "$tmp/checksum"
cat > "$tmp/mock/uname" <<'MOCK'
#!/bin/sh
printf '%s\n' x86_64
MOCK
cat > "$tmp/mock/curl" <<'MOCK'
#!/bin/sh
shift 5
url=$1
[ "$2" = -o ] || exit 2
case "$url" in
    *'/releases/download/v0.6.0/'*) ;;
    *) exit 2 ;;
esac
[ "${FAIL_DOWNLOAD:-0}" = 0 ] || exit 22
case "$url" in
    *.sha256) cp "$TEST_DIR/checksum" "$3" ;;
    *) cp "$TEST_DIR/new-engine" "$3" ;;
esac
MOCK
cat > "$tmp/mock/mv" <<'MOCK'
#!/bin/sh
case "${FAIL_REPLACE:-0}:$2" in
    1:*/.engine-update.*/engine) exit 1 ;;
esac
exec /usr/bin/mv "$@"
MOCK
chmod +x "$tmp/mock/"*
export PATH="$tmp/mock:$PATH" TEST_DIR="$tmp"
script="$root/tools/download-engine.sh"
check() { sh "$script" "$plugin" --check; }
download() { sh "$script" "$plugin"; }
printf '#!/bin/sh\necho old\n' > "$plugin/bin/depthscape-engine"
chmod +x "$plugin/bin/depthscape-engine"
old_hash=$(sha256sum "$plugin/bin/depthscape-engine")
if check; then echo 'unmarked old binary accepted' >&2; exit 1; fi
if FAIL_DOWNLOAD=1 download; then echo 'failed download accepted' >&2; exit 1; fi
[ "$(sha256sum "$plugin/bin/depthscape-engine")" = "$old_hash" ]
printf '%064d  depthscape-engine-x86_64-unknown-linux-gnu\n' 0 > "$tmp/checksum"
if download; then echo 'bad checksum accepted' >&2; exit 1; fi
[ "$(sha256sum "$plugin/bin/depthscape-engine")" = "$old_hash" ]
sha256sum "$tmp/new-engine" | sed 's|  .*|  depthscape-engine-x86_64-unknown-linux-gnu|' > "$tmp/checksum"
download
check
printf 'modified\n' >> "$plugin/bin/depthscape-engine"
if check; then echo 'modified binary accepted' >&2; exit 1; fi
printf 'v0.6.1\n' > "$plugin/engine-version"
if check; then echo 'different required version accepted' >&2; exit 1; fi
printf 'v0.6.0\n' > "$plugin/engine-version"
download
old_hash=$(sha256sum "$plugin/bin/depthscape-engine")
old_marker=$(cat "$plugin/bin/depthscape-engine.version")
printf '#!/bin/sh\necho replacement\n' > "$tmp/new-engine"
sha256sum "$tmp/new-engine" | sed 's|  .*|  depthscape-engine-x86_64-unknown-linux-gnu|' > "$tmp/checksum"
if FAIL_REPLACE=1 download; then echo 'failed replacement accepted' >&2; exit 1; fi
[ "$(sha256sum "$plugin/bin/depthscape-engine")" = "$old_hash" ]
[ "$(cat "$plugin/bin/depthscape-engine.version")" = "$old_marker" ]
check
echo 'download-engine tests passed'
