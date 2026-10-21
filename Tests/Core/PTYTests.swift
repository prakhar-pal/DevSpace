import XCTest
@testable import DevSpaceCore

final class PTYTests: XCTestCase {
    func testWorkingDirectoryEnvironmentInputAndChildResize() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/pty-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pty = PTYSession()
        let ready = expectation(description: "child ready")
        ready.assertForOverFulfill = false
        let exited = expectation(description: "child exited")
        let buffer = NSMutableData()
        let lock = NSLock()
        pty.onOutput = { data in
            lock.lock(); buffer.append(data); let text = String(decoding: buffer as Data, as: UTF8.self); lock.unlock()
            if text.contains("READY") { ready.fulfill() }
        }
        pty.onExit = { code in XCTAssertEqual(code, 0); exited.fulfill() }
        let pid = pty.start(path: "/bin/sh", args: ["-c",
            "stty -echo; printf 'cwd:%s env:%s READY\\n' \"$PWD\" \"$DEVSPACE_PTY_TEST\"; IFS= read -r line; stty size; printf 'received:%s\\n' \"$line\""],
            cols: 80, rows: 24, extraEnv: ["DEVSPACE_PTY_TEST": "inherited-marker"], workingDirectory: directory.path)
        XCTAssertNotNil(pid)
        wait(for: [ready], timeout: 3)
        pty.resize(cols: 97, rows: 31)
        pty.write(Data("λ界🙂\n".utf8))
        wait(for: [exited], timeout: 3)
        lock.lock(); let text = String(decoding: buffer as Data, as: UTF8.self); lock.unlock()
        XCTAssertTrue(text.contains("cwd:\(directory.path) env:inherited-marker"), text)
        XCTAssertTrue(text.contains("31 97"), text)
        XCTAssertTrue(text.contains("received:λ界🙂"), text)
    }

    #if os(Linux)
    func testTerminateClosesDescendantsAfterLeaderExits() {
        let pty = PTYSession()
        let ready = expectation(description: "descendant ready")
        ready.assertForOverFulfill = false
        let exited = expectation(description: "PTY descendant closed")
        let lock = NSLock()
        var didExit = false
        pty.onOutput = { data in if String(decoding: data, as: UTF8.self).contains("READY") { ready.fulfill() } }
        pty.onExit = { _ in lock.lock(); didExit = true; lock.unlock(); exited.fulfill() }
        let pid = pty.start(path: "/bin/sh", args: ["-c", "trap '' HUP; sleep 20 & printf READY; read -r line"], cols: 80, rows: 24)
        defer {
            lock.lock(); let needsCleanup = !didExit; lock.unlock()
            if needsCleanup, let pid { kill(-pid, SIGKILL) }
        }
        wait(for: [ready], timeout: 2)
        pty.terminate()
        wait(for: [exited], timeout: 2)
    }

    func testTerminateDoesNotLeaveAnIgnoringChildRunning() {
        let pty = PTYSession()
        let ready = expectation(description: "ignoring child ready")
        ready.assertForOverFulfill = false
        let exited = expectation(description: "ignoring child terminated")
        let lock = NSLock()
        var didExit = false
        pty.onOutput = { data in if String(decoding: data, as: UTF8.self).contains("READY") { ready.fulfill() } }
        pty.onExit = { _ in lock.lock(); didExit = true; lock.unlock(); exited.fulfill() }
        let pid = pty.start(path: "/bin/sh", args: ["-c", "trap '' TERM; printf READY; read -r line"], cols: 80, rows: 24)
        defer {
            lock.lock(); let needsCleanup = !didExit; lock.unlock()
            if needsCleanup, let pid { kill(pid, SIGKILL) }
        }
        wait(for: [ready], timeout: 2)
        pty.terminate()
        wait(for: [exited], timeout: 2)
    }

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
