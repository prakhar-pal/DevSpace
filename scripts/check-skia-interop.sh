#!/usr/bin/env bash
# Compile actual Skia calls without downloading, linking or launching anything.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_root=${SKIA_SOURCE:-"$repo_root/.tmp/ghostty-skia/skia"}
compiler=${SWIFTC:-swiftc}
expected_revision=$(<"$repo_root/Tests/SkiaInterop/skia-revision.txt")

if [[ ! -f "$source_root/include/core/SkCanvas.h" ]]; then
    printf 'Skia headers are missing; set SKIA_SOURCE to the pinned checkout.\n' >&2
    exit 1
fi
actual_revision=$(git -C "$source_root" rev-parse HEAD)
if [[ "$actual_revision" != "$expected_revision" ]]; then
    printf 'Skia revision mismatch: expected %s, found %s\n' "$expected_revision" "$actual_revision" >&2
    exit 1
fi
if ! git -C "$source_root" diff --quiet HEAD -- include; then
    printf 'Skia headers are modified; the direct import gate requires unmodified upstream headers.\n' >&2
    exit 1
fi

output_root="$repo_root/.tmp/ghostty-skia"
mkdir -p -- "$output_root"
"$compiler" -emit-object -warnings-as-errors \
    -module-cache-path "$output_root/apinotes-cache" \
    -cxx-interoperability-mode=default \
    -Xcc -std=c++20 -Xcc -fapinotes-modules \
    -Xcc "-I$source_root" \
    -I "$repo_root/Tests/SkiaInterop/CSkia" \
    "$repo_root/Tests/SkiaInterop/ImportSmoke.swift" \
    -o "$output_root/ImportSmoke.o"
printf 'Swift/Skia object compilation passed; linking, ownership and GPU runtime remain unverified.\n'
