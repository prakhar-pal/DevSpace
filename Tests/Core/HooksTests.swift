import XCTest
@testable import DevSpaceCore

// Mirrors hooks.rs tests.
final class HooksTests: XCTestCase {
    private final class RecordingRunner: CommandRunning, @unchecked Sendable {
        private let responses: [String]
        var calls: [[String]] = []

        init(responses: [String] = ["{}"]) {
            self.responses = responses
        }

        func run(_ args: [String]) throws -> String {
            calls.append(args)
            let index = calls.count - 1
            return responses.indices.contains(index) ? responses[index] : "{}"
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
        XCTAssertEqual(read, [
            "ssh", "--command",
            "cat \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json\" 2>/dev/null || echo '{}'",
            "--start-services=false", "--", "wc-1",
        ])
        let write = try XCTUnwrap(runner.calls.dropFirst().first)
        XCTAssertEqual(Array(write.prefix(2)), ["ssh", "--command"])
        XCTAssertEqual(write[3...], ["--start-services=false", "--", "wc-1"])
        return write
    }

    private func settingsPayload(from write: [String]) throws -> [String: Any] {
        let command = try XCTUnwrap(write.dropFirst(2).first)
        let prefix = "&& echo "
        let suffix = " | base64 -d > \"$CLAUDE_DIR/settings.json\""
        let payloadStart = try XCTUnwrap(command.range(of: prefix)?.upperBound)
        let payloadEnd = try XCTUnwrap(command.range(of: suffix, range: payloadStart..<command.endIndex)?.lowerBound)
        let encoded = String(command[payloadStart..<payloadEnd])
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
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

    func testInjectPreservesExistingSettingsInWrittenPayload() throws {
        let existing: [String: Any] = [
            "permissions": ["allow": ["Bash(git:*)"]],
            "hooks": ["Notification": [["hooks": [["type": "command", "command": "echo other"]]]]],
        ]
        let existingData = try JSONSerialization.data(withJSONObject: existing, options: [.sortedKeys])
        let runner = RecordingRunner(responses: [String(decoding: existingData, as: UTF8.self)])

        try Hooks.inject(runner, podID: "wc-1", token: "tok", installManualHelper: false)

        let written = try settingsPayload(from: try assertSettingsReadThenWrite(runner))
        let permissions = try XCTUnwrap(written["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["allow"] as? [String], ["Bash(git:*)"])
        XCTAssertEqual(eventArray(written, "Notification")?.count, 2)
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
