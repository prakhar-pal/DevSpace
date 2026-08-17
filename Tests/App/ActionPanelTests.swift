import XCTest
@testable import DevSpaceApp

@MainActor
final class ActionPanelTests: XCTestCase {
    func testConnectingStateRequiresAnOpenedSessionWithoutPanes() {
        XCTAssertTrue(AppModel.isConnecting(isOpened: true, hasPanes: false))
        XCTAssertFalse(AppModel.isConnecting(isOpened: false, hasPanes: false))
        XCTAssertFalse(AppModel.isConnecting(isOpened: true, hasPanes: true))
    }

    func testConnectionActionsGiveConnectingPrecedenceOverTransientStates() {
        for state in ["Loading", "Unknown", "Busy"] {
            XCTAssertTrue(ActionPanelView.showsConnectionActions(
                workspaceState: state,
                isConnecting: true
            ))
        }
        XCTAssertFalse(ActionPanelView.showsConnectionActions(
            workspaceState: "Stopped",
            isConnecting: false
        ))
    }

    func testMountedTerminalAwaitingIntegrationStillShowsConnecting() {
        XCTAssertEqual(
            ActionPanel.connectionAction(
                workspaceState: "Running",
                isConnecting: AppModel.isConnecting(
                    isOpened: true,
                    hasPanes: true,
                    isAwaitingShellIntegration: true
                )
            ),
            .connecting
        )
    }
}
