#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
prefix=${GHOSTTY_VT_PREFIX:-"$repo_root/.tmp/ghostty-skia/ghostty-vt"}
compiler=${SWIFTC:-swiftc}
if [[ ! -f "$prefix/lib/libghostty-vt.a" ]]; then
    printf 'Build the pinned libghostty-vt first; see Tests/SkiaInterop/README.md.\n' >&2
    exit 1
fi
output_root="$repo_root/.tmp/ghostty-skia"
mkdir -p -- "$output_root"
"$compiler" -parse-as-library -warnings-as-errors \
    -module-cache-path "$output_root/ghostty-module-cache" \
    -I "$repo_root/Tests/SkiaInterop/CGhosttyVT" -Xcc "-I$prefix/include" \
    "$repo_root/Tests/SkiaInterop/GhosttySmoke.swift" \
    "$prefix/lib/libghostty-vt.a" -o "$output_root/ghostty-smoke"
"$output_root/ghostty-smoke"
