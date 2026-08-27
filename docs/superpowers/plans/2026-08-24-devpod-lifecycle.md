# DevPod Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add live-log DevPod workspace creation with a mandatory repository URL and optional ID, plus confirmed per-workspace recreation.

**Architecture:** Keep subprocess argument construction in portable `DevSpaceCore`. Add one app-wide creation session and per-workspace recreate state to `AppModel`, both backed by the existing `TerminalPaneModel`. Present creation independently of workspace selection, while recreation reuses the selected workspace lifecycle pane and reconnects only after a successful exit.

**Tech Stack:** Swift 5.9, SwiftUI, SwiftPM/XCTest, DevPod CLI, libghostty-backed `TerminalPaneModel`.

## Global Constraints

- Creation repository URL is mandatory; DevPod ID is optional.
- Creation argv is `devpod up --ide none [--id <id>] -- <repository-url>`.
- Recreation argv is `devpod up --recreate --ide none -- <workspace-id>`.
- Recreate requires a destructive confirmation sheet.
- The selected UI layout is option B: Recreate lives in each workspace's ellipsis/context menu; New and Guide share the footer row.
- Both operations stream live output in DevSpace and preserve failed output until dismissed.
- Only one creation operation may run at a time.
- Do not build or stop the production `DevSpace.app`; use only `make test` and `make build-dev`.
- Preserve unrelated worktree changes, especially `.superpowers/sdd/2026-08-23-dide-zed-folder/task-2-report.md` and `.superpowers/brainstorm/`.

---

### Task 1: Portable Create and Recreate Requests

**Files:**
- Modify: `Sources/Core/Devpod.swift:145`
- Modify: `Tests/Core/DevpodTests.swift:40`

**Interfaces:**
- Produces: `Devpod.CreateRequest(repositoryURL:id:) throws`, with trimmed `repositoryURL: String`, normalized `id: String?`, and `args: [String]`.
- Produces: `Devpod.recreateArgs(_ id: String) throws -> [String]`.
- Consumes: existing `Devpod.validateId(_:)`.

- [ ] **Step 1: Write failing argument and validation tests**

Add these cases to `DevpodTests`:

```swift
func testCreateRequestBuildsArgsWithOptionalID() throws {
    let withID = try Devpod.CreateRequest(
        repositoryURL: "  https://github.com/acme/app.git  ",
        id: "  app-dev  "
    )
    XCTAssertEqual(withID.repositoryURL, "https://github.com/acme/app.git")
    XCTAssertEqual(withID.id, "app-dev")
    XCTAssertEqual(withID.args, [
        "up", "--ide", "none", "--id", "app-dev", "--",
        "https://github.com/acme/app.git",
    ])

    let derived = try Devpod.CreateRequest(
        repositoryURL: "git@github.com:acme/app.git",
        id: "  "
    )
    XCTAssertNil(derived.id)
    XCTAssertEqual(derived.args, [
        "up", "--ide", "none", "--", "git@github.com:acme/app.git",
    ])
}

func testCreateRequestRejectsEmptyRepositoryAndInvalidID() {
    XCTAssertThrowsError(try Devpod.CreateRequest(repositoryURL: "  ", id: nil))
    XCTAssertThrowsError(try Devpod.CreateRequest(
        repositoryURL: "https://github.com/acme/app.git",
        id: "--provider"
    ))
}

func testRecreateArgsUseRecreateFlagAndValidatedID() throws {
    XCTAssertEqual(try Devpod.recreateArgs("wc-1"), [
        "up", "--recreate", "--ide", "none", "--", "wc-1",
    ])
    XCTAssertThrowsError(try Devpod.recreateArgs("--provider"))
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter DevpodTests/testCreateRequestBuildsArgsWithOptionalID \
  --filter DevpodTests/testCreateRequestRejectsEmptyRepositoryAndInvalidID \
  --filter DevpodTests/testRecreateArgsUseRecreateFlagAndValidatedID
```

Expected: compilation fails because `Devpod.CreateRequest` and `recreateArgs` do not exist.

- [ ] **Step 3: Implement the minimal portable request types**

Add to `Devpod`:

```swift
public struct CreateRequest: Equatable, Sendable {
    public let repositoryURL: String
    public let id: String?

    public init(repositoryURL: String, id: String?) throws {
        let repositoryURL = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repositoryURL.isEmpty else {
            throw DevpodError("repository URL is required")
        }
        let normalizedID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedID, !normalizedID.isEmpty {
            try Devpod.validateId(normalizedID)
            self.id = normalizedID
        } else {
            self.id = nil
        }
        self.repositoryURL = repositoryURL
    }

    public var args: [String] {
        var result = ["up", "--ide", "none"]
        if let id { result += ["--id", id] }
        result += ["--", repositoryURL]
        return result
    }
}

public static func recreateArgs(_ id: String) throws -> [String] {
    try validateId(id)
    return ["up", "--recreate", "--ide", "none", "--", id]
}
```

- [ ] **Step 4: Run `swift test --filter DevpodTests` and verify GREEN**

Expected: all `DevpodTests` pass with zero failures.

- [ ] **Step 5: Commit the portable request layer**

```bash
git add Sources/Core/Devpod.swift Tests/Core/DevpodTests.swift
git commit -m "feat: build devpod create and recreate requests"
```

---

### Task 2: AppModel Creation and Recreation State Machine

**Files:**
- Create: `Tests/App/DevpodLifecycleTests.swift`
- Modify: `Sources/App/AppModel.swift:100`

**Interfaces:**
- Consumes: `Devpod.CreateRequest.args` and `Devpod.recreateArgs(_:)` from Task 1.
- Produces: `AppModel.CreationPhase` (`running`, `failed`), `creationSheetOpen`, `creationError`, `creationPane`, `creationPhase`, `recreateConfirmationID`, `recreating`, and `recreateFailures`.
- Produces: `beginCreation()`, `cancelCreation()`, `submitCreation(repositoryURL:devpodID:)`, `dismissCreationFailure()`, `beginRecreate(_:)`, `cancelRecreate()`, `confirmRecreate()`, and `dismissRecreateFailure(_:)`.
- Produces: testable completion/discovery seams `completeCreation(exitCode:refreshedViews:)`, `completeRecreate(_:exitCode:)`, and `createdWorkspaceID(explicitID:before:after:)`.

- [ ] **Step 1: Write failing validation and discovery tests**

Create `DevpodLifecycleTests.swift` with a `@MainActor` test class and workspace fixture helper. Add:

```swift
@MainActor
final class DevpodLifecycleTests: XCTestCase {
    private func workspace(_ id: String, state: String = "Stopped") -> WorkspaceView {
        WorkspaceView(
            id: id,
            provider: "test",
            source: "https://github.com/acme/\(id).git",
            lastUsed: "",
            state: state,
            error: nil
        )
    }

    private func makeModel(ids: [String], state: String = "Stopped") -> AppModel {
        AppModel(
            interval: 3_600,
            initialWorkspaces: ids.map { workspace($0, state: state) },
            startsRuntimeServices: false
        )
    }

func testCreationRejectsDuplicateExplicitIDBeforeMountingPane() {
    let model = makeModel(ids: ["wc-1"])
    model.beginCreation()
    model.submitCreation(
        repositoryURL: "https://github.com/acme/app.git",
        devpodID: "wc-1"
    )
    XCTAssertEqual(model.creationError, "A workspace named wc-1 already exists.")
    XCTAssertNil(model.creationPane)
    XCTAssertTrue(model.creationSheetOpen)
}

func testCreatedWorkspaceDiscoveryUsesExplicitOrSingleNewID() {
    XCTAssertEqual(AppModel.createdWorkspaceID(
        explicitID: "chosen", before: ["wc-1"], after: ["wc-1", "chosen"]
    ), "chosen")
    XCTAssertEqual(AppModel.createdWorkspaceID(
        explicitID: nil, before: ["wc-1"], after: ["wc-1", "derived"]
    ), "derived")
    XCTAssertNil(AppModel.createdWorkspaceID(
        explicitID: nil, before: ["wc-1"], after: ["wc-1", "a", "b"]
    ))
}
}
```

- [ ] **Step 2: Run the two tests and verify RED**

Run:

```bash
swift test --filter DevpodLifecycleTests/testCreationRejectsDuplicateExplicitIDBeforeMountingPane \
  --filter DevpodLifecycleTests/testCreatedWorkspaceDiscoveryUsesExplicitOrSingleNewID
```

Expected: compilation fails because the DevPod lifecycle AppModel API does not exist.

- [ ] **Step 3: Add the minimal published state and pure discovery logic**

Add these state shapes to `AppModel`:

```swift
enum CreationPhase: Equatable { case running, failed }

@Published var creationSheetOpen = false
@Published private(set) var creationError: String?
@Published private(set) var creationPane: TerminalPaneModel?
@Published private(set) var creationPhase: CreationPhase?
@Published var recreateConfirmationID: String?
@Published private(set) var recreating: Set<String> = []
@Published private(set) var recreateFailures: Set<String> = []

private var creationBeforeIDs: Set<String> = []
private var creationExplicitID: String?
private var creationPreviousSelection: String?
```

Implement `createdWorkspaceID` as explicit-ID membership first, otherwise the
single element of `after.subtracting(before)`. Implement duplicate checking in
`submitCreation` before constructing a pane.

- [ ] **Step 4: Run the two tests and verify GREEN**

Expected: both tests pass.

- [ ] **Step 5: Write failing lifecycle completion tests**

Add tests that call the internal completion seams directly:

```swift
func testFailedCreationKeepsLogUntilDismissed() {
    let model = makeModel(ids: ["wc-1"])
    model.beginCreation()
    model.submitCreation(repositoryURL: "https://github.com/acme/app.git", devpodID: "")
    let paneID = model.creationPane?.id

    model.completeCreation(exitCode: 1, refreshedViews: nil)

    XCTAssertEqual(model.creationPhase, .failed)
    XCTAssertEqual(model.creationPane?.id, paneID)
    model.dismissCreationFailure()
    XCTAssertNil(model.creationPane)
    XCTAssertNil(model.creationPhase)
}

func testSuccessfulCreationAppliesRefreshAndSelectsSingleNewWorkspace() {
    let model = makeModel(ids: ["wc-1"])
    model.selectedID = "wc-1"
    model.beginCreation()
    model.submitCreation(repositoryURL: "https://github.com/acme/new.git", devpodID: "")

    model.completeCreation(exitCode: 0, refreshedViews: [
        workspace("wc-1", state: "Stopped"),
        workspace("new", state: "Running"),
    ])

    XCTAssertEqual(model.selectedID, "new")
    XCTAssertNil(model.creationPane)
    XCTAssertNil(model.creationPhase)
}

func testFailedRecreateKeepsWorkspaceLogAndNeverMarksRunning() {
    let model = makeModel(ids: ["wc-1"], state: "Stopped")
    model.beginRecreate("wc-1")
    model.confirmRecreate()
    let paneID = model.panes["wc-1"]?.first?.id

    model.completeRecreate("wc-1", exitCode: 1)

    XCTAssertFalse(model.recreating.contains("wc-1"))
    XCTAssertTrue(model.recreateFailures.contains("wc-1"))
    XCTAssertEqual(model.panes["wc-1"]?.first?.id, paneID)
    XCTAssertEqual(model.byID["wc-1"]?.state, "Stopped")
}

func testSuccessfulRecreateMarksRunningAndClearsLifecycleLog() {
    let model = makeModel(ids: ["wc-1"], state: "Stopped")
    model.beginRecreate("wc-1")
    model.confirmRecreate()
    model.completeRecreate("wc-1", exitCode: 0)

    XCTAssertFalse(model.recreating.contains("wc-1"))
    XCTAssertFalse(model.recreateFailures.contains("wc-1"))
    XCTAssertEqual(model.byID["wc-1"]?.state, "Running")
}
```

- [ ] **Step 6: Run lifecycle tests and verify RED**

Expected: tests fail because completion paths, pane retention, and recreate
transitions are not implemented.

- [ ] **Step 7: Implement terminal-backed lifecycle transitions**

Implement `submitCreation` with `TerminalPaneModel(command: "devpod", args:
request.args)`. Snapshot IDs/selection before setting `.running`. Its `onExit`
must route non-zero status directly to `completeCreation`; on zero, run
`Poller.pollOnce(runner)` on a user-initiated global queue and dispatch the
result back to `completeCreation` on the main actor.

Implement recreation with a validated ID and:

```swift
let pane = TerminalPaneModel(command: "devpod", args: try Devpod.recreateArgs(id))
pane.onExit = { [weak self] code in self?.completeRecreate(id, exitCode: code) }
```

Before mounting it, invalidate SSH resolution, cancel the handoff, remove the
ID from `opened`, close existing panes, insert it into `recreating`, and select
it. On exit zero, share a refactored successful-up helper with `start`; on
non-zero, keep the exited pane and mark `recreateFailures`.

Extend `Phase` with `.recreating` and `.recreateFailed`. Make
`isPaneDisplayVisible` return true for both lifecycle phases when selected.
Implement dismiss functions that clear only the failed pane/state.

- [ ] **Step 8: Run `swift test --filter DevpodLifecycleTests` and verify GREEN**

Expected: all DevPod lifecycle model tests pass with zero failures.

- [ ] **Step 9: Run AppModel regression suites**

Run:

```bash
swift test --filter SidebarTests --filter ConnectionTimingTests --filter ActionPanelTests
```

Expected: all existing lifecycle and connection tests pass.

- [ ] **Step 10: Commit the lifecycle state machine**

```bash
git add Sources/App/AppModel.swift Tests/App/DevpodLifecycleTests.swift
git commit -m "feat: manage create and recreate lifecycle"
```

---

### Task 3: Creation and Confirmation Sheets

**Files:**
- Modify: `Sources/App/Modals.swift:1`
- Modify: `Sources/App/ContentView.swift:20`
- Modify: `Tests/App/DevpodLifecycleTests.swift`

**Interfaces:**
- Consumes: AppModel sheet, submission, confirmation, and failure APIs from Task 2.
- Produces: `NewWorkspaceSheet` and `RecreateWorkspaceSheet`.
- Produces: creation log overlay and failed-log dismissal controls in `MainPane`.

- [ ] **Step 1: Write failing pure presentation-policy tests**

Add a pure form-policy test before production code exists:

```swift
func testCreationFormEnablesSubmitOnlyForRepositoryAndIdleModel() {
    XCTAssertTrue(NewWorkspaceSheet.canSubmit(repositoryURL: " https://x/y ", isCreating: false))
    XCTAssertFalse(NewWorkspaceSheet.canSubmit(repositoryURL: "   ", isCreating: false))
    XCTAssertFalse(NewWorkspaceSheet.canSubmit(repositoryURL: "https://x/y", isCreating: true))
}
```

- [ ] **Step 2: Run the form-policy test and verify RED**

Expected: compilation fails because `NewWorkspaceSheet.canSubmit` does not exist.

- [ ] **Step 3: Implement the sheets and ContentView bindings**

`NewWorkspaceSheet` owns local `@State` strings, renders any `creationError`,
and invokes `onSubmit(repositoryURL, devpodID)`. Its Create button uses:

```swift
static func canSubmit(repositoryURL: String, isCreating: Bool) -> Bool {
    !repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !isCreating
}
```

`RecreateWorkspaceSheet` names the workspace, explains container replacement,
and uses a destructive-role Recreate button plus Cancel.

Add both sheets to the root `ContentView` using model-backed bindings. Creation
submission must leave the sheet open when `creationError` is set and close it
only after the model successfully mounts a creation pane.

- [ ] **Step 4: Present creation and recreate logs**

In `MainPane`, layer the app-wide `creationPane` above regular workspace panes.
Use `TerminalPaneView` directly and show `Creating workspace…` while running or
`Creation failed` with a Close button after failure.

Extend `paneContainer` headers for `.recreating` and `.recreateFailed`; the
failed case includes a Close button calling `dismissRecreateFailure(pid)`.
Keep all normal workspace panes mounted under the creation overlay.

- [ ] **Step 5: Run `swift test --filter DevpodLifecycleTests` and verify GREEN**

Expected: all DevPod form/presentation and lifecycle tests pass.

- [ ] **Step 6: Commit modal and main-pane presentation**

```bash
git add Sources/App/Modals.swift Sources/App/ContentView.swift Tests/App/DevpodLifecycleTests.swift
git commit -m "feat: present devpod lifecycle dialogs and logs"
```

---

### Task 4: Sidebar Actions and Guide Copy

**Files:**
- Modify: `Sources/App/Sidebar.swift:1`
- Modify: `Sources/App/Modals.swift:65`
- Modify: `Tests/App/SidebarTests.swift:1`

**Interfaces:**
- Consumes: `creationSheetOpen`, `beginRecreate(_:)`, and recreate lifecycle sets.
- Produces: the selected option-B workspace menu and footer layout.

- [ ] **Step 1: Write a failing sidebar recreate-policy test**

Add to `SidebarTests`:

```swift
func testRecreateMenuAvailabilityTracksWorkspaceLifecycle() {
    XCTAssertTrue(SidebarSessionActions.canRecreate(
        isStarting: false, isStopping: false, isRecreating: false
    ))
    XCTAssertFalse(SidebarSessionActions.canRecreate(
        isStarting: false, isStopping: true, isRecreating: false
    ))
}
```

Run `swift test --filter SidebarTests/testRecreateMenuAvailabilityTracksWorkspaceLifecycle`.
Expected: FAIL until the policy helper is available from `Sidebar.swift`.

- [ ] **Step 2: Add Recreate to the workspace menu**

Add a `Recreate…` button to the common `menuItems`, so both ellipsis and context
menus expose it for visible and hidden workspaces. Bind `.disabled` to
`SidebarSessionActions.canRecreate` using `starting`, `shuttingDown`, and
`recreating` membership.

- [ ] **Step 3: Replace the footer with the selected two-button row**

Use one `HStack(spacing: 4)` containing equal-width New and Guide plain buttons.
New calls `model.beginCreation()`; Guide preserves `model.guideOpen = true`.
Retain the existing hover tint/fill treatment and footer padding.

- [ ] **Step 4: Update GuideSheet lifecycle documentation**

Under Workspaces or Start & stop, add concise rows documenting:

```text
New workspace — Click New, enter a repository URL, and optionally choose a DevPod ID. The provisioning log streams in the main pane.
Recreate — Open a workspace's … menu → Recreate…, confirm, and watch DevPod replace the container before reconnecting.
```

- [ ] **Step 5: Run focused UI regression tests**

Run:

```bash
swift test --filter SidebarTests --filter DevpodLifecycleTests --filter ShortcutTests
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 6: Commit sidebar actions**

```bash
git add Sources/App/Sidebar.swift Sources/App/Modals.swift Tests/App/SidebarTests.swift
git commit -m "feat: expose devpod workspace actions"
```

---

### Task 5: Full Verification and Stack Readiness

**Files:**
- Verify: all files changed by Tasks 1–4

**Interfaces:**
- Consumes: complete DevPod lifecycle implementation.
- Produces: verified dev bundle and clean scoped diff on the feature branch.

- [ ] **Step 1: Run formatting/whitespace validation**

```bash
git diff --check feat/dide-zed-folder...HEAD
```

Expected: no output and exit status zero.

- [ ] **Step 2: Run the complete test suite**

```bash
make test
```

Expected: every Swift test passes with zero failures.

- [ ] **Step 3: Build the development bundle**

```bash
make build-dev
```

Expected: `build/DevSpaceDev.app` assembles successfully. Do not invoke the
release `make build` target.

- [ ] **Step 4: Inspect the complete stack-branch diff**

```bash
git status --short
git diff --stat feat/dide-zed-folder...HEAD
git log --oneline feat/dide-zed-folder..HEAD
gh stack view
```

Expected: only the pre-existing unrelated report/browser files remain dirty or
untracked; DevPod lifecycle commits appear above `feat/dide-zed-folder` in the local stack.

- [ ] **Step 5: Request focused code review and address all Critical/Important findings**

Review command construction, actor/thread transitions, terminal exit behavior,
selection/discovery ambiguity, and destructive confirmation wiring. Re-run
focused tests after each fix, then repeat Steps 1–4.
