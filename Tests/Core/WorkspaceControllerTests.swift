import XCTest
@testable import DevSpaceCore

final class WorkspaceControllerTests: XCTestCase {
    private func workspace(_ id: String, state: String = "Stopped") -> WorkspaceView {
        WorkspaceView(id: id, provider: "test", source: "", lastUsed: "", state: state, error: nil)
    }

    func testNotificationBadgesRejectUnknownWorkspacesAndClearOnSelection() {
        let controller = WorkspaceController(workspaces: [workspace("a"), workspace("b")])
        controller.select("a")
        XCTAssertTrue(controller.receiveNotification(workspaceID: "b"))
        XCTAssertEqual(controller.snapshot.badges, ["b"])
        XCTAssertTrue(controller.receiveNotification(workspaceID: "a"))
        XCTAssertEqual(controller.snapshot.badges, ["b"])
        XCTAssertFalse(controller.receiveNotification(workspaceID: "unknown"))
        XCTAssertFalse(controller.receiveNotification(workspaceID: "--invalid"))
        controller.select("b")
        XCTAssertEqual(controller.snapshot.badges, [])
        XCTAssertTrue(controller.receiveNotification(workspaceID: "a"))
        _ = controller.apply(PollUpdate(revision: 1, views: [workspace("b")]))
        XCTAssertEqual(controller.snapshot.badges, [], "removed workspace retained a badge")
    }

    func testNewerPollNormalizesLayoutAndPreservesSelectedWorkspace() {
        let controller = WorkspaceController(layout: Layout(order: ["gone", "b"], hidden: ["gone", "b"]))
        controller.select("b")

        XCTAssertTrue(controller.apply(PollUpdate(revision: 2, views: [workspace("a"), workspace("b")])))

        XCTAssertEqual(controller.snapshot.workspaces.map(\.id), ["a", "b"])
        XCTAssertEqual(controller.snapshot.layout.order, ["b", "a"])
        XCTAssertEqual(controller.snapshot.layout.hidden, ["b"])
        XCTAssertEqual(controller.snapshot.selectedID, "b")
    }

    func testStalePollCannotOverwriteNewerSnapshot() {
        let controller = WorkspaceController()
        XCTAssertTrue(controller.apply(PollUpdate(revision: 4, views: [workspace("new")])) )

        XCTAssertFalse(controller.apply(PollUpdate(revision: 3, views: [workspace("old")])))
        XCTAssertEqual(controller.snapshot.workspaces.map(\.id), ["new"])
    }

    func testSnapshotKeepsTerminalPaneIdentityAcrossPolls() {
        let controller = WorkspaceController()
        let paneID = UUID()
        controller.setTerminalPanes([TerminalPaneDescriptor(id: paneID, workspaceID: "a")])

        _ = controller.apply(PollUpdate(revision: 1, views: [workspace("a", state: "Running")]))

        XCTAssertEqual(controller.snapshot.terminalPanes, [TerminalPaneDescriptor(id: paneID, workspaceID: "a")])
    }

    func testCreationDiscoverySelectsExplicitOrOnlyNewWorkspace() {
        XCTAssertEqual(
            WorkspaceController.createdWorkspaceID(
                explicitID: "chosen",
                before: ["existing"],
                after: ["existing", "chosen"]
            ),
            "chosen"
        )
        XCTAssertEqual(
            WorkspaceController.createdWorkspaceID(
                explicitID: nil,
                before: ["existing"],
                after: ["existing", "derived"]
            ),
            "derived"
        )
        XCTAssertNil(WorkspaceController.createdWorkspaceID(
            explicitID: nil,
            before: ["existing"],
            after: ["existing", "one", "two"]
        ))
    }

    func testTerminalHandoffRequiresBothIntegrationAndPTYOutput() {
        XCTAssertEqual(
            WorkspaceController.terminalHandoffAction(
                integrationSucceeded: true,
                sshProducedOutput: true
            ),
            .restartRemoteShellThenReveal
        )
        XCTAssertEqual(
            WorkspaceController.terminalHandoffAction(
                integrationSucceeded: false,
                sshProducedOutput: true
            ),
            .revealOriginal
        )
    }

    func testConnectionGenerationRejectsStaleCallbacks() {
        let generations = WorkspaceConnectionGenerations()
        let first = generations.begin(workspaceID: "pod")
        let second = generations.begin(workspaceID: "pod")

        XCTAssertFalse(generations.isCurrent(first, workspaceID: "pod"))
        XCTAssertTrue(generations.isCurrent(second, workspaceID: "pod"))

        generations.invalidate(workspaceID: "pod")
        XCTAssertFalse(generations.isCurrent(second, workspaceID: "pod"))
    }

    func testLifecyclePlanConnectsFirstSeenRunningButNotExternallyRestartedPods() {
        let first = WorkspaceLifecycle.reconcile(
            workspaces: [workspace("running", state: "Running")],
            seenDefinitive: [],
            autoConnect: [],
            opened: [],
            starting: [],
            shuttingDown: []
        )
        XCTAssertEqual(first.autoConnect, ["running"])
        XCTAssertEqual(first.connect, ["running"])

        let externallyRestarted = WorkspaceLifecycle.reconcile(
            workspaces: [workspace("running", state: "Running")],
            seenDefinitive: ["running"],
            autoConnect: [],
            opened: [],
            starting: [],
            shuttingDown: []
        )
        XCTAssertTrue(externallyRestarted.connect.isEmpty)
    }

    func testLifecyclePlanDropsStoppedAndGoneSessions() {
        let plan = WorkspaceLifecycle.reconcile(
            workspaces: [workspace("stopped", state: "Stopped")],
            seenDefinitive: ["stopped"],
            autoConnect: ["stopped"],
            opened: ["stopped", "gone"],
            starting: [],
            shuttingDown: ["stopped"]
        )

        XCTAssertTrue(plan.autoConnect.isEmpty)
        XCTAssertEqual(plan.disconnect, ["gone", "stopped"])
        XCTAssertEqual(plan.stopConfirmed, ["stopped"])
    }
}
