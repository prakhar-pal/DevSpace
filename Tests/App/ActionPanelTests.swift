import XCTest
@testable import DevSpaceApp
@testable import DevSpaceCore

@MainActor
final class ActionPanelTests: XCTestCase {
    func testDideWorkdirAcceptsOnlyKnownWorkspaceWithAbsolutePath() {
        XCTAssertEqual(
            AppModel.dideWorkdir(
                podID: "wc-1",
                path: "/workspaces/my project",
                knownWorkspaceIDs: ["wc-1"]
            ),
            "/workspaces/my project"
        )
        XCTAssertNil(AppModel.dideWorkdir(
            podID: "wc-1",
            path: "relative/project",
            knownWorkspaceIDs: ["wc-1"]
        ))
        XCTAssertNil(AppModel.dideWorkdir(
            podID: "wc-1",
            path: "",
            knownWorkspaceIDs: ["wc-1"]
        ))
        XCTAssertNil(AppModel.dideWorkdir(
            podID: "-bad",
            path: "/workspace",
            knownWorkspaceIDs: ["-bad"]
        ))
        XCTAssertNil(AppModel.dideWorkdir(
            podID: "wc-2",
            path: "/workspace",
            knownWorkspaceIDs: ["wc-1"]
        ))
    }

    func testExplicitDideWorkdirNeverFallsBackToDevpod() {
        XCTAssertEqual(
            AppModel.zedFallbackAction(sessionActive: false, hasExplicitWorkdir: true),
            .none
        )
        XCTAssertEqual(
            AppModel.zedFallbackAction(sessionActive: true, hasExplicitWorkdir: true),
            .activateExistingSession
        )
        XCTAssertEqual(
            AppModel.zedFallbackAction(sessionActive: false, hasExplicitWorkdir: false),
            .openViaDevpod
        )
    }

    func testDidePayloadLaunchesItsExactRemoteURL() {
        let launched = expectation(description: "Zed URL launched")
        let lock = NSLock()
        var urls: [String] = []
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "docker",
                source: "test",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            zedLaunchURL: { url in
                lock.lock()
                urls.append(url)
                lock.unlock()
                launched.fulfill()
            }
        )

        model.receiveDide(DidePayload(
            podID: "wc-1",
            path: "/workspaces/my project#?",
            token: "ignored"
        ))

        wait(for: [launched], timeout: 2)
        lock.lock()
        let recordedURLs = urls
        lock.unlock()
        XCTAssertEqual(recordedURLs, ["ssh://wc-1.devpod/workspaces/my%20project%23%3F"])
    }

    func testDidePayloadRejectsUnknownPodBeforeLaunchingZed() {
        let notLaunched = expectation(description: "Zed must not launch")
        notLaunched.isInverted = true
        let model = AppModel(
            initialWorkspaces: [],
            startsRuntimeServices: false,
            zedLaunchURL: { _ in notLaunched.fulfill() }
        )

        model.receiveDide(DidePayload(
            podID: "wc-unknown",
            path: "/workspace",
            token: "ignored"
        ))

        wait(for: [notLaunched], timeout: 0.1)
    }

    func testDidePayloadRejectsWorkspaceWhileRecreating() {
        let notLaunched = expectation(description: "Zed must not launch during recreation")
        notLaunched.isInverted = true
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "docker",
                source: "test",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            zedLaunchURL: { _ in notLaunched.fulfill() }
        )
        model.beginRecreate("wc-1")
        model.confirmRecreate()

        model.receiveDide(DidePayload(
            podID: "wc-1",
            path: "/workspace",
            token: "ignored"
        ))

        wait(for: [notLaunched], timeout: 0.1)
    }

    func testAcceptedDideDoesNotLaunchAfterRecreationBegins() {
        let notLaunched = expectation(description: "accepted DIDE must be invalidated")
        notLaunched.isInverted = true
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "docker",
                source: "test",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            zedLaunchURL: { _ in notLaunched.fulfill() }
        )

        model.receiveDide(DidePayload(
            podID: "wc-1",
            path: "/workspace",
            token: "ignored"
        ))
        model.beginRecreate("wc-1")
        model.confirmRecreate()

        wait(for: [notLaunched], timeout: 0.1)
    }

    func testPendingLegacyFallbackDoesNotSpawnAfterRecreationBegins() {
        let contextStarted = expectation(description: "Zed environment lookup started")
        let notLaunched = expectation(description: "legacy fallback must be invalidated")
        notLaunched.isInverted = true
        let releaseContext = DispatchSemaphore(value: 0)
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "docker",
                source: "test",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            zedLaunchContext: {
                contextStarted.fulfill()
                releaseContext.wait()
                return (processTable: "", cli: nil)
            },
            zedDevpodLaunch: { _ in notLaunched.fulfill() }
        )

        model.openInZed("wc-1")
        wait(for: [contextStarted], timeout: 1)
        model.beginRecreate("wc-1")
        model.confirmRecreate()
        releaseContext.signal()

        wait(for: [notLaunched], timeout: 0.1)
    }

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
