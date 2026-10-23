# Experimental GTK adapter acceptance

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
