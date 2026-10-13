# Linux development (in progress)

Linux is a small, native DevSpace GTK application. GTK4 owns the
window/sidebar, and VTE is only the terminal renderer/input widget. DevSpace
application, backend protocol, and lifecycle logic remain Swift. The macOS
SwiftUI/libghostty app is unchanged. See the
[Linux UI design](superpowers/specs/2026-10-13-devspace-owned-linux-ui-design.md)
and [implementation plan](superpowers/plans/2026-10-13-devspace-owned-linux-ui.md).

## Dependencies

On Ubuntu install GTK4/VTE headers and the native build tools:

```sh
sudo apt-get install -y build-essential pkg-config libgtk-4-dev \
  libvte-2.91-gtk4-dev
```

The app links against the system GTK4 and VTE GTK4 runtime libraries. It also
uses OpenSSH, `setsid` from `util-linux`, and the user's `devpod` CLI. The
development bundle carries Swift runtime libraries, not GTK/VTE or DevPod.

## Build and launch

```sh
make linux-build-dev
make linux-bundle-dev
make linux-run
```

The SwiftPM products are `DevSpaceLinuxApp` and `DevSpaceLinuxBackend` under
`build/linux-dev/bin`. `build/linux-dev-bundle` is relocatable, including in
paths with spaces or Unicode. Its `bin/devspace-dev` launcher selects the
development channel and app identity, locates the sibling backend/runtime, and
prepares PATH before starting the UI. It does not kill another DevSpace
instance. Bundle replacement is limited to a generated bundle for the same
channel and retains rollback/recovery behavior.

For direct toolchain selection:

```sh
make linux-build-dev SWIFT=/path/to/swift
make linux-test-protocol SWIFTC=/path/to/swiftc
```

The current Ubuntu 26.04 host uses the globally installed Swift.org 6.4.1
toolchain (`swift`/`swiftc` on `PATH`), including its host-compatible SwiftPM.
No compiler is installed inside the repository. Verify the selected compiler
with `swift --version`; if multiple toolchains are installed, pass the desired
global executable through `SWIFT=` and `SWIFTC=`. Ubuntu 24.04 testing remains
deferred by user direction.

## Ownership and behavior

`DevSpaceLinuxBackend` continues to own DevPod commands, workspace state and
actions, SSH masters, Claude hooks, notification routing, image uploads, and
the private versioned protocol. The Swift GTK layer presents snapshots and
maps validated terminal effects to VTE. VTE owns the terminal child/PTY; bytes
are never sent through the backend control pipe. Terminal identities include
workspace, pane, and connection generation so delayed events cannot target a
replacement pane. Closing a terminal does not stop its workspace.

The first window is empty; it does not launch a local shell. Development and
production have distinct application IDs. Linux feature parity with macOS
libghostty remains a later effort; tabs/splits and a Ghostty-style settings
surface are out of scope.

Text selection/paste use VTE/GTK. The backend retains authenticated Claude
notification/helper, `ded`/Zed, and image-upload behavior. These integrations
are not considered host-accepted until their frontend event paths are verified;
tests must not replace the real desktop clipboard or mutate a real workspace.

Hook installation is owned by the backend. It preserves unrelated Claude
settings/hooks and publishes validated settings atomically. Development and
production keep separate layout, application identity, and SSH state while
sharing the owner-only notification token. The development helper is
`~/.devspace-notify`; it is not installed in production.

## Tests

```sh
make linux-test-protocol
make linux-test-gtk
make linux-test-core
make linux-test
```

The GTK test target uses private Xvfb and controlled backend/local-shell
fixtures. The Python suite covers compiler orchestration, bundle assembly and
rollback, frontend protocol behavior, the Swift backend with a controlled
DevPod peer, and source preparation remnants where still applicable. Native
bundle/runtime tests skip if their artifacts have not been built; skips are not
build evidence. The SwiftPM Core suite runs with the global host-compatible
Swift toolchain.

Channel coexistence can be checked with isolated X11 and D-Bus sessions after
building the development bundle:

```sh
env -u WAYLAND_DISPLAY GDK_BACKEND=x11 xvfb-run -a dbus-run-session -- \
  env DEVSPACE_TEST_ISOLATED_GUI=1 \
  DEVSPACE_TEST_FRONTEND_PREFIX="$PWD/build/linux-dev-bundle" \
  python3 -B -m unittest Tests.Linux.test_channel_identity -v
```

This launches each channel against a temporary protocol peer, verifies one
backend per channel, and cleans up its app/peer processes. Do not run it on the
user's ordinary session bus.

The host SSH integration is opt-in and opens temporary shells only. Use a
workspace expressly approved for temporary terminal checks; the test must not
start, stop, delete, or edit it. Hook installation and real notification,
clipboard, or image-upload acceptance require separate authorization. Manual
desktop checks still include visual layout, IME, copy/paste behavior, banner
clicks, app restart/recovery, and a native GTK/VTE host run. None should be
inferred from Xvfb or controlled backend tests.
