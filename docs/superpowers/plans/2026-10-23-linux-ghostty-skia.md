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
- [ ] Draw using a GPU surface hosted by GTK; verify actual host hardware.
- [x] Exercise the same drawing through a raster surface, resize and recreation.
- [ ] Commit the independently verified milestone.

Do not proceed to engine integration if direct imports, ownership or
presentation cannot work reliably. Revisit the design rather than introducing
a bridge silently. Do not claim software OpenGL proves hardware acceleration.

2026-10-23 checkpoint: global Swift 6.4.1/Zig 0.17.0 built the pinned native
dependencies. Swift ABI/ANSI tests, actual Skia raster pixel/font/ownership
tests, and GTK OpenGL pixel/resize/widget-recreation tests pass. Both private
X11 and actual Wayland expose llvmpipe; strict host hardware acceptance exits
77 (unavailable), not success. M01 remains incomplete. A decision to move this
external hardware check to the cutover gate is pending user direction.

## M02 — Ghostty terminal engine

- [ ] Add GTK-independent Swift terminal state/render-snapshot/input adapter.
- [ ] Preserve Swift PTY ownership, bounded delivery and launch identities.
- [ ] Route terminal replies back to the PTY and preserve directory reporting.
- [ ] Replace the VTE drain marker with ordered ingestion before exit delivery.
- [ ] Swift tests: split sequences, Unicode, alternate screen, replies, resize,
      final output and disposal. Commit after verification.

## M03 — Portable Skia renderer

- [ ] Render styled/shaped text, fallback fonts, wide/combining characters,
      emoji, backgrounds, cursor and selection.
- [ ] Implement metrics, clipping, scrolling, dirty updates, bounded caches and
      scale-aware resource recreation. Share GPU/raster drawing logic.
- [ ] Offscreen tests: long graphemes, fallback fonts, selection geometry and
      fractional scaling. Commit after verification.

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
- [ ] Commit verified cutover. Release builds/install changes need approval.

## Verification and deferrals

Use Swift tests for logic/rendering, existing Python orchestration only for
build/package/process/UI checks. Use private displays for automation and host
checks for GPU, desktop clipboard and IME. Defer inline Kitty image rendering
(not existing image-paste upload), macOS renderer migration, Windows, Ubuntu
24.04 acceptance and .deb production.
