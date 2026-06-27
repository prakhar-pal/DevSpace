import XCTest
@testable import DevSpaceCore

final class CoreSmokeTests: XCTestCase {
    func testCoreLinks() {
        XCTAssertEqual(DevSpaceCore.name, "DevSpaceCore")
    }

    func testLogWriteIsSafeWhenDisabled() {
        // In the test bundle there is no DevSpaceLogPath, so logging is a no-op
        // and must never throw or crash.
        XCTAssertFalse(Log.isEnabled)
        Log.write("smoke")
    }
}
