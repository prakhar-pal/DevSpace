import XCTest
@testable import DevSpaceCore

// Mirrors hooks.rs tests.
final class HooksTests: XCTestCase {
    private final class RecordingRunner: CommandRunning, @unchecked Sendable {
        var calls: [[String]] = []

        func run(_ args: [String]) throws -> String {
            calls.append(args)
            return "{}"
        }
    }

    private func eventArray(_ merged: [String: Any], _ key: String) -> [Any]? {
        (merged["hooks"] as? [String: Any])?[key] as? [Any]
    }

    private func canonical(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func assertSettingsReadThenWrite(_ runner: RecordingRunner) throws -> [String] {
        XCTAssertEqual(runner.calls.count, 2)
        let read = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(Array(read.prefix(2)), ["ssh", "--command"])
        XCTAssertEqual(
            try XCTUnwrap(read.dropFirst(2).first),
            "cat \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json\" 2>/dev/null || echo '{}'"
        )
        return try XCTUnwrap(runner.calls.dropFirst().first)
    }

    func testAddsHooksToEmptySettings() {
        let merged = Hooks.mergeSettings(nil, podID: "wc-1", token: "tok")
        XCTAssertEqual(eventArray(merged, "Notification")?.count, 1)
        XCTAssertEqual(eventArray(merged, "Stop")?.count, 1)
        XCTAssertEqual(eventArray(merged, "PreToolUse")?.count, 1)
    }

    func testIsIdempotent() {
        let once = Hooks.mergeSettings(nil, podID: "wc-1", token: "tok")
        let twice = Hooks.mergeSettings(once, podID: "wc-1", token: "tok")
        XCTAssertEqual(canonical(once), canonical(twice))
    }

    func testPreservesExistingUnrelatedHooks() {
        let existing: [String: Any] = [
            "hooks": ["Notification": [["hooks": [["type": "command", "command": "echo other"]]]]],
        ]
        let merged = Hooks.mergeSettings(existing, podID: "wc-1", token: "tok")
        XCTAssertEqual(eventArray(merged, "Notification")?.count, 2)
    }

    func testReinjectingReplacesOldTokenNotAccumulates() {
        let once = Hooks.mergeSettings(nil, podID: "wc-1", token: "tok1")
        let twice = Hooks.mergeSettings(once, podID: "wc-1", token: "tok2")
        let arr = eventArray(twice, "Notification")!
        XCTAssertEqual(arr.count, 1)
        let entry = arr[0] as! [String: Any]
        let cmd = ((entry["hooks"] as! [Any])[0] as! [String: Any])["command"] as! String
        XCTAssertTrue(cmd.contains("tok2"))
        XCTAssertFalse(cmd.contains("tok1"))
    }

    func testBase64MatchesKnownVector() {
        XCTAssertEqual(Hooks.base64Encode(Data("hi".utf8)), "aGk=")
        XCTAssertEqual(Hooks.base64Encode(Data("foo".utf8)), "Zm9v")
    }

    func testHelperScriptBakesPodAndToken() {
        let s = Hooks.notifyHelperScript(podID: "wc-1", token: "deadbeef")
        XCTAssertTrue(s.hasPrefix("#!/usr/bin/env bash"))
        XCTAssertTrue(s.contains("wc-1"))
        XCTAssertTrue(s.contains("deadbeef"))
        XCTAssertTrue(s.contains("/notify"))
        XCTAssertTrue(s.contains("${1:-Stop}"))
    }

    func testInjectWithManualHelperWritesSettingsAndHelper() throws {
        let runner = RecordingRunner()

        try Hooks.inject(runner, podID: "wc-1", token: "tok", installManualHelper: true)

        let write = try assertSettingsReadThenWrite(runner)
        XCTAssertEqual(Array(write.prefix(2)), ["ssh", "--command"])
        XCTAssertTrue(write[2].contains("settings.json"))
        XCTAssertTrue(write[2].contains("~/.devspace-notify"))
        XCTAssertTrue(write[2].contains("chmod +x ~/.devspace-notify"))
    }

    func testInjectWithoutManualHelperWritesSettingsOnly() throws {
        let runner = RecordingRunner()

        try Hooks.inject(runner, podID: "wc-1", token: "tok", installManualHelper: false)

        let write = try assertSettingsReadThenWrite(runner)
        XCTAssertEqual(Array(write.prefix(2)), ["ssh", "--command"])
        XCTAssertTrue(write[2].contains("base64 -d > \"$CLAUDE_DIR/settings.json\""))
        XCTAssertFalse(write[2].contains("~/.devspace-notify"))
        XCTAssertFalse(write[2].contains("chmod +x"))
    }

    func testBakesLiteralPodIdTokenEventNoEnv() {
        let merged = Hooks.mergeSettings(nil, podID: "wc-7", token: "deadbeef")
        let arr = eventArray(merged, "PreToolUse")!
        XCTAssertEqual(arr.count, 1)
        let entry = arr[0] as! [String: Any]
        XCTAssertEqual(entry["matcher"] as? String, "AskUserQuestion")
        let cmd = ((entry["hooks"] as! [Any])[0] as! [String: Any])["command"] as! String
        XCTAssertTrue(cmd.contains("AskUserQuestion"))
        XCTAssertTrue(cmd.contains("wc-7"))
        XCTAssertTrue(cmd.contains("deadbeef"))
        XCTAssertFalse(cmd.contains("$CLAUDE_HOOK_EVENT_NAME"))
        XCTAssertFalse(cmd.contains("$DEVSPACE_POD_ID"))
        XCTAssertFalse(cmd.contains("$DEVSPACE_NOTIFY_TOKEN"))
    }

    func testToleratesMalformedSettings() {
        let m1 = Hooks.mergeSettings(["hooks": "garbage"], podID: "wc-1", token: "tok")
        XCTAssertNotNil(m1["hooks"] as? [String: Any])
        XCTAssertEqual(eventArray(m1, "Stop")?.count, 1)
        XCTAssertEqual(eventArray(m1, "Notification")?.count, 1)
        XCTAssertEqual(eventArray(m1, "PreToolUse")?.count, 1)

        let m2 = Hooks.mergeSettings(["hooks": ["Stop": 5]], podID: "wc-1", token: "tok")
        XCTAssertEqual(eventArray(m2, "Stop")?.count, 1)
        XCTAssertEqual(eventArray(m2, "Notification")?.count, 1)
    }
}
