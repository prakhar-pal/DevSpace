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
            isProcessAlive: { $0 == 111 }
        )
        try first.acquire()

        let second = SSHTransportControlLease(
            root: root,
            bundleIdentifier: "com.prakharp.devspace",
            workspaceID: "wc-1",
            processID: 222,
            isProcessAlive: { $0 == 111 || $0 == 222 }
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
            isProcessAlive: { _ in false }
        )
        try dead.acquire()

        let replacement = SSHTransportControlLease(
            root: root,
            bundleIdentifier: "com.prakharp.devspace",
            workspaceID: "wc-1",
            processID: 222,
            isProcessAlive: { $0 == 222 }
        )
        try replacement.acquire()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: replacement.controlPath)
                .deletingLastPathComponent()
                .appendingPathComponent("owner.json").path
        ))
    }
}
