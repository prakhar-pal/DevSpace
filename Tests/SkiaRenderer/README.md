# Portable Swift/Skia renderer checks

After building the pinned native dependencies described in
`Tests/SkiaInterop/README.md`, run `make linux-test-skia`.
The runner compiles the engine and renderer as separate modules and executes
native XCTest tests with warnings treated as errors. No GTK headers are made
available to the renderer module. Tests cover independently specified RGBA
pixels, clearing, selection, decorations, cursor shapes/readability, contextual
Arabic shaping across cells, installed fallback fonts, wide cells, long
graphemes, clipping, fractional scaling and raster resource recreation.

`GDK_BACKEND=x11 xvfb-run -a bash scripts/check-skia-runtime.sh --terminal-gpu`
also draws actual terminal frames through the same renderer into a GtkGLArea
framebuffer, checks background and glyph pixels, resizes, destroys/recreates
windows and disposes contexts. This host uses llvmpipe; that exercises the GPU
API but does **not** establish hardware acceleration.

The renderer takes a borrowed generic SkFontMgr and acquires its own reference.
Linux's Fontconfig factory stays in the platform/test adapter. HarfBuzz shapes
from copies of that same Skia typeface's tables, keeping glyph IDs consistent.
Each cluster is anchored to its terminal column; this is terminal-grid layout,
not bidi paragraph layout. Shaped row caches retain at most 128 rows of at most
512 cells; larger rows render without caching. All drawing is Swift; the sole
C++ implementation remains the previously approved borrowed context upcast.

The Swift wrapper/Skia renderer is the Linux default. These tests do not establish live SSH, clipboard,
IME, accessibility, packaged artifacts or macOS renderer compatibility.
