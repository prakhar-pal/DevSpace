# Swift GTK/VTE Linux UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task in the main thread. Do not create worktrees or delegate implementation. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Zig/Ghostty Linux UI prototype with a Swift GTK4 application embedding VTE, while preserving the Swift workspace backend and macOS app.

**Architecture:** Add SwiftPM system-library targets for GTK4 and VTE and a Linux Swift executable for the DevSpace window/sidebar/terminal lifecycle. Reuse `DevSpaceCore`, the existing Swift backend executable, and its versioned control protocol. VTE owns terminal rendering and the child PTY; GTK and VTE are called directly from Swift.

**Tech Stack:** Swift 6.4.1 on the current Ubuntu 26.04 host, SwiftPM, GTK4, VTE GTK4, existing Swift `DevSpaceCore`/backend, Python integration harnesses compiling/running the actual Swift sources.

**Spec:** `docs/superpowers/specs/2026-10-13-devspace-owned-linux-ui-design.md`

## Global Constraints

- Use Swift for all DevSpace Linux application, UI, protocol-client and lifecycle logic; add C shim code only for a demonstrated Swift C-interop limitation.
- GTK4/VTE must be native system libraries imported through SwiftPM; do not add Zig or Rust to the Linux app build.
- Preserve macOS behavior and its `Package.resolved`; restore the lockfile unchanged after Linux Swift commands.
- Preserve the existing Swift backend, private protocol, SSH ownership, channel identity, hook/notification/upload safety and approved NOW/LATER priorities.
- Do not start/stop/delete workspaces or alter the physical clipboard during tests; use controlled test doubles/private displays.
- Ubuntu 24.04 testing remains deferred. Validate on the current Ubuntu host when Swift + VTE development dependencies are available.
- Do not build/launch a release bundle or close a running release app without user confirmation. Follow current `AGENTS.md` milestone-commit rules; do not push or create a PR unless requested.
- Preserve unrelated dirty work. Keep scratch artifacts in `.tmp/`; avoid duplicate dependency trees/caches.

## Execution status — 2026-10-14

Tasks 1–4 are implemented and their host verification is recorded in the
[completion audit](2026-10-13-linux-completion-audit.md). Verification uses the
global Swift.org 6.4.1 Ubuntu 26.04 toolchain; no compiler is installed in the
repository. The obsolete Linux Ghostty/Zig app pipeline has been retired.
Automated current-host suites pass. The actual text-only `wc-1` shell
round-trip through the GTK/VTE app passed under Xvfb, with the workspace still
running after terminal close. An unlocked-host inspection found the VTE widget
was only using its natural height; the pane and VTE now expand, covered by an
allocation regression test. The updated DevSpaceDev bundle rebuilt and
launched. Task 5 remains open for post-fix visual review, close/reopen
inspection, and hook/notification/ded/image paths through the visible app.
Real clipboard/image upload remains unverified pending separate approval.

## File Boundaries

| File | Responsibility |
| --- | --- |
| `Package.swift` | Linux-only GTK/VTE system libraries and `DevSpaceLinuxApp` executable; keep macOS products unchanged |
| `Sources/LinuxGTK/module.modulemap`, `Sources/LinuxVTE/module.modulemap` and shim headers | Expose GTK4/VTE C headers to SwiftPM without implementing app behavior |
| `Sources/LinuxApp/main.swift` | Validate channel, initialize GTK application, start Swift UI/backend client |
| `Sources/LinuxApp/WorkspaceWindow.swift` | DevSpace-owned GTK window/sidebar, workspace state/actions and empty/recovery UI |
| `Sources/LinuxApp/TerminalPane.swift` | VTE widget creation, approved SSH spawn arguments, pane identity and terminal callbacks |
| `Sources/LinuxApp/BackendClient.swift` | Swift private-protocol process and framed messages; reuse protocol semantics, not Zig implementation |
| `Makefile`, `scripts/assemble-linux.py` | Build and bundle Swift frontend/backend plus system GTK/VTE runtime dependencies |
| `Tests/Linux/` | Swift unit/native GTK tests and Python packaging/backend regressions |

## Review Focus

1. Invalid or stale terminal-launch effects must not spawn a shell — Tasks 2/3.
2. Closing a pane or losing its widget must not stop the workspace or SSH master — Tasks 2/3.
3. Backend snapshots and delayed callbacks must not recreate/re-target panes — Tasks 2/3.
4. A backend crash or bounded-write failure must leave the UI responsive and clean up owned children/images — Task 3.
5. Development/production app identities must remain isolated and repeated activation must reuse the correct window/backend — Tasks 1/4.

---

### Task 1: Add SwiftPM GTK/VTE imports and Linux application target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/LinuxGTK/module.modulemap`, `Sources/LinuxGTK/shim.h`
- Create: `Sources/LinuxVTE/module.modulemap`, `Sources/LinuxVTE/shim.h`
- Create: `Sources/LinuxApp/main.swift`
- Modify: `Tests/Linux/test_linux_build.py`

**Interfaces:**
- Produce Linux-only SwiftPM modules `CGTK` and `CVTE` backed by `gtk4` and `vte-2.91-gtk4` pkg-config modules.
- Produce executable product `DevSpaceLinuxApp`, depending on `DevSpaceCore`, `CGTK`, and `CVTE`.
- `main.swift` parses only the existing explicit development/production channel values and fails closed on invalid input.

- [x] Add Python build-contract tests that assert Linux product/target dependencies and reject Zig as the default app build tool; leave macOS products/dependencies unchanged.
- [x] Run `python3 -B -m unittest Tests.Linux.test_linux_build -v`; build-contract tests cover the Swift UI target and system modules.
- [x] Add system-library module maps and the minimal Swift GTK application entry. Keep headers limited to `<gtk/gtk.h>` and `<vte/vte.h>`.
- [x] Run the targeted build-contract test and `swift build --product DevSpaceLinuxApp --scratch-path .tmp/swift-linux-tests` with global Swift 6.4.1 and installed GTK4/VTE dependencies.
- [ ] Run `swift build --product DevSpaceApp` on macOS only when available; compare `Package.resolved` before/after and restore it unchanged if Linux SwiftPM modified it.

### Task 2: Implement the Swift GTK window and VTE terminal pane

**Files:**
- Create: `Sources/LinuxApp/WorkspaceWindow.swift`
- Create: `Sources/LinuxApp/TerminalPane.swift`
- Create: `Tests/LinuxApp/WorkspaceWindowTests.swift` (standalone Swift GTK/VTE integration runner)
- Modify: `Package.swift`

**Interfaces:**
- `WorkspaceWindow` owns one `GtkApplicationWindow`, workspace sidebar, terminal container and empty/error presentation.
- `TerminalPane` owns one `VteTerminal` widget and a copied `(workspaceID, paneID, generation)` binding.
- A terminal can only be created from a validated launch effect containing an executable plus an argument array; do not interpolate shell strings.

- [x] Add tests for one Workspaces heading, empty startup with zero terminal children, channel identity, and no implicit local shell.
- [x] Add controlled VTE coverage for literal output/input, PTY resize, and widget/child disposal.
- [x] Run the focused Swift GTK/VTE harness on private Xvfb and observe RED before implementation.
- [x] Implement GTK application activation/window layout in Swift. Import and call GTK/VTE APIs directly; add no Zig UI.
- [x] Implement pane creation/disposal and VTE spawn with explicit executable/argv/env/cwd; connect exit/focus/size callbacks using Swift C callbacks and opaque retained context.
- [x] Run focused tests with `G_DEBUG=fatal-criticals`; GTK/VTE suite passes 5/5.

### Task 3: Port the backend client and workspace behavior to Swift UI

**Files:**
- Create: `Sources/LinuxApp/BackendClient.swift`
- Modify: `Sources/LinuxApp/WorkspaceWindow.swift`, `TerminalPane.swift`
- Create: `Tests/LinuxApp/BackendClientTests.swift`
- Modify: `Sources/LinuxBackend/main.swift` only if a protocol correction is required

**Interfaces:**
- Swift client launches the existing `DevSpaceLinuxBackend`, performs the existing versioned handshake, decodes snapshots/effects and writes bounded control frames.
- The backend remains the owner of workspace operations, SSH masters, hooks, notifications and image uploads.
- Swift UI routes only terminal launch/close/inject/focus and existing workspace actions; terminal bytes remain in VTE/PTY.

- [x] Port protocol fixture coverage for handshake, fragmented frames, malformed frames, queue bounds, disconnect and orderly shutdown; observe RED before implementation.
- [x] Port existing UI effect coverage: backend workspace snapshot, selected workspace, open terminal, stable widget identity through later snapshots, close, inject and stale-generation rejection.
- [x] Implement the Swift client against existing protocol types and backend behavior. Reuse Core models; do not duplicate workspace state machines in the UI.
- [x] Run protocol/Core tests and existing Python backend tests; backend semantics remain unchanged.
- [x] Verify closing a VTE pane leaves the workspace running and backend crash disables actions without freezing GTK.

### Task 4: Switch Linux build/bundle defaults and retire the Zig/Ghostty app path

**Files:**
- Modify: `Makefile`, `scripts/assemble-linux.py`, `Sources/Linux/README.md`, `docs/linux-development.md`
- Modify: `Tests/Linux/test_linux_build.py`, `test_assemble_linux.py`, `test_bundle_runtime.py`, `test_channel_identity.py`
- Retire only after equivalent tests pass: `Sources/Linux/gtk/`, `Sources/Linux/backend_client.zig`, Ghostty frontend patch series and Zig frontend tests

**Interfaces:**
- `make linux-build-dev` builds `DevSpaceLinuxApp` and `DevSpaceLinuxBackend` with SwiftPM.
- The development bundle contains both Swift executables and Swift runtime libraries; GTK4/VTE remain documented system runtime dependencies unless current packaging policy explicitly bundles them.
- Existing bundle names, channel identifiers, replacement rollback and launcher behavior remain stable.

- [x] Add build/assembly tests for Swift executable names, dev channel metadata, runtime lookup and relocation; observe RED before replacement.
- [x] Switch default Linux targets and bundle assembly to the Swift frontend after Tasks 1–3 pass.
- [x] Run the full Linux test suite (69 passed, three opt-in skips), Core XCTest (220 passed, one opt-in skip), private channel coexistence, and bundle relocation/replacement tests.
- [x] Retire obsolete Zig/Ghostty Linux sources, patches and tests after equivalent GTK/VTE coverage passed; retain historical migration evidence.
- [x] Update Linux docs with GTK/VTE system package names and make commands; remove Linux Ghostty/Zig runtime requirements and retain macOS libghostty instructions.

### Task 5: Current-host acceptance and migration handoff

**Files:**
- Modify: `Tests/Linux/test_host_integration.py` only for the new Swift bundle/client paths
- Update: `docs/superpowers/plans/2026-10-09-linux-migration.md`, `docs/superpowers/plans/2026-10-13-linux-completion-audit.md`

**Interfaces:**
- Use existing opt-in `wc-1` checks only for temporary shells/hooks that are already authorized; never mutate workspace lifecycle/project files.
- Ubuntu 24.04 remains a deferred release gate.

- [x] Run Core/backend/protocol/UI/package suites on the current Ubuntu host; outcomes and skips are recorded in the completion audit.
- [x] With private Xvfb, test controlled output/input/resize/disposal and copy/paste using the private test clipboard, without touching the physical clipboard.
- [x] Run an actual `wc-1` shell round-trip through the GTK/VTE app under Xvfb, verifying output, input and terminal close while the workspace remains running.
- [ ] With the unlocked host display, verify visual GTK layout and close/reopen using the approved workspace; do not test clipboard replacement without separate approval.
- [ ] Verify these hook/notification/ded/image paths through the visible Swift frontend; the wc-1 backend/SSH integration passed without workspace lifecycle/project-file changes.
- [x] Record manual/deferred checks (IME, physical clipboard, notification banner/click, Ubuntu 24.04, package signing/CI) as unverified rather than inferring them from unit tests.
- [x] Run a final `git diff --check` and inspect the macOS lockfile comparison; commit verified milestones per `AGENTS.md`, without publishing.

## Self-Review

Spec coverage: Swift application/system imports → Task 1; owned GTK/VTE
window and terminal lifecycle → Task 2; protocol/workspace behavior → Task 3;
build retirement and bundle contracts → Task 4; host acceptance and deferred
gates → Task 5. Review Focus items have named owning tasks/tests. The current
execution environment must provide Swift and the VTE GTK4 development module
before compile/host acceptance; missing tools are environment blockers, not
passing verification.
