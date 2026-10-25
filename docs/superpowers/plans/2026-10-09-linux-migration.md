# DevSpace Linux Migration Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to implement this plan task by task in the current checkout. Do not create worktrees or delegate unless explicitly authorized. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a usable, native GTK/VTE Linux app while retaining the native macOS app. Linux feature parity with macOS is a later effort. Validate first on the current Ubuntu host; Ubuntu 24.04 remains deferred by user direction.

**Architecture:** Keep application, workspace, and backend protocol logic in Swift. Linux uses a DevSpace-owned GTK4 frontend with VTE for terminal rendering/input; Linux does not depend on Ghostty. macOS continues to use SwiftUI and libghostty. The frontend launches a Swift backend child process and exchanges commands and events through private JSON pipes.

**2026-10-13 ownership amendment:** The user requires Ghostty only as the macOS terminal renderer, not as a Linux application shell or a 1:1 GTK replica. The approved Linux UI uses DevSpace-owned GTK and VTE. The [replacement design](../specs/2026-10-13-devspace-owned-linux-ui-design.md) and [replacement implementation plan](2026-10-13-devspace-owned-linux-ui.md) supersede conflicting Linux architecture/tasks below. Historical prototype steps remain audit evidence, not current requirements.

**Tech Stack:** Swift/SwiftPM, GTK4, VTE, POSIX sockets/PTYs, OpenSSH, DevPod, Ubuntu packaging. Zig is not used by the Linux app.

**Spec:** The approved design and acceptance criteria are included below. The user approved this migration plan on 2026-10-09.

## Global Constraints

- UI-first priority amendment approved 2026-10-12: NOW F01 workspace sidebar/status/selection, F02 embedded SSH terminal, F04 start/stop, F05 reload/reconnect, F06 errors/recovery, F07 text copy/paste, F08 essential shortcuts, F15 Claude notifications, F16 badges/activation, F17 automatic Claude hooks/helper installation, F18 clipboard-image upload, F20 authenticated ded (including minimal Zed launch), F22 UI layout/styling, F23 development/production separation. All other feature IDs F03/F09–F14/F19/F21/F24–F28 are LATER; preserve existing implementations without expanding or deleting them. Full-port deliverables below remain later milestones, not requirements for the UI-first handoff.
- User explicitly authorized Claude hook/helper installation in wc-1, preserving unrelated settings and project files. F20 additionally requires managed shell integration for ded; preserve unrelated shell configuration. Installation must not overwrite malformed existing settings. No workspace lifecycle mutation is authorized for real-host acceptance.

- Current validation scope (user direction, 2026-10-12): test on the existing Ubuntu host and use running `wc-1` for temporary terminal sessions. Defer Ubuntu 24.04 environment/acceptance testing until later; it remains a release gate, not a blocker for current host work. Do not start/stop/delete the workspace or change its project files for terminal acceptance.
- Retain macOS support and its existing application identity and storage locations.
- Initial Linux validation targets the current Ubuntu host with GTK4/VTE. Ubuntu 24.04 is a deferred release gate.
- Preserve the macOS libghostty renderer; Linux uses VTE and does not require Linux Ghostty feature parity in this milestone.
- Work in the current checkout on a conventional feature branch; never commit on `main` or `master`.
- Use `.tmp/` for temporary files.
- Confirm before running `make build` for macOS release builds; never close the user's production app during development.
- DevPod, configured providers, and optional Zed are user-installed.

## Review Focus

- Reload and reconnect must wait for the previous SSH master to exit; stale callbacks cannot open replacement connections.
- Linux frontend/backend shutdown must release owned sessions without stopping workspaces or touching another instance's SSH master.
- App shortcuts, clipboard operations, and IME input must preserve terminal input behavior.
- Poll snapshots must not recreate terminal surfaces or lose active pane identity.
- An installed package must work without developer toolchains and under both Wayland and X11.

## Architecture and Interfaces

- **Shared Swift controller:** Extract workspace state, lifecycle operations, polling, SSH master management, hook injection, layout, badges, and connection recovery from `AppModel`. The macOS model becomes a SwiftUI adapter around this controller.
- **Platform terminal adapters:** macOS retains its existing libghostty integration. Linux uses VTE for terminal rendering/input and SSH clients attached to the controller's master connection.
- **Linux UI ownership:** DevSpace owns the GTK application/window/layout/actions. VTE supplies the terminal widget; Ghostty supplies no Linux app-shell or terminal dependency. Do not create an inherited local terminal at startup.
- **Terminal lifecycle contract:** The controller requests terminal creation or closure using workspace ID, pane ID, connection generation, executable, arguments, and environment. Adapters report launch failure, first output, working-directory changes, and exit. Reject events from superseded generations.
- **Private protocol:** Versioned newline-delimited JSON over stdin/stdout, with request IDs, responses, ordered state snapshots, and terminal/platform effects. Reserve stderr for diagnostics. Handshake before starting workspace operations.
- **Ownership:** Swift owns DevPod operations and SSH masters; GTK owns windows, terminal surfaces, clipboard access, desktop notifications, and Zed launching. Backend stdin EOF closes sessions and masters without stopping workspaces. Backend failure disables frontend actions and shows a restart option.

## Task 1: Prove the Ghostty Integration

- [x] Prepare checksum-pinned Ghostty 1.3.1 source with a standard-library Python tool; verify extraction, downloads, integrity rejection, existing-tree preservation, and atomic publication through red→green tests.
- [x] Start from Ghostty **1.3.1**, pinned to its release source and checksum, with **Zig 0.15.2**. Preserve upstream source and maintain a separate, documented patch series. See the [upstream dependency manifest](https://github.com/ghostty-org/ghostty/blob/v1.3.1/build.zig.zon).
- [x] Adapt its GTK application/window runtime to host a workspace sidebar and terminal tabs. Reuse its rendering and input paths; expose the lifecycle callbacks required by the shared controller.
- [ ] Demonstrate two SSH terminals sharing one master, working-directory reporting, injected text, resize, tab switching, and clean shutdown on Ubuntu 24.04.
- [ ] Verify Unicode, ligatures, truecolor, clipboard, IME, and scaling on Wayland and X11 before backend restructuring.
- [ ] If the required callbacks cannot be exposed without extensive terminal changes, record the concrete limitation and revise the design before proceeding.

**Deliverable:** A working Linux Ghostty terminal integration demonstrating the necessary controller callbacks. This is a prerequisite for Task 3.

The public terminal-state library alone does not supply Ghostty's renderer, so the source adaptation is intentional. See [Ghostling documentation](https://github.com/ghostty-org/ghostling#what-is-libghostty).

## Task 2: Make the Swift Core Portable

- [x] Change `Package.swift` so Linux builds the core, backend executable, and core tests without resolving Apple-only terminal packages or app targets.
- [x] Add Darwin/Glibc implementations for process operations; use Linux `<pty.h>` and `libutil` for the C shim.
- [x] Replace Apple process-identity inspection on Linux with `/proc` start-time identity, preserving conservative SSH lease reclamation and short socket paths.
- [x] Retain Network.framework on macOS; implement the Linux loopback listener with POSIX sockets and share request parsing. Use the Linux OS random source for notification tokens.
- [x] Introduce explicit platform/build identity rather than deriving Linux behavior from `Bundle.main`. Preserve development/production ports, hook routing, and owner-only token permissions.
- [x] Use XDG configuration, state, and runtime directories on Linux; retain existing macOS locations and the layout JSON format.
- [ ] Run core tests on Linux and macOS, covering listener authentication, PTY lifecycle, process identity, stale leases, socket ownership, and development/production routing.

**Deliverable:** The portable core builds and passes its tests on both operating systems, without Linux requiring Apple terminal dependencies.

## Task 3: Extract State and Connect Both Frontends

- [ ] Move the lifecycle controller incrementally, preserving existing cancellation, retries, first-output confirmation, and master-release ordering.
- [ ] Move relevant app lifecycle tests alongside the controller and run them on both platforms.
- [ ] Implement the Swift child-process executable and GTK protocol client, including fragmented messages, protocol mismatch, pending-request failure, and shutdown.
- [ ] Keep timers and controller events serialized. Preserve pane IDs across snapshots so polling never recreates terminal surfaces.
- [ ] Render workspace status, start logs, connection failures, creation/recreation dialogs, sidebar aliases/order/hiding, and terminal tabs from shared state.
- [ ] Test reload while a master is stopping, delayed callbacks from an old generation, cancelling creation, closing the last shell, frontend exit, and backend crash.
- [ ] Run macOS app regression tests and a development build after switching the SwiftUI model to the shared controller.

**Deliverable:** Both frontends use the same workspace controller; Linux manages real DevPod workspaces and embedded SSH sessions.

## Task 4: Complete Linux Feature Parity

### Current UI-first execution order

- [x] F15/F16: reproduce the ignored `ready.payload.notify_error` warning with the real GTK client fixture; persist a nonfatal warning without disabling workspace actions; rerun GTK client tests. Verify the maintained native notification activation patch focuses an existing workspace surface without opening another tab.
- [x] F17/F20: test malformed settings rejection before remote writes in `Hooks.inject`; reuse existing hook/shell generators and asynchronous `DevpodCLI` cancellation. Install once per live connection after first output, cancel on disconnect/shutdown, reject stale completion, report installation failures nonfatally. Verify settings preservation/idempotence with local fixtures before authorized wc-1 installation.
- [x] F20: connect authenticated `/dide` to `platform_open_zed` using validated known/running workspace and absolute UTF-8 path, emit a single percent-encoded `SSH.zedRemoteURL`. GTK invokes user-installed `zed` with argument arrays, no shell; absence/failure stays visible without breaking terminals. Exercise spaces/Unicode and unknown/stopped workspace rejection.
- [x] F18: request a GDK clipboard texture only for a bound workspace terminal, encode PNG with a bounded size, upload over the owned SSH master, then inject the remote path only into the original live pane/generation. Ordinary text paste retains Ghostty's existing path. Test upload failure, stale completion, local cleanup, and paths with spaces/Unicode; real test writes only a temporary image to the pod's /tmp.
- [ ] F01/F02/F04–F08/F22/F23: launch the host development UI, streamline the sidebar for the NOW actions, retain essential copy/paste/reload/navigation bindings and distinct identity. Rebuild and verify real wc-1 terminal/input/notification behavior on the current host; keep multiple-tab expansion and broader acceptance deferred.

Implementation checkpoint: the development UI is launchable on host XWayland;
core/GTK fixtures cover lifecycle controls without mutating wc-1. Real wc-1
hooks/helper/ded/image roundtrip and a live desktop-notification call are verified.
Backend recovery and first-shell Reload guidance are implemented. Linux channel
tokens are shared (owner-only and creation-locked) for production-first routing,
while layouts, application identities and SSH leases remain separate. The final
Ctrl+Shift+R native regression is recorded in the implementation ledger. Unlocked
Wayland, actual visual/banner interaction and final UI polish remain acceptance
work; no full-port or installed-package completion is claimed.

- [ ] Route Claude notifications through GTK desktop notifications; activation selects the workspace. Keep sidebar badges when banners or activation are unavailable.
- [ ] Read clipboard images through GDK, upload through the existing SSH transport, and inject the resulting path into the selected terminal. Preserve ordinary text paste.
- [ ] Launch Zed through its executable using argument arrays; support current-directory opening and authenticated `/dide` requests used by `ded`.
- [ ] Adopt Ctrl+Shift shortcuts for app commands, preserving terminal Ctrl keys: copy/paste, new tab, reload, sidebar toggle, Zed, workspace selection, and reordering. Use Ctrl+PageUp/PageDown for tab navigation.
- [ ] Keep distinct Linux application IDs, executables, icons, and logs for development and production.
- [ ] Verify notifications and activation, unavailable notification services, image upload failure, Zed unavailable, and paths containing spaces or Unicode.
- [ ] Test simultaneous local development and production instances, including notification routing and SSH ownership.

**Deliverable:** Linux supports the full daily workflow, including notifications, image paste, Zed, and distinct development/production instances.

## Task 5: Package and Release

- [x] Add Linux build, test, run, and package targets while preserving the macOS commands.
- [ ] Produce an Ubuntu `.deb` containing the Linux frontend/backend, required Swift runtime libraries, desktop entries/icons, and license notices. Declare GTK4 and VTE GTK4 as system dependencies; do not bundle Ghostty resources because Linux uses VTE.
- [ ] Build against Ubuntu 24.04 with baseline CPU settings; validate installation on a clean machine without developer toolchains.
- [ ] Add Linux core/protocol tests and package builds to CI alongside macOS tests and development builds.
- [x] Record the architecture decision, dependency pins, build prerequisites, patch-update procedure, and Linux installation instructions.
- [ ] Complete the release acceptance workflow below on the installed package.

**Deliverable:** A reproducible, installable Linux package validated alongside the maintained macOS application.

2026-10-14 checkpoint: `make linux-package` and `scripts/package-linux.py`
assemble a production `.deb` with standard system paths, Swift runtime notices,
and binary-derived versioned dependencies. Twenty build/assembly tests pass,
including a real XML-linked ELF fixture, package extraction, relocated launcher,
lockfile preservation, and refusal to overwrite existing output. Dependency
analysis of the current development binaries/runtime declares `libc6 >= 2.43`
and `libxml2-16 >= 2.14.1`; this is an Ubuntu 26.04 ABI, not 24.04 validation.
No actual production package has been built. Project/runtime copyright coverage,
maintainer metadata, release-build confirmation, clean-machine install, and CI
remain open.

The Linux CI job is now defined alongside the unchanged macOS job, using the
official Swift 6.4.1 Ubuntu 26.04 container. Its shell steps and YAML are locally
validated. The corresponding global-toolchain commands passed Core220 tests
(one opt-in skip), protocol4 checks, and Linux73 tests (three opt-in skips), and
assembled the updated development bundle. GitHub/container execution and an
actual production package build remain unverified. [ADR 0002](../../adr/0002-linux-swift-gtk-vte.md)
records the current architecture and replaces Linux Ghostty patch maintenance
with GTK/VTE/toolchain update checks.

## Test and Acceptance Criteria

- **Workspace behavior:** Create/cancel/recreate, start/stop/delete, polling races, stopped-workspace selection, aliases, hiding, ordering, and persistence.
- **SSH lifecycle:** Multiple tabs share one master and tunnel; reload waits for master exit; stale callbacks cannot reconnect; closing the last shell preserves workspace behavior; crashes and reused PIDs cannot reclaim a live owner's socket.
- **Terminal quality:** Unicode, ligatures, truecolor, scrollback, mouse input, IME, clipboard, bracketed paste, OSC 7/52, resize, and fractional scaling on Wayland and X11.
- **Integrations:** Finished/needs-input notifications, activation, unavailable notification service, image upload failure, Zed unavailable, and paths containing spaces or Unicode.
- **Protocol and shutdown:** Fragmented JSON, version mismatch, backend crash, UI exit, and cancellation during active operations.
- **Release gate:** The installed Linux app completes a real DevPod workflow with all parity features; shared and macOS regression tests pass; development and production instances coexist locally.

## Assumptions and Defaults

- First-release distribution is Ubuntu `.deb`; ARM64, other desktops, Flatpak, and AppImage follow separately.
- Layout files remain transferable manually; secrets and notification tokens are created locally.
- Simultaneous connections from different computers to the same pod retain today's tunnel limitations; this migration does not introduce multi-host routing.
- Linux imports GTK4/VTE directly from system libraries; it has no Ghostty source adaptation or patch series to maintain.
- This document records the approved migration plan. Implementation follows its milestones, with the terminal feasibility gate completed before the shared-controller extraction.
