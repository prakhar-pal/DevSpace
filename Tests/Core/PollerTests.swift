import XCTest
@testable import DevSpaceCore

// Mirrors poller.rs (merge_applies_status_and_error) plus a scripted pollOnce
// that exercises the concurrent status fetch.

private let listJSON = #"""
[{"id":"task-queue","provider":{"name":"docker"},"ide":{"name":"zed"},"source":{"localFolder":"/Users/prakhar.p/Documents/prakhar-pal/task-queue"},"lastUsed":"2026-05-20T04:55:37Z","context":"default"},{"id":"wc-1","provider":{"name":"kubernetes"},"ide":{"name":"none"},"source":{"gitRepository":"git@github.com:talview/webclients.git"},"lastUsed":"2026-06-13T07:25:01Z","context":"default"}]
"""#

private struct ScriptedRunner: CommandRunning {
    let list: String
    let statusByID: [String: String]
    func run(_ args: [String]) throws -> String {
        switch args.first {
        case "list": return list
        case "status":
            guard let id = args.last, let json = statusByID[id] else {
                throw DevpodError("no status for \(args)")
            }
            return json
        default:
            throw DevpodError("unexpected args \(args)")
        }
    }
}

final class PollerTests: XCTestCase {
    func testMergeAppliesStatusAndError() throws {
        let ws = try Devpod.parseList(listJSON)
        var statuses: [String: Result<WorkspaceStatus, DevpodError>] = [:]
        statuses["wc-1"] = .success(WorkspaceStatus(id: "wc-1", state: "Running"))
        statuses["task-queue"] = .failure(DevpodError("timeout"))

        let views = Poller.merge(ws, statuses)
        let wc1 = try XCTUnwrap(views.first { $0.id == "wc-1" })
        XCTAssertEqual(wc1.state, "Running")
        XCTAssertEqual(wc1.source, "git@github.com:talview/webclients.git")

        let tq = try XCTUnwrap(views.first { $0.id == "task-queue" })
        XCTAssertEqual(tq.state, "Unknown")
        XCTAssertEqual(tq.error, "timeout")
    }

    func testMergeMarksMissingStatusAsLoading() throws {
        let ws = try Devpod.parseList(listJSON)
        let views = Poller.merge(ws, [:])
        XCTAssertEqual(views.count, 2)
        XCTAssertTrue(views.allSatisfy { $0.state == "Loading" && $0.error == nil })
    }

    func testPollOnceListsFetchesAndMerges() throws {
        let runner = ScriptedRunner(
            list: listJSON,
            statusByID: [
                "task-queue": #"{"id":"task-queue","state":"Running"}"#,
                "wc-1": #"{"id":"wc-1","state":"Stopped"}"#,
            ]
        )
        let views = try Poller.pollOnce(runner)
        XCTAssertEqual(views.count, 2)
        XCTAssertEqual(Set(views.map(\.state)), ["Running", "Stopped"])
    }
}
