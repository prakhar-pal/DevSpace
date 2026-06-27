import XCTest
@testable import DevSpaceCore

// Mirrors the path_env.rs test module.
final class PathEnvTests: XCTestCase {
    func testExtractsPathBetweenMarkers() {
        let out = "some rc noise\n__DEVSPACE_PATH_START__/a/bin:/b/bin__DEVSPACE_PATH_END__\n"
        XCTAssertEqual(PathEnv.extractPath(out), "/a/bin:/b/bin")
    }

    func testExtractReturnsNoneWithoutMarkers() {
        XCTAssertNil(PathEnv.extractPath("no markers here"))
    }

    func testMergePrependsShellEntriesAndDedups() {
        let merged = PathEnv.mergePath("/usr/bin:/bin", "/Users/me/.local/bin:/usr/bin")
        XCTAssertEqual(merged, "/Users/me/.local/bin:/usr/bin:/bin")
    }

    func testMergeDropsEmptySegments() {
        XCTAssertEqual(PathEnv.mergePath(":/bin:", "/opt/bin::"), "/opt/bin:/bin")
    }

    func testMergeHandlesEmptyCurrent() {
        XCTAssertEqual(PathEnv.mergePath("", "/a:/b"), "/a:/b")
    }

    func testQueryCommandBracesThePathVariable() {
        let cmd = PathEnv.pathQueryCommand()
        XCTAssertTrue(cmd.contains("${PATH}"), "command must brace PATH: \(cmd)")
        XCTAssertFalse(cmd.contains("$PATH}"), "must not have a bare $PATH: \(cmd)")
    }

    func testDevpodInDetectsAnExecutableOnPath() throws {
        XCTAssertFalse(PathEnv.devpodIn(""))
        XCTAssertFalse(PathEnv.devpodIn("/no/such/dir:/also/missing"))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devspace-devpod-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Directory without a devpod file reads as absent.
        XCTAssertFalse(PathEnv.devpodIn(dir.path))

        let bin = dir.appendingPathComponent("devpod")
        try "#!/bin/sh\n".write(to: bin, atomically: true, encoding: .utf8)
        XCTAssertTrue(PathEnv.devpodIn(dir.path))
        XCTAssertTrue(PathEnv.devpodIn("/no/such/dir:\(dir.path)"))
    }

    func testQueryCommandRoundTripsThroughAShell() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", PathEnv.pathQueryCommand()]
        proc.environment = ["PATH": "/sentinel/bin:/usr/bin"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        try proc.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let stdout = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(PathEnv.extractPath(stdout), "/sentinel/bin:/usr/bin")
    }
}
