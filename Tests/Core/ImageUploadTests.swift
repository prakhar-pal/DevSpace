import Foundation
import XCTest
@testable import DevSpaceCore

private final class ImageUploadRecorder: CommandRunning, @unchecked Sendable {
    var calls: [[String]] = []
    var failure = false
    func run(_ args: [String]) throws -> String {
        calls.append(args)
        if failure { throw DevpodError("upload failed") }
        return ""
    }
}

final class ImageUploadTests: XCTestCase {
    func testPNGUploadUsesOnlyTheOwnedMasterAndPreservesTheSourceArgument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("image upload α-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("clipboard.png")
        try Data([137, 80, 78, 71, 13, 10, 26, 10, 1]).write(to: source)
        let runner = ImageUploadRecorder()
        let remote = try ImageUpload.upload(runner, podID: "pod", controlPath: "/tmp/owned master.sock", source: source)
        XCTAssertTrue(remote.hasPrefix("/tmp/devspace-paste-"))
        XCTAssertTrue(remote.hasSuffix(".png"))
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0], ["-o", "ControlMaster=no", "-o", "ControlPath=/tmp/owned master.sock",
            "-o", "ProxyCommand=/bin/false", "-o", "BatchMode=yes", "--", source.path, "pod.devpod:\(remote)"])
        runner.failure = true
        XCTAssertThrowsError(try ImageUpload.upload(runner, podID: "pod", controlPath: "/tmp/owned master.sock", source: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "uploader does not own arbitrary caller files")
    }

    func testInvalidImageOrWorkspaceNeverStartsSCP() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("bad-image-\(UUID()).png")
        try Data("not an image".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let runner = ImageUploadRecorder()
        XCTAssertThrowsError(try ImageUpload.upload(runner, podID: "pod", controlPath: "/tmp/socket", source: source))
        XCTAssertThrowsError(try ImageUpload.upload(runner, podID: "--all", controlPath: "/tmp/socket", source: source))
        XCTAssertTrue(runner.calls.isEmpty)
    }
}
