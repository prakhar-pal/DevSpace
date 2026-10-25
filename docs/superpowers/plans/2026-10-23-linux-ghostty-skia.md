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

- [x] GTK surface/input adapter: keyboard/mouse/focus encoding, IME, selection,
      scrolling, paste, existing shortcuts and accessibility.
- [x] Preserve Herdr OSC 52 copy and text/image clipboard flows. Keep current
      focused/active-pane clipboard restrictions and denial of remote reads.
- [x] Preserve theming, text inspection and directory-based editor actions.
- [x] Test actual interaction and commit after verification (`5428ad7`).

M04 implementation checkpoint: development-only opt-in SwiftPM frontend builds.
Private GTK tests deliver real keyboard events through IM commit, encode TUI
arrows/wheel and bracketed paste, select by drag/word, resize, render via raster
and OpenGL and dispose. Swift app tests use real PTYs and verify final output
before exit, generation/pane IDs, directory events, typing, resize and focused
OSC 52 writes with a hidden-pane denial case. The existing image upload path is
shared unchanged. VTE remains the default; the experimental binary refuses the
production channel. Full screen-reader text/caret navigation, actual IBus/Fcitx
composition, non-US key mapping, real Herdr and packaged artifacts remain M05
acceptance gates; basic accessibility label/visible-text metadata is present.

## M05 — Acceptance, packaging and cutover

- [x] Keep VTE default until previous milestones pass; development opt-in only.
- [x] Run affected acceptance tests and compare like-for-like VTE software performance.
- [x] Check private-display raster/software-OpenGL and injected context-error fallback.
- [x] Verify hidden/multiple PTYs and independent shutdown.
- [x] Verify real wc-1 shell readiness, reconnect/generation replacement and disconnect.
- [x] Verify isolated local/remote Herdr mouse-copy and OSC52 frontend ownership.
- [x] Verify real Vim alternate-screen input and shell restoration.
- [x] Verify image clipboard identity/private PNG handoff and real remote upload/cleanup.
- [x] Verify hook preservation, reverse notification and editor-URL routing on wc-1.
- [x] Cross-app desktop clipboard acceptance (user-confirmed on the experimental build).
- [x] Expose native GTK accessible text/caret/selection and verify AT-SPI queries.
- [x] Verify a non-US layout, AltGr and dead-key composition on private X11.
- [ ] Complete actual IBus/Fcitx composition and manual assistive-technology checks.
- [x] Add development runtime assembly, pinned native notices and architecture ADR.
- [x] Verify relocated experimental development bundles.
- [x] Select pinned static native libraries/system text+GL dependencies and update package inventory.
- [x] Switch the Linux default to the wrapper, removing VTE from the default graph.
      The user explicitly requested the switch with manual input/accessibility gaps recorded.
      An explicit VTE fallback remains available; its dependencies are conditional.
- [x] Verify accelerated GPU rendering on the actual host before final cutover.
- [x] Commit verified default selection with explicit fallback retained.
- [ ] Produce/install production artifacts when requested with release approval.

M05 acceptance checkpoint: real wc-1 was started with existing authorization.
The actual GTK controller/backend/Swift PTY/Ghostty path passes a synthetic SSH
shell round trip and orderly disconnect on a private display. Production was
kept running. A fresh branch review identified six implemented-path defects;
regressions cover GL initialization fallback, input returning to the live
prompt, keypad identity, mixed-script shaping, initial size replies and false
Kitty-image capability advertisement. All six fixes passed their regression
checks: 22 engine tests, nine renderer tests, private GTK raster/OpenGL/error
fallback tests, four frontend tests including actual wc-1, and the default VTE
source typecheck. The corrected keypad test was also proven with a deliberate
old-mapping mutation (failed), then restored and passed. Underline variants/colors and OSC12 cursor color remain
minor renderer gaps. This checkpoint does not claim packaged, real Herdr,
desktop IME/screen-reader, performance or hardware acceptance.

2026-10-24 checkpoint: the private GTK harness also passes actual
Ctrl+Shift+U Unicode preedit/commit using GtkIMContextSimple. Composition on
Return inserts the composed character once. This narrows the IME uncertainty
but does not establish IBus/Fcitx or screen-reader parity. A fresh experimental
debug app was opened alongside the installed production app.

M05 development packaging checkpoint: the migration-only bundle target (now
superseded by `make build-dev`) builds a
separate development bundle with the global Swift runtime and 20 pinned native
notice files. Source revisions and notice checksums are validated; native
archive hashes are recorded. 21 packaging/inventory tests and the relocated
bundle loader/backend handshake check pass. No production build/install or .deb
was performed. ADR 0003 records the opt-in architecture and remaining gates.

The private-display comparison uses the actual VTE and Ghostty/Skia raster
widgets, identical 80×24 grids and monospace-14px requests, 280,015 bytes of
styled Unicode, one warmup and nine samples. Parse-to-next-frame medians were
33.6 ms (VTE) and 49.2 ms (Ghostty); samples ranged 31.6–63.4 ms. This is a debug
software comparison, not hardware-GPU or sustained SSH throughput acceptance.
The isolated local Herdr mouse-copy test and hidden/sibling PTY shutdown test
pass. Remote Herdr mouse selection also passes through an isolated wc-1 SSH
connection and OSC52 into the frontend-owned private-display clipboard. The
fixture uses the existing Linux SSH supervisor: directly spawning OpenSSH can
block Foundation child-exit tracking when SSH closes its inherited descriptor.
The final affected frontend run passed six tests with zero failures; the
separate backend workspace test was skipped because its opt-in executable was
not provided (its earlier M04 run passed). Actual desktop cross-app clipboard,
IME/screen-reader and hardware checks remain open.

The explicit desktop synthetic-marker test passes in both directions between
the experimental terminal and a separate `xclip` process with `GDK_BACKEND=x11`.
The same automated attempt using GTK's default backend failed; native Wayland
clipboard automation remains unresolved. The user subsequently confirmed that
cross-app clipboard works on the experimental build; this satisfies manual
desktop clipboard acceptance, not the failed automated fixture. The desktop accessibility bus is also
unavailable in this session; no screen-reader acceptance is claimed.

Further M05 software acceptance: nine affected frontend tests pass, with only
the separately opted-in desktop clipboard test skipped on the private display.
These include a real Vim alternate-screen session, private PNG image-paste
handoff with pane/generation identity, and a real wc-1 reconnect that disposes
the old pane and restores shell I/O in a fresh generation. The existing host
integration check passes helper delivery, Claude settings/hook preservation,
notification routing, editor URL routing, remote image bytes and cleanup. An
earlier run timed out awaiting a notification; no production fix is claimed
from the successful retry, and the helper result is now asserted explicitly.

## Verification and deferrals

2026-10-26 default selection: the user requested libghostty wrapper as the
Linux default. Normal SwiftPM/Make development and release assembly now select
the Swift libghostty-vt/Skia graph, omit VTE unless explicitly requested, and
preserve pinned native notices. The production-channel migration refusal is
removed. No installed production app is replaced and no production build is
performed by this change. The existing hosted Linux CI job explicitly tests
the VTE fallback until it provisions the pinned native artifacts; default
renderer compilation/runtime is verified locally, not claimed as hosted CI
coverage. macOS remains unchanged.

2026-10-26 hardware checkpoint: the actual desktop now reports accelerated
VirGL backed by Mesa Intel UHD Graphics 630, OpenGL 4.3 (Mesa 26.0.8). Strict
Wayland terminal-renderer acceptance passes glyph/pixel readback, resize, two
widget lifecycles and Skia context disposal. A separate actual GTK terminal
widget check passes automatic OpenGL selection with no software override,
resize with frame acknowledgement, no GL errors and widget recreation. This
clears the current-host hardware-rendering gate through a hardware-backed
virtual GPU; it is not a direct GPU passthrough or hardware performance claim.
No default renderer switch, production build or install was performed.

Accessibility continuation: the GTK host now implements `GtkAccessibleText`
in Swift on a native terminal-role widget. Queries expose owned visible text,
Unicode-scalar caret offsets, separate rectangular-selection ranges and cell
geometry. Concealed cells remain concealed. Tests cover snapshot lifetime after
view disposal, and an isolated real AT-SPI bus reads Unicode text, caret and
selection through the public D-Bus interface. This is protocol verification,
not a claim of manual spoken screen-reader acceptance. German XKB shifted
punctuation, AltGr and dead-key composition pass with actual private-display
key events. The installed IBus daemon could not establish its isolated bus;
IBus/Fcitx composition remains unverified. The affected frontend run passed ten
tests with the separately opted-in physical clipboard check skipped; desktop
clipboard acceptance is supplied by the user's confirmation above.
After the accessibility change, the same private software benchmark measured
32.9 ms Ghostty/Skia and 33.6 ms VTE medians. This single debug benchmark run
does not establish a general speedup or hardware-GPU performance.

Use Swift tests for logic/rendering, existing Python orchestration only for
build/package/process/UI checks. Use private displays for automation and host
checks for GPU, desktop clipboard and IME. Defer inline Kitty image rendering
(not existing image-paste upload), macOS renderer migration, Windows, Ubuntu
24.04 acceptance and .deb production.
