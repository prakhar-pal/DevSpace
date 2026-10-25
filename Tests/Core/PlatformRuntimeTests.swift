import Foundation
import XCTest
@testable import DevSpaceCore

final class PlatformRuntimeTests: XCTestCase {
    #if os(Linux)
    func testSSHMasterSupervisorPreservesArgumentsAndChildFailureStatus() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let literal = "path with spaces; $(printf not-a-command) α"
        process.arguments = ["-c", "import sys; print(sys.argv[1]); sys.exit(7)", literal]
        let output = Pipe()
        process.standardOutput = output
        try runDesktopSSHMaster(process)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 7)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), literal + "\n")
    }

    func testSSHMasterSupervisorWaitsForChildCleanupBeforeReportingExit() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
            import os,signal,time,sys
            def stop(sig,frame):
                time.sleep(0.15)
                print('cleaned',flush=True)
                sys.exit(0)
            signal.signal(signal.SIGTERM,stop)
            os.closerange(3,256)
            print('ready',flush=True)
            time.sleep(30)
            """]
        let output = Pipe()
        process.standardOutput = output
        try runDesktopSSHMaster(process)
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 6), Data("ready\n".utf8))
        process.terminate()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "cleaned\n")
        XCTAssertEqual(process.terminationStatus, 143)
    }

    func testLongLivedChildClosingExtraDescriptorsDoesNotBlockOtherProcessExits() throws {
        let master = Process()
        master.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        master.arguments = ["-c", "import os,time; os.closerange(3,256); os.write(1,b'ready\\n'); time.sleep(3)"]
        let output = Pipe()
        master.standardOutput = output
        try runDesktopSSHMaster(master)
        defer { if master.isRunning { master.terminate() }; master.waitUntilExit() }
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 6), Data("ready\n".utf8))
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/true")
        let started = Date()
        try runDesktopProcess(check)
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5,
                          "closing inherited FDs must not block Foundation's process manager until the master exits")
    }
    #endif
    func testLinuxIgnoresEmptyAndRelativeXDGDirectories() {
        for value in ["", "relative/path"] {
            let paths = DevSpacePaths(platform: .linux, channel: .production,
                environment: ["HOME": "/home/alice", "XDG_CONFIG_HOME": value,
                              "XDG_STATE_HOME": value, "XDG_RUNTIME_DIR": value], uid: 1000)
            XCTAssertEqual(paths.configDirectory.path, "/home/alice/.config/devspace")
            XCTAssertEqual(paths.stateDirectory.path, "/home/alice/.local/state/devspace")
            XCTAssertEqual(paths.runtimeDirectory.path, "/tmp/devspace-1000")
        }
    }

    func testLinuxMissingHomeUsesCurrentUsersHomeNotFilesystemRoot() {
        let paths = DevSpacePaths(platform: .linux, channel: .production, environment: [:])
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(paths.configDirectory, home.appendingPathComponent(".config/devspace"))
        XCTAssertEqual(paths.stateDirectory, home.appendingPathComponent(".local/state/devspace"))
    }

    func testLinuxUsesDistinctXDGDirectoriesForDevelopment() {
        let paths = DevSpacePaths(
            platform: .linux,
            channel: .development,
            environment: [
                "XDG_CONFIG_HOME": "/cfg",
                "XDG_STATE_HOME": "/state",
                "XDG_RUNTIME_DIR": "/run/user/1000",
            ]
        )

        XCTAssertEqual(paths.configDirectory.path, "/cfg/devspace-dev")
        XCTAssertEqual(paths.stateDirectory.path, "/state/devspace-dev")
        XCTAssertEqual(paths.runtimeDirectory.path, "/run/user/1000/devspace-dev")
    }

    func testLinuxFallsBackToStandardXDGHomeLocations() {
        let paths = DevSpacePaths(
            platform: .linux,
            channel: .production,
            environment: ["HOME": "/home/alice"],
            uid: 1000
        )

        XCTAssertEqual(paths.configDirectory.path, "/home/alice/.config/devspace")
        XCTAssertEqual(paths.stateDirectory.path, "/home/alice/.local/state/devspace")
        XCTAssertEqual(paths.runtimeDirectory.path, "/tmp/devspace-1000")
    }

    func testMacOSPreservesExistingApplicationSupportLocation() {
        let paths = DevSpacePaths(
            platform: .macOS,
            channel: .development,
            environment: ["HOME": "/Users/alice"]
        )

        XCTAssertEqual(paths.configDirectory.path, "/Users/alice/Library/Application Support/DevSpace")
        XCTAssertEqual(paths.stateDirectory.path, "/Users/alice/Library/Logs/DevSpaceDev")
    }

    func testRuntimeIdentityReadsOnlyExplicitBuildChannel() {
        XCTAssertEqual(
            DevSpaceRuntimeIdentity(environment: ["DEVSPACE_BUILD_CHANNEL": "development"]).channel,
            .development
        )
        XCTAssertEqual(DevSpaceRuntimeIdentity(environment: [:]).channel, .production)
    }

    func testNotifyTokenPersistsInLinuxConfigDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devspace-runtime-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DevSpacePaths(
            platform: .linux,
            channel: .development,
            environment: ["XDG_CONFIG_HOME": root.path],
            uid: 1000
        )

        let first = try Notify.loadOrCreateToken(paths: paths)
        let second = try Notify.loadOrCreateToken(paths: paths)

        XCTAssertEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.notificationTokenDirectory.appendingPathComponent("notify-token").path
        ))
    }

    func testLinuxChannelsShareHookAuthenticationWithoutSharingLayout() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("devspace-channel-auth-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["XDG_CONFIG_HOME": root.path]
        let development = DevSpacePaths(platform: .linux, channel: .development, environment: environment)
        let production = DevSpacePaths(platform: .linux, channel: .production, environment: environment)
        XCTAssertNotEqual(development.configDirectory, production.configDirectory)
        XCTAssertEqual(try Notify.loadOrCreateToken(paths: development), try Notify.loadOrCreateToken(paths: production),
                       "production-first remote hooks must authenticate to either channel")
    }

    #if os(Linux)
    func testConcurrentLinuxTokenCreationReturnsOneSharedSecret() throws {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var tokens: [String] = []
            func append(_ token: String) { lock.lock(); defer { lock.unlock() }; tokens.append(token) }
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("devspace-token-race-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DevSpacePaths(platform: .linux, channel: .development, environment: ["XDG_CONFIG_HOME": root.path])
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            results.append((try? Notify.loadOrCreateToken(paths: paths)) ?? "failed")
        }
        XCTAssertFalse(results.tokens.contains("failed"))
        XCTAssertEqual(Set(results.tokens).count, 1, "simultaneous listeners must not bake different tokens into hooks")
    }
    #endif

    func testExistingTokenRestoresOwnerOnlyPermissions() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devspace-token-mode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DevSpacePaths(platform: .linux, channel: .development,
            environment: ["XDG_CONFIG_HOME": root.path], uid: 1000)
        let token = try Notify.loadOrCreateToken(paths: paths)
        let file = paths.notificationTokenDirectory.appendingPathComponent("notify-token")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(try Notify.loadOrCreateToken(paths: paths), token)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
