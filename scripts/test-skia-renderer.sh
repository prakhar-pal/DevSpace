#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_root=${SKIA_SOURCE:-"$repo_root/.tmp/ghostty-skia/skia"}
prefix=${GHOSTTY_VT_PREFIX:-"$repo_root/.tmp/ghostty-skia/ghostty-vt"}
compiler=${SWIFTC:-swiftc}
output="$repo_root/.tmp/ghostty-skia/renderer-tests"
engine="$repo_root/.tmp/ghostty-skia/engine-tests"
mkdir -p -- "$output"
bash "$repo_root/scripts/test-ghostty-engine.sh"
common=(-warnings-as-errors -cxx-interoperability-mode=default -Xcc -std=c++20 -Xcc -fapinotes-modules
    -Xcc -DNDEBUG -Xcc -DSK_R32_SHIFT=16 -Xcc "-I$source_root" -Xcc "-I$prefix/include"
    -module-cache-path "$output/module-cache" -I "$repo_root/Sources/SkiaInterop"
    -I "$repo_root/Sources/HarfBuzzInterop" -I "$repo_root/Sources/GhosttyVTInterop" -I "$engine")
read -r -a hb_flags <<< "$(pkg-config --cflags harfbuzz)"
for flag in "${hb_flags[@]}"; do common+=(-Xcc "$flag"); done
libraries=(-L "$engine" -lDevSpaceGhosttyVT -Xlinker -rpath -Xlinker "$engine"
    -L "$source_root/out/DevSpace" -lskia -lskcms -lstdc++ -lharfbuzz -lfontconfig -lfreetype -lGL -lEGL -lGLESv2 -ldl)
"$compiler" "${common[@]}" -emit-library -emit-module -module-name DevSpaceSkiaRenderer -enable-testing \
    -emit-module-path "$output/DevSpaceSkiaRenderer.swiftmodule" \
    "$repo_root"/Sources/SkiaRenderer/*.swift "${libraries[@]}" -o "$output/libDevSpaceSkiaRenderer.so"
"$compiler" "${common[@]}" -I "$output" -L "$output" -lDevSpaceSkiaRenderer \
    -Xlinker -rpath -Xlinker "$output" "$repo_root"/Tests/SkiaRenderer/*.swift \
    "${libraries[@]}" -o "$output/tests"
"$output/tests"
