import Foundation
import XCTest
@testable import DevSpaceCore

#if !os(Linux)
@MainActor
#endif
final class HostSSHTransportTests: XCTestCase {
    func testApprovedHostMasterBecomesReadyAndReleasesItsLease() throws {
        guard let workspace = ProcessInfo.processInfo.environment["DEVSPACE_HOST_WORKSPACE"] else {
            throw XCTSkip("opt-in real workspace SSH acceptance")
        }
        let transport = SSHTransportSession(podID: workspace, proxyCommand: SSH.resolveDevpodProxyCommand(podID: workspace),
                                           bundleIdentifier: "com.prakharp.devspace.dev")
        let ready = expectation(description: "real master ready or reports its failure")
        var failure: SSHTransportSession.StartError?
        transport.onReady = { ready.fulfill() }
        transport.onStartError = { failure = $0; ready.fulfill() }
        transport.start()
        defer { transport.stop() }
        wait(for: [ready], timeout: 25)
        XCTAssertNil(failure, "SSH failure: \(String(describing: failure)); stderr: \(transport.stderrTail)")
        guard failure == nil else { return }
        let stopped = expectation(description: "real master stopped")
        transport.onStopped = { stopped.fulfill() }
        transport.stop()
        wait(for: [stopped], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transport.controlPath))
    }
}
