# DevPod Lifecycle Log Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the selected workspace's lifecycle header and `devpod up`/stop output while preserving the connected SSH shell-integration handoff behavior.

**Architecture:** Add an `AppModel` display-visibility predicate that treats `.starting` and `.shuttingDown` as visible UI phases, and otherwise delegates to the current SSH-terminal visibility predicate. `MainPane` uses that predicate only for the whole-pane opacity and hit-testing; terminal focus and terminal-action rules stay SSH-specific.

**Tech Stack:** Swift 6, SwiftUI, XCTest, Swift Package Manager.

## Global Constraints

- Keep lifecycle commands and their completion behavior unchanged; the PTY already starts correctly.
- Keep a pending SSH shell-integration terminal mounted but hidden and non-interactive.
- Keep non-selected workspace panes hidden.
- Do not quit or build the release `DevSpace.app`; use `make test` and, if manually checked, `make build-dev` only.

---

### Task 1: Model a selected pane's display visibility

**Files:**
- Modify: `Sources/App/AppModel.swift:1086-1121`
- Modify: `Tests/App/ConnectionTimingTests.swift:97-100`

**Interfaces:**
- Produces: `static func isPaneDisplayVisible(isSelected: Bool, phase: Phase, isTerminalVisible: Bool) -> Bool`.
- Consumes: `Phase` and the existing `isTerminalVisible` handoff result.
- `ContentView.MainPane` will call the instance wrapper `isPaneDisplayVisible(_:)` in Task 2.

- [x] **Step 1: Write failing tests for lifecycle display visibility**

```swift
func testSelectedLifecyclePanesAreDisplayVisibleBeforeSSHIsReady() {
    XCTAssertTrue(AppModel.isPaneDisplayVisible(
        isSelected: true, phase: .starting, isTerminalVisible: false
    ))
    XCTAssertTrue(AppModel.isPaneDisplayVisible(
        isSelected: true, phase: .shuttingDown, isTerminalVisible: false
    ))
}

func testPaneDisplayVisibilityPreservesSelectionAndSSHHandoffRules() {
    XCTAssertFalse(AppModel.isPaneDisplayVisible(
        isSelected: false, phase: .starting, isTerminalVisible: true
    ))
    XCTAssertFalse(AppModel.isPaneDisplayVisible(
        isSelected: true, phase: .terminal, isTerminalVisible: false
    ))
    XCTAssertTrue(AppModel.isPaneDisplayVisible(
        isSelected: true, phase: .terminal, isTerminalVisible: true
    ))
}
```

- [x] **Step 2: Run the focused tests to verify they fail**

Run: `swift test --filter ConnectionTimingTests/testSelectedLifecyclePanesAreDisplayVisibleBeforeSSHIsReady --filter ConnectionTimingTests/testPaneDisplayVisibilityPreservesSelectionAndSSHHandoffRules`

Expected: compilation failure because `AppModel.isPaneDisplayVisible` does not exist.

- [x] **Step 3: Add the minimal AppModel predicate**

```swift
static func isPaneDisplayVisible(
    isSelected: Bool,
    phase: Phase,
    isTerminalVisible: Bool
) -> Bool {
    guard isSelected else { return false }
    switch phase {
    case .starting, .shuttingDown: return true
    case .terminal: return isTerminalVisible
    case .none: return false
    }
}

func isPaneDisplayVisible(_ id: String) -> Bool {
    Self.isPaneDisplayVisible(
        isSelected: id == selectedID,
        phase: phase(of: id),
        isTerminalVisible: isTerminalVisible(id)
    )
}
```

- [x] **Step 4: Run the focused tests to verify they pass**

Run: `swift test --filter ConnectionTimingTests/testSelectedLifecyclePanesAreDisplayVisibleBeforeSSHIsReady --filter ConnectionTimingTests/testPaneDisplayVisibilityPreservesSelectionAndSSHHandoffRules`

Expected: both tests pass.

### Task 2: Apply the display rule to the main pane

**Files:**
- Modify: `Sources/App/ContentView.swift:54-62`
- Test: `Tests/App/ConnectionTimingTests.swift`

**Interfaces:**
- Consumes: `AppModel.isPaneDisplayVisible(_:)` from Task 1.
- Does not change: `isTerminalVisible(_:)`, focus behavior, keyboard shortcuts, terminal key handling, or sidebar terminal actions.

- [x] **Step 1: Replace the whole-pane visibility condition**

```swift
paneContainer(pid: pid)
    .opacity(model.isPaneDisplayVisible(pid) ? 1 : 0)
    .allowsHitTesting(model.isPaneDisplayVisible(pid))
```

Update the nearby comment to say that only a pending connected SSH terminal is hidden for shell integration; lifecycle panes remain visible.

- [x] **Step 2: Run the focused regression tests**

Run: `swift test --filter ConnectionTimingTests --filter SidebarTests/testPendingHandoffBlocksReloadAndNewTerminalUntilVisible`

Expected: lifecycle display tests and the existing shell-handoff regression test pass.

- [x] **Step 3: Run the full suite**

Run: `make test`

Expected: the SwiftPM test suite exits successfully with zero failures.

- [x] **Step 4: Review the diff and commit on the feature branch**

Run: `git diff --check && git diff -- Sources/App/AppModel.swift Sources/App/ContentView.swift Tests/App/ConnectionTimingTests.swift docs/superpowers/specs/2026-08-19-devpod-starting-log-visibility-bug.md docs/superpowers/plans/2026-08-19-devpod-lifecycle-log-visibility.md`

Then commit all task files with: `git commit -m "fix: show devpod lifecycle logs"`.
