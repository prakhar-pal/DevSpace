# Connect experience

## Scope

This document records the connected-workspace changes approved on 2026-08-17:
the Connect loading state, latency diagnostics, and the sidebar Disconnect
action.

## Connect loading state — implemented

`AppModel.opened` represents both an opening and an active SSH session. While
an ID is opened but has no terminal pane, the status card shows a disabled
**Connecting…** button with an indeterminate spinner; Stop remains available.
The Connecting/Stop row takes precedence over transient `Loading`, `Unknown`,
and `Busy` poll states so Start cannot appear during setup. Once the pane is
created, the already-mounted terminal replaces the card once its handoff
resolves; normal lifecycle cleanup restores
Connect if setup ends early.

Tests cover idle, opening, pane-ready, and transient poll-state cases.

## Connection latency diagnostics — implemented

Debug builds log generic, privacy-safe phase timings for every connection:

```text
connect pod=<workspace-id> phase=<phase> elapsed_ms=<milliseconds>
```

Phases are `requested`, `ssh-pane-mounted`, `ssh-pty-started`,
`hook-started`, `hooks-finished`, `shell-integration-finished`,
`shell-integration-timeout`, `remote-shell-restarted`, and
`terminal-revealed`. The workspace ID is a correlation field for concurrent
connections; logging is not limited to a particular workspace. Lines contain
no tokens, settings contents, or remote command payloads.

Claude settings and notification-hook injection runs in parallel with shell
integration and never blocks terminal creation. Shell integration runs in
parallel with initial SSH too; DevSpace holds the mounted terminal behind the
Connecting card only until the integration handoff completes or times out.
Either successful setup route confirms SSH for notification gating.

### Concurrent terminal and shell-integration handoff — approved

The primary SSH terminal and the shell-integration write will start together.
DevSpace keeps the terminal pane hidden behind **Connecting…** until the
write completes. If the original SSH session has already begun, DevSpace
restarts the remote interactive shell inside that same SSH session; the new
shell then sources the OSC 7 block without rebinding the reverse notification
tunnel. If the write completes before the initial SSH session produces output,
DevSpace reveals the original session without a restart. If the write fails or
does not finish within ten seconds, DevSpace reveals the original terminal
unchanged; directory tracking is unavailable for that session but a usable
shell is never blocked. Claude hooks remain independent background work.

Tests must cover the no-restart outcome, the restart-after-early-SSH outcome,
and the injection-failure/timeout fallback. Diagnostics will distinguish SSH
launch, the integration write, remote-shell restart, and the first pane made
visible.

## Concurrent terminal and shell-integration handoff Implementation Plan

> **For agentic workers:** Execute each task with a fresh red-green test cycle.

**Goal:** Remove shell-integration injection from the terminal launch critical
path while preserving OSC 7 setup for the visible primary shell whenever the
write succeeds.

**Architecture:** `AppModel` will mount the primary terminal immediately so
its lazy layout starts SSH, but retain an explicit pending-integration state so
`ContentView` keeps it transparent and displays the existing Connecting card.
The first PTY output marks that the original SSH session has reached the
remote side. When integration completes, a successful write either reveals the
original terminal (no output yet) or restarts the remote shell in that same
SSH session (output arrived first). A failed or timed-out write reveals the
original terminal. Claude hook injection is unchanged and independent.

**Tech stack:** Swift 6, SwiftUI, libghostty, host-managed `PTYSession`,
SwiftPM/XCTest.

### Global constraints

- Launch only `build/DevSpaceDev.app`; do not build or close `DevSpace.app`.
- Never block a usable terminal if shell integration fails.
- Preserve the primary terminal's reverse notification tunnel by never
  replacing its SSH process; keep extra-terminal behavior unchanged.
- Preserve the existing workspace-id timing log format and do not log tokens
  or remote command payloads.
- Do not commit or push changes.

### Task 1: Model the handoff decision

**Files:**

- Modify: `Sources/App/AppModel.swift`
- Modify: `Tests/App/ConnectionTimingTests.swift`

**Interfaces:**

- Produce `AppModel.TerminalHandoffAction` with cases
  `.revealOriginal` and `.restartRemoteShellThenReveal`.
- Produce `AppModel.terminalHandoffAction(integrationSucceeded:sshProducedOutput:)`.

- [ ] **Step 1: Write failing decision tests**

```swift
func testIntegrationCompletingBeforeSSHOutputRevealsOriginalTerminal() {
    XCTAssertEqual(
        AppModel.terminalHandoffAction(
            integrationSucceeded: true,
            sshProducedOutput: false
        ),
        .revealOriginal
    )
}

func testIntegrationCompletingAfterSSHOutputRestartsRemoteShell() {
    XCTAssertEqual(
        AppModel.terminalHandoffAction(
            integrationSucceeded: true,
            sshProducedOutput: true
        ),
        .restartRemoteShellThenReveal
    )
}

func testFailedIntegrationRevealsOriginalTerminal() {
    XCTAssertEqual(
        AppModel.terminalHandoffAction(
            integrationSucceeded: false,
            sshProducedOutput: true
        ),
        .revealOriginal
    )
}
```

- [ ] **Step 2: Run the focused test and verify it fails because the action
  type/function is absent**

Run: `swift test --filter ConnectionTimingTests`

- [ ] **Step 3: Add the minimal equatable action and pure decision function**

```swift
enum TerminalHandoffAction: Equatable {
    case revealOriginal
    case restartRemoteShellThenReveal
}

static func terminalHandoffAction(
    integrationSucceeded: Bool,
    sshProducedOutput: Bool
) -> TerminalHandoffAction {
    integrationSucceeded && sshProducedOutput
        ? .restartRemoteShellThenReveal
        : .revealOriginal
}
```

- [ ] **Step 4: Re-run the focused test and verify all decision cases pass**

### Task 2: Start SSH concurrently and resolve the hidden terminal

**Files:**

- Modify: `Sources/App/AppModel.swift`
- Modify: `Sources/App/TerminalPane.swift`
- Modify: `Tests/App/ConnectionTimingTests.swift`

**Interfaces:**

- Consume `TerminalHandoffAction` from Task 1.
- Add `TerminalPaneModel.onFirstOutput`, called once on the main actor before
  terminal data is delivered to Ghostty.
- Add `AppModel.isTerminalVisible(_:)` and pending-state cleanup to the normal
  disconnect, stop, exit, and replacement paths.

- [ ] **Step 1: Write failing state-predicate tests**

```swift
func testConnectingIncludesMountedTerminalAwaitingIntegration() {
    XCTAssertTrue(AppModel.isConnecting(
        isOpened: true,
        hasPanes: true,
        isAwaitingShellIntegration: true
    ))
}

func testMountedTerminalIsVisibleAfterIntegrationHandoff() {
    XCTAssertTrue(AppModel.isTerminalVisible(isAwaitingShellIntegration: false))
    XCTAssertFalse(AppModel.isTerminalVisible(isAwaitingShellIntegration: true))
}
```

- [ ] **Step 2: Run the focused test and verify the new predicates are absent**

Run: `swift test --filter ConnectionTimingTests`

- [ ] **Step 3: Implement the minimal lifecycle wiring**

```swift
// AppModel state
private var awaitingShellIntegration: Set<String> = []
private var sshProducedOutput: Set<String> = []

// openSSHIfNeeded
awaitingShellIntegration.insert(id)
let pane = makeTerminal(id, tunnel: true)
pane.onFirstOutput = { [weak self, paneID = pane.id] in
    self?.primarySSHProducedOutput(id, paneID: paneID)
}
setPanes(id, [pane])                 // mounts and starts SSH immediately
injectShellIntegration(id, startedAt: attemptStartedAt) { success in
    self?.resolveShellIntegration(id, succeeded: success)
}
```

`primarySSHProducedOutput` records output only when `paneID` is still the
primary pending pane. `resolveShellIntegration` first re-checks that the
workspace remains opened and pending. It then uses the Task 1 decision:

- `.revealOriginal`: remove the pending state and log `terminal-revealed`.
- `.restartRemoteShellThenReveal`: send the existing remote interactive shell
  a terminal-reset plus `exec "${SHELL:-/bin/sh}" -i` command, clear pending
  state, and log `remote-shell-restarted` then `terminal-revealed`. The SSH
  process and its reverse tunnel stay alive.

`injectShellIntegration` reports its actual success to this resolver rather
than treating completion as success, begins immediately (no scheduled delay),
and gets a ten-second pane-identity-bound fail-open callback. Emit
`ssh-pane-mounted`, `ssh-pty-started`, `shell-integration-finished`,
`remote-shell-restarted`, and `terminal-revealed` timing phases. Clear both
sets in `disconnect`, `closePane`,
the final-pane exit path, stop, and workspace deletion so a stale callback
cannot reveal or replace a later session.

- [ ] **Step 4: Re-run the focused tests and verify them green**

### Task 3: Keep the prewarmed terminal hidden until handoff completes

**Files:**

- Modify: `Sources/App/ContentView.swift`
- Modify: `Sources/App/AppModel.swift`
- Modify: `Tests/App/ActionPanelTests.swift`

**Interfaces:**

- Consume `AppModel.isTerminalVisible(_:)` and the expanded
  `AppModel.isConnecting(...)` predicate from Task 2.

- [ ] **Step 1: Write a failing ActionPanel state test**

```swift
func testMountedTerminalAwaitingIntegrationStillShowsConnecting() {
    XCTAssertEqual(
        ActionPanel.connectionAction(
            workspaceState: "Running",
            isConnecting: AppModel.isConnecting(
                isOpened: true,
                hasPanes: true,
                isAwaitingShellIntegration: true
            )
        ),
        .connecting
    )
}
```

- [ ] **Step 2: Run the focused test and verify it fails until the predicate
  wiring is complete**

Run: `swift test --filter ActionPanelTests`

- [ ] **Step 3: Make the SwiftUI handoff invisible to the user**

Keep pending terminal views mounted so Ghostty receives a viewport and starts
their PTY, but give a pending workspace zero opacity and no hit testing.
Continue showing `ActionPanelView` while `model.isConnecting(selectedID)` is
true even though its pane array is populated. Suppress focus movement and
terminal keyboard shortcuts until `isTerminalVisible` is true. Once the model
resolves the handoff, SwiftUI reveals the existing pane normally.

- [ ] **Step 4: Re-run ActionPanel tests and then the full suite**

Run: `make test`

### Task 4: Build and measure the dev handoff

**Files:**

- Modify only if needed after measurement: the same files from Tasks 1–3.

- [ ] **Step 1: Verify formatting and a fresh dev build**

Run: `git diff --check && make build-dev`

- [ ] **Step 2: Launch only the rebuilt dev bundle**

Run: `open "build/DevSpaceDev.app"`

- [ ] **Step 3: Measure a manual `wc-2` Connect attempt**

Run after the click: `rg 'connect pod=wc-2 ' .tmp/devspace.log | tail -n 12`

Report click-to-`ssh-pty-started`, click-to-`terminal-revealed`, whether a
remote-shell restart occurred, and the user-visible click-to-zsh-prompt
stopwatch.

For a manual measurement, use only `DevSpaceDev.app`, filter
`.tmp/devspace.log` for its connection lines, and report the timing phases
alongside a click-to-zsh-prompt stopwatch. This instrumentation does not itself
detect first remote-prompt readiness.

## Sidebar Disconnect — implemented

**Disconnect** appears immediately above **Reload SSH Session** in the sidebar
overflow menu only when the workspace has an actual open terminal PTY: its ID
is in `opened` and its pane list is non-empty. It does not appear during the
hidden Connecting handoff or for disconnected/stopped workspaces.

The action uses the existing session teardown path: it closes all terminal
panes, removes the open-session intent, and returns to the Connect card. It
does not stop the DevPod or modify the workspace state.

The focused menu-visibility test covers an open PTY, an opening session, and
an idle workspace.
