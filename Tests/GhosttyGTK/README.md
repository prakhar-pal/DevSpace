# GTK terminal adapter acceptance

Build the native dependencies and run `make linux-test-skia` first. Then use
the private-display commands in `docs/linux-development.md`. The Swift harness
reuses the existing XTEST safety helper, which requires
`DEVSPACE_PRIVATE_KEY_TEST=1`; never set it for the user's desktop.

The harness exercises actual GTK key events and IM commit (ordinary typing and
Control-C and Unicode preedit/commit), native application-cursor keys and bracketed paste, pointer/word
selection, wheel reports to TUIs, resize, basic accessibility metadata and
idempotent disposal. It can use raster or the real adapter's OpenGL path.
The harness selects GtkIMContextSimple explicitly for reproducible Unicode
composition; it does not establish IBus/Fcitx behavior on the user's desktop.
The app's `TerminalPaneTests` exercise actual shared Swift PTYs and private
clipboard writes. They do not establish desktop clipboard, full IME/screen
reader support, or hardware acceleration.

The hardware-only fixture opens its own desktop windows and never uses XTEST,
the clipboard or a DevPod. Run it without the software override:

```sh
env -u DEVSPACE_GHOSTTY_ALLOW_SOFTWARE_GL DEVSPACE_REQUIRE_HARDWARE=1 \
  GDK_BACKEND=wayland bash scripts/test-ghostty-gtk.sh --hardware-gpu
```

It checks the actual adapter's automatic OpenGL selection, resized-frame
acknowledgement, GL errors and two widget lifecycles. Combine it with strict
portable terminal-renderer pixel readback:

```sh
DEVSPACE_REQUIRE_HARDWARE=1 GDK_BACKEND=wayland \
  bash scripts/check-skia-runtime.sh --terminal-gpu
```

Both passed on 2026-10-26 with hardware-backed VirGL/Intel UHD Graphics 630.
These are rendering-correctness checks, not a hardware performance benchmark.
