import XCTest
@testable import DevSpaceApp
import DevSpaceCore

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
            explicitID: "chosen",
            before: ["wc-1"],
            after: ["wc-1", "chosen"]
        ), "chosen")
        XCTAssertEqual(AppModel.createdWorkspaceID(
            explicitID: nil,
            before: ["wc-1"],
            after: ["wc-1", "derived"]
        ), "derived")
        XCTAssertNil(AppModel.createdWorkspaceID(
            explicitID: nil,
            before: ["wc-1"],
            after: ["wc-1", "a", "b"]
        ))
    }

    func testFailedCreationKeepsLogUntilDismissed() {
        let model = makeModel(ids: ["wc-1"])
        model.beginCreation()
        model.submitCreation(
            repositoryURL: "https://github.com/acme/app.git",
            devpodID: ""
        )
        let paneID = model.creationPane?.id

        model.completeCreation(exitCode: 1, refreshedViews: nil)

        XCTAssertEqual(model.creationPhase, .failed)
        XCTAssertEqual(model.creationPane?.id, paneID)
        model.dismissCreationFailure()
        XCTAssertNil(model.creationPane)
        XCTAssertNil(model.creationPhase)
    }

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

        model.beginCreation()
        model.submitCreation(
            repositoryURL: "https://github.com/acme/next.git",
            devpodID: ""
        )
        let nextPaneID = model.creationPane?.id
        lateExit?(1)

        XCTAssertEqual(model.creationPane?.id, nextPaneID)
        XCTAssertEqual(model.creationPhase, .running)
    }

    func testSuccessfulCreationAppliesRefreshAndSelectsSingleNewWorkspace() {
        let model = makeModel(ids: ["wc-1"])
        model.selectedID = "wc-1"
        model.beginCreation()
        model.submitCreation(
            repositoryURL: "https://github.com/acme/new.git",
            devpodID: ""
        )

        model.completeCreation(exitCode: 0, refreshedViews: [
            workspace("wc-1"),
            workspace("new", state: "Running"),
        ])

        XCTAssertEqual(model.selectedID, "new")
        XCTAssertNil(model.creationPane)
        XCTAssertNil(model.creationPhase)
    }

    func testSuccessfulCreationSelectsExplicitWorkspaceID() {
        let model = makeModel(ids: ["wc-1"])
        model.selectedID = "wc-1"
        model.beginCreation()
        model.submitCreation(
            repositoryURL: "https://github.com/acme/new.git",
            devpodID: "chosen"
        )

        model.completeCreation(exitCode: 0, refreshedViews: [
            workspace("wc-1"),
            workspace("chosen", state: "Running"),
            workspace("unrelated"),
        ])

        XCTAssertEqual(model.selectedID, "chosen")
        XCTAssertNil(model.creationPhase)
    }

    func testSuccessfulCreationPreservesSelectionWhenDiscoveryIsAmbiguous() {
        let model = makeModel(ids: ["wc-1"])
        model.selectedID = "wc-1"
        model.beginCreation()
        model.submitCreation(
            repositoryURL: "https://github.com/acme/new.git",
            devpodID: ""
        )

        model.completeCreation(exitCode: 0, refreshedViews: [
            workspace("wc-1"),
            workspace("new-a"),
            workspace("new-b"),
        ])

        XCTAssertEqual(model.selectedID, "wc-1")
        XCTAssertNil(model.creationPhase)
    }

    func testSuccessfulCreationWaitsForLaterPollWhenImmediateRefreshFails() {
        let revisions = PollRevisionSource()
        let model = AppModel(
            interval: 3_600,
            initialWorkspaces: [workspace("wc-1")],
            startsRuntimeServices: false,
            pollRevisionSource: revisions
        )
        model.selectedID = "wc-1"
        model.beginCreation()
        model.submitCreation(
            repositoryURL: "https://github.com/acme/new.git",
            devpodID: ""
        )
        let paneID = model.creationPane?.id

        model.completeCreation(
            exitCode: 0,
            refreshedViews: nil,
            refreshRevision: revisions.next()
        )

        XCTAssertEqual(model.creationPhase, .running)
        XCTAssertEqual(model.creationPane?.id, paneID)

        model.receivePollUpdate(PollUpdate(
            revision: revisions.next(),
            views: [workspace("wc-1"), workspace("new", state: "Running")]
        ))

        XCTAssertEqual(model.selectedID, "new")
        XCTAssertNil(model.creationPhase)
        XCTAssertNil(model.creationPane)
    }

    func testCreationDiscoveryWaitsThroughAStalePollWithNoNewWorkspace() {
        let revisions = PollRevisionSource()
        let model = AppModel(
            interval: 3_600,
            initialWorkspaces: [workspace("wc-1")],
            startsRuntimeServices: false,
            pollRevisionSource: revisions
        )
        model.selectedID = "wc-1"
        model.beginCreation()
        model.submitCreation(
            repositoryURL: "https://github.com/acme/new.git",
            devpodID: ""
        )

        model.completeCreation(
            exitCode: 0,
            refreshedViews: nil,
            refreshRevision: revisions.next()
        )
        model.receivePollUpdate(PollUpdate(
            revision: revisions.next(),
            views: [workspace("wc-1")]
        ))

        XCTAssertEqual(model.creationPhase, .running)
        XCTAssertNotNil(model.creationPane)

        model.receivePollUpdate(PollUpdate(
            revision: revisions.next(),
            views: [workspace("wc-1"), workspace("new", state: "Running")]
        ))

        XCTAssertEqual(model.selectedID, "new")
        XCTAssertNil(model.creationPhase)
    }

    func testCreationDiscoveryEventuallyPreservesSelectionWhenNoWorkspaceAppears() {
        let revisions = PollRevisionSource()
        let model = AppModel(
            interval: 3_600,
            initialWorkspaces: [workspace("wc-1")],
            startsRuntimeServices: false,
            pollRevisionSource: revisions
        )
        model.selectedID = "wc-1"
        model.beginCreation()
        model.submitCreation(
            repositoryURL: "https://github.com/acme/new.git",
            devpodID: "expected"
        )
        model.completeCreation(
            exitCode: 0,
            refreshedViews: nil,
            refreshRevision: revisions.next()
        )

        for _ in 0..<3 {
            model.receivePollUpdate(PollUpdate(
                revision: revisions.next(),
                views: [workspace("wc-1")]
            ))
        }

        XCTAssertEqual(model.selectedID, "wc-1")
        XCTAssertNil(model.creationPhase)
        XCTAssertNil(model.creationPane)
    }

    func testFailedRecreateKeepsWorkspaceLogAndNeverMarksRunning() {
        let model = makeModel(ids: ["wc-1"])
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
        let revisions = PollRevisionSource()
        let model = AppModel(
            interval: 3_600,
            initialWorkspaces: [workspace("wc-1")],
            startsRuntimeServices: false,
            pollRevisionSource: revisions
        )
        model.beginRecreate("wc-1")
        model.confirmRecreate()

        let staleRevision = revisions.next()

        model.completeRecreate("wc-1", exitCode: 0)

        model.receivePollUpdate(PollUpdate(
            revision: staleRevision,
            views: [workspace("wc-1", state: "Stopped")]
        ))

        XCTAssertFalse(model.recreating.contains("wc-1"))
        XCTAssertFalse(model.recreateFailures.contains("wc-1"))
        XCTAssertEqual(model.byID["wc-1"]?.state, "Running")
    }

    func testCachedStoppedEmissionCannotUndoSuccessfulRecreate() {
        let revisions = PollRevisionSource()
        let model = AppModel(
            interval: 3_600,
            initialWorkspaces: [workspace("wc-1")],
            startsRuntimeServices: false,
            pollRevisionSource: revisions
        )
        model.beginRecreate("wc-1")
        model.confirmRecreate()
        model.completeRecreate("wc-1", exitCode: 0)

        model.receivePollUpdate(PollUpdate(
            revision: revisions.next(),
            views: [workspace("wc-1", state: "Stopped")],
            hasFreshStatuses: false
        ))

        XCTAssertEqual(model.byID["wc-1"]?.state, "Stopped")
        XCTAssertEqual(model.phase(of: "wc-1"), .terminal)

        model.receivePollUpdate(PollUpdate(
            revision: revisions.next(),
            views: [workspace("wc-1", state: "Running")],
            hasFreshStatuses: true
        ))

        XCTAssertEqual(model.byID["wc-1"]?.state, "Running")
        XCTAssertEqual(model.phase(of: "wc-1"), .terminal)
    }

    func testStopCannotReplaceAnActiveRecreatePane() {
        let model = makeModel(ids: ["wc-1"], state: "Running")
        model.beginRecreate("wc-1")
        model.confirmRecreate()
        let recreatePaneID = model.panes["wc-1"]?.first?.id

        model.stop("wc-1")

        XCTAssertTrue(model.recreating.contains("wc-1"))
        XCTAssertFalse(model.shuttingDown.contains("wc-1"))
        XCTAssertEqual(model.panes["wc-1"]?.first?.id, recreatePaneID)
    }

    func testStopClearsACompletedRecreateFailureBeforeShutdown() {
        let model = makeModel(ids: ["wc-1"], state: "Running")
        model.beginRecreate("wc-1")
        model.confirmRecreate()
        model.completeRecreate("wc-1", exitCode: 1)

        model.stop("wc-1")

        XCTAssertFalse(model.recreateFailures.contains("wc-1"))
        XCTAssertTrue(model.shuttingDown.contains("wc-1"))
        XCTAssertEqual(model.phase(of: "wc-1"), .shuttingDown)
    }

    func testCreationPaneBecomesTheKeyboardFocusTarget() {
        let model = makeModel(ids: ["wc-1"], state: "Running")
        model.beginCreation()
        model.submitCreation(
            repositoryURL: "https://github.com/acme/new.git",
            devpodID: ""
        )

        XCTAssertEqual(model.focusTargetModel()?.id, model.creationPane?.id)
    }

    func testCreationFormEnablesSubmitOnlyForRepositoryAndIdleModel() {
        XCTAssertTrue(NewWorkspaceSheet.canSubmit(
            repositoryURL: " https://github.com/acme/app.git ",
            isCreating: false
        ))
        XCTAssertFalse(NewWorkspaceSheet.canSubmit(
            repositoryURL: "   ",
            isCreating: false
        ))
        XCTAssertFalse(NewWorkspaceSheet.canSubmit(
            repositoryURL: "https://github.com/acme/app.git",
            isCreating: true
        ))
    }
}
