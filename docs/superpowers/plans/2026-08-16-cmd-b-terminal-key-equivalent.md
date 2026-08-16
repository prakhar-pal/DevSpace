# Cmd+B Terminal Key-Equivalent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure Command-B toggles the DevSpace sidebar exactly once without writing any key bytes to an embedded terminal, including when Herdr enables Kitty enhanced keyboard reporting.

**Architecture:** Introduce an app-owned `AppTerminalView` subclass whose `performKeyEquivalent(with:)` override handles DevSpace-owned key equivalents before libghostty can encode them. A behavior-compatible `NSViewRepresentable` wires the subclass to the existing `TerminalViewState`; the local monitor forwards Command-B when that subclass is first responder and retains ownership when focus is elsewhere, so exactly one path performs the sidebar action.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, SwiftPM, libghostty-spm/GhosttyTerminal, XCTest.

## Global Constraints

- Work on the existing `fix/cmd-b-terminal-passthrough-followup` branch without creating a git worktree.
- Do not edit `.build/checkouts/libghostty-spm`; it is generated dependency state.
- Do not modify or discard the unrelated in-progress notification-helper changes in `CLAUDE.md`, `Sources/App/AppModel.swift`, `Sources/Core/Hooks.swift`, `Tests/Core/HooksTests.swift`, or their existing design/plan documents.
- Do not commit or push; present the final diff and proposed Conventional Commit message to the user.
- Do not run `make build`, stop `DevSpace.app`, or otherwise disturb the production bundle.
- Development validation may use `make build-dev`, `open "build/DevSpaceDev.app"`, and, if a restart is necessary, `pkill -f "build/DevSpaceDev.app"` only.
- Preserve modal ownership: rename and guide UI must continue receiving their keyboard events.
- Delegate every key except exact Command-B to libghostty unchanged.

---

### Task 1: Classify the complete Command-B event

**Files:**
- Modify: `Sources/App/AppModel.swift:795-892`
- Modify: `Tests/App/ShortcutTests.swift`

**Interfaces:**
- Consumes: `NSEvent.type`, `NSEvent.charactersIgnoringModifiers`, and `NSEvent.modifierFlags`.
- Produces: `AppModel.isSidebarToggleKeyEquivalent(_ event: NSEvent) -> Bool`, which returns `true` only for a key-down event whose normalized modifiers are exactly `.command` and whose modifier-independent characters equal `b` case-insensitively.
- Preserves: `AppModel.isSidebarToggleShortcut(_:)` as the character-only helper used by the new event classifier.

- [ ] **Step 1: Replace the character-only regression test with event-level failing tests**

Add `import AppKit`, retain the existing next-tab tests, and add an event factory plus these cases to `Tests/App/ShortcutTests.swift`:

```swift
private func keyEvent(
    type: NSEvent.EventType = .keyDown,
    characters: String = "b",
    modifiers: NSEvent.ModifierFlags = [.command]
) -> NSEvent {
    NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 1,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 11
    )!
}

func testSidebarToggleKeyEquivalentAcceptsUppercaseCommandB() {
    XCTAssertTrue(AppModel.isSidebarToggleKeyEquivalent(
        keyEvent(characters: "B")
    ))
}

func testSidebarToggleKeyEquivalentRejectsWrongModifiersAndEventType() {
    XCTAssertFalse(AppModel.isSidebarToggleKeyEquivalent(
        keyEvent(modifiers: [])
    ))
    XCTAssertFalse(AppModel.isSidebarToggleKeyEquivalent(
        keyEvent(modifiers: [.command, .shift])
    ))
    XCTAssertFalse(AppModel.isSidebarToggleKeyEquivalent(
        keyEvent(modifiers: [.control])
    ))
    XCTAssertFalse(AppModel.isSidebarToggleKeyEquivalent(
        keyEvent(type: .keyUp)
    ))
}

func testSidebarToggleKeyEquivalentRejectsOtherCommandKey() {
    XCTAssertFalse(AppModel.isSidebarToggleKeyEquivalent(
        keyEvent(characters: "c")
    ))
}
```

- [ ] **Step 2: Run the focused tests and verify the new API is absent**

Run:

```bash
swift test --filter ShortcutTests
```

Expected: compilation fails because `AppModel` has no member `isSidebarToggleKeyEquivalent`.

- [ ] **Step 3: Implement the complete event classifier and use it in the local monitor**

Add this method beside the existing shortcut helpers in `AppModel`:

```swift
static func isSidebarToggleKeyEquivalent(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown,
          let chars = event.charactersIgnoringModifiers
    else { return false }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    return flags == [.command] && isSidebarToggleShortcut(chars)
}
```

In `handleKey(_:)`, replace:

```swift
if Self.isSidebarToggleShortcut(chars) {
```

with:

```swift
if Self.isSidebarToggleKeyEquivalent(event) {
```

Keep the surrounding modal guard and sidebar action unchanged.

- [ ] **Step 4: Run the focused tests and verify the classifier passes**

Run:

```bash
swift test --filter ShortcutTests
```

Expected: all `ShortcutTests` pass, including uppercase Command-B and rejection of plain, shifted, controlled, released, and unrelated keys.

---

### Task 2: Add the app-owned libghostty key-equivalent boundary

**Files:**
- Create: `Sources/App/DevSpaceTerminalSurface.swift`
- Create: `Tests/App/TerminalKeyEquivalentTests.swift`

**Interfaces:**
- Consumes: `AppTerminalView`, `TerminalViewState`, and a `(NSEvent) -> Bool` handler supplied by the application.
- Produces: `DevSpaceTerminalView.handleKeyEquivalent: (NSEvent) -> Bool` and `DevSpaceTerminalSurfaceView.init(state:handleKeyEquivalent:)`.
- Guarantees: a handler-owned event performs its app action and returns `true` without calling libghostty's `performKeyEquivalent(with:)`; all other events call `super` exactly as before.

- [ ] **Step 1: Write tests against the missing terminal subclass**

Create `Tests/App/TerminalKeyEquivalentTests.swift`:

```swift
import AppKit
import XCTest
@testable import DevSpaceApp

@MainActor
final class TerminalKeyEquivalentTests: XCTestCase {
    private func keyEvent(_ characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 2,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: characters.caseInsensitiveCompare("b") == .orderedSame ? 11 : 8
        )!
    }

    func testOwnedCommandBStopsAtTerminalBoundary() {
        let view = DevSpaceTerminalView(frame: .zero)
        var handlerCalls = 0
        view.handleKeyEquivalent = { event in
            handlerCalls += 1
            return AppModel.isSidebarToggleKeyEquivalent(event)
        }

        XCTAssertTrue(view.performKeyEquivalent(with: keyEvent("B")))
        XCTAssertEqual(handlerCalls, 1)
    }

    func testUnownedCommandKeyFallsThroughToGhostty() {
        let view = DevSpaceTerminalView(frame: .zero)
        var handlerCalls = 0
        view.handleKeyEquivalent = { event in
            handlerCalls += 1
            return AppModel.isSidebarToggleKeyEquivalent(event)
        }

        // With no window/surface, AppTerminalView's implementation returns false.
        // That result proves this override called super instead of claiming Cmd+C.
        XCTAssertFalse(view.performKeyEquivalent(with: keyEvent("c")))
        XCTAssertEqual(handlerCalls, 1)
    }
}
```

- [ ] **Step 2: Run the focused test and verify the boundary type is absent**

Run:

```bash
swift test --filter TerminalKeyEquivalentTests
```

Expected: compilation fails because `DevSpaceTerminalView` does not exist.

- [ ] **Step 3: Implement the subclass and behavior-compatible SwiftUI wrapper**

Create `Sources/App/DevSpaceTerminalSurface.swift` with the following implementation:

```swift
import AppKit
import GhosttyTerminal
import SwiftUI

@MainActor
final class DevSpaceTerminalView: AppTerminalView {
    var handleKeyEquivalent: (NSEvent) -> Bool = { _ in false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKeyEquivalent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct DevSpaceTerminalSurfaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var state: TerminalViewState
    let handleKeyEquivalent: (NSEvent) -> Bool

    var body: some View {
        DevSpaceTerminalViewRepresentable(
            state: state,
            handleKeyEquivalent: handleKeyEquivalent
        )
        .background(.clear)
        .onChange(of: colorScheme) { newScheme in
            state.adopt(colorScheme: newScheme)
        }
        .onAppear {
            state.adopt(colorScheme: colorScheme)
        }
    }
}

private struct DevSpaceTerminalViewRepresentable: NSViewRepresentable {
    let state: TerminalViewState
    let handleKeyEquivalent: (NSEvent) -> Bool

    func makeNSView(context _: Context) -> DevSpaceTerminalView {
        let view = DevSpaceTerminalView(frame: .zero)
        view.delegate = state
        configure(view)
        return view
    }

    func updateNSView(_ view: DevSpaceTerminalView, context _: Context) {
        configure(view)
    }

    static func dismantleNSView(
        _ view: DevSpaceTerminalView,
        coordinator _: ()
    ) {
        view.handleKeyEquivalent = { _ in false }
    }

    private func configure(_ view: DevSpaceTerminalView) {
        view.handleKeyEquivalent = handleKeyEquivalent
        if let currentController = view.controller,
           currentController === state.controller {
            // Preserve the current surface and its scrollback.
        } else {
            view.controller = state.controller
        }
        // TerminalSurfaceCoordinator ignores equivalent assignments.
        view.configuration = state.configuration
    }
}
```

Do not set `view.delegate = nil` during dismantling: libghostty uses that weak
delegate during surface teardown to clear `TerminalViewState.surface`.

- [ ] **Step 4: Run the focused boundary tests**

Run:

```bash
swift test --filter TerminalKeyEquivalentTests
```

Expected: both tests pass. Command-B returns `true` from the app-owned boundary; Command-C returns libghostty's unhandled result.

---

### Task 3: Route terminal panes through the new boundary

**Files:**
- Modify: `Sources/App/AppModel.swift:781-892`
- Modify: `Sources/App/ContentView.swift:111-135`
- Modify: `Sources/App/TerminalPane.swift:202-211`

**Interfaces:**
- Consumes: `AppModel.isSidebarToggleKeyEquivalent(_:)` from Task 1 and `DevSpaceTerminalSurfaceView` from Task 2.
- Produces: `AppModel.handleTerminalKeyEquivalent(_:) -> Bool` and `TerminalPaneView.init(model:handleKeyEquivalent:)`.
- Preserves: non-terminal focus uses the local monitor; terminal focus performs the action at the terminal boundary.

- [ ] **Step 1: Add the modal-aware terminal action handler**

Add this instance method beside `installKeyMonitor()` in `AppModel`:

```swift
func handleTerminalKeyEquivalent(_ event: NSEvent) -> Bool {
    guard renaming == nil, !guideOpen else { return false }
    guard Self.isSidebarToggleKeyEquivalent(event) else { return false }
    sidebarOpen.toggle()
    return true
}
```

This is the sole Command-B action path while `DevSpaceTerminalView` is first
responder. Returning `true` tells the view not to invoke libghostty.

- [ ] **Step 2: Make the local monitor forward terminal-focused Command-B**

Update the Command-B branch in `handleKey(_:)`:

```swift
if Self.isSidebarToggleKeyEquivalent(event) {
    let window = event.window ?? NSApp.keyWindow
    if window?.firstResponder is DevSpaceTerminalView {
        return event
    }
    sidebarOpen.toggle()
    return nil
}
```

This preserves local-monitor behavior outside the terminal. When the app-owned
terminal is focused, returning the event routes it to the handler from Step 1;
the action cannot execute on both paths.

- [ ] **Step 3: Pass the live handler from `MainPane` into every terminal pane**

Change the terminal construction in `ContentView.paneContainer(pid:)` to:

```swift
TerminalPaneView(
    model: pane,
    handleKeyEquivalent: { event in
        model.handleTerminalKeyEquivalent(event)
    }
)
.opacity(pane.id == activeID ? 1 : 0)
.allowsHitTesting(pane.id == activeID)
```

The closure intentionally reads and updates `model` at event time so changing
modal state does not recreate the terminal surface.

- [ ] **Step 4: Replace libghostty's high-level view at the DevSpace call site**

Change `TerminalPaneView` to:

```swift
struct TerminalPaneView: View {
    @ObservedObject var model: TerminalPaneModel
    let handleKeyEquivalent: (NSEvent) -> Bool

    var body: some View {
        // Focus is driven imperatively by MainPane.focusSelectedTerminal().
        DevSpaceTerminalSurfaceView(
            state: model.state,
            handleKeyEquivalent: handleKeyEquivalent
        )
        .background(Color(red: 0.067, green: 0.067, blue: 0.067)) // #111
    }
}
```

Add an explicit `import AppKit` to `TerminalPane.swift` for the closure type.
Do not change `MainPane.terminalView(in:controller:)`: its
`as? AppTerminalView` check already matches `DevSpaceTerminalView` subclasses.

- [ ] **Step 5: Run both focused shortcut suites**

Run:

```bash
swift test --filter ShortcutTests
swift test --filter TerminalKeyEquivalentTests
```

Expected: both suites pass and the complete `DevSpaceApp` target compiles with the new terminal call site.

- [ ] **Step 6: Run the complete unit test suite**

Run:

```bash
make test
```

Expected: all Core and App tests pass with no notification-helper regressions.

---

### Task 4: Validate the real Kitty-mode failure path in DevSpaceDev

**Files:**
- Verify only; no release files or production bundle changes.

**Interfaces:**
- Consumes: the exact live reproduction—an SSH terminal inside a running DevPod with Herdr 0.8.0 enabling Kitty flags via `ESC[>7u`.
- Produces: evidence that Command-B toggles the sidebar once and produces no Herdr input/action.

- [ ] **Step 1: Build only the development bundle**

Run:

```bash
make build-dev
```

Expected: `build/DevSpaceDev.app` assembles successfully. Do not substitute `make build`.

- [ ] **Step 2: Launch the development bundle through LaunchServices**

If an old development instance must be replaced, stop only that bundle:

```bash
pkill -f "build/DevSpaceDev.app"
```

Then launch:

```bash
open "build/DevSpaceDev.app"
```

Expected: DevSpaceDev opens while the production `DevSpace.app` remains running and untouched.

- [ ] **Step 3: Reproduce against Herdr inside the DevPod**

In DevSpaceDev, connect to the same running workspace used for the original
failure, start Herdr 0.8.0, focus its terminal input, and press Command-B once.

Expected:

- The DevSpace sidebar changes state exactly once.
- Herdr performs no Command-B action and displays/inserts no corresponding input.
- Repeating Command-B continues to toggle only the sidebar.

- [ ] **Step 4: Smoke-test delegated terminal behavior and lifecycle**

With the same terminal focused:

- Type normal text and use the existing terminal copy/paste behavior.
- Exercise one non-owned command-modified key used by Herdr.
- Switch terminal tabs and workspaces, then return to the original terminal.
- Resize the window and confirm the terminal still renders and resizes.

Expected: unowned keys still reach the terminal; terminal focus, scrollback,
tab/workspace switching, rendering, and resize behavior are unchanged.

- [ ] **Step 5: Inspect only development diagnostics for new failures**

Run:

```bash
tail -n 100 .tmp/devspace.log
```

Expected: no new surface rebuild loop, PTY lifecycle error, or crash around the validation session.

---

### Task 5: Review and hand off the uncommitted change

**Files:**
- Review: `Sources/App/AppModel.swift`
- Review: `Sources/App/ContentView.swift`
- Review: `Sources/App/TerminalPane.swift`
- Review: `Sources/App/DevSpaceTerminalSurface.swift`
- Review: `Tests/App/ShortcutTests.swift`
- Review: `Tests/App/TerminalKeyEquivalentTests.swift`

**Interfaces:**
- Consumes: passing automated tests and live DevSpaceDev/Herdr evidence.
- Produces: a scoped diff and a Conventional Commit message for the user to apply.

- [ ] **Step 1: Check formatting and accidental whitespace errors**

Run:

```bash
git diff --check
```

Expected: no output.

- [ ] **Step 2: Review the scoped diff without disturbing unrelated work**

Run:

```bash
git diff -- Sources/App/AppModel.swift Sources/App/ContentView.swift Sources/App/TerminalPane.swift Sources/App/DevSpaceTerminalSurface.swift Tests/App/ShortcutTests.swift Tests/App/TerminalKeyEquivalentTests.swift
git status --short
```

Expected: the shortcut fix is limited to the listed files; the pre-existing
notification-helper edits remain present and unchanged.

- [ ] **Step 3: Present the change for user commit**

Do not run `git add`, `git commit`, or `git push`. Report focused/full test
results, the live Herdr result, residual risks, and propose:

```text
fix: intercept Cmd+B before libghostty key handling
```
