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
    #if os(Linux)
    func testCLIReadsStderrWhileWaitingForStdout() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devspace-devpod-pipes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("devpod")
        try "#!/usr/bin/env python3\nimport sys\nsys.stderr.write('x' * 262144)\nsys.stderr.flush()\nprint('done')\n".write(
            to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let cli = DevpodCLI(environment: ["PATH": "\(directory.path):/usr/bin:/bin"])
        let finished = expectation(description: "both pipes drained")
        DispatchQueue.global().async {
            do { XCTAssertEqual(try cli.run(["list"]), "done\n") }
            catch { XCTFail("command failed: \(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        cli.cancel()
    }
    #endif

    func testCancelledCLICannotLaunchAnotherCommand() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devspace-devpod-after-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("devpod")
        try "#!/bin/sh\nprintf launched\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let cli = DevpodCLI(environment: ["PATH": "\(directory.path):/usr/bin:/bin"])
        cli.cancel()
        XCTAssertThrowsError(try cli.run(["list"]))
    }

    func testCLIStopsAnInFlightDevpodProcess() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devspace-devpod-cancel-\(UUID().uuidString)")
        let marker = directory.appendingPathComponent("started")
        let executable = directory.appendingPathComponent("devpod")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "#!/bin/sh\ntouch \"$DEVSPACE_TEST_MARKER\"\nexec sleep 30\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let cli = DevpodCLI(environment: [
            "PATH": "\(directory.path):/usr/bin:/bin",
            "DEVSPACE_TEST_MARKER": marker.path,
        ])
        let finished = expectation(description: "cancelled process returns")
        DispatchQueue.global().async {
            _ = try? cli.run(["list"])
            finished.fulfill()
        }
        let deadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        cli.cancel()
        wait(for: [finished], timeout: 2)
    }

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

    func testCreateRequestBuildsArgsWithOptionalID() throws {
        let withID = try Devpod.CreateRequest(
            repositoryURL: "  https://github.com/acme/app.git  ",
            id: "  app-dev  "
        )
        XCTAssertEqual(withID.repositoryURL, "https://github.com/acme/app.git")
        XCTAssertEqual(withID.id, "app-dev")
        XCTAssertEqual(withID.args, [
            "up", "--ide", "none", "--id", "app-dev", "--",
            "https://github.com/acme/app.git",
        ])

        let derived = try Devpod.CreateRequest(
            repositoryURL: "git@github.com:acme/app.git",
            id: "  "
        )
        XCTAssertNil(derived.id)
        XCTAssertEqual(derived.args, [
            "up", "--ide", "none", "--", "git@github.com:acme/app.git",
        ])
    }

    func testCreateRequestRejectsEmptyRepositoryAndInvalidID() {
        XCTAssertThrowsError(try Devpod.CreateRequest(repositoryURL: "  ", id: nil))
        XCTAssertThrowsError(try Devpod.CreateRequest(
            repositoryURL: "https://github.com/acme/app.git",
            id: "--provider"
        ))
    }

    func testRecreateArgsUseRecreateFlagAndValidatedID() throws {
        XCTAssertEqual(try Devpod.recreateArgs("wc-1"), [
            "up", "--recreate", "--ide", "none", "--", "wc-1",
        ])
        XCTAssertThrowsError(try Devpod.recreateArgs("--provider"))
    }
}
