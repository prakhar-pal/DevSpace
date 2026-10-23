# ADR 0003: Portable Ghostty terminal state and Swift/Skia rendering

- **Status:** Accepted for development opt-in; production cutover pending M05
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

VTE stays the default until acceptance completes. The experimental frontend
refuses the production channel. Its development bundle uses a separate path,
ships the selected global Swift runtime and pinned native notices, and does not
install over either running application. No Ghostty themes or application UI
are bundled. Inline Kitty image drawing is deferred and its capability is
disabled; existing clipboard-image uploads remain a host/backend function.

Hardware verification, actual desktop IME/screen reader/Herdr acceptance,
shipping dependency policy and release approval remain cutover gates. A private
software-rendering benchmark and basic accessibility metadata do not establish
GPU performance or screen-reader parity. See the migration plan and
`docs/linux-development.md` for current evidence and remaining work.
