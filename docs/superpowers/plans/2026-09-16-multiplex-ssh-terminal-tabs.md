# Multiplexed SSH Terminal Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each workspace one hidden SSH transport and reverse tunnel while every visible terminal tab uses an independent multiplexed SSH client channel.

**Architecture:** `SSHTransportSession` owns the `ssh -N` master process, its private control socket, readiness polling, bounded diagnostics, and teardown. `AppModel` owns a transport per workspace and only creates `TerminalPaneModel` clients after that transport is ready; its existing startup and fresh-status Fibonacci recovery policies classify master failures. A visible client is never a transport owner, so closing or retrying one tab cannot bring down its siblings or notification tunnel.

**Tech Stack:** Swift 5.9, SwiftPM/XCTest, Foundation `Process`/`Pipe`, SwiftUI, libghostty terminal panes, OpenSSH ControlMaster.

## Global Constraints

- Keep DevSpaceDev and DevSpace independent: their bundle channels use distinct listener/reverse-forward ports and never share a control socket.
- Control directories must be private, short-path, instance-unique, and only cleaned up after owner identity is proven dead.
- The hidden master uses `-N`, `ControlMaster=yes`, `ControlPersist=no`, `ExitOnForwardFailure=yes`, the validated DevPod `ProxyCommand`, and the only `-R` forward.
- Visible clients use the exact master `ControlPath`, `ControlMaster=no`, `ControlPersist=no`, `-tt`, and no `-R`.
- A master is ready only after `ssh -O check` succeeds; a 15-second pre-ready deadline is an initial-start failure.
- Master disruption retains the visible-tab count and selected index, then runs fresh-status recovery at 3, 5, 8, 13, and 21 seconds; stopped workspaces are never SSH'd automatically.
- An ordinary process in an interrupted client PTY is not resumed. Recovery creates fresh shells; users who need continuity use a remote detachment mechanism such as tmux.
- Client-only nonzero exits retry the client at 0.5 then 1.5 seconds while the master is ready; exhaustion presents a Retry/Close failed-tab state.
- Work only on `feat/multiplex-ssh-terminal-tabs`; do not use a worktree, per repository instructions.

---

## File structure

- `Sources/Core/SSH.swift` — builds separately testable master, client, and control-check SSH argv from one validated configuration.
- `Sources/Core/SSHTransportSession.swift` — private-directory lease, owner metadata, Process/Pipe lifecycle, readiness check/deadline, and generation-filtered callbacks.
- `Tests/Core/SSHTests.swift` — argument and dev/prod control-path isolation assertions.
- `Tests/Core/SSHTransportSessionTests.swift` — deterministic fake process/check/clock coverage for readiness, cleanup, ownership, output draining, and stale events.
- `Sources/App/AppModel.swift` — owns workspace transport sessions, opens clients after readiness, coordinates tab and master recovery, and exposes client failure state.
- `Sources/App/TerminalPane.swift` — exposes the spawned SSH argv to app tests, represents a failed client slot without starting a PTY, and exposes its retry/close actions to the view.
- `Sources/App/ContentView.swift` — renders a failed terminal tab instead of a Ghostty surface.
- `Tests/App/ConnectionTimingTests.swift` — injects a manual transport factory and verifies AppModel lifecycle/recovery behavior.

### Task 1: Define multiplexed SSH argv

**Files:**
- Modify: `Sources/Core/SSH.swift`
- Modify: `Tests/Core/SSHTests.swift`

**Interfaces:**
- Produces `SSH.masterArgs(podID:proxyCommand:controlPath:bundleIdentifier:) -> [String]`.
- Produces `SSH.clientArgs(podID:proxyCommand:controlPath:bundleIdentifier:) -> [String]`.
- Produces `SSH.controlCheckArgs(controlPath:) -> [String]` and `SSH.controlExitArgs(controlPath:) -> [String]`.
- Removes the ambiguous `tunnel` boolean from new callers; only the master function is permitted to add `-R`.

- [ ] **Step 1: Write failing core tests for master/client argument separation**

```swift
func testMasterOwnsReverseTunnelAndControlSocket() {
    let args = SSH.masterArgs(podID: "wc-1", proxyCommand: "devpod ssh --stdio wc-1", controlPath: "/tmp/ds/socket", bundleIdentifier: "com.prakharp.devspace")
    XCTAssertTrue(args.contains("-N"))
    XCTAssertTrue(args.contains("ControlMaster=yes"))
    XCTAssertTrue(args.contains("ControlPersist=no"))
    XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
    XCTAssertTrue(args.contains("8765:localhost:17865"))
    XCTAssertTrue(args.contains("ControlPath=/tmp/ds/socket"))
}

func testClientUsesExistingControlSocketWithoutReverseTunnel() {
    let args = SSH.clientArgs(podID: "wc-1", proxyCommand: "devpod ssh --stdio wc-1", controlPath: "/tmp/ds/socket")
    XCTAssertTrue(args.contains("-tt"))
    XCTAssertTrue(args.contains("ControlMaster=no"))
    XCTAssertTrue(args.contains("ControlPath=/tmp/ds/socket"))
    XCTAssertFalse(args.contains("-R"))
}
```

- [ ] **Step 2: Run the targeted tests and verify they fail because the new APIs are absent**

Run: `swift test --filter SSHTests/testMasterOwnsReverseTunnelAndControlSocket`

Expected: compile failure naming `masterArgs`.

- [ ] **Step 3: Implement one shared option builder and the explicit APIs**

```swift
public static func masterArgs(
    podID: String,
    proxyCommand: String?,
    controlPath: String,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier
) -> [String] {
    commonArgs(podID: podID, proxyCommand: proxyCommand, bundleIdentifier: bundleIdentifier)
        + ["-N", "-o", "ControlMaster=yes", "-o", "ControlPersist=no",
           "-o", "ControlPath=\\(controlPath)", "-o", "ExitOnForwardFailure=yes",
           "-R", reverseForward(bundleIdentifier: bundleIdentifier), "\\(podID).devpod"]
}

public static func clientArgs(
    podID: String,
    proxyCommand: String?,
    controlPath: String,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier
) -> [String] {
    commonArgs(podID: podID, proxyCommand: proxyCommand, bundleIdentifier: bundleIdentifier)
        + ["-tt", "-o", "ControlMaster=no", "-o", "ControlPersist=no",
           "-o", "ControlPath=\\(controlPath)", "\\(podID).devpod"]
}
```

Keep `SetEnv` in both command types so every interactive shell gets its build-specific pod forward variable; only the master binds the remote port.

- [ ] **Step 4: Run the core SSH tests and verify they pass**

Run: `swift test --filter SSHTests`

Expected: all SSH argument tests pass, including existing dev/prod port tests.

- [ ] **Step 5: Commit the isolated argv change**

```bash
git add Sources/Core/SSH.swift Tests/Core/SSHTests.swift
git commit -m "feat: add multiplexed ssh arguments"
```

### Task 2: Build a testable hidden-master transport controller

**Files:**
- Create: `Sources/Core/SSHTransportSession.swift`
- Create: `Tests/Core/SSHTransportSessionTests.swift`

**Interfaces:**
- Produces `public final class SSHTransportSession` with `start()`, `stop()`, `state`, `controlPath`, and callbacks `onReady`, `onExit`, `onStartError`.
- Consumes `SSHTransportLaunching`, `SSHTransportChecking`, and `SSHTransportScheduling` protocols so tests do not start real SSH processes.
- Produces `SSHTransportOwner` metadata and `SSHTransportControlDirectory` lease validation/cleanup helpers.

- [ ] **Step 1: Write failing transport lifecycle tests**

```swift
func testReadyRequiresSuccessfulControlCheck() {
    let harness = TransportHarness(checkResults: [.failure, .success])
    let session = harness.makeSession()
    var ready = 0
    session.onReady = { ready += 1 }
    session.start()
    harness.fireCheck()
    XCTAssertEqual(ready, 0)
    harness.fireCheck()
    XCTAssertEqual(ready, 1)
}

func testReadinessDeadlineTerminatesUnreadyMasterOnce() {
    let harness = TransportHarness(checkResults: [.failure])
    let session = harness.makeSession()
    var error: SSHTransportSession.StartError?
    session.onStartError = { error = $0 }
    session.start()
    harness.fireDeadline()
    XCTAssertEqual(error, .readinessTimedOut)
    XCTAssertEqual(harness.process.terminateCount, 1)
}
```

Also add tests that an unmatched/live owner is never removed, a proven-dead matching owner is sent control-exit then cleaned, a stale ready/exit callback is ignored after `stop()`, stdout/stderr readers continuously drain and stderr retains only the configured tail, and dev/prod instance directory names differ.

- [ ] **Step 2: Run the new transport test target and verify it fails because the controller is absent**

Run: `swift test --filter SSHTransportSessionTests/testReadyRequiresSuccessfulControlCheck`

Expected: compile failure naming `SSHTransportSession`.

- [ ] **Step 3: Implement deterministic dependencies and controller state transitions**

```swift
public enum SSHTransportState: Equatable { case idle, starting, ready, stopping, exited }

public final class SSHTransportSession {
    public func start() {
        let generation = beginStartingGeneration()
        launchMaster(for: generation)
        scheduleReadinessCheck(for: generation)
        scheduleReadinessDeadline(for: generation)
    }

    public func stop() {
        let generation = invalidateGeneration()
        requestControlExit(for: generation)
        terminateMaster(for: generation)
        removeOwnedLease(for: generation)
    }
}
```

Generate the lease under `NSTemporaryDirectory()/devspace-ssh/<build-channel>/<launch-id>/<short-hash>`, create it with mode `0700`, and write JSON owner metadata atomically. Capture the process generation in all scheduled checks, deadline handling, and termination callbacks. Start `Pipe` readability handlers before launching; discard stdout and append only the last 8 KiB of stderr. On a ready master exit call `onExit`; on a pre-ready error or deadline call `onStartError` exactly once.

- [ ] **Step 4: Run all transport-controller tests and core suite**

Run: `swift test --filter SSHTransportSessionTests && swift test --filter SSHTests`

Expected: every controller and SSH test passes.

- [ ] **Step 5: Commit the transport controller**

```bash
git add Sources/Core/SSHTransportSession.swift Tests/Core/SSHTransportSessionTests.swift Sources/Core/SSH.swift Tests/Core/SSHTests.swift
git commit -m "feat: manage multiplexed ssh transports"
```

### Task 3: Replace primary-pane transport ownership in AppModel

**Files:**
- Modify: `Sources/App/AppModel.swift`
- Modify: `Tests/App/ConnectionTimingTests.swift`

**Interfaces:**
- Consumes `SSHTransportSession` through `SSHTransportSessionCreating` injected into `AppModel.init`.
- Produces one `SSHTransportSession` in `transports[id]` while a workspace is opened.
- Produces `openClient(id:proxyCommand:)`, `masterReady(id:generation:)`, and `masterExited(id:generation:exitCode:)` lifecycle handlers.
- Produces `RecoverySnapshot(tabCount: Int, activeIndex: Int)` retained only across unexpected ready-master exit.
- Produces `TerminalPaneModel.commandArguments` with internal read access so app tests can assert that each visible pane is a multiplex client.

- [ ] **Step 1: Write failing AppModel tests with a manual transport factory**

```swift
func testMasterReadinessCreatesInitialClientWithoutReverseTunnel() {
    let transport = ManualTransport()
    let model = makeModel(transportFactory: transport.factory)
    model.connect("wc-1")
    transport.succeedReady()
    XCTAssertEqual(model.panes["wc-1"]?.count, 1)
    XCTAssertFalse(model.panes["wc-1"]!.first!.commandArguments.contains("-R"))
    XCTAssertTrue(model.panes["wc-1"]!.first!.commandArguments.contains("ControlMaster=no"))
}

func testMasterExitRestoresTabCountAndSelectedIndexAfterFreshStatus() async {
    let transport = ManualTransport()
    let model = makeEstablishedTwoTabModel(transport: transport)
    model.setActivePane("wc-1", paneID: model.panes["wc-1"]![1].id)
    transport.exitReadyMaster(255)
    retryScheduler.fireNext()
    statusResolver.completeRunning()
    transport.succeedReady()
    XCTAssertEqual(model.panes["wc-1"]?.count, 2)
    XCTAssertEqual(model.activePane["wc-1"], model.panes["wc-1"]?[1].id)
}
```

Add tests for closing the first visible tab retaining master plus second client; closing the final tab stops master; stopped fresh status stops recovery; transport start failure uses the existing 0.5/1.5 startup policy; and a late master callback after disconnect/stop/delete/recreate is ignored.

- [ ] **Step 2: Run a targeted AppModel test and verify it fails for lack of transport injection**

Run: `swift test --filter ConnectionTimingTests/testMasterReadinessCreatesInitialClientWithoutReverseTunnel`

Expected: compile failure naming the injected factory or new master lifecycle API.

- [ ] **Step 3: Integrate master state with existing connection/recovery state**

Replace `openResolvedSSH` with: resolve proxy → construct/store master transport → call `start()` → create first client only from `onReady`. Keep `sshStartupPanes`/handoff logic for the first *client* output, but use master readiness—not client output—to classify master establishment. On master exit, nil every client `onExit`, terminate clients, save count/index, and route to existing `scheduleDisruptionRecovery`; on recovery `Running`, start a new master and recreate exactly the saved slots. All lifecycle invalidation helpers must also call `transports[id]?.stop()`, remove the transport, clear snapshot, and increment/clear its generation before terminating panes.

Make `reload` replace only the active multiplex client with a new client through the ready transport. Make `newTerminal` create only a client through the ready transport; it must never invoke a second proxy-resolution/SSH transport.

- [ ] **Step 4: Run targeted AppModel connection tests**

Run: `swift test --filter ConnectionTimingTests`

Expected: existing startup/disruption tests and the new master lifecycle tests pass.

- [ ] **Step 5: Commit the AppModel transport integration**

```bash
git add Sources/App/AppModel.swift Tests/App/ConnectionTimingTests.swift
git commit -m "feat: recover multiplexed terminal transports"
```

### Task 4: Add client-slot retry and failure presentation

**Files:**
- Modify: `Sources/App/TerminalPane.swift`
- Modify: `Sources/App/AppModel.swift`
- Modify: `Sources/App/ContentView.swift`
- Modify: `Tests/App/ConnectionTimingTests.swift`

**Interfaces:**
- Produces `TerminalPaneModel.failure: TerminalClientFailure?` and `TerminalPaneModel.failedSlot(message:onRetry:onClose:)`.
- Produces `AppModel.retryClient(id:paneID:)` and client retry bookkeeping keyed by pane UUID plus generation.
- `ContentView` consumes failed panes and renders an error panel with Retry and Close actions rather than `TerminalPaneView`.

- [ ] **Step 1: Write failing tests for an isolated client failure**

```swift
func testClientFailureRetriesOnlyThatSlotAndKeepsMasterReady() {
    let model = makeEstablishedTwoTabModel()
    let failed = model.panes["wc-1"]![1]
    failed.onExit?(255)
    XCTAssertEqual(retryScheduler.scheduled.map(\.delay), [0.5])
    XCTAssertEqual(transport.stopCount, 0)
    retryScheduler.fireNext()
    XCTAssertEqual(model.panes["wc-1"]?.count, 2)
}

func testExhaustedClientFailureShowsRetryableFailedTab() {
    let model = makeEstablishedTwoTabModel()
    failClientTwiceThenFireRetries(model)
    XCTAssertNotNil(model.panes["wc-1"]![1].failure)
    XCTAssertTrue(model.opened.contains("wc-1"))
}
```

- [ ] **Step 2: Run the targeted tests and verify they fail because client retries/failure slots do not exist**

Run: `swift test --filter ConnectionTimingTests/testClientFailureRetriesOnlyThatSlotAndKeepsMasterReady`

Expected: assertion failure because the current code simply removes the extra pane.

- [ ] **Step 3: Implement client-only retry and UI**

When a nonzero client exit occurs while its master is ready, replace that pane at the same list position with a retrying/failed slot carrying a generation. Schedule 0.5 then 1.5 seconds; valid retries replace the slot with a fresh multiplex client. A clean client exit and explicit close remove only its slot. Cancel client retry handles when a master exits or any explicit workspace teardown begins. Render a failed slot with its diagnostic and `Retry`/`Close`, and keep the tab selectable so its user can act on it.

- [ ] **Step 4: Run the focused UI-model tests and full app test target**

Run: `swift test --filter ConnectionTimingTests && swift test --filter DevSpaceAppTests`

Expected: client slots retry without direct SSH/master recovery; all app tests pass.

- [ ] **Step 5: Commit the client failure path**

```bash
git add Sources/App/TerminalPane.swift Sources/App/AppModel.swift Sources/App/ContentView.swift Tests/App/ConnectionTimingTests.swift
git commit -m "feat: recover failed multiplex ssh clients"
```

### Task 5: Full verification and development-bundle smoke test

**Files:**
- Modify: `docs/superpowers/plans/2026-09-16-multiplex-ssh-terminal-tabs.md` (mark completed steps only after evidence exists)

- [ ] **Step 1: Inspect the final diff for unintended production-bundle or port changes**

Run: `git diff main...HEAD -- Sources/Core/SSH.swift Sources/Core/SSHTransportSession.swift Sources/App/AppModel.swift Sources/App/TerminalPane.swift Sources/App/ContentView.swift Tests`

Expected: only multiplex transport, client lifecycle, and their tests are changed; development/production listener port mapping remains 17866/8766 and 17865/8765 respectively.

- [ ] **Step 2: Run the complete unit suite**

Run: `make test`

Expected: exit 0 with all DevSpaceCore and DevSpaceApp tests passing.

- [ ] **Step 3: Build the development app only**

Run: `make build-dev`

Expected: exit 0 and `build/DevSpaceDev.app` exists. Do not run `make build` or quit the installed production app.

- [ ] **Step 4: Smoke-test with DevSpaceDev while production remains running**

Run: `open "build/DevSpaceDev.app"`

Expected: connect one running workspace, open two tabs, close the first tab, observe the second remains usable, then disconnect. Confirm the development app uses only the development tunnel port.

- [ ] **Step 5: Commit the checked plan state if any checkboxes changed**

```bash
git add docs/superpowers/plans/2026-09-16-multiplex-ssh-terminal-tabs.md
git commit -m "docs: record multiplex ssh verification"
```
