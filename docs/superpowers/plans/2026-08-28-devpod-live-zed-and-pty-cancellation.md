# DevPod Live Zed and PTY Cancellation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow Open in Zed only for operationally live DevPods and make PTY termination permanently prevent lazy startup.

**Architecture:** Centralize Zed eligibility in `AppModel.canOpenInZed(_:)`, derived from the latest `Running` status plus the workspace lifecycle sets, and consume it from UI, shortcuts, DIDE, and the model action. Replace `PTYSession`'s one-way `started` Boolean with a lock-protected idle/running/terminated lifecycle so termination before first resize makes every later start a no-op.

**Tech Stack:** Swift 5.9, SwiftUI, SwiftPM/XCTest, Darwin PTY APIs, libghostty-backed `TerminalPaneModel`.

## Global Constraints

- Open in Zed requires status exactly `Running` and no active start, stop, or recreate transition.
- The model-level action is the final enforcement boundary; UI and shortcut policy must agree with it.
- DIDE requests use the same model-level live-workspace guard.
- `PTYSession.terminate()` is irreversible before or after `start()`.
- Running PTY children remain signalled and reaped exactly once.
- Use test-first red/green cycles.
- Use only `make test` and `make build-dev`; never build or stop production `DevSpace.app`.
- Work in the current feature branch; do not create a worktree.

---

### Task 1: Central Live-Workspace Policy for Open in Zed

**Files:**
- Modify: `Tests/App/ActionPanelTests.swift`
- Modify: `Tests/App/ShortcutTests.swift`
- Modify: `Tests/App/SidebarTests.swift`
- Modify: `Sources/App/AppModel.swift`
- Modify: `Sources/App/Sidebar.swift`

**Interfaces:**
- Produces: `AppModel.canOpenInZed(_ id: String) -> Bool`.
- Produces: `AppShortcutState.selectedWorkspaceCanOpenInZed: Bool`.
- Consumes: `WorkspaceView.state`, `starting`, `shuttingDown`, and `recreating`.

- [ ] **Step 1: Write failing live-policy regressions**

Add model-policy assertions showing that a Running idle workspace is eligible,
while Stopped, starting, stopping, and recreating workspaces are not. Add an
inverted DIDE launch expectation after `beginRecreate`/`confirmRecreate`, and
update the shortcut fixture to express `selectedWorkspaceCanOpenInZed`:

```swift
XCTAssertEqual(AppModel.shortcutRoute(
    event: keyEvent(characters: "o"),
    state: .fixture(selectedID: "wc-1", selectedWorkspaceCanOpenInZed: false)
), .handledNoOp)
```

The production mutation these tests catch is any caller checking only cached
`state == "Running"` or bypassing the model policy.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter ActionPanelTests --filter ShortcutTests --filter SidebarTests
```

Expected: compilation fails because `canOpenInZed(_:)` and
`selectedWorkspaceCanOpenInZed` do not exist.

- [ ] **Step 3: Implement the centralized live policy**

Add to `AppModel`:

```swift
func canOpenInZed(_ id: String) -> Bool {
    byID[id]?.state == "Running"
        && !starting.contains(id)
        && !shuttingDown.contains(id)
        && !recreating.contains(id)
}
```

Guard `openInZed(_:workdir:)` with `canOpenInZed(id)`. Rename the shortcut-state
Boolean and populate it through `canOpenInZed`. Make the sidebar render Open in
Zed only when `model.canOpenInZed(workspace.id)` is true. DIDE remains routed
through `openInZed`, so it inherits the same final guard.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter ActionPanelTests --filter ShortcutTests --filter SidebarTests
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 5: Commit the live-workspace policy**

```bash
git add Sources/App/AppModel.swift Sources/App/Sidebar.swift Tests/App/ActionPanelTests.swift Tests/App/ShortcutTests.swift Tests/App/SidebarTests.swift
git commit -m "fix: restrict Zed to live devpods"
```

---

### Task 2: Irreversible PTY Termination

**Files:**
- Modify: `Tests/Core/PTYTests.swift`
- Modify: `Sources/Core/PTY.swift`

**Interfaces:**
- Produces: a private `PTYSession.Lifecycle` state with `.idle`, `.running`, and `.terminated`.
- Preserves: `start(path:args:cols:rows:extraEnv:)`, `terminate()`, and exactly-once `onExit` behavior for a running child.

- [ ] **Step 1: Write the failing terminate-before-start regression**

Add a real PTY test that installs inverted output and exit expectations, calls
`terminate()`, then attempts `/bin/echo` startup:

```swift
func testTerminateBeforeStartPreventsChildLaunch() {
    let pty = PTYSession()
    let output = expectation(description: "terminated PTY emits no output")
    output.isInverted = true
    let exited = expectation(description: "terminated PTY starts no child")
    exited.isInverted = true
    pty.onOutput = { _ in output.fulfill() }
    pty.onExit = { _ in exited.fulfill() }

    pty.terminate()
    pty.start(path: "/bin/echo", args: ["must-not-launch"], cols: 80, rows: 24)

    wait(for: [output, exited], timeout: 0.25)
}
```

The production mutation this catches is allowing `.start()` after termination.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter PTYTests.testTerminateBeforeStartPreventsChildLaunch
```

Expected: FAIL because the current idle termination is forgotten and `/bin/echo`
starts, producing output or exit.

- [ ] **Step 3: Implement the minimal lifecycle state**

Replace `started` with:

```swift
private enum Lifecycle { case idle, running, terminated }
private var lifecycle: Lifecycle = .idle
```

Under `lock`, let `start()` transition only `.idle -> .running`; all other states
return. Let `terminate()` transition `.idle` or `.running` to `.terminated`
before reading the PID/source. Mark fork failure and successful reaping
`.terminated` under the same lock. Preserve the existing `reapStarted` gate.

- [ ] **Step 4: Run PTY tests and verify GREEN**

Run:

```bash
swift test --filter PTYTests
```

Expected: terminate-before-start, real termination/reaping, normal output, and
idempotent start tests all pass.

- [ ] **Step 5: Commit irreversible termination**

```bash
git add Sources/Core/PTY.swift Tests/Core/PTYTests.swift
git commit -m "fix: prevent cancelled PTY startup"
```

---

### Task 3: Full Verification and Stack Resubmission

**Files:**
- Verify: all files changed by Tasks 1 and 2.

**Interfaces:**
- Consumes: completed live-workspace and PTY lifecycle fixes.
- Produces: clean verified DevSpaceDev bundle and updated PR #99.

- [ ] **Step 1: Run repository checks**

```bash
git diff --check
```

Expected: the whitespace check produces no findings.

- [ ] **Step 2: Run the complete test suite**

```bash
make test
```

Expected: all Swift tests pass with zero failures.

- [ ] **Step 3: Assemble the development bundle**

```bash
make build-dev
```

Expected: `build/DevSpaceDev.app` assembles successfully. Do not run `make build`.

- [ ] **Step 4: Review and resubmit the stack**

```bash
git status --short
git log --oneline feat/dide-zed-folder..HEAD
gh stack view
gh stack submit --auto --open
```

Expected: the working tree is clean, PR #99 remains above PR #98, and the stack
is synchronized on GitHub.
