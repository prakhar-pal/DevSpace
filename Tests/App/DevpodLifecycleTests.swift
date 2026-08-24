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
        let model = makeModel(ids: ["wc-1"])
        model.beginRecreate("wc-1")
        model.confirmRecreate()

        model.completeRecreate("wc-1", exitCode: 0)

        XCTAssertFalse(model.recreating.contains("wc-1"))
        XCTAssertFalse(model.recreateFailures.contains("wc-1"))
        XCTAssertEqual(model.byID["wc-1"]?.state, "Running")
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
