# ADR 0003: Portable Ghostty terminal state and Swift/Skia rendering

- **Status:** Linux default selected by the user on 2026-10-26
- **Date:** 2026-10-24
- **Amends:** ADR 0002's Linux terminal renderer, preserving its GTK/Swift shell

The user requires a platform-independent, GPU-capable terminal renderer and
Swift implementation wherever practical. Copying Ghostty's GTK application
would import unrelated UI and lifecycle behavior. Ghostling is a useful example,
but it does not supply the production terminal widget DevSpace needs.

Use the pinned libghostty-vt C API for terminal state and protocol encoding.
Swift owns an independent snapshot/input adapter and draws with Skia through
direct Swift C++ interoperability. HarfBuzz shapes using the matching Skia
typeface's tables. Portable modules import no GTK, PTY or clipboard APIs.
The only C++ implementation helper is the user-approved borrowed
GrDirectContext-to-GrRecordingContext conversion.

GTK hosts the Linux surface, input method, selection gestures and clipboard.
Use OpenGL with a hardware driver and explicitly report a Skia raster fallback
for unavailable/software contexts. Keep the existing Swift PTY, bounded output
delivery, identities, backend, SSH ownership, hooks and notification routing.
macOS remains unchanged. Future native hosts can supply another font manager,
surface and input adapter; that portability has not been verified on macOS.

The Swift libghostty-vt/Skia wrapper is the Linux default. VTE is available only
through explicit `DEVSPACE_LINUX_TERMINAL=vte` fallback selection and is absent
from the default dependency graph. Both app identities support the wrapper.
Normal bundles ship the selected global Swift runtime and pinned native
notices; selecting the default does not install over a running application.
No Ghostty themes or application UI
are bundled. Inline Kitty image drawing is deferred and its capability is
disabled; existing clipboard-image uploads remain a host/backend function.

Hardware rendering was verified on 2026-10-26 through accelerated VirGL on the
actual desktop. Herdr and cross-app clipboard acceptance also passed. Actual
IBus/Fcitx and manual screen-reader acceptance remain unverified. The user
explicitly requested the default change with those gaps recorded. The selected
dependency policy uses pinned static Ghostty/Skia/skcms, distro-provided
GTK/font/text/GL libraries, and complete native notices. Release builds/install
still require separate approval. Native AT-SPI text/caret/selection
queries pass; this does not establish manual screen-reader parity or hardware
performance. See the migration plan and
`docs/linux-development.md` for current evidence and remaining work.
