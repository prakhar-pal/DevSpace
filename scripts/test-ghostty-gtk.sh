#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_root=${SKIA_SOURCE:-"$repo_root/.tmp/ghostty-skia/skia"}
prefix=${GHOSTTY_VT_PREFIX:-"$repo_root/.tmp/ghostty-skia/ghostty-vt"}
compiler=${SWIFTC:-swiftc}
output="$repo_root/.tmp/ghostty-skia/gtk-tests"
engine="$repo_root/.tmp/ghostty-skia/engine-tests"
renderer="$repo_root/.tmp/ghostty-skia/renderer-tests"
mkdir -p -- "$output"
common=(-D DEVSPACE_GHOSTTY -warnings-as-errors -cxx-interoperability-mode=default
    -Xcc -std=c++20 -Xcc -fapinotes-modules -Xcc -DNDEBUG -Xcc -DSK_R32_SHIFT=16
    -Xcc "-I$source_root" -Xcc "-I$prefix/include" -module-cache-path "$output/module-cache"
    -I "$repo_root/Sources/SkiaInterop" -I "$repo_root/Sources/HarfBuzzInterop"
    -I "$repo_root/Sources/GhosttyVTInterop" -I "$repo_root/Sources/LinuxGTK"
    -I "$repo_root/Sources/LinuxGPU" -I "$engine" -I "$renderer")
read -r -a native_flags <<< "$(pkg-config --cflags gtk4 harfbuzz)"
for flag in "${native_flags[@]}"; do common+=(-Xcc "$flag"); done
read -r -a native_libraries <<< "$(pkg-config --libs gtk4 harfbuzz)"
"$compiler" "${common[@]}" "$repo_root/Sources/LinuxApp/GhosttyTerminalView.swift" \
    "$repo_root/Tests/LinuxApp/NativeKeyInput.swift" "$repo_root/Tests/GhosttyGTK/main.swift" -L "$engine" -lDevSpaceGhosttyVT \
    -Xlinker -rpath -Xlinker "$engine" -L "$renderer" -lDevSpaceSkiaRenderer \
    -Xlinker -rpath -Xlinker "$renderer" -L "$source_root/out/DevSpace" \
    -lskia -lskcms -lstdc++ -lfontconfig -lfreetype -lGL -lEGL -lGLESv2 -ldl \
    "${native_libraries[@]}" -o "$output/tests"
"$output/tests"
