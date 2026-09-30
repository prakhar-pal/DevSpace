import XCTest
import Darwin
@testable import DevSpaceCore

@MainActor
final class SSHTransportSessionTests: XCTestCase {
    private final class ManualProcess: SSHTransportProcess {
        private var exit: ((Int32) -> Void)?
        private(set) var terminateCount = 0
        var stderrTail = ""

        func setExitHandler(_ handler: @escaping (Int32) -> Void) {
            exit = handler
        }

        func terminate() { terminateCount += 1 }

        func exit(with code: Int32) { exit?(code) }
    }

    private final class ManualScheduler: SSHTransportScheduling {
        private(set) var scheduled: [(delay: TimeInterval, action: () -> Void)] = []

        func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
            scheduled.append((delay, action))
        }

        func fireNext() {
            XCTAssertFalse(scheduled.isEmpty)
            scheduled.removeFirst().action()
        }

        func fireLast() {
            XCTAssertFalse(scheduled.isEmpty)
            scheduled.removeLast().action()
        }
    }

    private final class Harness {
        let process = ManualProcess()
        let scheduler = ManualScheduler()
        var checks: [Bool] = []
        var deferChecks = false
        private var checkCompletions: [(Bool) -> Void] = []

        func makeSession() -> SSHTransportSession {
            SSHTransportSession(
                podID: "wc-1",
                proxyCommand: "devpod ssh --stdio wc-1",
                bundleIdentifier: "com.prakharp.devspace",
                controlPath: "/tmp/devspace-test/socket",
                launch: { _, onExit in
                    self.process.setExitHandler(onExit)
                    return self.process
                },
                check: { _, completion in
                    let result = self.checks.isEmpty ? false : self.checks.removeFirst()
                    if self.deferChecks {
                        self.checkCompletions.append(completion)
                    } else {
                        completion(result)
                    }
                },
                scheduler: self.scheduler
            )
        }

        func completeNextCheck(with result: Bool) {
            checkCompletions.removeFirst()(result)
        }
    }

    func testReadyRequiresSuccessfulControlCheck() {
        let harness = Harness()
        harness.checks = [false, true]
        let session = harness.makeSession()
        var readyCount = 0
        session.onReady = { readyCount += 1 }

        session.start()
        XCTAssertEqual(readyCount, 0)

        harness.scheduler.fireNext()
        XCTAssertEqual(readyCount, 1)
        XCTAssertEqual(session.state, .ready)
    }

    func testReadinessDeadlineTerminatesUnreadyMasterOnce() {
        let harness = Harness()
        harness.checks = [false]
        let session = harness.makeSession()
        var failure: SSHTransportSession.StartError?
        session.onStartError = { failure = $0 }

        session.start()
        XCTAssertEqual(harness.scheduler.scheduled.map(\.delay), [0.2, 15])

        harness.scheduler.fireLast()

        XCTAssertNil(failure)
        XCTAssertEqual(harness.process.terminateCount, 1)
        XCTAssertEqual(session.state, .stopping)
        harness.process.exit(with: 15)
        XCTAssertEqual(session.state, .exited)
        XCTAssertEqual(failure, .readinessTimedOut)
    }

    func testLateCheckAfterStopCannotMakeTransportReady() {
        let harness = Harness()
        harness.deferChecks = true
        let session = harness.makeSession()
        var readyCount = 0
        session.onReady = { readyCount += 1 }

        session.start()
        session.stop()
        harness.completeNextCheck(with: true)

        XCTAssertEqual(readyCount, 0)
        XCTAssertNotEqual(session.state, .ready)
    }

    func testStopNotifiesOnlyAfterTheMasterExits() {
        let harness = Harness()
        harness.checks = [true]
        let session = harness.makeSession()
        var stoppedCount = 0
        session.onStopped = { stoppedCount += 1 }

        session.start()
        XCTAssertEqual(session.state, .ready)

        session.stop()

        XCTAssertEqual(session.state, .stopping)
        XCTAssertEqual(stoppedCount, 0)

        harness.process.exit(with: 0)

        XCTAssertEqual(session.state, .exited)
        XCTAssertEqual(stoppedCount, 1)
    }

    func testExitRetainsMasterDiagnosticTail() {
        let harness = Harness()
        harness.checks = [true]
        harness.process.stderrTail = "remote port is already allocated"
        let session = harness.makeSession()

        session.start()
        harness.process.exit(with: 255)

        XCTAssertEqual(session.stderrTail, "remote port is already allocated")
    }

    func testDefaultMasterControlPathLeavesRoomForOpenSSHTemporarySocketSuffix() {
        let session = SSHTransportSession(
            podID: "wc-8",
            proxyCommand: nil,
            bundleIdentifier: "com.prakharp.devspace.dev"
        )

        // OpenSSH appends a dot plus 16 random characters while binding the
        // ControlMaster listener. macOS allows a 104-byte Unix socket path,
        // including its NUL terminator.
        XCTAssertLessThan(session.controlPath.utf8.count + 17, 104)
    }

    func testDefaultMasterControlPathUsesAnEffectiveUserScopedRoot() {
        let session = SSHTransportSession(
            podID: "wc-8",
            proxyCommand: nil,
            bundleIdentifier: "com.prakharp.devspace.dev"
        )

        XCTAssertTrue(
            session.controlPath.hasPrefix("/tmp/devspace-ssh-\(geteuid())-dev/")
        )
    }
}
