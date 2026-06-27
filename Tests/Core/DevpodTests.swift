import XCTest
@testable import DevSpaceCore

// Mirrors the devpod.rs test module.

private let listJSON = #"""
[{"id":"task-queue","provider":{"name":"docker"},"ide":{"name":"zed"},"source":{"localFolder":"/Users/prakhar.p/Documents/prakhar-pal/task-queue"},"lastUsed":"2026-05-20T04:55:37Z","context":"default"},{"id":"wc-1","provider":{"name":"kubernetes"},"ide":{"name":"none"},"source":{"gitRepository":"git@github.com:talview/webclients.git"},"lastUsed":"2026-06-13T07:25:01Z","context":"default"}]
"""#

private let statusJSON = #"{"id":"wc-1","context":"default","provider":"kubernetes","state":"Stopped"}"#

private struct FakeRunner: CommandRunning {
    let output: String
    let expectedArgs: [String]
    func run(_ args: [String]) throws -> String {
        XCTAssertEqual(args, expectedArgs)
        return output
    }
}

private struct PanicRunner: CommandRunning {
    func run(_ args: [String]) throws -> String {
        XCTFail("runner must not be invoked for an invalid id")
        return ""
    }
}

final class DevpodTests: XCTestCase {
    func testParsesListFixture() throws {
        let ws = try Devpod.parseList(listJSON)
        XCTAssertEqual(ws.count, 2)
        XCTAssertEqual(ws[0].id, "task-queue")
        XCTAssertEqual(ws[1].provider.name, "kubernetes")
        XCTAssertEqual(ws[1].source.gitRepository, "git@github.com:talview/webclients.git")
    }

    func testParsesStatusFixture() throws {
        let s = try Devpod.parseStatus(statusJSON)
        XCTAssertEqual(s.id, "wc-1")
        XCTAssertEqual(s.state, "Stopped")
    }

    func testListCallsCliAndParses() throws {
        let runner = FakeRunner(
            output: listJSON,
            expectedArgs: ["list", "--output", "json", "--skip-pro"]
        )
        let ws = try Devpod.list(runner)
        XCTAssertEqual(ws.count, 2)
    }

    func testRejectsFlagLikeIdBeforeRunning() {
        XCTAssertThrowsError(try Devpod.delete(PanicRunner(), id: "--ide"))
        XCTAssertThrowsError(try Devpod.delete(PanicRunner(), id: "-rf"))
        XCTAssertNoThrow(try Devpod.validateId("wc-1"))
        XCTAssertNoThrow(try Devpod.validateId("task-queue"))
        XCTAssertThrowsError(try Devpod.validateId(""))
    }
}
