import XCTest
@testable import DevSpaceCore

final class SSHRecoveryBudgetTests: XCTestCase {
    func testStartupAllowsOnlyTwoRetries() {
        var budget = SSHRecoveryBudget()
        XCTAssertEqual(budget.nextDelay(), 0.5)
        XCTAssertEqual(budget.nextDelay(), 1.5)
        XCTAssertNil(budget.nextDelay())
        XCTAssertNil(budget.nextDelay(), "an exhausted budget restarted itself")
    }

    func testReplacementMasterFailuresStayOnTheBoundedDisruptionBudget() {
        var budget = SSHRecoveryBudget()
        budget.didConnect()
        for delay in [3.0, 5, 8, 13, 21] { XCTAssertEqual(budget.nextDelay(), delay) }
        XCTAssertNil(budget.nextDelay())
    }

    func testRealConnectionOutputResetsTheDisruptionBudget() {
        var budget = SSHRecoveryBudget()
        _ = budget.nextDelay()
        budget.didConnect()
        XCTAssertEqual(budget.nextDelay(), 3)
        _ = budget.nextDelay()
        budget.didConnect()
        XCTAssertEqual(budget.nextDelay(), 3)
    }
}
