import Foundation
import DevSpaceCore

@main
struct BackendClientTests {
    private static var inbox: [BackendProtocolMessage] = []

    static func main() {
        do {
            guard CommandLine.arguments.count == 4 else { throw TestFailure("expected Python, fixture path, and mode") }
            let client = BackendClient(
                executableURL: URL(fileURLWithPath: CommandLine.arguments[1]),
                arguments: Array(CommandLine.arguments[2...3]),
                channel: "development"
            )
            defer { client.terminate() }
            try client.start()

            switch CommandLine.arguments[3] {
            case "normal": try testNormalProtocol(client)
            case "malformed", "oversized", "disconnect", "wrong-channel":
                try testRejectedPeer(client)
            case "outgoing-frame": try testOversizedFrame(client)
            case "queue": try testBoundedWrites(client)
            default: throw TestFailure("unknown test mode")
            }
        } catch {
            fputs("BackendClientTests: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func testNormalProtocol(_ client: BackendClient) throws {
        let ready = try receive(client, kind: "ready")
        try expect(client.state == .ready, "fragmented handshake was not accepted")
        try expect(ready.payload?["channel"] == "development", "channel was not verified")

        let pollID = try client.send("poll")
        let snapshot = try receive(client, kind: "snapshot", id: pollID)
        try expect(snapshot.payload?["json"]?.contains("\"revision\"") == true,
                   "snapshot response was not preserved")
        _ = try receive(client, kind: "platform_info")

        let pingID = try client.send("ping")
        _ = try receive(client, kind: "pong", id: pingID)

        let shutdownID = try client.shutdown()
        _ = try receive(client, kind: "stopped", id: shutdownID)
        try expect(waitUntil(timeout: 3) { client.state == .stopped },
                   "orderly shutdown did not reap the backend")
        print("backend-client fragmented=ok multi-frame=ok handshake=ok shutdown=ok")
    }

    private static func testRejectedPeer(_ client: BackendClient) throws {
        try expect(waitUntil(timeout: 3) {
            if case .failed = client.state { return true }
            return false
        }, "invalid or disconnected backend was not rejected; state=\(client.state), reason=\(client.failure ?? "none")")
        if CommandLine.arguments[3] == "disconnect" {
            try expect(client.failure?.contains("closed") == true,
                       "unexpected EOF was not reported")
        }
        print("backend-client \(CommandLine.arguments[3])=rejected")
    }

    private static func testBoundedWrites(_ client: BackendClient) throws {
        _ = try receive(client, kind: "ready")
        let payload = ["padding": String(repeating: "x", count: 600_000)]
        var accepted = 0
        var rejectedAtLimit = false
        for _ in 0..<5 {
            do {
                _ = try client.send("ping", payload: payload)
                accepted += 1
            } catch BackendClientError.queueFull {
                rejectedAtLimit = true
                break
            }
        }
        try expect(accepted > 0 && rejectedAtLimit, "write queue did not reject at its byte limit")
        try expect(client.state == .failed, "queue overflow did not fail the control connection closed")
        print("backend-client bounded-write-queue=ok")
    }

    private static func testOversizedFrame(_ client: BackendClient) throws {
        _ = try receive(client, kind: "ready")
        do {
            _ = try client.send("ping", payload: ["padding": String(repeating: "y", count: 1_100_000)])
            throw TestFailure("oversized outgoing frame was accepted")
        } catch BackendClientError.frameTooLarge {
            try expect(client.state == .ready, "a rejected single frame corrupted the connection")
            print("backend-client outgoing-frame-limit=ok")
        }
    }

    private static func receive(_ client: BackendClient, kind: String, id: String? = nil) throws -> BackendProtocolMessage {
        inbox.append(contentsOf: client.takeReceived())
        let matched = waitUntil(timeout: 4) {
            inbox.append(contentsOf: client.takeReceived())
            return inbox.contains { $0.kind == kind && (id == nil || $0.id == id) }
        }
        guard matched, let index = inbox.firstIndex(where: { $0.kind == kind && (id == nil || $0.id == id) }) else {
            throw TestFailure("timed out waiting for \(kind)")
        }
        return inbox.remove(at: index)
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(message) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
