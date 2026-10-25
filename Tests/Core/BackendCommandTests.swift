import XCTest
@testable import DevSpaceCore

private final class RecordingBackendRunner: CommandRunning, @unchecked Sendable {
    var arguments: [[String]] = []
    func run(_ args: [String]) throws -> String {
        arguments.append(args)
        return ""
    }
}

final class BackendCommandTests: XCTestCase {
    func testStartValidatesAndRunsWorkspaceWithoutOpeningAnIDE() throws {
        let runner = RecordingBackendRunner()
        let response = try BackendWorkspaceCommands.execute(
            BackendProtocolMessage(id: "request", kind: "start", payload: ["workspace_id": "pod"]),
            runner: runner
        )
        XCTAssertEqual(runner.arguments, [["--log-output", "raw", "up", "--ide", "none", "--", "pod"]])
        XCTAssertEqual(response.id, "request")
        XCTAssertEqual(response.kind, "completed")
    }

    func testHostileWorkspaceIDNeverReachesRunner() {
        let runner = RecordingBackendRunner()
        XCTAssertThrowsError(try BackendWorkspaceCommands.execute(
            BackendProtocolMessage(kind: "delete", payload: ["workspace_id": "--all"]),
            runner: runner
        ))
        XCTAssertTrue(runner.arguments.isEmpty)
    }

    func testCreatePassesRepositoryAsOneArgument() throws {
        let runner = RecordingBackendRunner()
        _ = try BackendWorkspaceCommands.execute(
            BackendProtocolMessage(kind: "create", payload: ["repository": "/path with spaces", "workspace_id": "new"]),
            runner: runner
        )
        XCTAssertEqual(runner.arguments, [["--log-output", "raw", "up", "--ide", "none", "--id", "new", "--", "/path with spaces"]])
    }

    func testAllLifecycleCommandsRequestUnformattedLogsForPlainTextProgress() throws {
        for kind in ["start", "stop", "recreate", "delete", "create"] {
            let arguments = try BackendWorkspaceCommands.arguments(BackendProtocolMessage(
                kind: kind, payload: ["workspace_id": "pod", "repository": "https://example.invalid/new.git"]))
            XCTAssertEqual(Array(arguments.prefix(2)), ["--log-output", "raw"], kind)
            XCTAssertEqual(arguments.last, kind == "create" ? "https://example.invalid/new.git" : "pod")
        }
    }
}
