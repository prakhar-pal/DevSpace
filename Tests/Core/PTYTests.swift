import XCTest
@testable import DevSpaceCore

final class PTYTests: XCTestCase {
    #if os(Linux)
    func testExitWaitsForOutputCallbackToFinish() {
        let pty = PTYSession()
        let entered = expectation(description: "output callback entered")
        let premature = expectation(description: "exit must not overtake output")
        premature.isInverted = true
        let exited = expectation(description: "exit reported")
        let releaseOutput = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var drained = false
        pty.onOutput = { _ in
            entered.fulfill()
            _ = releaseOutput.wait(timeout: .now() + 3)
            lock.lock(); drained = true; lock.unlock()
        }
        pty.onExit = { _ in
            lock.lock(); let finished = drained; lock.unlock()
            if !finished { premature.fulfill() }
            exited.fulfill()
        }
        pty.start(path: "/bin/echo", args: ["ordered-output"], cols: 80, rows: 24)
        wait(for: [entered], timeout: 2)
        wait(for: [premature], timeout: 0.2)
        releaseOutput.signal()
        wait(for: [exited], timeout: 2)
    }
    #endif

    func testRapidPTYLifecyclesPreserveOutputAndSingleExit() {
        for index in 0..<128 {
            let pty = PTYSession()
            let output = expectation(description: "PTY \(index) output")
            output.assertForOverFulfill = false
            let exited = expectation(description: "PTY \(index) exits once")
            let marker = "devspace-cycle-\(index)"
            pty.onOutput = { data in
                if String(decoding: data, as: UTF8.self).contains(marker) { output.fulfill() }
            }
            pty.onExit = { status in
                XCTAssertEqual(status, 0)
                exited.fulfill()
            }
            pty.start(path: "/bin/echo", args: [marker], cols: 80, rows: 24)
            wait(for: [output, exited], timeout: 5)
            pty.terminate()
        }
    }

    /// Spawns a real PTY child, reads its output, and confirms exit — exercising
    /// forkpty + execve + the read loop + reap without any GUI.
    func testEchoRunsStreamsOutputAndExits() {
        let pty = PTYSession()
        let outputSeen = expectation(description: "output contains marker")
        outputSeen.assertForOverFulfill = false
        let exited = expectation(description: "child exits")

        let buffer = NSMutableData()
        let bufLock = NSLock()

        pty.onOutput = { data in
            bufLock.lock()
            buffer.append(data)
            let text = String(data: buffer as Data, encoding: .utf8) ?? ""
            bufLock.unlock()
            if text.contains("devspace-pty-ok") { outputSeen.fulfill() }
        }
        pty.onExit = { code in
            XCTAssertEqual(code, 0)
            exited.fulfill()
        }

        pty.start(path: "/bin/echo", args: ["devspace-pty-ok"], cols: 80, rows: 24)
        wait(for: [outputSeen, exited], timeout: 5)
    }

    func testStartIsIdempotent() {
        let pty = PTYSession()
        let exited = expectation(description: "exits once")
        exited.assertForOverFulfill = true
        pty.onExit = { _ in exited.fulfill() }
        pty.start(path: "/bin/echo", args: ["hi"], cols: 80, rows: 24)
        pty.start(path: "/bin/echo", args: ["again"], cols: 80, rows: 24) // ignored
        wait(for: [exited], timeout: 5)
    }

    func testTerminateReapsChildAndReportsExitOnce() {
        let pty = PTYSession()
        let exited = expectation(description: "terminated child is reaped")
        exited.assertForOverFulfill = true
        var exitCodes: [Int32] = []
        let lock = NSLock()
        pty.onExit = { code in
            lock.lock()
            exitCodes.append(code)
            lock.unlock()
            exited.fulfill()
        }

        pty.start(path: "/bin/sleep", args: ["30"], cols: 80, rows: 24)
        pty.terminate()

        wait(for: [exited], timeout: 5)
        lock.lock()
        let codes = exitCodes
        lock.unlock()
        XCTAssertEqual(codes, [143])
    }

    func testTerminateBeforeStartPreventsChildLaunch() {
        let pty = PTYSession()
        let output = expectation(description: "terminated PTY emits no output")
        output.isInverted = true
        let exited = expectation(description: "terminated PTY starts no child")
        exited.isInverted = true
        pty.onOutput = { _ in output.fulfill() }
        pty.onExit = { _ in exited.fulfill() }

        pty.terminate()
        pty.start(path: "/bin/echo", args: ["must-not-launch"], cols: 80, rows: 24)

        wait(for: [output, exited], timeout: 0.25)
    }
}
