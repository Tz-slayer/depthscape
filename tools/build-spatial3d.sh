#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/engine/spatial3d"
BUILD="$SOURCE/build"
DEST="$ROOT/qml/native/Depthscape/Spatial3D"

if ! cmake -S "$SOURCE" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release; then
    printf '%s\n' "Qt Quick3D development files are required for the spatial mesh renderer." >&2
    exit 1
fi
cmake --build "$BUILD" --parallel
mkdir -p "$DEST"
cp "$BUILD/qml/Depthscape/Spatial3D/libdepthscape_spatial3d.so" "$DEST/.libdepthscape_spatial3d.so.tmp"
mv -f "$DEST/.libdepthscape_spatial3d.so.tmp" "$DEST/libdepthscape_spatial3d.so"
cp "$SOURCE/qmldir" "$DEST/"
printf 'Installed the Quick3D spatial mesh plugin into %s\n' "$DEST"
