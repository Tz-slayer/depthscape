#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/engine/spatial3d"
BUILD="$SOURCE/build"
DEST="$ROOT/qml/native/Depthscape/Spatial3D"

# The daemon matches these two sentences to tell the user what to install, so
# they are part of the contract rather than free-form log text.
if ! command -v cmake >/dev/null 2>&1; then
    printf '%s\n' "cmake is not installed. Install cmake and a C++ toolchain." >&2
    exit 1
fi
if ! command -v c++ >/dev/null 2>&1; then
    printf '%s\n' "No C++ compiler found. Install a C++ toolchain." >&2
    exit 1
fi

if ! cmake -S "$SOURCE" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release; then
    printf '%s\n' "Qt Quick3D development files are required for the spatial mesh renderer." >&2
    exit 1
fi
# Three translation units, but never let the job count scale with the host.
nice -n 10 cmake --build "$BUILD" --parallel 4
mkdir -p "$DEST"
cp "$BUILD/qml/Depthscape/Spatial3D/libdepthscape_spatial3d.so" "$DEST/.libdepthscape_spatial3d.so.tmp"
mv -f "$DEST/.libdepthscape_spatial3d.so.tmp" "$DEST/libdepthscape_spatial3d.so"
cp "$SOURCE/qmldir" "$DEST/"
printf 'Installed the Quick3D spatial mesh plugin into %s\n' "$DEST"
