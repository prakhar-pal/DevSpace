# Swift libghostty-vt engine tests

Run `make linux-test-ghostty` after building the pinned native library described
in [the interoperability checks](../SkiaInterop/README.md). The script compiles
the production Swift engine with testing enabled and runs native XCTest against
the actual static library. It does not use Python or mock terminal parsing.

The engine deliberately owns no PTY, SSH process, DevPod identity or GTK widget.
Hosts feed child bytes into `receive`, then deliver returned `writePTY` events
to their existing ordered PTY input queue. `resize` can also return replies
(e.g. in-band size reports), so callers must process those events too. `finish`
preserves final output and emits an exit exactly once; `close` is idempotent.

Render snapshots contain owned Swift strings and values, including wide-cell,
style and selection information. A renderer acknowledges a successfully painted
revision; stale acknowledgements cannot erase subsequently received output.
Synchronized-output holds capture the exact preceding frame, expire after one
second, and end on process exit. Tests use an injected monotonic clock, not
sleep-based timing.

Coverage includes split ANSI/UTF-8, long graphemes, true color, alternate screen,
directory validation, terminal replies, resize/reflow, final output, disposal,
scrollback/selection, keyboard modes and Kitty release events, mouse geometry,
focus reports and native paste safety/bracketing.

The root SwiftPM app still uses VTE. This standalone module is intentionally
not added to its default dependency graph before the opt-in UI integration.
Tests do not establish actual desktop input, clipboard, IME or notification
behavior for the Ghostty frontend; those are later acceptance checks.
