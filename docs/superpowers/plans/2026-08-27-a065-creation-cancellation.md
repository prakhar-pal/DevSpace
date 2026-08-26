# A065 Creation Cancellation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app-wide DevPod creation terminal dismissible while a command or post-create discovery is still active.

**Architecture:** Add one explicit `AppModel.cancelActiveCreation()` transition that restores the pre-create selection and clears the transient pane through the existing callback-detaching cleanup path. Present that transition as a visible Cancel button in the active creation header, while retaining the existing Close action after failure and leaving all terminal keyboard routing unchanged.

**Tech Stack:** Swift 5.9, SwiftUI, SwiftPM/XCTest, libghostty-backed `TerminalPaneModel`.

## Global Constraints

- The embedded terminal continues to own Escape and every other keyboard input.
- Cancel is available while creation or post-create discovery remains active.
- Cancel detaches the PTY exit callback before terminating the local process.
- A late completion callback cannot recreate creation or failure state.
- Failure output remains visible until the existing Close action is used.
- Work on `feat/a065-devpod-lifecycle`; do not create a worktree.
- Use only `make test` and `make build-dev`; never build or stop the production `DevSpace.app`.

---

### Task 1: Active Creation Cancellation Transition

**Files:**
- Modify: `Tests/App/DevpodLifecycleTests.swift`
- Modify: `Sources/App/AppModel.swift`

**Interfaces:**
- Consumes: existing `creationPreviousSelection`, `creationPhase`, `creationPane`, and `clearCreationSession()`.
- Produces: `AppModel.cancelActiveCreation()` with no parameters and no return value.

- [ ] **Step 1: Write the failing cancellation regression**

Add this test to `DevpodLifecycleTests`:

```swift
func testCancellingActiveCreationRestoresSelectionAndIgnoresLateExit() {
    let model = makeModel(ids: ["wc-1", "wc-2"])
    model.selectedID = "wc-1"
    model.beginCreation()
    model.submitCreation(
        repositoryURL: "https://github.com/acme/new.git",
        devpodID: ""
    )
    let lateExit = model.creationPane?.onExit
    model.selectedID = "wc-2"

    model.cancelActiveCreation()

    XCTAssertEqual(model.selectedID, "wc-1")
    XCTAssertNil(model.creationPane)
    XCTAssertNil(model.creationPhase)

    lateExit?(1)
    XCTAssertNil(model.creationPane)
    XCTAssertNil(model.creationPhase)
}
```

This catches a missing cancellation transition, failure to restore selection,
and failure to detach/neutralize a completion retained before cancellation.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter DevpodLifecycleTests.testCancellingActiveCreationRestoresSelectionAndIgnoresLateExit
```

Expected: compilation fails because `cancelActiveCreation()` does not exist.

- [ ] **Step 3: Implement the minimal model transition**

Add beside `dismissCreationFailure()`:

```swift
func cancelActiveCreation() {
    guard creationPhase == .running else { return }
    selectedID = creationPreviousSelection
    clearCreationSession()
}
```

`clearCreationSession()` already nils `creationPane.onExit` before terminating
the PTY, then clears all discovery state. Keep that ordering unchanged.

- [ ] **Step 4: Run lifecycle tests and verify GREEN**

Run:

```bash
swift test --filter DevpodLifecycleTests
```

Expected: every lifecycle test passes with zero failures.

- [ ] **Step 5: Commit the model transition**

```bash
git add Sources/App/AppModel.swift Tests/App/DevpodLifecycleTests.swift
git commit -m "fix: cancel active devpod creation"
```

---

### Task 2: Always-Available Header Action

**Files:**
- Modify: `Sources/App/ContentView.swift`
- Modify: `Tests/App/ShortcutTests.swift`

**Interfaces:**
- Consumes: `AppModel.cancelActiveCreation()` from Task 1 and existing `dismissCreationFailure()`.
- Produces: a creation header with Cancel during `.running` and Close during `.failed`.

- [ ] **Step 1: Add the terminal-input characterization**

Extend `testA065SheetsOwnAppShortcuts` after creation starts:

```swift
let escape = keyEvent(characters: "\u{1b}", modifiers: [])
XCTAssertFalse(model.handleTerminalKeyEquivalent(escape))
XCTAssertEqual(model.creationPhase, .running)
XCTAssertNotNil(model.creationPane)
```

Expected: this passes before the UI change, proving the existing terminal route
does not map Escape to cancellation. It is a characterization guard, not the
red test for the model transition.

- [ ] **Step 2: Give `logHeader` a configurable action label**

Change its signature and button:

```swift
private func logHeader(
    _ text: String,
    actionTitle: String = "Close",
    onClose: (() -> Void)? = nil
) -> some View {
    HStack {
        Text(text).font(.system(size: 12))
        Spacer()
        if let onClose {
            Button(actionTitle, action: onClose)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color(white: 0.1))
    .overlay(Divider(), alignment: .bottom)
}
```

Existing recreate and terminal callers retain the default Close label.

- [ ] **Step 3: Wire Cancel into the running creation header**

Replace the actionless active header with:

```swift
logHeader(
    "Creating workspace…",
    actionTitle: "Cancel",
    onClose: model.cancelActiveCreation
)
```

Keep the failed branch as:

```swift
logHeader("Creation failed", onClose: model.dismissCreationFailure)
```

- [ ] **Step 4: Run focused UI-policy and lifecycle tests**

Run:

```bash
swift test --filter DevpodLifecycleTests
swift test --filter ShortcutTests.testA065SheetsOwnAppShortcuts
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 5: Commit the header action**

```bash
git add Sources/App/ContentView.swift Tests/App/ShortcutTests.swift
git commit -m "fix: expose creation cancellation"
```

---

### Task 3: Verification and Stack Update

Before final verification, independent review adds two required regressions:

- Tag each creation PTY exit and asynchronous discovery refresh with a UUID
  generation. Cancellation clears that generation; callbacks from an older
  generation return before mutating poll revisions or creation state.
- Make `PTYSession.terminate()` initiate the existing `waitpid` path. Guard
  reaping under the PTY lock so EOF and explicit termination report exactly one
  exit and never leave the terminated child as a zombie.

These corrections are covered by a canceled-A/active-B late-exit lifecycle test
and a real `/bin/sleep` PTY termination test.

**Files:**
- Verify only; no planned production edits.

**Interfaces:**
- Consumes: completed Tasks 1 and 2.
- Produces: a verified dev bundle and updated A065 PR #99.

- [ ] **Step 1: Run whitespace verification**

```bash
git diff --check
```

Expected: exit 0 with no output.

- [ ] **Step 2: Run the full test suite**

```bash
make test
```

Expected: all tests pass with zero failures.

- [ ] **Step 3: Build the development bundle**

```bash
make build-dev
```

Expected: `build/DevSpaceDev.app` is assembled successfully.

- [ ] **Step 4: Review the scoped diff and branch state**

```bash
git status --short
git log --oneline feat/dide-zed-folder..HEAD
gh stack view
```

Expected: only intentional A065 commits appear above the DIDE parent, the
working tree is clean, and A065 remains the upper PR in stack #100.

- [ ] **Step 5: Resubmit the stack**

```bash
gh stack submit --auto --open
```

Expected: PR #99 is updated and remains based on `feat/dide-zed-folder`.
