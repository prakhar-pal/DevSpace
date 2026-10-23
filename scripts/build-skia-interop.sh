#!/usr/bin/env bash
# Build only the pinned experimental renderer dependency, not a DevSpace bundle.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_root=${SKIA_SOURCE:-"$repo_root/.tmp/ghostty-skia/skia"}
compiler_c=$(command -v "${CC:-clang}")
compiler_cxx=$(command -v "${CXX:-clang++}")
for tool in gn ninja pkg-config; do command -v "$tool" >/dev/null; done
pkg-config --exists fontconfig freetype2 harfbuzz icu-uc
bash "$repo_root/scripts/check-skia-interop.sh"
cd -- "$source_root"

# Optimized dependency, no debug symbols or unrelated codecs/tools: keep the
# feasibility build bounded on disk. This is NOT a production configuration.
gn gen out/DevSpace --args="
    is_debug=false is_official_build=true
    cc=\"$compiler_c\" cxx=\"$compiler_cxx\" extra_cflags=[\"-g0\"]
    skia_use_partition_alloc=false
    skia_enable_tools=false skia_enable_pdf=false skia_enable_skottie=false skia_enable_svg=false
    skia_use_perfetto=false skia_use_piex=false skia_use_expat=false skia_use_wuffs=false
    skia_use_libjpeg_turbo_decode=false skia_use_libjpeg_turbo_encode=false
    skia_use_libwebp_decode=false skia_use_libwebp_encode=false
    skia_use_libpng_decode=false skia_use_libpng_encode=false
    skia_use_system_freetype2=true skia_use_system_harfbuzz=true
    skia_use_system_icu=true skia_use_system_zlib=true
    skia_use_gl=true skia_use_egl=true skia_use_vulkan=false skia_enable_graphite=false
"
ninja -C out/DevSpace -j "${SKIA_BUILD_JOBS:-2}" skia skshaper skunicode
