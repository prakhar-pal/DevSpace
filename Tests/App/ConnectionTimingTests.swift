import XCTest
@testable import DevSpaceApp
import DevSpaceCore

@MainActor
final class ConnectionTimingTests: XCTestCase {
    private final class LockedOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private struct SuccessfulCommandRunner: CommandRunning {
        func run(_: [String]) throws -> String { "" }
    }

    private final class WorkspaceStatusResolver {
        enum Response {
            case running
            case stopped
            case failure
        }

        private let response: Response
        private let lock = NSLock()
        private var statusCalls = 0

        init(response: Response) {
            self.response = response
        }

        func resolve(_ podID: String, completion: @escaping (Result<WorkspaceStatus, DevpodError>) -> Void) {
            XCTAssertEqual(podID, "wc-1")
            lock.lock()
            statusCalls += 1
            lock.unlock()

            let result: Result<WorkspaceStatus, DevpodError>
            switch response {
            case .running:
                result = .success(WorkspaceStatus(id: podID, state: "Running"))
            case .stopped:
                result = .success(WorkspaceStatus(id: podID, state: "Stopped"))
            case .failure:
                result = .failure(DevpodError("status unavailable"))
            }
            completion(result)
        }

        var statusCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return statusCalls
        }
    }

    private final class DeferredWorkspaceStatusResolver {
        private var completions: [(Result<WorkspaceStatus, DevpodError>) -> Void] = []

        func resolve(_ podID: String, completion: @escaping (Result<WorkspaceStatus, DevpodError>) -> Void) {
            XCTAssertEqual(podID, "wc-1")
            completions.append(completion)
        }

        func complete(at index: Int, with result: Result<WorkspaceStatus, DevpodError>) {
            completions[index](result)
        }

        var requestCount: Int { completions.count }
    }

    private final class ManualConnectionRetryScheduler: AppModel.ConnectionRetryScheduling {
        private(set) var scheduled: [(delay: TimeInterval, action: () -> Void)] = []

        func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
            scheduled.append((delay, action))
        }

        func fireNext(file: StaticString = #filePath, line: UInt = #line) {
            guard !scheduled.isEmpty else {
                XCTFail("Expected a scheduled connection retry", file: file, line: line)
                return
            }
            scheduled.removeFirst().action()
        }
    }

    private final class ManualHandoffTimeoutScheduler: AppModel.HandoffTimeoutScheduling {
        private var action: (() -> Void)?

        func schedule(after _: TimeInterval, action: @escaping () -> Void) {
            self.action = action
        }

        func fire() {
            action?()
            action = nil
        }
    }

    private final class DeferredSSHProxyResolver {
        private var completions: [(String?) -> Void] = []

        func resolve(_ podID: String, completion: @escaping (String?) -> Void) {
            XCTAssertEqual(podID, "wc-1")
            completions.append(completion)
        }

        func complete(at index: Int, with proxyCommand: String?) {
            completions[index](proxyCommand)
        }

        var completionCount: Int { completions.count }
    }

    private final class ManualSSHTransport: SSHTransportControlling {
        let controlPath = "/tmp/devspace-test/socket"
        private(set) var state: SSHTransportSession.State = .idle
        var onReady: (() -> Void)?
        var onExit: ((Int32) -> Void)?
        var onStartError: ((SSHTransportSession.StartError) -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0

        func start() {
            startCount += 1
            state = .starting
        }

        func stop() {
            stopCount += 1
            state = .exited
        }

        func succeedReady() {
            state = .ready
            onReady?()
        }

        func exit(with code: Int32) {
            state = .exited
            onExit?(code)
        }

        func failStart(_ error: SSHTransportSession.StartError) {
            state = .exited
            onStartError?(error)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func testMasterReadinessCreatesInitialMultiplexClient() {
        let transport = ManualSSHTransport()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1", provider: "test", source: "", lastUsed: "",
                state: "Running", error: nil
            )],
            startsRuntimeServices: false,
            sshProxyResolver: { _, completion in completion("devpod ssh --stdio wc-1") },
            sshTransportFactory: { _, _ in transport }
        )

        model.connect("wc-1")

        XCTAssertEqual(transport.startCount, 1)
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)

        transport.succeedReady()

        let pane = try! XCTUnwrap(model.panes["wc-1"]?.first)
        XCTAssertTrue(pane.commandArguments.contains("ControlMaster=no"))
        XCTAssertFalse(pane.commandArguments.contains("-R"))
    }

    func testMasterExitRestoresTabCountAndSelectedIndexAfterFreshStatus() async {
        let firstTransport = ManualSSHTransport()
        let recoveredTransport = ManualSSHTransport()
        let transports = [firstTransport, recoveredTransport]
        var transportIndex = 0
        let statusResolver = WorkspaceStatusResolver(response: .running)
        let retryScheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            runner: SuccessfulCommandRunner(),
            initialWorkspaces: [WorkspaceView(
                id: "wc-1", provider: "test", source: "", lastUsed: "",
                state: "Running", error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: retryScheduler,
            sshProxyResolver: { _, completion in completion("devpod ssh --stdio wc-1") },
            sshTransportFactory: { _, _ in
                defer { transportIndex += 1 }
                return transports[transportIndex]
            },
            workspaceStatusResolver: statusResolver.resolve
        )

        model.connect("wc-1")
        firstTransport.succeedReady()
        let firstPane = try! XCTUnwrap(model.panes["wc-1"]?.first)
        firstPane.onFirstOutput?()
        let established = await waitUntil { model.isTerminalVisible("wc-1") }
        XCTAssertTrue(established)
        model.newTerminal("wc-1")
        let secondPane = try! XCTUnwrap(model.panes["wc-1"]?[1])
        model.setActivePane("wc-1", paneID: secondPane.id)

        firstTransport.exit(with: 255)
        XCTAssertEqual(retryScheduler.scheduled.map(\.delay), [3])

        retryScheduler.fireNext()
        let checkedStatus = await waitUntil { statusResolver.statusCallCount == 1 }
        XCTAssertTrue(checkedStatus)
        recoveredTransport.succeedReady()

        XCTAssertEqual(model.panes["wc-1"]?.count, 2)
        guard let recoveredPanes = model.panes["wc-1"], recoveredPanes.count == 2 else { return }
        XCTAssertEqual(model.activePane["wc-1"], recoveredPanes[1].id)
    }

    func testClientFailureRetriesOnlyThatSlotAndKeepsMasterReady() async {
        let transport = ManualSSHTransport()
        let retryScheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            runner: SuccessfulCommandRunner(),
            initialWorkspaces: [WorkspaceView(
                id: "wc-1", provider: "test", source: "", lastUsed: "",
                state: "Running", error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: retryScheduler,
            sshProxyResolver: { _, completion in completion("devpod ssh --stdio wc-1") },
            sshTransportFactory: { _, _ in transport }
        )

        model.connect("wc-1")
        transport.succeedReady()
        let initial = try! XCTUnwrap(model.panes["wc-1"]?.first)
        initial.onFirstOutput?()
        let established = await waitUntil { model.isTerminalVisible("wc-1") }
        XCTAssertTrue(established)
        model.newTerminal("wc-1")
        let failed = try! XCTUnwrap(model.panes["wc-1"]?[1])

        failed.onExit?(255)

        XCTAssertEqual(retryScheduler.scheduled.map(\.delay), [0.5])
        XCTAssertEqual(transport.stopCount, 0)
        XCTAssertEqual(model.panes["wc-1"]?.count, 2)
        retryScheduler.fireNext()
        XCTAssertEqual(model.panes["wc-1"]?.count, 2)
        guard let panes = model.panes["wc-1"], panes.count == 2 else { return }
        XCTAssertEqual(panes[1].id, failed.id)
    }

    func testExhaustedClientFailureKeepsRetryableFailedTab() async {
        let transport = ManualSSHTransport()
        let retryScheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            runner: SuccessfulCommandRunner(),
            initialWorkspaces: [WorkspaceView(
                id: "wc-1", provider: "test", source: "", lastUsed: "",
                state: "Running", error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: retryScheduler,
            sshProxyResolver: { _, completion in completion("devpod ssh --stdio wc-1") },
            sshTransportFactory: { _, _ in transport }
        )

        model.connect("wc-1")
        transport.succeedReady()
        let initial = try! XCTUnwrap(model.panes["wc-1"]?.first)
        initial.onFirstOutput?()
        let established = await waitUntil { model.isTerminalVisible("wc-1") }
        XCTAssertTrue(established)
        model.newTerminal("wc-1")

        for delay in [0.5, 1.5] {
            let client = try! XCTUnwrap(model.panes["wc-1"]?[1])
            client.onExit?(255)
            XCTAssertEqual(retryScheduler.scheduled.map(\.delay), [delay])
            retryScheduler.fireNext()
        }
        let exhaustedClient = try! XCTUnwrap(model.panes["wc-1"]?[1])
        exhaustedClient.onExit?(255)

        let failedTab = try! XCTUnwrap(model.panes["wc-1"]?[1])
        XCTAssertEqual(failedTab.clientFailure?.isRetrying, false)
        XCTAssertEqual(transport.stopCount, 0)
        XCTAssertTrue(retryScheduler.scheduled.isEmpty)
    }

    func testPreReadyMasterFailureUsesStartupRetryBudget() {
        let firstTransport = ManualSSHTransport()
        let retryTransport = ManualSSHTransport()
        let retryScheduler = ManualConnectionRetryScheduler()
        var index = 0
        let transports = [firstTransport, retryTransport]
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1", provider: "test", source: "", lastUsed: "",
                state: "Running", error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: retryScheduler,
            sshProxyResolver: { _, completion in completion("devpod ssh --stdio wc-1") },
            sshTransportFactory: { _, _ in
                defer { index += 1 }
                return transports[index]
            }
        )

        model.connect("wc-1")
        firstTransport.failStart(.exitedBeforeReady(255))

        XCTAssertEqual(retryScheduler.scheduled.map(\.delay), [0.5])
        XCTAssertTrue(model.opened.contains("wc-1"))
        XCTAssertNil(model.connectionFailure("wc-1"))
        retryScheduler.fireNext()
        XCTAssertEqual(retryTransport.startCount, 1)
    }

    func testConnectWaitsForProxyResolutionBeforeMountingSSHPane() {
        let resolver = DeferredSSHProxyResolver()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            sshProxyResolver: resolver.resolve
        )

        model.connect("wc-1")

        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)

        resolver.complete(at: 0, with: "devpod ssh --stdio wc-1")

        XCTAssertEqual(model.panes["wc-1"]?.count, 1)
    }

    func testStaleProxyResolutionCannotMountAfterDisconnectAndReconnect() {
        let resolver = DeferredSSHProxyResolver()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            sshProxyResolver: resolver.resolve
        )

        model.connect("wc-1") // attempt A
        model.disconnect("wc-1")
        model.connect("wc-1") // attempt B

        resolver.complete(at: 0, with: "devpod ssh --stdio wc-1")
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)

        resolver.complete(at: 1, with: "devpod ssh --stdio wc-1")
        XCTAssertEqual(model.panes["wc-1"]?.count, 1)
    }

    func testPreReadySSHExitRetriesTwiceThenShowsFailure() {
        let scheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: scheduler
        )

        model.connect("wc-1")
        let firstPane = model.panes["wc-1"]!.first!
        firstPane.onExit?(255)

        XCTAssertTrue(model.isConnecting("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)
        XCTAssertEqual(scheduler.scheduled.map(\.delay), [0.5])
        XCTAssertNil(model.connectionFailure("wc-1"))

        scheduler.fireNext()
        let secondPane = model.panes["wc-1"]!.first!
        XCTAssertNotEqual(secondPane.id, firstPane.id)
        secondPane.onExit?(255)
        XCTAssertEqual(scheduler.scheduled.map(\.delay), [1.5])

        scheduler.fireNext()
        let thirdPane = model.panes["wc-1"]!.first!
        thirdPane.onExit?(255)

        XCTAssertFalse(model.isConnecting("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)
        XCTAssertTrue(scheduler.scheduled.isEmpty)
        XCTAssertEqual(model.connectionFailure("wc-1"), "SSH connection failed (exit 255).")
    }

    func testDisconnectCancelsPendingStartupRetry() {
        let scheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: scheduler
        )

        model.connect("wc-1")
        model.panes["wc-1"]?.first?.onExit?(255)
        model.disconnect("wc-1")
        scheduler.fireNext()

        XCTAssertFalse(model.opened.contains("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)
        XCTAssertNil(model.connectionFailure("wc-1"))
    }

    func testStoppedWorkspaceCancelsPendingStartupRetry() {
        let scheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: scheduler
        )

        model.connect("wc-1")
        model.panes["wc-1"]?.first?.onExit?(255)
        model.receivePollUpdate(PollUpdate(revision: 1, views: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Stopped",
                error: nil
            )]))
        scheduler.fireNext()

        XCTAssertFalse(model.opened.contains("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)
        XCTAssertNil(model.connectionFailure("wc-1"))
    }

    func testRetryWaitsForRunningAfterTransientUnknownStatus() {
        let scheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: scheduler
        )

        model.connect("wc-1")
        model.panes["wc-1"]?.first?.onExit?(255)
        model.receivePollUpdate(PollUpdate(
            revision: 1,
            views: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Unknown",
                error: "temporary status failure"
            )],
            hasFreshStatuses: false
        ))
        scheduler.fireNext()

        XCTAssertFalse(model.opened.contains("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)

        model.receivePollUpdate(PollUpdate(revision: 2, views: [WorkspaceView(
            id: "wc-1",
            provider: "test",
            source: "",
            lastUsed: "",
            state: "Running",
            error: nil
        )]))

        XCTAssertTrue(model.opened.contains("wc-1"))
        XCTAssertEqual(model.panes["wc-1"]?.count, 1)
    }

    func testUnknownStatusBeforeExitPreservesRecoveryIntent() {
        let scheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: scheduler
        )

        model.connect("wc-1")
        let failedPane = model.panes["wc-1"]!.first!
        model.receivePollUpdate(PollUpdate(
            revision: 1,
            views: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Unknown",
                error: "temporary status failure"
            )],
            hasFreshStatuses: false
        ))
        failedPane.onExit?(255)

        XCTAssertEqual(scheduler.scheduled.map(\.delay), [0.5])
        scheduler.fireNext()
        XCTAssertFalse(model.opened.contains("wc-1"))

        model.receivePollUpdate(PollUpdate(revision: 2, views: [WorkspaceView(
            id: "wc-1",
            provider: "test",
            source: "",
            lastUsed: "",
            state: "Running",
            error: nil
        )]))

        XCTAssertTrue(model.opened.contains("wc-1"))
        XCTAssertEqual(model.panes["wc-1"]?.count, 1)
    }

    func testProxyResolutionCannotMountAfterStatusBecomesUnknown() {
        let resolver = DeferredSSHProxyResolver()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            sshProxyResolver: resolver.resolve
        )

        model.connect("wc-1")
        model.receivePollUpdate(PollUpdate(
            revision: 1,
            views: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Unknown",
                error: "temporary status failure"
            )],
            hasFreshStatuses: false
        ))
        resolver.complete(at: 0, with: "devpod ssh --stdio wc-1")

        XCTAssertFalse(model.opened.contains("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)

        model.receivePollUpdate(PollUpdate(revision: 2, views: [WorkspaceView(
            id: "wc-1",
            provider: "test",
            source: "",
            lastUsed: "",
            state: "Running",
            error: nil
        )]))
        XCTAssertEqual(resolver.completionCount, 2)
        if resolver.completionCount == 2 {
            resolver.complete(at: 1, with: "devpod ssh --stdio wc-1")
        }

        XCTAssertEqual(model.panes["wc-1"]?.count, 1)
    }

    func testWorkspaceRemovalCancelsRetryIntentWhenIDReappears() {
        let scheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: scheduler
        )

        model.receivePollUpdate(PollUpdate(revision: 1, views: model.workspaces))
        model.panes["wc-1"]?.first?.onExit?(255)
        XCTAssertEqual(scheduler.scheduled.map(\.delay), [0.5])
        model.receivePollUpdate(PollUpdate(revision: 2, views: []))
        scheduler.fireNext()

        model.receivePollUpdate(PollUpdate(revision: 3, views: [WorkspaceView(
            id: "wc-1",
            provider: "test",
            source: "",
            lastUsed: "",
            state: "Running",
            error: nil
        )]))

        XCTAssertFalse(model.opened.contains("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)
    }

    func testManualConnectClearsFailureAndRestoresRetryBudget() {
        let scheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: scheduler
        )

        model.connect("wc-1")
        for attempt in 0 ..< 3 {
            model.panes["wc-1"]?.first?.onExit?(255)
            if attempt < 2 { scheduler.fireNext() }
        }
        XCTAssertNotNil(model.connectionFailure("wc-1"))

        model.connect("wc-1")
        XCTAssertNil(model.connectionFailure("wc-1"))
        model.panes["wc-1"]?.first?.onExit?(255)

        XCTAssertEqual(scheduler.scheduled.map(\.delay), [0.5])
        XCTAssertTrue(model.isConnecting("wc-1"))
    }

    func testEstablishedPrimaryExitChecksRunningStatusBeforeReconnect() async {
        let statusResolver = WorkspaceStatusResolver(response: .running)
        let retryScheduler = ManualConnectionRetryScheduler()
        let handoffScheduler = ManualHandoffTimeoutScheduler()
        let model = AppModel(
            runner: SuccessfulCommandRunner(),
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            handoffTimeoutScheduler: handoffScheduler,
            connectionRetryScheduler: retryScheduler,
            workspaceStatusResolver: statusResolver.resolve
        )

        model.connect("wc-1")
        let pane = model.panes["wc-1"]!.first!
        pane.onFirstOutput?()
        for _ in 0 ..< 100 where !model.isTerminalVisible("wc-1") {
            try? await Task.sleep(for: .milliseconds(10))
        }
        pane.onExit?(255)

        XCTAssertEqual(retryScheduler.scheduled.map(\.delay), [3])
        XCTAssertTrue(model.opened.contains("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)
        XCTAssertNil(model.connectionFailure("wc-1"))

        retryScheduler.fireNext()
        let reconnected = await waitUntil {
            statusResolver.statusCallCount == 1 && model.panes["wc-1"]?.count == 1
        }
        XCTAssertTrue(reconnected)
    }

    func testRecoveredSSHExitBeforeOutputRemainsStatusGated() async {
        let statusResolver = WorkspaceStatusResolver(response: .running)
        let retryScheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            runner: SuccessfulCommandRunner(),
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: retryScheduler,
            workspaceStatusResolver: statusResolver.resolve
        )

        model.connect("wc-1")
        let establishedPane = model.panes["wc-1"]!.first!
        establishedPane.onFirstOutput?()
        let established = await waitUntil { model.isTerminalVisible("wc-1") }
        XCTAssertTrue(established)
        guard established else { return }

        establishedPane.onExit?(255)
        retryScheduler.fireNext()
        let recovered = await waitUntil {
            statusResolver.statusCallCount == 1 && model.panes["wc-1"]?.count == 1
        }
        XCTAssertTrue(recovered)
        guard recovered, let recoveredPane = model.panes["wc-1"]?.first else { return }

        recoveredPane.onExit?(255)

        XCTAssertEqual(retryScheduler.scheduled.map(\.delay), [5])
        retryScheduler.fireNext()
        let secondStatusCheck = await waitUntil { statusResolver.statusCallCount == 2 }
        XCTAssertTrue(secondStatusCheck)
    }

    func testEstablishedPrimaryExitDoesNotReconnectWhenFreshStatusIsStopped() async {
        let statusResolver = WorkspaceStatusResolver(response: .stopped)
        let retryScheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            runner: SuccessfulCommandRunner(),
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: retryScheduler,
            workspaceStatusResolver: statusResolver.resolve
        )

        model.connect("wc-1")
        let pane = model.panes["wc-1"]!.first!
        pane.onFirstOutput?()
        let established = await waitUntil { model.isTerminalVisible("wc-1") }
        XCTAssertTrue(established)
        guard established else { return }

        pane.onExit?(255)
        retryScheduler.fireNext()
        let statusChecked = await waitUntil { statusResolver.statusCallCount == 1 }

        XCTAssertTrue(statusChecked)
        XCTAssertFalse(model.opened.contains("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)
    }

    func testDisruptionStatusFailureUsesFibonacciRetryDelays() async {
        let statusResolver = WorkspaceStatusResolver(response: .failure)
        let retryScheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            runner: SuccessfulCommandRunner(),
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: retryScheduler,
            workspaceStatusResolver: statusResolver.resolve
        )

        model.connect("wc-1")
        let pane = model.panes["wc-1"]!.first!
        pane.onFirstOutput?()
        let established = await waitUntil { model.isTerminalVisible("wc-1") }
        XCTAssertTrue(established)
        guard established else { return }

        pane.onExit?(255)
        let delays: [TimeInterval] = [3, 5, 8, 13, 21]
        for (index, delay) in delays.enumerated() {
            XCTAssertEqual(retryScheduler.scheduled.map(\.delay), [delay])
            retryScheduler.fireNext()

            let statusChecked = await waitUntil { statusResolver.statusCallCount == index + 1 }
            XCTAssertTrue(statusChecked)
        }

        XCTAssertFalse(model.opened.contains("wc-1"))
        XCTAssertTrue(retryScheduler.scheduled.isEmpty)
        XCTAssertEqual(
            model.connectionFailure("wc-1"),
            "SSH connection failed after disruption (exit 255)."
        )
    }

    func testStaleDisruptionStatusCannotReconnectAfterDisconnect() async {
        let statusResolver = DeferredWorkspaceStatusResolver()
        let retryScheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            runner: SuccessfulCommandRunner(),
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: retryScheduler,
            workspaceStatusResolver: statusResolver.resolve
        )

        model.connect("wc-1")
        let pane = model.panes["wc-1"]!.first!
        pane.onFirstOutput?()
        let established = await waitUntil { model.isTerminalVisible("wc-1") }
        XCTAssertTrue(established)
        guard established else { return }

        pane.onExit?(255)
        retryScheduler.fireNext()
        XCTAssertEqual(statusResolver.requestCount, 1)

        model.disconnect("wc-1")
        statusResolver.complete(at: 0, with: .success(WorkspaceStatus(id: "wc-1", state: "Running")))

        XCTAssertFalse(model.opened.contains("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)
    }

    func testStaleDisruptionStatusCannotReconnectWhileStopping() async {
        let statusResolver = DeferredWorkspaceStatusResolver()
        let retryScheduler = ManualConnectionRetryScheduler()
        let model = AppModel(
            runner: SuccessfulCommandRunner(),
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            connectionRetryScheduler: retryScheduler,
            workspaceStatusResolver: statusResolver.resolve
        )

        model.connect("wc-1")
        let pane = model.panes["wc-1"]!.first!
        pane.onFirstOutput?()
        let established = await waitUntil { model.isTerminalVisible("wc-1") }
        XCTAssertTrue(established)
        guard established else { return }

        pane.onExit?(255)
        retryScheduler.fireNext()
        XCTAssertEqual(statusResolver.requestCount, 1)

        model.stop("wc-1")
        statusResolver.complete(at: 0, with: .success(WorkspaceStatus(id: "wc-1", state: "Running")))

        XCTAssertFalse(model.opened.contains("wc-1"))
        XCTAssertTrue(model.shuttingDown.contains("wc-1"))
        XCTAssertEqual(model.panes["wc-1"]?.count, 1)
    }

    func testTimedOutOutputFreePrimaryExitStillRetries() {
        let retryScheduler = ManualConnectionRetryScheduler()
        let handoffScheduler = ManualHandoffTimeoutScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            handoffTimeoutScheduler: handoffScheduler,
            connectionRetryScheduler: retryScheduler
        )

        model.connect("wc-1")
        let pane = model.panes["wc-1"]!.first!
        handoffScheduler.fire()

        XCTAssertTrue(model.isTerminalVisible("wc-1"))

        pane.onExit?(255)

        XCTAssertEqual(retryScheduler.scheduled.map(\.delay), [0.5])
        XCTAssertTrue(model.isConnecting("wc-1"))
        XCTAssertNil(model.connectionFailure("wc-1"))
    }

    func testTimedOutOutputFreePrimaryCannotOpenExtraTerminal() {
        let handoffScheduler = ManualHandoffTimeoutScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            handoffTimeoutScheduler: handoffScheduler
        )

        model.connect("wc-1")
        handoffScheduler.fire()

        model.newTerminal("wc-1")

        XCTAssertEqual(model.panes["wc-1"]?.count, 1)
    }

    func testTimedOutOutputFreePrimaryCannotReload() {
        let handoffScheduler = ManualHandoffTimeoutScheduler()
        let model = AppModel(
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            handoffTimeoutScheduler: handoffScheduler
        )

        model.connect("wc-1")
        let primaryPaneID = model.panes["wc-1"]!.first!.id
        handoffScheduler.fire()

        model.reload("wc-1")

        XCTAssertEqual(model.panes["wc-1"]?.first?.id, primaryPaneID)
    }

    func testExtraTerminalFailureRetriesWithoutDisconnectingWorkspace() async {
        let retryScheduler = ManualConnectionRetryScheduler()
        let handoffScheduler = ManualHandoffTimeoutScheduler()
        let model = AppModel(
            runner: SuccessfulCommandRunner(),
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            handoffTimeoutScheduler: handoffScheduler,
            connectionRetryScheduler: retryScheduler
        )

        model.connect("wc-1")
        model.panes["wc-1"]?.first?.onFirstOutput?()
        for _ in 0 ..< 100 where !model.isTerminalVisible("wc-1") {
            try? await Task.sleep(for: .milliseconds(10))
        }
        model.newTerminal("wc-1")
        let extraPane = model.panes["wc-1"]![1]
        extraPane.onExit?(255)

        XCTAssertTrue(model.opened.contains("wc-1"))
        XCTAssertEqual(model.panes["wc-1"]?.count, 2)
        XCTAssertEqual(retryScheduler.scheduled.map(\.delay), [0.5])
    }

    func testPrimaryCleanExitDisconnectsDependentExtraTerminal() async {
        let model = AppModel(
            runner: SuccessfulCommandRunner(),
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false
        )

        model.connect("wc-1")
        let primary = model.panes["wc-1"]!.first!
        primary.onFirstOutput?()
        let established = await waitUntil { model.isTerminalVisible("wc-1") }
        XCTAssertTrue(established)
        guard established else { return }

        model.newTerminal("wc-1")
        XCTAssertEqual(model.panes["wc-1"]?.count, 2)

        primary.onExit?(0)

        XCTAssertFalse(model.opened.contains("wc-1"))
        XCTAssertTrue(model.panes["wc-1"]?.isEmpty ?? true)
    }

    func testElapsedMillisecondsUsesMonotonicNanoseconds() {
        XCTAssertEqual(AppModel.elapsedMilliseconds(
            startedAt: 1_000_000_000,
            now: 2_234_999_999
        ), 1_234)
        XCTAssertEqual(AppModel.elapsedMilliseconds(startedAt: 10, now: 9), 0)
    }

    func testTerminalReadinessDoesNotWaitForClaudeHooks() {
        XCTAssertTrue(AppModel.isTerminalReady(
            hooksFinished: false,
            shellIntegrationFinished: true
        ))
        XCTAssertFalse(AppModel.isTerminalReady(
            hooksFinished: true,
            shellIntegrationFinished: false
        ))
    }

    func testConnectingIncludesMountedTerminalAwaitingIntegration() {
        XCTAssertTrue(AppModel.isConnecting(
            isOpened: true,
            hasPanes: true,
            isAwaitingShellIntegration: true
        ))
    }

    func testMountedTerminalIsVisibleAfterIntegrationHandoff() {
        XCTAssertTrue(AppModel.isTerminalVisible(isAwaitingShellIntegration: false))
        XCTAssertFalse(AppModel.isTerminalVisible(isAwaitingShellIntegration: true))
    }

    func testSelectedLifecyclePanesAreDisplayVisibleBeforeSSHIsReady() {
        XCTAssertTrue(AppModel.isPaneDisplayVisible(
            isSelected: true,
            phase: .starting,
            isTerminalVisible: false
        ))
        XCTAssertTrue(AppModel.isPaneDisplayVisible(
            isSelected: true,
            phase: .shuttingDown,
            isTerminalVisible: false
        ))
    }

    func testPaneDisplayVisibilityPreservesSelectionAndSSHHandoffRules() {
        XCTAssertFalse(AppModel.isPaneDisplayVisible(
            isSelected: false,
            phase: .starting,
            isTerminalVisible: true
        ))
        XCTAssertFalse(AppModel.isPaneDisplayVisible(
            isSelected: true,
            phase: .terminal,
            isTerminalVisible: false
        ))
        XCTAssertTrue(AppModel.isPaneDisplayVisible(
            isSelected: true,
            phase: .terminal,
            isTerminalVisible: true
        ))
    }

    func testIntegrationCompletingBeforeSSHOutputRevealsOriginalTerminal() {
        XCTAssertEqual(
            AppModel.terminalHandoffAction(
                integrationSucceeded: true,
                sshProducedOutput: false
            ),
            .revealOriginal
        )
    }

    func testIntegrationCompletingAfterSSHOutputRestartsRemoteShell() {
        XCTAssertEqual(
            AppModel.terminalHandoffAction(
                integrationSucceeded: true,
                sshProducedOutput: true
            ),
            .restartRemoteShellThenReveal
        )
    }

    func testFailedIntegrationRevealsOriginalTerminal() {
        XCTAssertEqual(
            AppModel.terminalHandoffAction(
                integrationSucceeded: false,
                sshProducedOutput: true
            ),
            .revealOriginal
        )
    }

    func testSuccessfulShellIntegrationConfirmsSSHIndependentlyOfTheHandoff() {
        XCTAssertTrue(AppModel.shouldConfirmSSH(forShellIntegrationSuccess: true))
        XCTAssertFalse(AppModel.shouldConfirmSSH(forShellIntegrationSuccess: false))
    }

    func testHandoffMountsPrimaryBeforeSchedulingTimeout() {
        var events: [String] = []

        AppModel.startTerminalHandoff(
            mountPrimary: { events.append("mount") },
            scheduleTimeout: { delay in events.append("timeout:\(Int(delay))") }
        )

        XCTAssertEqual(events, ["mount", "timeout:10"])
    }

    func testFirstOutputThenSuccessfulIntegrationRestartsRemoteShell() {
        let paneID = UUID()
        var handoff = AppModel.TerminalHandoffState(paneID: paneID)

        XCTAssertNil(handoff.handle(.firstOutput(paneID: paneID)))
        XCTAssertEqual(
            handoff.handle(.integrationFinished(
                paneID: paneID,
                succeeded: true,
                sshProducedOutputAtIngress: false
            )),
            .restartRemoteShellThenReveal
        )
    }

    func testSuccessfulIntegrationUsesOutputObservedAtPTYIngress() {
        let paneID = UUID()
        var handoff = AppModel.TerminalHandoffState(paneID: paneID)

        // PTY output may be observed on its read queue before its UI delivery
        // reaches the main actor. The handoff must still restart that shell.
        XCTAssertEqual(
            handoff.handle(.integrationFinished(
                paneID: paneID,
                succeeded: true,
                sshProducedOutputAtIngress: true
            )),
            .restartRemoteShellThenReveal
        )
    }

    func testFailedIntegrationAndTimeoutRevealOriginalTerminal() {
        let failedPaneID = UUID()
        var failed = AppModel.TerminalHandoffState(paneID: failedPaneID)
        XCTAssertEqual(
            failed.handle(.integrationFinished(
                paneID: failedPaneID,
                succeeded: false,
                sshProducedOutputAtIngress: true
            )),
            .revealOriginal
        )

        let timedOutPaneID = UUID()
        var timedOut = AppModel.TerminalHandoffState(paneID: timedOutPaneID)
        XCTAssertEqual(
            timedOut.handle(.timedOut(paneID: timedOutPaneID)),
            .revealOriginal
        )
    }

    func testTimeoutIsPaneBoundAndRejectsLateIntegrationCompletion() {
        let paneID = UUID()
        var handoff = AppModel.TerminalHandoffState(paneID: paneID)

        XCTAssertNil(handoff.handle(.timedOut(paneID: UUID())))
        XCTAssertEqual(
            handoff.handle(.timedOut(paneID: paneID)),
            .revealOriginal
        )
        XCTAssertNil(handoff.handle(.integrationFinished(
            paneID: paneID,
            succeeded: true,
            sshProducedOutputAtIngress: true
        )))
    }

    func testCancellationRejectsStaleIntegrationCompletion() {
        let paneID = UUID()
        var handoff = AppModel.TerminalHandoffState(paneID: paneID)

        handoff.cancel()

        XCTAssertNil(handoff.handle(.integrationFinished(
            paneID: paneID,
            succeeded: true,
            sshProducedOutputAtIngress: true
        )))
    }

    func testRemoteShellRestartPreservesResetAfterInterruptHandlerConsumesNextByte() async {
        let pty = PTYSession()
        let output = LockedOutputBuffer()
        pty.onOutput = { output.append($0) }
        defer { pty.terminate() }

        pty.start(
            path: "/bin/zsh",
            args: ["-f", "-i"],
            cols: 80,
            rows: 24,
            extraEnv: ["PS1": "DEVSPACE_READY> ", "SHELL": "/bin/sh"]
        )
        let initialPromptAppeared = await waitUntil {
            output.text.contains("DEVSPACE_READY> ")
        }
        XCTAssertTrue(initialPromptAppeared)
        guard initialPromptAppeared else { return }

        pty.write(Data("TRAPINT() { read -rk 1; }\r".utf8))
        let trapInstalled = await waitUntil {
            output.text.components(separatedBy: "DEVSPACE_READY> ").count >= 3
        }
        XCTAssertTrue(trapInstalled)
        guard trapInstalled else { return }

        pty.write(Data(TerminalPaneModel.restartRemoteShellCommand.utf8))
        let restartedPromptAppeared = await waitUntil {
            output.text.components(separatedBy: "DEVSPACE_READY> ").count >= 4
        }

        XCTAssertTrue(restartedPromptAppeared)
        XCTAssertFalse(output.text.contains("command not found: eset"))
    }
}
