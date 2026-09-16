import XCTest
@testable import DevSpaceCore

final class SSHTransportControlLeaseTests: XCTestCase {
    func testLiveSameBuildOwnerRejectsSecondLease() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devspace-lease-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = SSHTransportControlLease(
            root: root,
            bundleIdentifier: "com.prakharp.devspace",
            workspaceID: "wc-1",
            processID: 111,
            isProcessAlive: { $0 == 111 },
            processIdentity: { $0 == 111 ? "first-process" : nil },
            requestControlExit: { _, _ in }
        )
        try first.acquire()

        let second = SSHTransportControlLease(
            root: root,
            bundleIdentifier: "com.prakharp.devspace",
            workspaceID: "wc-1",
            processID: 222,
            isProcessAlive: { $0 == 111 || $0 == 222 },
            processIdentity: { $0 == 111 ? "first-process" : "second-process" },
            requestControlExit: { _, _ in }
        )

        XCTAssertThrowsError(try second.acquire()) { error in
            XCTAssertEqual(error as? SSHTransportControlLease.Error, .workspaceAlreadyOwned)
        }
    }

    func testProvenDeadOwnerIsCleanedBeforeNewLeaseIsCreated() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devspace-lease-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dead = SSHTransportControlLease(
            root: root,
            bundleIdentifier: "com.prakharp.devspace",
            workspaceID: "wc-1",
            processID: 111,
            isProcessAlive: { _ in false },
            processIdentity: { _ in nil },
            requestControlExit: { _, _ in }
        )
        try dead.acquire()

        let replacement = SSHTransportControlLease(
            root: root,
            bundleIdentifier: "com.prakharp.devspace",
            workspaceID: "wc-1",
            processID: 222,
            isProcessAlive: { $0 == 222 },
            processIdentity: { $0 == 222 ? "replacement-process" : nil },
            requestControlExit: { _, _ in }
        )
        try replacement.acquire()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "\(URL(fileURLWithPath: replacement.controlPath).deletingLastPathComponent().lastPathComponent).owner.json"
            ).path
        ))
    }

    func testLivePIDWithDifferentStartIdentityIsNotTreatedAsOurOwner() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devspace-lease-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = SSHTransportControlLease(
            root: root,
            bundleIdentifier: "com.prakharp.devspace",
            workspaceID: "wc-1",
            processID: 111,
            isProcessAlive: { $0 == 111 },
            processIdentity: { _ in "original-start" },
            requestControlExit: { _, _ in }
        )
        try first.acquire()

        let replacementPID = SSHTransportControlLease(
            root: root,
            bundleIdentifier: "com.prakharp.devspace",
            workspaceID: "wc-1",
            processID: 222,
            isProcessAlive: { $0 == 111 || $0 == 222 },
            processIdentity: { $0 == 111 ? "reused-pid-start" : "new-process" },
            requestControlExit: { _, _ in }
        )

        XCTAssertThrowsError(try replacementPID.acquire()) { error in
            XCTAssertEqual(error as? SSHTransportControlLease.Error, .directoryUnavailable)
        }
    }

    func testLegacyControlDirectoryIsNeverRemovedWhenClaimCreationCannotUseIt() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devspace-lease-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = SSHTransportControlLease(
            root: root,
            bundleIdentifier: "com.prakharp.devspace",
            workspaceID: "wc-1",
            processID: 111,
            isProcessAlive: { _ in false },
            processIdentity: { _ in nil },
            requestControlExit: { _, _ in }
        )
        let legacyDirectory = URL(fileURLWithPath: lease.controlPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try lease.acquire()) { error in
            XCTAssertEqual(error as? SSHTransportControlLease.Error, .directoryUnavailable)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyDirectory.path))
    }
}
