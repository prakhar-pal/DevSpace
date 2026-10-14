# Linux development (in progress)

Linux is a small, native DevSpace GTK application. GTK4 owns the
window/sidebar, and VTE is only the terminal renderer/input widget. DevSpace
application, backend protocol, and lifecycle logic remain Swift. The macOS
SwiftUI/libghostty app is unchanged. See the
[Linux UI design](superpowers/specs/2026-10-13-devspace-owned-linux-ui-design.md)
and [implementation plan](superpowers/plans/2026-10-13-devspace-owned-linux-ui.md).
The architecture choice is recorded in [ADR 0002](adr/0002-linux-swift-gtk-vte.md).

## Dependencies

On Ubuntu install GTK4/VTE headers and the native build tools:

```sh
sudo apt-get install -y build-essential dpkg-dev pkg-config libgtk-4-dev \
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
channel and retains rollback/recovery behavior. Before `make linux-run`, verify
no `DevSpaceDev` or `DevSpaceDevBackend` process is using that bundle; when one
is active, stage to a separate `LINUX_DEV_BUNDLE` path instead.

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

## Ubuntu package

The production package build uses the release SwiftPM configuration, embeds the
Swift runtime and its license notice, and keeps GTK/VTE as system dependencies.
`dpkg-shlibdeps` derives versioned system-library dependencies from both app
executables and every bundled Swift library, including Foundation's XML and
networking libraries. Packages built on Ubuntu 26.04 declare that host ABI;
they are not Ubuntu 24.04 packages.
It installs the app under `/usr/lib/devspace`, the `devspace` launcher under
`/usr/bin`, and desktop metadata/icon under `/usr/share`. DevPod remains a
user-installed executable.

The repository currently has no project copyright/license manifest. Supply a
Debian-format copyright file and maintainer identity before building a package:
The manifest must cover the project and third-party code in the bundled runtime.

```sh
make linux-package \
  LINUX_PACKAGE_COPYRIGHT=/path/to/debian/copyright \
  LINUX_PACKAGE_MAINTAINER="Name <email>"
```

The result is `build/devspace_<version>_<architecture>.deb`. This target builds
production artifacts; get confirmation before running it. The package has not
yet been tested on a clean machine or Ubuntu 24.04.

After producing and reviewing the package on its target Ubuntu version, install
with `sudo apt install ./build/devspace_<version>_<architecture>.deb` so APT
resolves the declared system dependencies. Launch it from the desktop menu or
with `devspace`. The package requires DevPod to be installed separately. The
builder preserves an existing output file; use `LINUX_PACKAGE_OUTPUT=` for a
different artifact path when rebuilding.

## Continuous integration

The Linux job in `.github/workflows/ci.yml` uses the official
[`swift:6.4.1-resolute` image](https://www.swift.org/install/linux/ubuntu/26_04/)
on the [Ubuntu 26.04 runner](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2604-Readme.md).
It installs GTK/VTE headers and test tools, runs Core XCTest, the Swift protocol
client, Linux integration and synthetic package assembly checks, then assembles a
development bundle. GUI checks use private Xvfb displays with accessibility
disabled for test processes. Real workspaces, physical clipboard/IME, and
notification banner clicks remain opt-in host acceptance.

The workflow definition is locally validated; its GitHub execution is pending
publication. It does not produce a production `.deb` while project/runtime
copyright coverage and maintainer metadata are missing. The existing macOS
job remains in the same workflow.

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
# Stage debug binaries for both test identities; this is not a release build.
test_prefix=$(mktemp -d "$PWD/.tmp/channel-debug.XXXXXX")
cp -a build/linux-dev-bundle/bin build/linux-dev-bundle/lib "$test_prefix/"
cp "$test_prefix/bin/DevSpaceDev" "$test_prefix/bin/DevSpace"
env -u WAYLAND_DISPLAY GDK_BACKEND=x11 xvfb-run -a dbus-run-session -- \
  env GTK_A11Y=none DEVSPACE_TEST_ISOLATED_GUI=1 \
  DEVSPACE_TEST_FRONTEND_PREFIX="$test_prefix" \
  python3 -B -m unittest Tests.Linux.test_channel_identity -v
rm -r -- "$test_prefix"
```

This launches each channel against a temporary protocol peer, verifies one
backend per channel, and cleans up its app/peer processes. Do not run it on the
user's ordinary session bus.
Both test executable names must exist; pointing this check at a normal
development-only bundle skips it rather than proving coexistence. The staged
executables are the same debug build; this verifies runtime channel isolation,
not production package assembly or release compilation.

The host SSH integration is opt-in and opens temporary shells only. Use a
workspace expressly approved for temporary terminal checks; the test must not
start, stop, delete, or edit it. Hook installation and real notification,
clipboard, or image-upload acceptance require separate authorization. Manual
desktop checks still include visual layout, IME, copy/paste behavior, banner
clicks, app restart/recovery, and a native GTK/VTE host run. None should be
inferred from Xvfb or controlled backend tests.

For an authorized workspace check on the host Wayland display, run:

```sh
DEVSPACE_HOST_UI_WORKSPACE=wc-1 DEVSPACE_TEST_CHANNEL=production \
DEVSPACE_HOST_UI_DISPLAY=wayland \
DEVSPACE_HOST_UI_SCREENSHOT="$PWD/.tmp/linux-migration/host-vte.png" \
dbus-run-session -- python3 -B -m unittest \
  Tests.Linux.test_linux_workspace_window.LinuxWorkspaceWindowTests.test_real_workspace_shell_round_trips_through_the_vte_widget -v
```

Use an unoccupied test channel and create the screenshot's parent directory
first. Omit the screenshot variable to disable capture. The test captures only
its own GTK window, not the desktop; it sends shell markers and closes its
temporary terminal, requests reconnect, and checks I/O in a distinct replacement
pane before closing it without stopping the workspace. This does not verify
app restart, repeated Open-button reuse, physical clipboard, input methods, or
banner interaction.
