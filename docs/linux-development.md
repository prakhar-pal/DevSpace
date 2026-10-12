# Linux development (in progress)

The Linux port is not release-ready. The approved scope and remaining
acceptance gates are in [the migration plan](superpowers/plans/2026-10-09-linux-migration.md).
macOS build commands remain unchanged.

## Build and launch

Install Swift (currently tested with 6.1.3), Zig **0.15.2**, Python 3, Make,
and the GTK4/libadwaita development dependencies required by Ghostty 1.3.1.
The runtime also uses OpenSSH and `setsid` from Ubuntu's `util-linux` package.
Ghostty's source archive is checksum-pinned in `Sources/Linux/ghostty-source.json`.
The first preparation/build needs network access for source and dependencies.

```sh
make linux-build-dev
make linux-bundle-dev
make linux-run
```

`linux-build-dev` produces the frontend and backend in `build/linux-dev`.
`linux-bundle-dev` includes Swift runtime libraries, Ghostty resources,
desktop metadata, and the existing development icon in `build/linux-dev-bundle`.
`linux-run` builds that bundle and launches `bin/devspace-dev`; it does not
terminate existing applications. These are development-channel targets,
not release/package targets.

Override `SWIFT` and `ZIG` to select installed toolchains. The Swift runtime
directory is discovered using `swift -print-target-info`; override
`LINUX_SWIFT_RUNTIME` if needed. `LINUX_OPTIMIZE` defaults to `Debug`.
`ReleaseFast` changes optimization only, not the development identity.

Bundles can be moved to a directory containing spaces or Unicode. The launcher
resolves its own location and selects bundled libraries, resources, and backend.
Runtime users do not need Swift or Zig toolchains, but still need the system
GTK libraries and user-installed DevPod. Ubuntu 24.04 clean-machine validation
and license-complete `.deb` packaging remain outstanding.

The assembler stages a complete new bundle before replacement. `--replace`
accepts only a directory bearing its matching generated-bundle/channel marker;
it rejects symlinks and unrecognized directories. Assembly failure leaves the
previous bundle intact; publication exceptions, including Ctrl+C, restore it.
If restoration itself fails, the error identifies the retained recovery copy.
Do not run concurrent assembly commands against the same output. This is not
a transactional installer with power-loss recovery.

## UI-first workspace integrations

The current milestone prioritizes the sidebar, SSH, start/stop, reload/recovery,
copy/paste, Claude notifications/badges/hooks, image upload, and minimal `ded`
launching. Feature IDs and deferrals are in the amended migration plan. Existing
deferred controls remain available, without expanding them in this milestone.

After first terminal output, DevSpace installs Claude hooks and managed Bash/Zsh
integration in the workspace user's home. Unrelated settings/hook commands are
preserved; invalid or unreadable settings fail without a settings write. Settings
are published through a private temporary file and atomic rename (mode 0600).
The development-only `~/.devspace-notify` helper is mode 0700. Installation is
nonfatal and cancellable on disconnect/shutdown.

Linux channels share the owner-only `~/.config/devspace/notify-token` (respecting
`XDG_CONFIG_HOME`), matching macOS production-first hook routing. Token creation
is serialized across simultaneous starts. Layout, state, application identity,
ports, and SSH leases remain channel-specific; tokens are never displayed.

The first shell is already running when its rc files are updated. The sidebar
tells you to **Reload** to enable `ded` and managed directory reporting in that
shell. Setup commands are not injected into an active terminal. Reload waits
for the old SSH master and retries after a cancelled installer finishes.

`ded /absolute/path` sends an authenticated tunnel request. The local `zed`
executable must be on PATH; it receives one encoded SSH URL argument. Missing
Zed produces a visible, nonfatal error. Unknown/stopped workspace requests are
ignored.

Image paste converts clipboard images to PNG and uploads through the owned SSH
master, with no fallback connection. Limits are 16 million pixels and 16 MiB
encoded PNG. Completion targets the original live pane/generation. Accepted
local temporary images are removed after upload/failure; normal remote images
remain at generated `/tmp/devspace-paste-*.png` paths for Claude to read.
Text-only clipboard paste is unchanged.

Ctrl+Shift+C/V retain Ghostty's text copy/paste. Ctrl+Shift+R reconnects the
active workspace terminal through the same backend path as Reload. It does
nothing in an unbound local shell and does not replace ordinary terminal Ctrl
keys. Broader app shortcuts remain deferred.

Backend disconnect/protocol failure disables workspace controls and offers
**Restart DevSpace**. It waits for the current frontend and its owned backend
to exit, then relaunches that frontend. Other application identities are not
killed.

The authorized remote-home acceptance is opt-in:

```sh
DEVSPACE_HOST_INTEGRATION_WORKSPACE=wc-1 \
LD_LIBRARY_PATH="$PWD/build/linux-dev-bundle/lib" \
python3 -m unittest discover -s Tests/Linux -p test_host_integration.py
```

Automatic integration means host terminal tests now write managed home files
when first output is reported. Run only with approval for those changes. The
integration test also checks helper/ded routing and actual PNG contents, removing
its exact generated remote test image. It changes no project files or workspace
lifecycle state.

## Tests

```sh
make linux-test-core
make linux-test-protocol
make linux-test-gtk
python3 -m unittest discover -s Tests/Linux -v
```

The Python suite exercises preparation, build orchestration, assembly, and the
real backend with a controlled DevPod executable. Native binary tests skip
when their artifacts are absent; a green run with skips is not native-build
evidence. Override `DEVSPACE_TEST_FRONTEND_PREFIX`, `DEVSPACE_TEST_BACKEND`,
and `DEVSPACE_TEST_SWIFT_RUNTIME` to test alternate artifact paths.

GTK integration tests require desktop access. Backend/Core integration tests
need subprocesses and local sockets; restricted sandboxes can prevent them.
Tests with controlled peers are not substitutes for the real SSH, Wayland/X11,
IME, and installed-package acceptance gates in the plan.

### Opt-in host SSH acceptance

Use only a running workspace explicitly approved for testing. This opens
temporary shells, runs `cd`/`printf`/`stty`, disables history for injected test
commands, and closes its own master; it does not change workspace project files
or start/stop/delete the workspace. The transparent recorder forwards the real
backend's frames and records control traffic, not terminal contents.

```sh
make linux-bundle-dev
DEVSPACE_HOST_WORKSPACE=wc-1 \
DEVSPACE_HOST_BACKEND="$PWD/build/linux-dev-bundle/bin/DevSpaceDevBackend" \
LD_LIBRARY_PATH="$PWD/build/linux-dev-bundle/lib" \
GHOSTTY_RESOURCES_DIR="$PWD/build/linux-dev-bundle/share/ghostty" \
make linux-test-gtk
```

The host mode checks two terminal panes sharing one master, distinct pane IDs,
first output, OSC 7 directory callbacks, injected commands, tab selection,
remote PTY resize, pane identity across polling, and last-shell master cleanup.
It also checks suppression of DevPod service restarts. Run with
`GDK_BACKEND=wayland` or `GDK_BACKEND=x11` to select the host display backend.
This is not yet a visual IME/ligature/clipboard/scaling acceptance check.
Ubuntu 24.04 testing is deferred by user direction; it remains a release gate.

The opt-in Core transport diagnostic is:

```sh
DEVSPACE_HOST_WORKSPACE=wc-1 swift test --filter HostSSHTransportTests
```

## Maintained source patches

`scripts/prepare-linux-frontend.py` copies pristine pinned source and applies
`Sources/Linux/patches/*.patch` in order with zero fuzz, then copies integration
sources and the GTK test. It refuses to overwrite existing source trees.
Default prepared-tree names include a hash of integration inputs to avoid
reusing stale patches. Never edit a prepared tree as the maintained source:
update the patch series/integration files, prepare a fresh tree, and rerun tests.

All prepared revisions share `.tmp/linux-migration/zig-local-cache` and
`.tmp/linux-migration/zig-cache`; do not accumulate compiler caches per revision.
Swift build/test artifacts share `.tmp/swift-controller-test`. Linux SwiftPM
can remove the macOS-only `Package.resolved`; restore it unchanged after Linux
verification rather than committing its deletion.

## Host acceptance status (2026-10-12)

The UI-first implementation now has passing Core, backend, GTK-client and
native XWayland tests, plus an authorized real wc-1 hook/ded/PNG roundtrip.
The updated development UI was launched on the host and opened wc-1 through
its normal desktop action. A real helper event reached the desktop notification
service with the development application ID; actual banner appearance/clicks
remain a visual check. The latest Wayland run could not initialize a newly
selected surface while the host screen was locked. Its identical binary passed
on XWayland; unlocked Wayland verification is still pending, not waived.

The opt-in real-backend/real-GTK test passed on the Ubuntu 26.04 host with
`GDK_BACKEND=wayland` and `GDK_BACKEND=x11` (XWayland in this session).
It verified two wc-1 shells sharing one SSH master, output, pasted commands
executed with an Enter key, tab selection, remote PTY resizing, stable pane
identity through polling, and last-shell master cleanup. A subsequent regression
proved normal remote-host OSC 7 directory metadata reaches the backend without
changing Ghostty's trusted local directory. Current host checks also inspect
decoded Greek/CJK/emoji output and a cell's actual parsed 24-bit foreground
color, avoiding false positives from command echo. They do not establish
visual font/ligature rendering, IME, clipboard, scaling, Ubuntu 24.04, or
native-Xorg acceptance.

The shared backend now exposes bounded live provisioning logs, operation-specific
cancellation, creation discovery/selection, and native GTK creation/recreation
confirmation dialogs. Cancelling an operation waits for its command cleanup
without disabling polling or later jobs. Conflicting operations on a workspace
are rejected; stop/delete/recreate wait for the owned SSH master to exit.
Polls predating a lifecycle completion are re-read before publishing status,
while selection remains responsive during slow status checks. SSH configuration
lookup is asynchronous and cancellable; cancelled/stale callbacks cannot launch
a master. These lifecycle checks use controlled local DevPod fixtures, not
destructive operations on wc-1. Full macOS controller adoption, installed
packaging, and visual acceptance remain open. Additional hook, image-upload,
and authenticated `ded` coverage does not establish visual clipboard quality
or actual desktop-banner activation.

The same host X11 test also passed with `GDK_SCALE=2`. That checks for
functional failures under the override, not visual or fractional-DPI quality.

An earlier X11 run failed an immediate relative-tab assertion; the same binary
then passed four sequential rechecks. The current harness explicitly selects
and verifies the starting page before exercising relative navigation, and
passes on both host backends. The intermittent failure's original cause was
not established; it remains a focus/navigation risk for visual acceptance.

