import Foundation
import XCTest
@testable import DevSpaceCore

#if os(Linux)
final class LogTests: XCTestCase {
    func testDevelopmentLoggingIsPrivateAndProductionLoggingIsDisabled() throws {
        if ProcessInfo.processInfo.environment["DEVSPACE_LOG_TEST_CHILD"] == "1" {
            Log.write("first diagnostic marker")
            Log.write("second diagnostic marker")
            return
        }
        for channel in ["development", "production"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devspace-log-test-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["DevSpaceCoreTests.LogTests/testDevelopmentLoggingIsPrivateAndProductionLoggingIsDisabled"]
            child.environment = ProcessInfo.processInfo.environment.merging([
                "DEVSPACE_LOG_TEST_CHILD": "1", "DEVSPACE_BUILD_CHANNEL": channel,
                "XDG_STATE_HOME": directory.path,
            ]) { _, value in value }
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try runDesktopProcess(child)
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0)
            let file = directory.appendingPathComponent("devspace-dev/devspace.log")
            #if DEBUG
            let expected = channel == "development"
            #else
            let expected = false
            #endif
            XCTAssertEqual(FileManager.default.fileExists(atPath: file.path), expected,
                           "diagnostic logging did not respect configuration/channel \(channel)")
            if expected, FileManager.default.fileExists(atPath: file.path) {
                let contents = try String(contentsOf: file, encoding: .utf8)
                XCTAssertEqual(contents.split(separator: "\n").count, 2)
                XCTAssertTrue(contents.contains("first diagnostic marker"))
                XCTAssertTrue(contents.contains("second diagnostic marker"))
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
        }
    }
}
#endif
