import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import DevSpaceCore

// Mirrors hooks.rs tests.
final class HooksTests: XCTestCase {
    func testSignalDuringPublicationDoesNotContinueWithoutItsLock() throws {
        final class InterruptedRunner: CommandRunning, @unchecked Sendable {
            let directory: URL
            init(_ directory: URL) { self.directory = directory }
            func run(_ args: [String]) throws -> String {
                var interrupted = args
                interrupted[2] = args[2].replacingOccurrences(of: "&& settings_tmp=", with: "&& kill -TERM $$ && settings_tmp=")
                return try LocalShellRunner(directory: directory).run(interrupted)
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-signal-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("settings.json")
        let original = "{\"unrelated\":true}"
        try original.write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Hooks.inject(InterruptedRunner(directory), podID: "pod", token: "tok", installManualHelper: false))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".devspace-settings.lock").path))
    }
    func testConcurrentSettingsEditIsNotOverwritten() throws {
        final class EditingRunner: CommandRunning, @unchecked Sendable {
            let directory: URL
            var calls = 0
            init(_ directory: URL) { self.directory = directory }
            func run(_ args: [String]) throws -> String {
                calls += 1
                if calls == 2 {
                    try "{\"concurrentEdit\":true}".write(to: directory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
                }
                return try LocalShellRunner(directory: directory).run(args)
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-race-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = EditingRunner(directory)
        XCTAssertThrowsError(try Hooks.inject(runner, podID: "pod", token: "tok", installManualHelper: false))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("settings.json"), encoding: .utf8), "{\"concurrentEdit\":true}")
    }
    private final class LocalShellRunner: CommandRunning, @unchecked Sendable {
        let runner: DesktopCommandRunner
        init(directory: URL, environment: [String: String] = [:]) {
            runner = DesktopCommandRunner(executable: "/bin/sh", environment: environment.merging(["CLAUDE_CONFIG_DIR": directory.path]) { _, value in value })
        }
        func run(_ args: [String]) throws -> String { try runner.run(["-c", args[2]]) }
    }

    func testFailedSettingsDecodeLeavesOriginalFileUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-atomic-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("settings.json")
        let original = "{\"permissions\":{\"allow\":[\"Bash(git:*)\"]}}"
        try original.write(to: settings, atomically: true, encoding: .utf8)
        let decoder = directory.appendingPathComponent("base64")
        try "#!/bin/sh\nprintf broken\nexit 1\n".write(to: decoder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: decoder.path)
        let environment = ["PATH": directory.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")]
        XCTAssertThrowsError(try Hooks.inject(LocalShellRunner(directory: directory, environment: environment), podID: "pod", token: "tok", installManualHelper: false))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".devspace-settings-") })
    }

    func testInstalledSettingsArePrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-private-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Hooks.inject(LocalShellRunner(directory: directory), podID: "pod", token: "tok", installManualHelper: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("settings.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testUnreadableButWritableSettingsAreNotReplacedWithEmptySettings() throws {
        try XCTSkipIf(geteuid() == 0, "Root bypasses file read permissions; run this test as an unprivileged user")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-settings-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("settings.json")
        let original = "{\"permissions\":{\"allow\":[\"Bash(git:*)\"]}}"
        try original.write(to: settings, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: settings.path)
        XCTAssertThrowsError(try Hooks.inject(LocalShellRunner(directory: directory), podID: "pod", token: "tok", installManualHelper: false))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original)
    }
    func testMalformedExistingSettingsAreNeverOverwritten() throws {
        for settings in ["{not-json", "[]", "null", ""] {
            let runner = RecordingRunner(responses: [settings])
            XCTAssertThrowsError(try Hooks.inject(runner, podID: "wc-1", token: "tok", installManualHelper: true))
            XCTAssertEqual(runner.calls.count, 1, "invalid existing settings must not reach the write command")
        }
    }
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
            "if [ -e \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json\" ]; then cat \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json\"; else printf '{}'; fi",
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
        let suffix = " | base64 -d > \"$settings_tmp\""
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

    func testPreservesOtherToolsNotificationHooksContainingPodID() throws {
        let command = "curl -d '{\"pod_id\":\"pod\"}' https://other-tool.example/notify"
        let existing: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": command]]]]]]
        let entries = try XCTUnwrap(eventArray(Hooks.mergeSettings(existing, podID: "pod", token: "tok"), "Stop") as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual((entries.first?["hooks"] as? [[String: String]])?.first?["command"], command)
    }

    func testReinjectionPreservesUnrelatedCommandsWithinAManagedHookEntry() throws {
        let old = Hooks.hookCommand("Stop", podID: "pod", token: "old")
        let existing: [String: Any] = ["hooks": ["Stop": [["matcher": "custom", "hooks": [
            ["type": "command", "command": old], ["type": "command", "command": "echo keep-me"],
        ]]]]]
        let merged = Hooks.mergeSettings(existing, podID: "pod", token: "new")
        let entries = try XCTUnwrap(eventArray(merged, "Stop") as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?["matcher"] as? String, "custom")
        XCTAssertEqual((entries.first?["hooks"] as? [[String: String]])?.first?["command"], "echo keep-me")
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
        XCTAssertTrue(write[2].contains("chmod 700 \"$helper_tmp\""))
    }

    func testInjectWithoutManualHelperWritesSettingsOnly() throws {
        let runner = RecordingRunner()

        try Hooks.inject(runner, podID: "wc-1", token: "tok", installManualHelper: false)

        let write = try assertSettingsReadThenWrite(runner)
        XCTAssertEqual(Array(write.prefix(2)), ["ssh", "--command"])
        XCTAssertTrue(write[2].contains("base64 -d > \"$settings_tmp\""))
        XCTAssertFalse(write[2].contains("~/.devspace-notify"))
        XCTAssertFalse(write[2].contains("chmod +x"))
    }

    func testRemoveDeletesOnlyDevspaceHooksAndPreservesOtherSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-remove-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = LocalShellRunner(directory: directory)
        let settingsURL = directory.appendingPathComponent("settings.json")
        let existing: [String: Any] = [
            "permissions": ["allow": ["Bash(git:*)"]],
            "hooks": [
                "Notification": [
                    ["hooks": [["type": "command", "command": "echo unrelated"]]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsURL)
        try Hooks.inject(runner, podID: "wc-1", token: "tok", installManualHelper: false)

        try Hooks.remove(runner, podID: "wc-1")

        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        XCTAssertEqual(result["permissions"] as? [String: [String]], ["allow": ["Bash(git:*)"]])
        XCTAssertEqual(eventArray(result, "Notification")?.count, 1)
        XCTAssertNil(eventArray(result, "Stop"))
        XCTAssertNil(eventArray(result, "PreToolUse"))
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

    func testHookCommandResolvesProductionThenDevelopment() {
        let command = Hooks.hookCommand("Stop", podID: "wc-1", token: "tok")
        XCTAssertTrue(command.contains("__devspace_resolve_port"))
        XCTAssertTrue(command.contains("DEVSPACE_PROD_POD_FORWARD_PORT"))
        XCTAssertTrue(command.contains("DEVSPACE_DEV_POD_FORWARD_PORT"))
        XCTAssertFalse(command.contains("DEVSPACE_POD_FORWARD_PORT="))
        XCTAssertTrue(command.contains("port=\"$(__devspace_resolve_port)\""))
        XCTAssertTrue(command.contains("wc-1"))
        XCTAssertTrue(command.contains("Stop"))
        XCTAssertTrue(command.contains("tok"))
        XCTAssertTrue(command.contains("/notify"))
        XCTAssertTrue(command.contains(">/dev/null 2>&1 || true"))
    }

    func testManualHelperUsesSharedResolver() {
        let script = Hooks.notifyHelperScript(podID: "wc-1", token: "tok")
        XCTAssertTrue(script.contains(PodPortRouting.resolverShell))
        XCTAssertTrue(script.contains("port=\"$(__devspace_resolve_port)\""))
    }

    func testGeneratedHookPrefersProductionAndPreservesRequest() throws {
        let harness = try GeneratedNotificationClientHarness()
        defer { harness.cleanup() }

        let result = try harness.runHook(
            Hooks.hookCommand("Stop", podID: "wc-1", token: "tok"),
            livePorts: [8765, 8766]
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.probedPorts, ["8765"])
        XCTAssertEqual(result.postURL, "http://localhost:8765/notify")
        XCTAssertEqual(result.payload, #"{"pod_id":"wc-1","event":"Stop","token":"tok"}"#)
    }

    func testGeneratedHookFallsBackToDevelopmentAndPreservesRequest() throws {
        let harness = try GeneratedNotificationClientHarness()
        defer { harness.cleanup() }

        let result = try harness.runHook(
            Hooks.hookCommand("Stop", podID: "wc-1", token: "tok"),
            livePorts: [8766]
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.probedPorts, ["8765", "8766"])
        XCTAssertEqual(result.postURL, "http://localhost:8766/notify")
        XCTAssertEqual(result.payload, #"{"pod_id":"wc-1","event":"Stop","token":"tok"}"#)
    }

    func testGeneratedHookExitsSilentlyWithoutPostingWhenNoRouteIsLive() throws {
        let harness = try GeneratedNotificationClientHarness()
        defer { harness.cleanup() }

        let result = try harness.runHook(
            Hooks.hookCommand("Stop", podID: "wc-1", token: "tok"),
            livePorts: []
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.probedPorts, ["8765", "8766"])
        XCTAssertNil(result.postURL)
        XCTAssertNil(result.payload)
    }

    func testGeneratedHelperPrefersProductionAndReportsPreservedRequest() throws {
        let harness = try GeneratedNotificationClientHarness()
        defer { harness.cleanup() }

        let result = try harness.runHelper(
            Hooks.notifyHelperScript(podID: "wc-1", token: "tok"),
            event: "Notification",
            livePorts: [8765, 8766]
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "devspace-notify: sent event=Notification\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.probedPorts, ["8765"])
        XCTAssertEqual(result.postURL, "http://localhost:8765/notify")
        XCTAssertEqual(result.payload, #"{"pod_id":"wc-1","event":"Notification","token":"tok"}"#)
    }

    func testGeneratedHelperFallsBackToDevelopmentAndReportsPreservedRequest() throws {
        let harness = try GeneratedNotificationClientHarness()
        defer { harness.cleanup() }

        let result = try harness.runHelper(
            Hooks.notifyHelperScript(podID: "wc-1", token: "tok"),
            event: "AskUserQuestion",
            livePorts: [8766]
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "devspace-notify: sent event=AskUserQuestion\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.probedPorts, ["8765", "8766"])
        XCTAssertEqual(result.postURL, "http://localhost:8766/notify")
        XCTAssertEqual(result.payload, #"{"pod_id":"wc-1","event":"AskUserQuestion","token":"tok"}"#)
    }

    func testGeneratedHelperReportsFailureWithoutPostingWhenNoRouteIsLive() throws {
        let harness = try GeneratedNotificationClientHarness()
        defer { harness.cleanup() }

        let result = try harness.runHelper(
            Hooks.notifyHelperScript(podID: "wc-1", token: "tok"),
            event: nil,
            livePorts: []
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(
            result.stdout,
            "devspace-notify: failed (is this the DevSpace terminal?)\n"
        )
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.probedPorts, ["8765", "8766"])
        XCTAssertNil(result.postURL)
        XCTAssertNil(result.payload)
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

private struct GeneratedNotificationClientResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let probedPorts: [String]
    let postURL: String?
    let payload: String?
}

private final class GeneratedNotificationClientHarness {
    private let root: URL
    private let binDir: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devspace-notification-client-\(UUID().uuidString)")
        binDir = root.appendingPathComponent("bin", isDirectory: true)

        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            is_post=0
            previous=
            data=
            url=
            for arg in "$@"; do
              if [ "$previous" = "-X" ] && [ "$arg" = "POST" ]; then
                is_post=1
              fi
              if [ "$previous" = "-d" ]; then
                data=$arg
              fi
              previous=$arg
              url=$arg
            done
            port=${url#http://localhost:}
            port=${port%%/*}
            if [ "$is_post" = "1" ]; then
              printf '%s' "$url" > "$DEVSPACE_TEST_POST_URL"
              printf '%s' "$data" > "$DEVSPACE_TEST_POST_PAYLOAD"
              exit 0
            fi
            printf '%s\n' "$port" >> "$DEVSPACE_TEST_PROBES"
            case ",${DEVSPACE_TEST_LIVE_PORTS:-}," in
              *,"$port",*) exit 0 ;;
              *) exit 7 ;;
            esac
            """,
            to: binDir.appendingPathComponent("curl")
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func runHook(_ command: String, livePorts: [UInt16]) throws -> GeneratedNotificationClientResult {
        try run(
            executable: "/bin/sh",
            arguments: ["-c", command],
            livePorts: livePorts
        )
    }

    func runHelper(
        _ script: String,
        event: String?,
        livePorts: [UInt16]
    ) throws -> GeneratedNotificationClientResult {
        let helperFile = root.appendingPathComponent("helper-\(UUID().uuidString).sh")
        try writeExecutable(script, to: helperFile)
        return try run(
            executable: "/bin/bash",
            arguments: [helperFile.path] + (event.map { [$0] } ?? []),
            livePorts: livePorts
        )
    }

    private func run(
        executable: String,
        arguments: [String],
        livePorts: [UInt16]
    ) throws -> GeneratedNotificationClientResult {
        let runID = UUID().uuidString
        let probesFile = root.appendingPathComponent("probes-\(runID).txt")
        let postURLFile = root.appendingPathComponent("post-url-\(runID).txt")
        let payloadFile = root.appendingPathComponent("payload-\(runID).json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = [
            "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "DEVSPACE_TEST_LIVE_PORTS": livePorts.map(String.init).joined(separator: ","),
            "DEVSPACE_TEST_PROBES": probesFile.path,
            "DEVSPACE_TEST_POST_URL": postURLFile.path,
            "DEVSPACE_TEST_POST_PAYLOAD": payloadFile.path,
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let probes = (try? String(contentsOf: probesFile, encoding: .utf8)) ?? ""
        return GeneratedNotificationClientResult(
            status: process.terminationStatus,
            stdout: String(
                decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            stderr: String(
                decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            probedPorts: probes.split(separator: "\n").map(String.init),
            postURL: try? String(contentsOf: postURLFile, encoding: .utf8),
            payload: try? String(contentsOf: payloadFile, encoding: .utf8)
        )
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
