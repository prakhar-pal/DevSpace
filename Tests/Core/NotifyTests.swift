import XCTest
@testable import DevSpaceCore

// Mirrors notify.rs tests.
final class NotifyTests: XCTestCase {
    func testMapsEvents() {
        XCTAssertEqual(Notify.messageFor("Stop"), "Claude finished")
        XCTAssertEqual(Notify.messageFor("Notification"), "Claude needs your input")
        XCTAssertEqual(Notify.messageFor("AskUserQuestion"), "Claude needs your input")
    }

    func testParsesPayload() throws {
        let p = try JSONDecoder().decode(
            NotifyPayload.self,
            from: Data(#"{"pod_id":"wc-1","event":"Stop","token":"abc"}"#.utf8)
        )
        XCTAssertEqual(p.podID, "wc-1")
        XCTAssertEqual(p.event, "Stop")
        XCTAssertEqual(p.token, "abc")
    }

    func testTokenDefaultsWhenAbsent() throws {
        let p = try JSONDecoder().decode(
            NotifyPayload.self,
            from: Data(#"{"pod_id":"wc-1","event":"Stop"}"#.utf8)
        )
        XCTAssertEqual(p.token, "")
    }

    func testRandomTokenIs32HexChars() throws {
        let t = try Notify.randomToken()
        XCTAssertEqual(t.count, 32)
        XCTAssertTrue(t.allSatisfy(\.isHexDigit))
    }

    // Integration: exercise the real loopback HTTP listener end to end.

    private func post(port: UInt16, json: String) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/notify")!)
        req.httpMethod = "POST"
        req.httpBody = Data(json.utf8)
        let done = expectation(description: "posted")
        URLSession.shared.dataTask(with: req) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 3)
    }

    func testListenerInvokesOnNotifyForMatchingToken() throws {
        let port: UInt16 = 17987
        let got = expectation(description: "onNotify")
        var received: (String, String)?
        let listener = NotifyListener(expectedToken: "secret", port: port) { pod, msg in
            received = (pod, msg)
            got.fulfill()
        }
        try listener.start()
        defer { listener.stop() }
        Thread.sleep(forTimeInterval: 0.3) // let it bind

        post(port: port, json: #"{"pod_id":"wc-1","event":"Stop","token":"secret"}"#)
        wait(for: [got], timeout: 3)
        XCTAssertEqual(received?.0, "wc-1")
        XCTAssertEqual(received?.1, "Claude finished")
    }

    func testListenerIgnoresWrongToken() throws {
        let port: UInt16 = 17988
        let notFired = expectation(description: "onNotify must not fire")
        notFired.isInverted = true
        let listener = NotifyListener(expectedToken: "secret", port: port) { _, _ in
            notFired.fulfill()
        }
        try listener.start()
        defer { listener.stop() }
        Thread.sleep(forTimeInterval: 0.3)

        post(port: port, json: #"{"pod_id":"wc-1","event":"Stop","token":"WRONG"}"#)
        wait(for: [notFired], timeout: 1.5)
    }
}
