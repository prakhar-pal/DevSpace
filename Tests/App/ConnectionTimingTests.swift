import XCTest
@testable import DevSpaceApp

@MainActor
final class ConnectionTimingTests: XCTestCase {
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

    func testHandoffMountsPrimaryBeforeBeginningIntegrationAndTimeout() {
        var events: [String] = []

        AppModel.startTerminalHandoff(
            mountPrimary: { events.append("mount") },
            beginShellIntegration: { events.append("integration") },
            scheduleTimeout: { delay in events.append("timeout:\(Int(delay))") }
        )

        XCTAssertEqual(events, ["mount", "integration", "timeout:10"])
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
