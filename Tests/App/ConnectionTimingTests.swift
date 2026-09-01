import XCTest
@testable import DevSpaceApp
import DevSpaceCore

@MainActor
final class ConnectionTimingTests: XCTestCase {
    private final class ManualConnectionRetryScheduler: AppModel.ConnectionRetryScheduling {
        private(set) var scheduled: [(delay: TimeInterval, action: () -> Void)] = []

        func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
            scheduled.append((delay, action))
        }

        func fireNext() {
            scheduled.removeFirst().action()
        }
    }

    private final class ManualHandoffTimeoutScheduler: AppModel.HandoffTimeoutScheduling {
        private var action: (() -> Void)?

        func schedule(after _: TimeInterval, action: @escaping () -> Void) {
            self.action = action
        }

        func fire() {
            action?()
            action = nil
        }
    }

    private final class DeferredSSHProxyResolver {
        private var completions: [(String?) -> Void] = []

        func resolve(_ podID: String, completion: @escaping (String?) -> Void) {
            XCTAssertEqual(podID, "wc-1")
            completions.append(completion)
        }

        func complete(at index: Int, with proxyCommand: String?) {
            completions[index](proxyCommand)
        }
    }

    func testConnectWaitsForProxyResolutionBeforeMountingSSHPane() {
        let resolver = DeferredSSHProxyResolver()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            sshProxyResolver: resolver.resolve
        )

        model.connect("wc-1")

        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)

        resolver.complete(at: 0, with: "devpod ssh --stdio wc-1")

        XCTAssertEqual(model.panes["wc-1"]?.count, 1)
    }

    func testStaleProxyResolutionCannotMountAfterDisconnectAndReconnect() {
        let resolver = DeferredSSHProxyResolver()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            sshProxyResolver: resolver.resolve
        )

        model.connect("wc-1") // attempt A
        model.disconnect("wc-1")
        model.connect("wc-1") // attempt B

        resolver.complete(at: 0, with: "devpod ssh --stdio wc-1")
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)

        resolver.complete(at: 1, with: "devpod ssh --stdio wc-1")
        XCTAssertEqual(model.panes["wc-1"]?.count, 1)
    }

    func testPreReadySSHExitRetriesTwiceThenShowsFailure() {
        let scheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: scheduler
        )

        model.connect("wc-1")
        let firstPane = model.panes["wc-1"]!.first!
        firstPane.onExit?(255)

        XCTAssertTrue(model.isConnecting("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)
        XCTAssertEqual(scheduler.scheduled.map(\.delay), [0.5])
        XCTAssertNil(model.connectionFailure("wc-1"))

        scheduler.fireNext()
        let secondPane = model.panes["wc-1"]!.first!
        XCTAssertNotEqual(secondPane.id, firstPane.id)
        secondPane.onExit?(255)
        XCTAssertEqual(scheduler.scheduled.map(\.delay), [1.5])

        scheduler.fireNext()
        let thirdPane = model.panes["wc-1"]!.first!
        thirdPane.onExit?(255)

        XCTAssertFalse(model.isConnecting("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)
        XCTAssertTrue(scheduler.scheduled.isEmpty)
        XCTAssertEqual(model.connectionFailure("wc-1"), "SSH connection failed (exit 255).")
    }

    func testDisconnectCancelsPendingStartupRetry() {
        let scheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: scheduler
        )

        model.connect("wc-1")
        model.panes["wc-1"]?.first?.onExit?(255)
        model.disconnect("wc-1")
        scheduler.fireNext()

        XCTAssertFalse(model.opened.contains("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)
        XCTAssertNil(model.connectionFailure("wc-1"))
    }

    func testStoppedWorkspaceCancelsPendingStartupRetry() {
        let scheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: scheduler
        )

        model.connect("wc-1")
        model.panes["wc-1"]?.first?.onExit?(255)
        model.receivePollUpdate(PollUpdate(revision: 1, views: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Stopped",
                error: nil
            )]))
        scheduler.fireNext()

        XCTAssertFalse(model.opened.contains("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)
        XCTAssertNil(model.connectionFailure("wc-1"))
    }

    func testRetryWaitsForRunningAfterTransientUnknownStatus() {
        let scheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: scheduler
        )

        model.connect("wc-1")
        model.panes["wc-1"]?.first?.onExit?(255)
        model.receivePollUpdate(PollUpdate(
            revision: 1,
            views: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Unknown",
                error: "temporary status failure"
            )],
            hasFreshStatuses: false
        ))
        scheduler.fireNext()

        XCTAssertFalse(model.opened.contains("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)

        model.receivePollUpdate(PollUpdate(revision: 2, views: [WorkspaceView(
            id: "wc-1",
            provider: "test",
            source: "",
            lastUsed: "",
            state: "Running",
            error: nil
        )]))

        XCTAssertTrue(model.opened.contains("wc-1"))
        XCTAssertEqual(model.panes["wc-1"]?.count, 1)
    }

    func testManualConnectClearsFailureAndRestoresRetryBudget() {
        let scheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: scheduler
        )

        model.connect("wc-1")
        for attempt in 0 ..< 3 {
            model.panes["wc-1"]?.first?.onExit?(255)
            if attempt < 2 { scheduler.fireNext() }
        }
        XCTAssertNotNil(model.connectionFailure("wc-1"))

        model.connect("wc-1")
        XCTAssertNil(model.connectionFailure("wc-1"))
        model.panes["wc-1"]?.first?.onExit?(255)

        XCTAssertEqual(scheduler.scheduled.map(\.delay), [0.5])
        XCTAssertTrue(model.isConnecting("wc-1"))
    }

    func testEstablishedPrimaryExitDoesNotRetry() {
        let retryScheduler = ManualConnectionRetryScheduler()
        let handoffScheduler = ManualHandoffTimeoutScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            handoffTimeoutScheduler: handoffScheduler,
            connectionRetryScheduler: retryScheduler
        )

        model.connect("wc-1")
        let pane = model.panes["wc-1"]!.first!
        handoffScheduler.fire()
        pane.onExit?(255)

        XCTAssertFalse(model.opened.contains("wc-1"))
        XCTAssertTrue(retryScheduler.scheduled.isEmpty)
        XCTAssertNil(model.connectionFailure("wc-1"))
    }

    func testExtraTerminalExitDoesNotRetryOrDisconnectPrimary() {
        let retryScheduler = ManualConnectionRetryScheduler()
        let handoffScheduler = ManualHandoffTimeoutScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            handoffTimeoutScheduler: handoffScheduler,
            connectionRetryScheduler: retryScheduler
        )

        model.connect("wc-1")
        handoffScheduler.fire()
        model.newTerminal("wc-1")
        let extraPane = model.panes["wc-1"]![1]
        extraPane.onExit?(255)

        XCTAssertTrue(model.opened.contains("wc-1"))
        XCTAssertEqual(model.panes["wc-1"]?.count, 1)
        XCTAssertTrue(retryScheduler.scheduled.isEmpty)
    }

    func testElapsedMillisecondsUsesMonotonicNanoseconds() {
        XCTAssertEqual(AppModel.elapsedMilliseconds(
            startedAt: 1_000_000_000,
            now: 2_234_999_999
        ), 1_234)
        XCTAssertEqual(AppModel.elapsedMilliseconds(startedAt: 10, now: 9), 0)
    }

    func testTerminalReadinessDoesNotWaitForClaudeHooks() {
        XCTAssertTrue(AppModel.isTerminalReady(
            hooksFinished: false,
            shellIntegrationFinished: true
        ))
        XCTAssertFalse(AppModel.isTerminalReady(
            hooksFinished: true,
            shellIntegrationFinished: false
        ))
    }

    func testConnectingIncludesMountedTerminalAwaitingIntegration() {
        XCTAssertTrue(AppModel.isConnecting(
            isOpened: true,
            hasPanes: true,
            isAwaitingShellIntegration: true
        ))
    }

    func testMountedTerminalIsVisibleAfterIntegrationHandoff() {
        XCTAssertTrue(AppModel.isTerminalVisible(isAwaitingShellIntegration: false))
        XCTAssertFalse(AppModel.isTerminalVisible(isAwaitingShellIntegration: true))
    }

    func testSelectedLifecyclePanesAreDisplayVisibleBeforeSSHIsReady() {
        XCTAssertTrue(AppModel.isPaneDisplayVisible(
            isSelected: true,
            phase: .starting,
            isTerminalVisible: false
        ))
        XCTAssertTrue(AppModel.isPaneDisplayVisible(
            isSelected: true,
            phase: .shuttingDown,
            isTerminalVisible: false
        ))
    }

    func testPaneDisplayVisibilityPreservesSelectionAndSSHHandoffRules() {
        XCTAssertFalse(AppModel.isPaneDisplayVisible(
            isSelected: false,
            phase: .starting,
            isTerminalVisible: true
        ))
        XCTAssertFalse(AppModel.isPaneDisplayVisible(
            isSelected: true,
            phase: .terminal,
            isTerminalVisible: false
        ))
        XCTAssertTrue(AppModel.isPaneDisplayVisible(
            isSelected: true,
            phase: .terminal,
            isTerminalVisible: true
        ))
    }

    func testIntegrationCompletingBeforeSSHOutputRevealsOriginalTerminal() {
        XCTAssertEqual(
            AppModel.terminalHandoffAction(
                integrationSucceeded: true,
                sshProducedOutput: false
            ),
            .revealOriginal
        )
    }

    func testIntegrationCompletingAfterSSHOutputRestartsRemoteShell() {
        XCTAssertEqual(
            AppModel.terminalHandoffAction(
                integrationSucceeded: true,
                sshProducedOutput: true
            ),
            .restartRemoteShellThenReveal
        )
    }

    func testFailedIntegrationRevealsOriginalTerminal() {
        XCTAssertEqual(
            AppModel.terminalHandoffAction(
                integrationSucceeded: false,
                sshProducedOutput: true
            ),
            .revealOriginal
        )
    }

    func testSuccessfulShellIntegrationConfirmsSSHIndependentlyOfTheHandoff() {
        XCTAssertTrue(AppModel.shouldConfirmSSH(forShellIntegrationSuccess: true))
        XCTAssertFalse(AppModel.shouldConfirmSSH(forShellIntegrationSuccess: false))
    }

    func testHandoffMountsPrimaryBeforeSchedulingTimeout() {
        var events: [String] = []

        AppModel.startTerminalHandoff(
            mountPrimary: { events.append("mount") },
            scheduleTimeout: { delay in events.append("timeout:\(Int(delay))") }
        )

        XCTAssertEqual(events, ["mount", "timeout:10"])
    }

    func testFirstOutputThenSuccessfulIntegrationRestartsRemoteShell() {
        let paneID = UUID()
        var handoff = AppModel.TerminalHandoffState(paneID: paneID)

        XCTAssertNil(handoff.handle(.firstOutput(paneID: paneID)))
        XCTAssertEqual(
            handoff.handle(.integrationFinished(
                paneID: paneID,
                succeeded: true,
                sshProducedOutputAtIngress: false
            )),
            .restartRemoteShellThenReveal
        )
    }

    func testSuccessfulIntegrationUsesOutputObservedAtPTYIngress() {
        let paneID = UUID()
        var handoff = AppModel.TerminalHandoffState(paneID: paneID)

        // PTY output may be observed on its read queue before its UI delivery
        // reaches the main actor. The handoff must still restart that shell.
        XCTAssertEqual(
            handoff.handle(.integrationFinished(
                paneID: paneID,
                succeeded: true,
                sshProducedOutputAtIngress: true
            )),
            .restartRemoteShellThenReveal
        )
    }

    func testFailedIntegrationAndTimeoutRevealOriginalTerminal() {
        let failedPaneID = UUID()
        var failed = AppModel.TerminalHandoffState(paneID: failedPaneID)
        XCTAssertEqual(
            failed.handle(.integrationFinished(
                paneID: failedPaneID,
                succeeded: false,
                sshProducedOutputAtIngress: true
            )),
            .revealOriginal
        )

        let timedOutPaneID = UUID()
        var timedOut = AppModel.TerminalHandoffState(paneID: timedOutPaneID)
        XCTAssertEqual(
            timedOut.handle(.timedOut(paneID: timedOutPaneID)),
            .revealOriginal
        )
    }

    func testTimeoutIsPaneBoundAndRejectsLateIntegrationCompletion() {
        let paneID = UUID()
        var handoff = AppModel.TerminalHandoffState(paneID: paneID)

        XCTAssertNil(handoff.handle(.timedOut(paneID: UUID())))
        XCTAssertEqual(
            handoff.handle(.timedOut(paneID: paneID)),
            .revealOriginal
        )
        XCTAssertNil(handoff.handle(.integrationFinished(
            paneID: paneID,
            succeeded: true,
            sshProducedOutputAtIngress: true
        )))
    }

    func testCancellationRejectsStaleIntegrationCompletion() {
        let paneID = UUID()
        var handoff = AppModel.TerminalHandoffState(paneID: paneID)

        handoff.cancel()

        XCTAssertNil(handoff.handle(.integrationFinished(
            paneID: paneID,
            succeeded: true,
            sshProducedOutputAtIngress: true
        )))
    }

    func testRemoteShellRestartCommandResetsThenExecsInteractiveShell() {
        XCTAssertEqual(
            TerminalPaneModel.restartRemoteShellCommand,
            "\u{3}reset; exec \"${SHELL:-/bin/sh}\" -i\r"
        )
    }
}
