import XCTest
@testable import DevSpaceCore

final class WorkspaceCreationDiscoveryTests: XCTestCase {
    func testExplicitIDWaitsForItsOwnWorkspaceRatherThanSelectingAnotherCreation() {
        var discovery = WorkspaceCreationDiscovery(explicitID: "new", before: ["pod"])
        XCTAssertEqual(discovery.observe(["pod"]), .waiting)
        XCTAssertEqual(discovery.observe(["pod", "other"]), .waiting)
        XCTAssertEqual(discovery.observe(["pod", "new"]), .resolved("new"))
    }

    func testSingleGeneratedIDIsSelectedButAmbiguousDiscoveriesPreserveSelection() {
        var single = WorkspaceCreationDiscovery(explicitID: nil, before: ["pod"])
        XCTAssertEqual(single.observe(["pod", "generated"]), .resolved("generated"))
        var ambiguous = WorkspaceCreationDiscovery(explicitID: nil, before: ["pod"])
        XCTAssertEqual(ambiguous.observe(["pod", "one", "two"]), .resolved(nil))
    }

    func testThreeSuccessfulMissesEndDiscoveryWithoutClaimingProvisioningFailed() {
        var discovery = WorkspaceCreationDiscovery(explicitID: "new", before: ["pod"])
        XCTAssertEqual(discovery.observe(["pod"]), .waiting)
        XCTAssertEqual(discovery.observe(["pod"]), .waiting)
        XCTAssertEqual(discovery.observe(["pod"]), .resolved(nil))
    }
}
