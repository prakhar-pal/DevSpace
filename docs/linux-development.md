# Linux development (in progress)

Linux is a small, native DevSpace GTK application. GTK4 owns the
window/sidebar, and VTE is only the terminal renderer/input widget. DevSpace
application, backend protocol, and lifecycle logic remain Swift. macOS retains
its SwiftUI/libghostty frontend. See the
[Linux UI design](superpowers/specs/2026-10-13-devspace-owned-linux-ui-design.md)
and [implementation plan](superpowers/plans/2026-10-13-devspace-owned-linux-ui.md).
The architecture choice is recorded in [ADR 0002](adr/0002-linux-swift-gtk-vte.md).
The [remaining-feature plan](superpowers/plans/2026-10-15-remaining-linux-features.md)
records milestone implementation and outstanding host/release acceptance.

The experimental `feat/linux-libghostty-migration` branch adds a portable Swift
libghostty-vt engine and Swift/Skia acceptance fixtures. VTE remains the default
application renderer until the opt-in frontend and acceptance gates are complete.
After building the pinned native dependencies, run `make linux-test-ghostty` for
the engine's native Swift XCTest suite; see [engine tests](../Tests/GhosttyVT/README.md)
and [renderer dependency checks](../Tests/SkiaInterop/README.md).
`make linux-test-skia` additionally verifies the portable Swift/Skia renderer's
pixels, shaping, fallback fonts, cursors, selection and scaling; see
[renderer tests](../Tests/SkiaRenderer/README.md). Hardware-GPU acceptance is
deferred to a capable host and remains required before default cutover.

## Dependencies

On Ubuntu install GTK4/VTE headers and the native build tools:

```sh
sudo apt-get install -y build-essential dpkg-dev pkg-config libgtk-4-dev \
  libvte-2.91-gtk4-dev
```

The app links against the system GTK4 and VTE GTK4 runtime libraries. It also
uses OpenSSH, `setsid` from `util-linux`, and the user's `devpod` CLI. The
development bundle carries Swift runtime libraries, not GTK/VTE or DevPod.

For the test suites, also install the shell and private-display tools:

```sh
sudo apt-get install -y python3 zsh curl xvfb xauth dbus openssh-client util-linux
```

## Build and launch

```sh
make linux-build-dev
make linux-bundle-dev
make linux-run
```

For a production bundle without installing or launching it:

```sh
make build
# Launch later, if desired:
build/linux-production/bin/devspace
```

`make build` (also `make linux-bundle`) compiles both release products and
assembles `build/linux-production`. Override `LINUX_RELEASE_BUNDLE` to choose
another output path. Repeated builds safely replace only a generated production
bundle; unrelated files and development bundles are refused. This does not
create a `.deb` or update your installed application. macOS `make build` still
assembles `DevSpace.app`.

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

### Install directly from source (no .deb, no sudo)

```sh
make install
```

On Linux this builds the release Swift frontend/backend, assembles a production
bundle, then installs it under `~/.local/lib/devspace`. It creates the
`~/.local/bin/devspace` launcher and desktop-menu/icon entries under
`~/.local/share`. Ensure `~/.local/bin` is on PATH, or launch with
`~/.local/bin/devspace`. No existing app is stopped or launched automatically.
The macOS `make install` behavior remains unchanged.

The running-app check skips inaccessible unrelated processes such as
`systemd --user`, but still refuses a running destination or an inaccessible
process named `DevSpace`/`DevSpaceBackend` whose safety cannot be verified.

To install an already-built production bundle without recompiling:

```sh
make install LINUX_INSTALL_BUNDLE=build/linux-production-20261021-05d23d7
```

`LINUX_INSTALL_PREFIX=/absolute/path` overrides `~/.local`. A custom prefix's
`bin` and `share` directories must be on PATH and XDG_DATA_DIRS respectively
for shell/menu discovery; the installed desktop entry uses absolute launcher
and icon paths. Builds still use the global Swift toolchain.

Quit the installed frontend and backend before updating: installation refuses
to replace their executable files while either is running. It also refuses
unrecognized bundles, unrelated launcher/menu/icon entries, and parent symlinks
escaping the prefix. Updates stage a copy before swapping; failures restore
the old bundle or report its retained recovery location if restoration fails.
This does not replace a Debian-managed installation or modify a separate
production bundle running from another directory. Do not run concurrent installs
to the same prefix, or launch the destination during an update.

Installer/assembly regression checks (temporary prefixes only):

```sh
python3 -B -m unittest Tests.Linux.test_install_linux Tests.Linux.test_assemble_linux -v
```

### Debian packaging

The production package build uses the release SwiftPM configuration, embeds the
Swift runtime and its license notice, and keeps GTK/VTE as system dependencies.
`dpkg-shlibdeps` derives versioned system-library dependencies from both app
executables and every bundled Swift library, including Foundation's XML and
networking libraries. Packages built on Ubuntu 26.04 declare that host ABI;
they are not Ubuntu 24.04 packages.
It installs the app under `/usr/lib/devspace`, the `devspace` launcher under
`/usr/bin`, and desktop metadata/icon under `/usr/share`. DevPod remains a
user-installed executable.

DevSpace-owned source is GPL-3.0-or-later (see the root LICENSE and README).
Bundles include that license and the selected Swift toolchain's license under
`share/doc/devspace`; pass `LINUX_SWIFT_LICENSE=` for a nonstandard toolchain
layout. `LICENSES/ICU-76.1.txt` supplies the full upstream ICU notice, including
data/third-party notices, for the verified Swift.org 6.4.1 runtime (ICU 76.1).
Assembly and Debian packaging reject ICU-containing runtimes without a notice.
With another toolchain, verify its ICU version and set `LINUX_ICU_LICENSE=` to
the matching complete notice; direct assembly uses `--icu-license`.
`packaging/debian/copyright` records the project, creator-confirmed custom
GPL-3.0-or-later artwork, and third-party code in the verified bundled runtime.
The approved maintainer is `prakhar-pal <prakharpalpfdr+github@gmail.com>`.

```sh
make linux-package \
  LINUX_PACKAGE_COPYRIGHT=packaging/debian/copyright \
  LINUX_PACKAGE_MAINTAINER="prakhar-pal <prakharpalpfdr+github@gmail.com>"
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

## Diagnostics

Debug development builds append diagnostics to
`${XDG_STATE_HOME:-$HOME/.local/state}/devspace-dev/devspace.log`.
The directory is private (0700) and the file is owner-only (0600); unsafe
directories and symlink log files are rejected. The app and backend share this
append-only log. Production channels and release binaries do not write it.
Logging never uses the backend's protocol stdout.

## Continuous integration

The Linux job in `.github/workflows/ci.yml` uses the official
[`swift:6.4.1-resolute` image](https://www.swift.org/install/linux/ubuntu/26_04/)
on the [Ubuntu 26.04 runner](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2604-Readme.md).
It installs GTK/VTE headers and test tools (including Bash and Zsh), runs Core XCTest, the Swift protocol
client, Linux integration and synthetic package assembly checks, then assembles a
development bundle. GUI checks use private Xvfb displays with accessibility
disabled for test processes. Real workspaces, physical clipboard/IME, and
notification banner clicks remain opt-in host acceptance.

The permission-denial Core test requires an unprivileged user and explicitly
skips under root, which can bypass Unix file read permissions. Other hook
preservation tests still run in the CI container.

The workflow verifies synthetic package assembly rather than publishing a
production `.deb`. The real package uses the copyright manifest and approved
maintainer above and is built separately with release approval. The existing
macOS job remains in the same workflow.

## Ownership and behavior

`DevSpaceLinuxBackend` continues to own DevPod commands, workspace state and
actions, SSH masters, Claude hooks, notification routing, image uploads, and
the private versioned protocol. The Swift GTK layer presents snapshots and
maps validated terminal effects to VTE. Shared Swift `PTYSession` owns the
terminal child/PTY, forwarding output to VTE and VTE-encoded input to the child;
bytes are never sent through the backend control pipe. Terminal identities include
workspace, pane, and connection generation so delayed events cannot target a
replacement pane. Closing a terminal does not stop its workspace.

Remote OSC52 clipboard writes (used by Herdr over SSH) are supported only from
the mapped/focused terminal in the active window. Writes are strict UTF-8/base64,
limited to 64 KiB of decoded text; clipboard reads, primary-selection writes,
malformed/oversized sequences and nested control-string requests are rejected.
This complements native VTE text-selection copy, rather than replacing it.

For authorized DevPod clipboard acceptance on a private Xvfb display:

```sh
DEVSPACE_HOST_UI_WORKSPACE=wc-1 dbus-run-session -- python3 -B -m unittest \
  Tests.Linux.test_linux_workspace_window.LinuxWorkspaceWindowTests.test_real_workspace_clipboard_roundtrip_on_private_display -v
```

The Swift runner uses the actual DevSpace terminal pane and a temporary SSH
session, with no production master reuse. It verifies remote OSC52 writes,
native copying of remote terminal text, and paste into both the source terminal
and a distinct second terminal's non-executing remote input loop, including
Unicode/multiline text. It does not start the workspace,
change project files, read/replace the physical clipboard, or prove Herdr's own
mouse selection or external-desktop paste. Those remain separate acceptance
checks. Python only builds/launches the existing Swift assertion harness.

Physical-desktop acceptance is a separate, explicitly authorized opt-in:

```sh
DEVSPACE_TEST_DESKTOP_CLIPBOARD=1 DEVSPACE_HOST_UI_WORKSPACE=wc-1 \
  dbus-run-session -- python3 -B -m unittest \
  Tests.Linux.test_linux_workspace_window.LinuxWorkspaceWindowTests.test_real_desktop_clipboard_exchange_with_workspace -v
```

This replaces the desktop clipboard with synthetic text. Focus the temporary
"DevSpace Clipboard Acceptance" window and click its Start button. The check
uses an external `xclip` process as well as the real remote input loop. It
requires desktop focus/input and, on Wayland, the XWayland clipboard bridge;
a private-display pass does not satisfy it. As of 2026-10-21 this host check
remains unresolved (external read failure, then unsuccessful focus/input runs).
After testing the development build at `6f9fe26`, the user confirmed on
2026-10-21 that cross-app copy/paste works, in response to the Herdr-to-desktop
and paste-back acceptance request. This is manual desktop acceptance, not a
passing result for the automated xclip harness above.

The sidebar lists DevPods as compact selectable rows without a heading, with
a Stop icon for running workspaces and New/Guide at the bottom. Rows scroll
vertically. The sidebar uses a fixed 367-pixel outer width, including its
16-pixel side margins, matching the approved screenshot. Workspace scrollers
do not propagate their content's natural width. Names wrap with a 24-character
natural-width cap; status and notification messages wrap with a 36-character cap.
The single-terminal view has no workspace title or Close bar.
Rows show a
green dot for running DevPods and a grey dot for stopped
or unresolved DevPods; selection is indicated by the row highlight. Status
refresh runs automatically. Running DevPods connect on startup
and retain their terminals and notification hooks in the background; the right
pane displays only the selected workspace's terminal. Clicking a sidebar row
switches the displayed terminal without restarting its shell. The first running
workspace is selected automatically. A stopped workspace offers Start; a
disconnected running workspace offers Connect. Start, Stop and provisioning
show live output. Right-click a row for Disconnect, Reload SSH Session, New
Terminal, Set friendly name, Move Up/Down, Hide/Show, Open in Zed or Recreate,
with session/busy-state eligibility. Hiding never disconnects or stops a pod;
the collapsed Hidden section keeps its selected row reachable.

New accepts a repository and optional DevPod ID; Recreate requires confirmation
before replacing a container. Provisioning logs appear even without a selected
workspace, cancellation targets only its request, and failed output remains
until Close is pressed. Successful creation/recreation reconnects only after
confirmed Running status. Friendly names and sidebar organization are saved
without changing DevPod IDs.

Lifecycle-command progress is plain text, not a terminal: the backend requests
DevPod's `--log-output raw` format so CLI colour escapes do not appear in the
GTK progress panel or retained failure output. macOS's PTY-rendered logs keep
their existing formatting.

Additional terminals explicitly share one owned SSH master. Normal Connect,
polling and selection do not create duplicate shells. The tab strip appears
only with multiple panes, uses working-directory titles (numbers until known),
and preserves each shell's state while switching. Closing the last shell only
disconnects SSH. Startup and disruption recovery are bounded; retries check
fresh status and never start stopped workspaces.

Linux shortcuts: Ctrl+Shift+1–9 selects visible workspaces; Ctrl+Shift+B toggles
the sidebar; Ctrl+Shift+R reloads SSH; Ctrl+Shift+O opens the active folder in
Zed; Ctrl+Shift+T creates a terminal; Ctrl+Tab selects the next terminal and
Ctrl+PageUp/PageDown selects the previous/next terminal;
Ctrl+Shift+Alt+Up/Down reorders the selected workspace. Copy/paste uses
Ctrl+Shift+C/V and targets the active terminal even when a sidebar row owns
focus. Ctrl+Shift+Q quits, Ctrl+Shift+W closes the active window/dialog,
Ctrl+Shift+M minimizes, and Ctrl+Shift+H hides the window; reopening DevSpace
restores it. Quit/Minimize/Hide/Close remain available during dialogs. Return
submits a valid form and Escape cancels/closes a dialog. Other application
shortcuts do not override editable fields or modal input; ordinary terminal
Ctrl+C/V/R/B/T remain shell input. These are Linux Ctrl+Shift shortcuts, not
Super/Windows-key bindings.

Each sidebar row has an always-visible vertical-three-dots (⋮) menu button;
right-click remains available. Opening its menu does not select/connect that
workspace. New, Guide, Stop and menu controls use native GTK button styling.

An SSH connection error clears when that workspace successfully opens a new
terminal. Connecting another workspace does not clear the failed workspace's
error.

The first window is empty until a running workspace connects; it does not
launch a local shell. Development and
production have distinct application IDs. Linux feature parity with macOS
libghostty rendering remains a later effort; splits and a Ghostty-style settings
surface remain out of scope.

Text selection/paste use VTE/GTK.
The terminal takes its default text, background, cursor and selection colours
from the GTK theme, including light/dark theme changes, without restarting
the shell. ANSI colours remain VTE's standard palette.

The backend retains authenticated Claude
notification/helper, `ded`/Zed, and image-upload behavior. These integrations
are not considered host-accepted until their frontend event paths are verified;
tests must not replace the real desktop clipboard or mutate a real workspace.

Hook installation is owned by the backend. It preserves unrelated Claude
settings/hooks and publishes validated settings atomically. Development and
production keep separate layout, application identity, and SSH state while
sharing the owner-only notification token. The development helper is
`~/.devspace-notify`; it is not installed in production.

Disconnect cleanup cancels only that channel's owned reverse notification
forward before removing managed Claude hooks. When the other channel's tunnel
is still reachable, shared hooks remain installed for it. The last disconnect
removes managed notification hooks while preserving unrelated settings.

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

With explicit authorization for a temporary remote PNG, add
`DEVSPACE_HOST_UI_IMAGE=1` to that command. This creates a private local fixture,
sends it through the Swift frontend's existing image-upload command, verifies
the injected remote path and exact PNG bytes through VTE, and removes that
specific generated `/tmp/devspace-paste-*.png` file. It checks local-source
cleanup too. It does not read or replace the physical clipboard, so it is not
proof of the desktop clipboard-image handoff.

For authorized installed-helper/`ded` acceptance, set
`DEVSPACE_TEST_CHANNEL=development DEVSPACE_HOST_UI_INTEGRATION=1` instead.
First verify that no existing development app owns its listener or workspace
lease. The probe selects another listed workspace without connecting to it,
sends the real helper notification and checks the sidebar badge, then calls
`ded /tmp` through the reopened VTE shell. A temporary controlled Zed executable
records the resulting SSH URL; the user's editor is not launched. This verifies
authenticated routing and launcher arguments, not a physical banner click or
the real Zed UI. Managed integration remains installed as authorized.
