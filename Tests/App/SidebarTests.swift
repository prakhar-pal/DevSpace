import XCTest
@testable import DevSpaceApp
import DevSpaceCore

@MainActor
final class SidebarTests: XCTestCase {
    private final class BlockingShellIntegrationRunner: CommandRunning, @unchecked Sendable {
        let shellIntegrationStarted = DispatchSemaphore(value: 0)
        let releaseShellIntegration = DispatchSemaphore(value: 0)

        func run(_ args: [String]) throws -> String {
            if args.count > 2,
               args[0] == "ssh",
               args[2].contains("devspace shell integration")
            {
                shellIntegrationStarted.signal()
                _ = releaseShellIntegration.wait(timeout: .now() + 5)
            }
            return "{}"
        }
    }

    private final class FailingShellIntegrationRunner: CommandRunning, @unchecked Sendable {
        func run(_ args: [String]) throws -> String {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    private final class ManualHandoffTimeoutScheduler: AppModel.HandoffTimeoutScheduling {
        private(set) var action: (() -> Void)?

        func schedule(after _: TimeInterval, action: @escaping () -> Void) {
            self.action = action
        }

        func fire() { action?() }
    }

    func testDisconnectMenuItemRequiresAnOpenPTY() {
        XCTAssertTrue(SidebarSessionActions.showsDisconnect(
            isOpened: true,
            hasPanes: true,
            isTerminalVisible: true
        ))
        XCTAssertFalse(SidebarSessionActions.showsDisconnect(
            isOpened: true,
            hasPanes: true,
            isTerminalVisible: false
        ))
        XCTAssertFalse(SidebarSessionActions.showsDisconnect(
            isOpened: true,
            hasPanes: false,
            isTerminalVisible: true
        ))
        XCTAssertFalse(SidebarSessionActions.showsDisconnect(
            isOpened: false,
            hasPanes: false,
            isTerminalVisible: true
        ))
    }

    func testTerminalActionsRequireAVisibleOpenedPane() {
        XCTAssertTrue(SidebarSessionActions.showsTerminalActions(
            isOpened: true,
            hasPanes: true,
            isTerminalVisible: true
        ))
        XCTAssertFalse(SidebarSessionActions.showsTerminalActions(
            isOpened: true,
            hasPanes: true,
            isTerminalVisible: false
        ))
    }

    func testTerminalMutationsRequireAVisibleOpenedPane() {
        XCTAssertTrue(AppModel.canMutateTerminal(
            isOpened: true,
            hasPanes: true,
            isTerminalVisible: true
        ))
        XCTAssertFalse(AppModel.canMutateTerminal(
            isOpened: true,
            hasPanes: true,
            isTerminalVisible: false
        ))
    }

    func testRecreateMenuAvailabilityTracksWorkspaceLifecycle() {
        XCTAssertTrue(SidebarSessionActions.canRecreate(
            isStarting: false,
            isStopping: false,
            isRecreating: false
        ))
        XCTAssertFalse(SidebarSessionActions.canRecreate(
            isStarting: true,
            isStopping: false,
            isRecreating: false
        ))
        XCTAssertFalse(SidebarSessionActions.canRecreate(
            isStarting: false,
            isStopping: true,
            isRecreating: false
        ))
        XCTAssertFalse(SidebarSessionActions.canRecreate(
            isStarting: false,
            isStopping: false,
            isRecreating: true
        ))
    }

    func testOpenInZedRequiresRunningStatusOutsideLifecycleTransitions() {
        func model(state: String) -> AppModel {
            AppModel(
                initialWorkspaces: [WorkspaceView(
                    id: "wc-1",
                    provider: "test",
                    source: "",
                    lastUsed: "",
                    state: state,
                    error: nil
                )],
                startsRuntimeServices: false
            )
        }

        let running = model(state: "Running")
        XCTAssertTrue(running.canOpenInZed("wc-1"))
        XCTAssertFalse(model(state: "Stopped").canOpenInZed("wc-1"))

        running.beginRecreate("wc-1")
        running.confirmRecreate()
        XCTAssertFalse(running.canOpenInZed("wc-1"))

        let starting = model(state: "Running")
        starting.start("wc-1")
        XCTAssertFalse(starting.canOpenInZed("wc-1"))

        let stopping = model(state: "Running")
        stopping.stop("wc-1")
        XCTAssertFalse(stopping.canOpenInZed("wc-1"))
    }

    func testPendingHandoffBlocksReloadAndNewTerminalUntilVisible() async {
        let id = "pending-pod"
        let runner = BlockingShellIntegrationRunner()
        let model = AppModel(
            runner: runner,
            interval: 3_600,
            initialWorkspaces: [WorkspaceView(
                id: id,
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false
        )
        defer { runner.releaseShellIntegration.signal() }

        model.connect(id)
        XCTAssertEqual(
            runner.shellIntegrationStarted.wait(timeout: .now() + 0.05),
            .timedOut
        )
        model.panes[id]?.first?.onFirstOutput?()
        XCTAssertEqual(runner.shellIntegrationStarted.wait(timeout: .now() + 1), .success)

        let pendingPaneIDs = model.panes[id]!.map(\.id)
        let pendingActivePane = model.activePane[id]
        XCTAssertFalse(model.isTerminalVisible(id))

        model.reload(id)
        model.newTerminal(id)

        XCTAssertEqual(model.panes[id]!.map(\.id), pendingPaneIDs)
        XCTAssertEqual(model.activePane[id], pendingActivePane)

        runner.releaseShellIntegration.signal()
        for _ in 0 ..< 100 where !model.isTerminalVisible(id) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.isTerminalVisible(id))

        model.newTerminal(id)
        XCTAssertEqual(model.panes[id]?.count, 2)
        let activeBeforeReload = model.activePane[id]
        model.reload(id)
        XCTAssertEqual(model.panes[id]?.count, 1)
        XCTAssertNotEqual(model.activePane[id], activeBeforeReload)
    }

    func testFailedShellIntegrationRevealsTheMountedTerminal() async {
        let id = "failed-integration-pod"
        let model = AppModel(
            runner: FailingShellIntegrationRunner(),
            interval: 3_600,
            initialWorkspaces: [WorkspaceView(
                id: id,
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            handoffTimeout: 1
        )

        model.connect(id)
        model.panes[id]?.first?.onFirstOutput?()
        let mountedPaneID = model.panes[id]!.first!.id
        for _ in 0 ..< 100 where !model.isTerminalVisible(id) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(model.isTerminalVisible(id))
        XCTAssertEqual(model.panes[id]?.count, 1)
        XCTAssertEqual(model.panes[id]?.first?.id, mountedPaneID)
    }

    func testTimedOutShellIntegrationRevealsTheMountedTerminal() async {
        let id = "timed-out-integration-pod"
        let runner = BlockingShellIntegrationRunner()
        let scheduler = ManualHandoffTimeoutScheduler()
        let model = AppModel(
            runner: runner,
            interval: 3_600,
            initialWorkspaces: [WorkspaceView(
                id: id,
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            handoffTimeoutScheduler: scheduler
        )
        defer { runner.releaseShellIntegration.signal() }

        model.connect(id)
        XCTAssertEqual(
            runner.shellIntegrationStarted.wait(timeout: .now() + 0.05),
            .timedOut
        )
        let mountedPaneID = model.panes[id]!.first!.id
        XCTAssertFalse(model.isTerminalVisible(id))
        scheduler.fire()

        XCTAssertTrue(model.isTerminalVisible(id))
        XCTAssertEqual(model.panes[id]?.count, 1)
        XCTAssertEqual(model.panes[id]?.first?.id, mountedPaneID)
        XCTAssertEqual(
            runner.shellIntegrationStarted.wait(timeout: .now() + 0.05),
            .timedOut
        )

        for _ in 0 ..< 100 {
            await Task.yield()
        }
        XCTAssertTrue(model.isTerminalVisible(id))
        XCTAssertEqual(model.panes[id]?.count, 1)
        XCTAssertEqual(model.panes[id]?.first?.id, mountedPaneID)
    }
}
