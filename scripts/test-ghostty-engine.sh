#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
prefix=${GHOSTTY_VT_PREFIX:-"$repo_root/.tmp/ghostty-skia/ghostty-vt"}
compiler=${SWIFTC:-swiftc}
output="$repo_root/.tmp/ghostty-skia/engine-tests"
mkdir -p -- "$output"
common=(-module-cache-path "$output/module-cache" -I "$repo_root/Sources/GhosttyVTInterop" -Xcc "-I$prefix/include")
"$compiler" "${common[@]}" -warnings-as-errors -emit-library -emit-module \
    -module-name DevSpaceGhosttyVT -enable-testing \
    -emit-module-path "$output/DevSpaceGhosttyVT.swiftmodule" \
    "$repo_root"/Sources/GhosttyVT/*.swift "$prefix/lib/libghostty-vt.a" \
    -o "$output/libDevSpaceGhosttyVT.so"
"$compiler" "${common[@]}" -warnings-as-errors -I "$output" -L "$output" \
    -lDevSpaceGhosttyVT -Xlinker -rpath -Xlinker "$output" \
    "$repo_root"/Tests/GhosttyVT/*.swift -o "$output/tests"
"$output/tests"
