# Terminal App-Shortcut Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every DevSpace and existing application/window command shortcut executes once and cannot be swallowed by a focused embedded terminal.

**Architecture:** `AppModel` will classify an event plus one immutable snapshot into a semantic `AppShortcutRoute` and execute it through one model-owned dispatcher. A terminal-focused syntactically possible app shortcut is deferred without pasteboard access and resolved only through `DevSpaceTerminalView.performKeyEquivalent`; every other first responder is resolved only by the monitor. Tests use a recording semantic-action executor and a real AppKit event-delivery path to prove one action and no Kitty bytes.

**Tech Stack:** Swift 6, SwiftUI/AppKit, libghostty, XCTest, Swift Package Manager.

## Global Constraints

- Preserve all current shortcut semantics, including conditional text Cmd+V and out-of-range Cmd+number pass-through.
- Cmd+Q/M/H/W remain active before modal checks; every other app shortcut is unowned while rename or guide UI is open.
- Do not add shortcuts or change PTY, Ghostty, SSH, DevPod, or notification behavior.
- Terminal-first-responder routing must execute one action at most once per event and resolve pasteboard image data at most once.
- Run `make test`; do not build or quit the release bundle.

---

### Task 1: Define semantic shortcut routes and cover their policy

**Files:**
- Modify: `Sources/App/AppModel.swift:1167-1321`
- Modify: `Tests/App/ShortcutTests.swift`

**Interfaces:**
- Produces: `enum AppShortcutRoute: Equatable` with `.unhandled`, `.handledNoOp`, and `.action(AppShortcutAction)` cases.
- Produces: `enum AppShortcutAction: Equatable` with cases for sidebar toggle, reload, open-in-Zed, new terminal, image paste, visible-workspace selection, workspace movement, next tab, quit, minimize, hide, and close window.
- Produces: `static func shortcutRoute(event: NSEvent, state: AppShortcutState) -> AppShortcutRoute`.
- `AppShortcutState` supplies modal state, selected workspace, terminal visibility, workspace-running state, visible IDs, and one `PastedImage?` payload; it contains no AppKit side effects.

- [ ] **Step 1: Write failing route-policy tests**

```swift
func testCommandORoutesToOpenInZedForARunningSelectedWorkspace() {
    XCTAssertEqual(AppModel.shortcutRoute(
        event: keyEvent(characters: "o"),
        state: .fixture(selectedID: "wc-1", selectedWorkspaceIsRunning: true)
    ), .action(.openInZed("wc-1")))
}

func testCommandRConsumesAsNoOpWithoutVisibleTerminal() {
    XCTAssertEqual(AppModel.shortcutRoute(
        event: keyEvent(characters: "r"),
        state: .fixture(selectedID: "wc-1", selectedTerminalIsVisible: false)
    ), .handledNoOp)
}

func testModalLeavesDevSpaceCommandsUnhandledButNotCommandQ() {
    let modal = AppShortcutState.fixture(isModalOpen: true)
    XCTAssertEqual(AppModel.shortcutRoute(event: keyEvent(characters: "o"), state: modal), .unhandled)
    XCTAssertEqual(AppModel.shortcutRoute(event: keyEvent(characters: "q"), state: modal), .action(.quit))
}

func testTextPasteAndOutOfRangeWorkspaceSelectionPassThrough() {
    XCTAssertEqual(AppModel.shortcutRoute(
        event: keyEvent(characters: "v"), state: .fixture(hasPastedImage: false)
    ), .unhandled)
    XCTAssertEqual(AppModel.shortcutRoute(
        event: keyEvent(characters: "9"), state: .fixture(visibleWorkspaceIDs: ["wc-1"])
    ), .unhandled)
}
```

- [ ] **Step 2: Run focused tests to verify the missing API fails**

Run: `swift test --filter ShortcutTests/testCommandORoutesToOpenInZedForARunningSelectedWorkspace --filter ShortcutTests/testCommandRConsumesAsNoOpWithoutVisibleTerminal --filter ShortcutTests/testModalLeavesDevSpaceCommandsUnhandledButNotCommandQ --filter ShortcutTests/testTextPasteAndOutOfRangeWorkspaceSelectionPassThrough`

Expected: compilation failure because `AppShortcutState`, `AppShortcutRoute`, and `shortcutRoute` do not exist.

- [ ] **Step 3: Implement the pure route classifier**

Move only the event classification branches from `handleKey(_:)` into
`shortcutRoute(event:state:)`. Preserve the current ordering: Cmd+Q/M/H/W
first; modal rejection next; then option/shift/plain-command DevSpace actions.
Map every current action to an `AppShortcutAction`, return `.handledNoOp` for
currently consumed-but-inapplicable actions, and `.unhandled` for current
pass-through cases.

- [ ] **Step 4: Run the focused route-policy tests to verify they pass**

Run: `swift test --filter ShortcutTests/testCommandORoutesToOpenInZedForARunningSelectedWorkspace --filter ShortcutTests/testCommandRConsumesAsNoOpWithoutVisibleTerminal --filter ShortcutTests/testModalLeavesDevSpaceCommandsUnhandledButNotCommandQ --filter ShortcutTests/testTextPasteAndOutOfRangeWorkspaceSelectionPassThrough`

Expected: all four tests pass.

### Task 2: Dispatch each recognized shortcut through one owner

**Files:**
- Modify: `Sources/App/AppModel.swift:1167-1321`
- Modify: `Tests/App/ShortcutTests.swift`
- Modify: `Tests/App/TerminalKeyEquivalentTests.swift`

**Interfaces:**
- Consumes: `AppShortcutRoute`, `AppShortcutAction`, and `shortcutRoute(event:state:)` from Task 1.
- Produces: `func dispatchAppShortcut(_ event: NSEvent) -> Bool`, which executes exactly one route action and returns whether it consumed the event.
- Produces: `static func shouldDeferPotentialAppShortcutToTerminal(_ event: NSEvent, firstResponder: NSResponder?) -> Bool`, true only for a terminal first responder and a syntactically possible app shortcut; it must not resolve pasteboard data or inspect AppModel state.
- Uses: an internal injectable `AppShortcutActionExecuting` test seam; its production implementation calls the existing AppModel methods and AppKit actions.

- [ ] **Step 1: Write failing single-owner and semantic-action tests**

```swift
func testTerminalFocusedCommandODefersMonitorAndExecutesOpenInZedOnceAtTerminalBoundary() {
    let recorder = RecordingShortcutExecutor()
    let model = fixtureModel(executor: recorder, selectedRunningWorkspace: "wc-1")
    let terminal = DevSpaceTerminalView(frame: .zero)
    let event = keyEvent(characters: "o")

    XCTAssertTrue(model.shouldDeferPotentialAppShortcutToTerminal(event, firstResponder: terminal))
    XCTAssertFalse(model.dispatchAppShortcutFromMonitor(event, firstResponder: terminal))
    XCTAssertTrue(model.dispatchAppShortcut(event))
    XCTAssertEqual(recorder.actions, [.openInZed("wc-1")])
}

func testNonterminalFocusedCommandRExecutesReloadOnceAtMonitor() {
    let recorder = RecordingShortcutExecutor()
    let model = fixtureModel(executor: recorder, selectedVisibleTerminal: "wc-1")
    let event = keyEvent(characters: "r")

    XCTAssertTrue(model.dispatchAppShortcutFromMonitor(event, firstResponder: NSView()))
    XCTAssertEqual(recorder.actions, [.reload("wc-1")])
}
```

- [ ] **Step 2: Run focused tests to verify they fail**

Run: `swift test --filter ShortcutTests/testTerminalFocusedCommandODefersMonitorAndExecutesOpenInZedOnceAtTerminalBoundary --filter ShortcutTests/testNonterminalFocusedCommandRExecutesReloadOnceAtMonitor`

Expected: compilation failure because the shared dispatcher and recording executor seam do not exist.

- [ ] **Step 3: Implement the dispatcher and update both event boundaries**

Implement `dispatchAppShortcut(_:)` as a switch over the pure route result.
Map each semantic action to the pre-existing AppModel operation without
changing that operation. Update `handleKey(_:)` so the local monitor defers a
recognized terminal-focused route and otherwise consumes only when
`dispatchAppShortcut(_:)` returns true. Update
`handleTerminalKeyEquivalent(_:)` to call that same dispatcher. Remove the
Cmd+B-only helpers once no caller uses them. Remove ContentView's
`isTerminalVisible(pid)` guard from the terminal handler closure: the dispatcher
must receive focused lifecycle/log terminals so Cmd+Q/M/H/W are available there.

- [ ] **Step 4: Extend the real terminal-surface regression test**

Install the model's real local monitor, focus the Kitty-mode terminal surface,
and send one Cmd+O and Cmd+R event through AppKit's window/application dispatch
path. Assert each expected semantic action occurs once and `writes.joined()`
remains empty. Keep a non-owned command event and text Cmd+V assertion that
reaches libghostty. Add an image-paste fixture whose resolver counts one read
and whose recording action contains the exact fixture payload.

- [ ] **Step 5: Run focused routing and terminal tests**

Run: `swift test --filter ShortcutTests --filter TerminalKeyEquivalentTests`

Expected: route policy, one-owner action, and Kitty no-byte regressions pass.

- [ ] **Step 6: Run the full suite and commit**

Run: `make test && git diff --check`

Expected: all SwiftPM tests pass and the diff has no whitespace errors.

Commit the implementation and plan with: `git commit -m "fix: route app shortcuts through terminal"`.
