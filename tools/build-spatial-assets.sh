#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$root/engine/spatial-assets"
build_dir="$source_dir/build"
cmake_args=()
if [[ -n "${DEPTHSCAPE_OPENCV_ROOT:-}" ]]; then
    opencv_dir="$(find "$DEPTHSCAPE_OPENCV_ROOT/usr/lib/cmake" -name OpenCVConfig.cmake -print -quit 2>/dev/null)"
    if [[ -z "$opencv_dir" ]]; then
        printf '%s\n' 'OpenCV configuration not found under DEPTHSCAPE_OPENCV_ROOT.' >&2
        exit 1
    fi
    cmake_args+=("-DOpenCV_DIR=$(dirname "$opencv_dir")")
fi
if ! cmake -S "$source_dir" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release "${cmake_args[@]}"; then
    printf '%s\n' 'OpenCV development files (core, imgproc, imgcodecs) are required for spatial asset preparation.' >&2
    exit 1
fi
cmake --build "$build_dir" --parallel
for profile in release debug; do
    dest="$root/engine/target/$profile"
    mkdir -p "$dest"
    cp "$build_dir/depthscape-spatial-assets" "$dest/.depthscape-spatial-assets.tmp"
    mv -f "$dest/.depthscape-spatial-assets.tmp" "$dest/depthscape-spatial-assets"
    if [[ -n "${DEPTHSCAPE_OPENCV_ROOT:-}" ]]; then
        mkdir -p "$dest/spatial-lib"
        for module in core imgproc imgcodecs geometry flann; do
            for lib in "$DEPTHSCAPE_OPENCV_ROOT"/usr/lib/libopencv_"$module".so*; do
                [[ -e "$lib" ]] || continue
                cp -a "$lib" "$dest/spatial-lib/"
            done
        done
    fi
done
printf 'Installed spatial asset helper into engine/target/{release,debug}\n'
