import XCTest
@testable import DevSpaceCore

final class PTYTests: XCTestCase {
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
}
