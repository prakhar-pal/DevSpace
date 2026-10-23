# Linux Ghostty + Swift/Skia Terminal Migration

Approved in conversation on 2026-10-23. Execute inline with
`superpowers:executing-plans`, using TDD and incremental verified commits.

## Goal and constraints

Replace Linux VTE with libghostty-vt and a portable Swift/Skia renderer. Keep
GTK as the application shell and keep the macOS implementation unchanged.
Call Skia directly through Swift C++ interoperability: declaration-only import
headers/type aliases are allowed. Following the M01 compiler investigation,
the user approved one minimal C++ context-conversion helper on 2026-10-23;
all drawing and application behavior must remain Swift, not expand into a
general C++ rendering bridge.
GPU rendering is the normal path; report a Skia software fallback when hardware
rendering is unavailable. Linux-only verification does not establish macOS
renderer compatibility. Preserve usability before changing the default.

## M01 — Direct interoperability and GPU presentation

- [x] Pin Ghostty, compatible Zig, Skia and Skia dependency revisions.
- [x] Compile real Skia APIs from Swift, including ownership, text and GPU APIs.
- [x] Draw using an OpenGL surface hosted by GTK (software driver on this host).
- [x] Exercise the same drawing through a raster surface, resize and recreation.
- [x] Commit the independently verified milestone (`dac30d6`).

Do not proceed to engine integration if direct imports, ownership or
presentation cannot work reliably. Revisit the design rather than introducing
a bridge silently. Do not claim software OpenGL proves hardware acceleration.

2026-10-23 checkpoint: global Swift 6.4.1/Zig 0.17.0 built the pinned native
dependencies. Swift ABI/ANSI tests, actual Skia raster pixel/font/ownership
tests, and GTK OpenGL pixel/resize/widget-recreation tests pass. Both private
X11 and actual Wayland expose llvmpipe; strict host hardware acceptance exits
77 (unavailable), not success. The user approved deferring hardware-GPU
verification to the final cutover step because this host does not support it.
M01's implementation gate is satisfied; physical-GPU acceptance remains open.

## M02 — Ghostty terminal engine

- [x] Add GTK-independent Swift terminal state/render-snapshot/input adapter.
- [x] Preserve the existing host's PTY ownership and identities (engine owns none).
- [x] Expose ordered PTY replies and directory changes for M04 host integration.
- [x] Use synchronous native ingestion before exit delivery (no marker in this engine).
- [x] Swift tests: split sequences, Unicode, alternate screen, replies, resize,
      final output and disposal. Commit after verification.

M02 library checkpoint: 17 native Swift engine tests pass; baseline Core suite
passes 260 tests with its opt-in real-workspace SSH test skipped (261 total).
Snapshots own their buffers and preserve synchronized frames; a deliberate
mutation removing the hold guard caused the expected two failing assertions,
then the restored implementation passed. VTE's current frontend and drain
marker remain unchanged until M04/M05; no live Ghostty PTY is claimed yet.

## M03 — Portable Skia renderer

- [x] Render styled/shaped text, fallback fonts, wide/combining characters,
      emoji, backgrounds, cursor and selection.
- [x] Implement metrics, clipping, scrolling, dirty updates, bounded caches and
      scale-aware resource recreation. Share GPU/raster drawing logic.
- [x] Offscreen tests: long graphemes, fallback fonts, selection geometry and
      fractional scaling. Commit after verification.

M03 checkpoint: 18 native engine tests and eight offscreen renderer tests pass.
The same Swift terminal drawing also passes framebuffer background/glyph pixel
checks, resize and window recreation through GtkGLArea using llvmpipe. Shaping
joins neighboring cells and anchors HarfBuzz clusters to terminal columns;
unchanged rows reuse bounded shaped layouts. Painting still clears/redraws the
surface; partial framebuffer damage is not assumed across GTK frames.
Both native foreground/background defaults are initialized before independent
OSC overrides, following the pinned Ghostty RenderState source contract.

## M04 — Linux interaction

- [ ] GTK surface/input adapter: keyboard/mouse/focus encoding, IME, selection,
      scrolling, paste, existing shortcuts and accessibility.
- [ ] Preserve Herdr OSC 52 copy and text/image clipboard flows. Keep current
      focused/active-pane clipboard restrictions and denial of remote reads.
- [ ] Preserve theming, text inspection and directory-based editor actions.
- [ ] Test actual interaction and commit after verification.

## M05 — Acceptance, packaging and cutover

- [ ] Keep VTE default until previous milestones pass; development opt-in only.
- [ ] Run affected acceptance tests and compare like-for-like VTE performance.
- [ ] Check GPU/software paths, context loss, reconnect, hidden/multiple panes
      and shutdown, real wc-1, Herdr clipboard, hooks/notifications and editors.
- [ ] Update runtime assembly, build/install tooling, licenses and architecture.
- [ ] Verify relocated bundles; then switch default and remove VTE dependencies.
- [ ] Verify real hardware-GPU rendering on a capable host before final cutover.
- [ ] Commit verified cutover. Release builds/install changes need approval.

## Verification and deferrals

Use Swift tests for logic/rendering, existing Python orchestration only for
build/package/process/UI checks. Use private displays for automation and host
checks for GPU, desktop clipboard and IME. Defer inline Kitty image rendering
(not existing image-paste upload), macOS renderer migration, Windows, Ubuntu
24.04 acceptance and .deb production.
