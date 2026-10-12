# Linux integration

The Linux migration adapts Ghostty's GTK runtime and runs the portable Swift
controller in a child backend. Implementation is in progress; this is not
yet a feature-complete or packaged Linux application. See the
[migration plan](../../docs/superpowers/plans/2026-10-09-linux-migration.md).

## Prepare upstream source

Python 3.12+ is sufficient for source preparation and its tests. Ghostty and
Zig versions are recorded in `ghostty-source.json`. The SHA-256 pin was
computed from the Ghostty 1.3.1 release source archive downloaded over HTTPS.

From the repository root:

```bash
python3 -B -m unittest discover -s Tests/Linux -v
python3 scripts/prepare-linux-ghostty.py --output .tmp/linux-migration/upstream
```

For an already downloaded archive:

```bash
python3 scripts/prepare-linux-ghostty.py \
  --archive .tmp/linux-migration/ghostty-1.3.1.tar.gz \
  --output .tmp/linux-migration/upstream
```

Preparation checks the archive checksum before extraction, requires the
expected source root, and uses Python's safe tar extraction filter. It
publishes the extracted tree only after successful extraction and refuses
to overwrite any existing output directory. Use a different output path
for another copy; the downloaded archive remains unchanged.

The pristine source is at `.tmp/linux-migration/upstream/ghostty-1.3.1`.
Keep it unchanged. Integration changes live in the separate
`Sources/Linux/patches/` series and apply to a working copy.

Prepare the integration in a new directory with:

```bash
make linux-prepare
# To prepare another revision without overwriting existing work:
make linux-prepare LINUX_FRONTEND=.tmp/linux-migration/frontend-next
```

The preparation tool applies the complete patch series with `--fuzz=0`,
copies the current protocol/client and GTK integration test, and publishes
the working tree only after every patch succeeds. Existing output is rejected;
choose a new directory after changing patches. `--upstream` must refer to
source verified by `prepare-linux-ghostty.py`.

Portable core and protocol checks are also available as `make linux-test-core`
and `make linux-test-protocol`; override `SWIFT` or `ZIG` for local toolchains.

## Compiler prerequisites

On Ubuntu, install the native build prerequisites from an interactive
terminal where sudo authentication is available:

```bash
sudo apt-get install -y build-essential pkg-config libgtk-4-dev \
  libadwaita-1-dev libxml2-utils gettext libonig-dev libssl-dev zlib1g-dev
```

Install Zig **0.15.2** separately and put it on PATH. The later shared-core
milestone also requires Swift. `gtk4-layer-shell` can be built from Ghostty's
pinned dependency by passing `-fno-sys=gtk4-layer-shell` as shown below.

## Apply and test the GTK patches

From the repository root, using a new working-copy destination:

```bash
python3 scripts/prepare-linux-frontend.py \
  --upstream .tmp/linux-migration/upstream/ghostty-1.3.1 \
  --output .tmp/linux-migration/working-ghostty
cd .tmp/linux-migration/working-ghostty
zig build test-devspace -Doptimize=ReleaseFast -Demit-docs=false \
  -Demit-webdata=false -Di18n=false -fno-sys=gtk4-layer-shell -j2 \
  --global-cache-dir ../zig-cache
```

This test needs access to a graphical desktop. A sandbox without display
access fails at `gtk.initCheck`; it cannot validate the real window hierarchy.
The test uses non-unique application registration so it creates a local
application instead of forwarding to an existing Ghostty instance.

Patch 0001 adds a focused GTK integration test target and a runtime library
search path for the bundled layer-shell dependency. Patch 0002 wraps the
existing terminal/tab content beside the workspace sidebar. Patch 0003
launches the backend, and patch 0004 exposes host text injection through
Ghostty's normal paste path. Patch 0005 connects terminal launch effects to
tabs with direct argument arrays, rather than shell command strings.
Patch 0006 gives GTK, its window icon, and D-Bus IPC the same explicit
development/production identity as the backend, independently of compiler
optimization or Ghostty's user-configured window class.
Patch 0007 binds each backend-created terminal to copied workspace, pane,
and connection-generation IDs and forwards OSC 7 directory changes through
the private backend pipe. Bindings retain their client through widget disposal.
Patch 0008 reports the first nonempty PTY read once through Ghostty's existing
main-thread surface mailbox; no terminal bytes cross the backend pipe.
Patch 0009 reports shell exit (including retained error overlays) and user
surface disposal once, so closing the last shell can release its SSH master.
Patch 0010 handles backend closure through the normal split-tree removal
path, matching workspace/pane/generation and leaving other surfaces intact.
Patch 0012 forwards foreign-host OSC 7 paths as separate remote metadata
only to backend-bound panes. It does not change Ghostty's trusted local pwd,
local directory inheritance, title fallback, or filesystem-path validation.

The GTK test uses one Ghostty application per process because upstream's
GLib log writer initialization is process-global. Its controlled backend
fixture exercises the Open action without connecting to users' real pods.
It also checks tab switching, OSC 7 directory reporting, and text injection.
Passing the GTK fixture does not prove a real shared SSH-master workflow.

## Backend and pipe-client tests

With Swift and Zig 0.15.2 on PATH, from the repository root:

```bash
swift build --product DevSpaceLinuxBackend
swift test
DEVSPACE_TEST_BACKEND="$PWD/.build/debug/DevSpaceLinuxBackend" \
  python3 -B -m unittest discover -s Tests/Linux -v
zig test --dep protocol -Mroot=Tests/Linux/backend_protocol_test.zig \
  -Mprotocol=Sources/Linux/backend_protocol.zig
zig test --dep client -Mroot=Tests/Linux/backend_client_test.zig \
  -Mclient=Sources/Linux/backend_client.zig \
  -lc -lgtk-4 -lgio-2.0 -lgobject-2.0 -lglib-2.0
```

The Python backend tests launch the real Swift executable with a controlled
DevPod peer, isolated configuration directory, and no real workspaces. Set
`DEVSPACE_TEST_BACKEND` when using a nondefault SwiftPM scratch path. If no
backend binary exists, those tests report skips rather than claiming backend
coverage. GTK tests need display access; Foundation subprocess and listener
tests need local socket permissions.

The frontend resolves `DEVSPACE_BACKEND` (or `DevSpaceLinuxBackend` on PATH)
and passes `DEVSPACE_BUILD_CHANNEL` (`production` or `development`) to its
child. The development channel uses its own application identity and SSH
ports. The protocol reserves stdin/stdout for versioned NDJSON and stderr
for diagnostics; terminal bytes stay inside Ghostty. The backend supports
poll, select, create, start, stop, delete, recreate, connect/reconnect,
disconnect, and generation-checked terminal events. GTK currently exposes
Start/Stop, Hide/Show, Unicode aliases through a native rename dialog, and,
with its host adapter, Open/Reload. Stored sidebar ordering and hidden-section
collapse are rendered, and connection errors survive automatic refresh.
Creation/recreation dialogs, reorder controls, restart UI, and remaining
parity features are still outstanding.

## Integration boundary identified in the source

Ghostty's GTK `Surface` exposes working-directory state via `getPwd`/`setPwd`
and child-exit state via `childExited`. Its renderer and input machinery
belong to the GTK application runtime. First-output and directory reporting
and shell exit are verified by the real GTK runtime fixture.
Backend-requested closure rejects stale generations, preserves other tabs,
and suppresses duplicate exit reports in the runtime fixture.
Ubuntu 24.04 Wayland/X11 verification remains outstanding; the current host
is Ubuntu 26.04 with GTK 4.22 and libadwaita 1.9.
