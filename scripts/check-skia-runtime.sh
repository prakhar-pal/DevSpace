#!/usr/bin/env bash
# Explicit acceptance executable; no production startup, installation or clipboard writes.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_root=${SKIA_SOURCE:-"$repo_root/.tmp/ghostty-skia/skia"}
compiler=${SWIFTC:-swiftc}
mode=${1:---raster}
sample_source="$repo_root/Tests/SkiaInterop/SampleDrawing.swift"
case "$mode" in
    --raster) test_source=RasterSmoke.swift ;;
    --gpu) test_source=GPUSmoke.swift ;;
    --terminal-gpu)
        test_source=GPUSmoke.swift
        sample_source="$repo_root/Tests/SkiaGPU/TerminalDrawing.swift"
        bash "$repo_root/scripts/test-skia-renderer.sh"
        ;;
    *) printf 'Usage: bash scripts/check-skia-runtime.sh [--raster|--gpu|--terminal-gpu]\n' >&2; exit 2 ;;
esac
if [[ ! -f "$source_root/out/DevSpace/libskia.a" ]]; then
    printf 'Build the pinned Skia library first with scripts/build-skia-interop.sh.\n' >&2
    exit 1
fi
bash "$repo_root/scripts/check-skia-interop.sh"
output_root="$repo_root/.tmp/ghostty-skia"
runtime_dir=$(mktemp -d "$output_root/runtime-${mode#--}.XXXXXX")
trap 'rm -f -- "$runtime_dir/check"; rmdir -- "$runtime_dir"' EXIT
native_flags=()
native_libraries=(-lstdc++ -lfontconfig -lfreetype -lGL -lEGL -lGLESv2 -ldl)
if [[ "$mode" == *gpu ]]; then
    read -r -a gtk_flags <<< "$(pkg-config --cflags gtk4)"
    for flag in "${gtk_flags[@]}"; do native_flags+=(-Xcc "$flag"); done
    read -r -a gtk_libraries <<< "$(pkg-config --libs gtk4)"
    native_libraries+=("${gtk_libraries[@]}")
fi
if [[ "$mode" == --terminal-gpu ]]; then
    engine="$output_root/engine-tests"
    renderer="$output_root/renderer-tests"
    prefix=${GHOSTTY_VT_PREFIX:-"$output_root/ghostty-vt"}
    native_flags+=(-D DEVSPACE_TERMINAL_GPU -I "$repo_root/Sources/GhosttyVTInterop" -Xcc "-I$prefix/include"
        -I "$repo_root/Sources/HarfBuzzInterop" -I "$engine" -I "$renderer")
    read -r -a hb_flags <<< "$(pkg-config --cflags harfbuzz)"
    for flag in "${hb_flags[@]}"; do native_flags+=(-Xcc "$flag"); done
    native_libraries+=(-L "$engine" -lDevSpaceGhosttyVT -Xlinker -rpath -Xlinker "$engine"
        -L "$renderer" -lDevSpaceSkiaRenderer -Xlinker -rpath -Xlinker "$renderer" -lharfbuzz)
fi
"$compiler" -parse-as-library -warnings-as-errors \
    -module-cache-path "$output_root/apinotes-cache" \
    -cxx-interoperability-mode=default -Xcc -std=c++20 \
    -Xcc -DNDEBUG -Xcc -DSK_R32_SHIFT=16 -Xcc -fapinotes-modules \
    -Xcc "-I$source_root" -I "$repo_root/Sources/SkiaInterop" \
    -I "$repo_root/Tests/SkiaInterop/CGPU" -I "$repo_root/Sources/LinuxGTK" \
    "${native_flags[@]}" "$repo_root/Tests/SkiaInterop/$test_source" \
    "$sample_source" \
    -L "$source_root/out/DevSpace" -lskia -lskcms "${native_libraries[@]}" \
    -o "$runtime_dir/check"
"$runtime_dir/check"
