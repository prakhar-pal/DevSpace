import XCTest
@testable import DevSpaceCore

private final class ControlledMaster: SSHTransportControlling {
    let controlPath = "/tmp/devspace-controller-test/socket"
    var proxyCommand: String?
    var state: SSHTransportSession.State = .idle
    var onReady: (() -> Void)?
    var onExit: ((Int32) -> Void)?
    var onStopped: (() -> Void)?
    var onStartError: ((SSHTransportSession.StartError) -> Void)?
    func start() { state = .starting }
    func stop() { state = .stopping }
    func ready() { state = .ready; onReady?() }
    func stopped() { state = .exited; onStopped?() }
}

private final class TimeoutMasterProcess: SSHTransportProcess {
    var stderrTail = ""
    var terminated = false
    func terminate() { terminated = true }
}

private final class TimeoutMasterScheduler: SSHTransportScheduling {
    var deadline: (() -> Void)?
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
        if delay == 15 { deadline = action }
    }
}

final class WorkspaceTerminalControllerTests: XCTestCase {
    func testConnectDuringDisconnectWaitsForCleanupAndOldMasterExit() throws {
        let first = ControlledMaster(), second = ControlledMaster()
        var transports = [first, second]
        var effects: [WorkspaceTerminalEffect] = []
        let controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in transports.removeFirst() }, emit: { effects.append($0) })
        var cleanup: (() -> Void)?
        controller.beforeDisconnect = { _, _, _, completion in cleanup = completion }
        try controller.connect("pod")
        XCTAssertEqual(controller.connectionStates["pod"], "connecting")
        first.ready()
        XCTAssertEqual(controller.connectionStates["pod"], "connected")
        controller.disconnect("pod")
        XCTAssertEqual(controller.connectionStates["pod"], "disconnecting")
        try controller.connect("pod")
        XCTAssertEqual(second.state, .idle)
        cleanup?()
        XCTAssertEqual(second.state, .idle, "replacement started before the old master released its lease")
        first.stopped()
        XCTAssertEqual(second.state, .starting, "explicit Connect was lost while Disconnect was finishing")
        second.ready()
        XCTAssertEqual(effects.filter { $0.kind == "terminal_launch" }.count, 2)
    }
    func testLastShellExitStillWaitsForHookCleanup() throws {
        let master = ControlledMaster()
        var effects: [WorkspaceTerminalEffect] = []
        let controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in master }, emit: { effects.append($0) })
        var cleanup: (() -> Void)?
        controller.beforeDisconnect = { _, _, _, completion in
            if controller.hasProducedOutput("pod") { cleanup = completion }
            else { completion() }
        }
        try controller.connect("pod")
        master.ready()
        let launch = try XCTUnwrap(effects.first)
        let pane = try XCTUnwrap(launch.paneID)
        XCTAssertTrue(controller.report(workspace: "pod", generation: launch.generation,
            pane: pane, kind: "terminal_output"))
        XCTAssertTrue(controller.report(workspace: "pod", generation: launch.generation,
            pane: pane, kind: "terminal_exit"))
        XCTAssertNotNil(cleanup, "last shell exit discarded evidence needed to remove its hooks")
        XCTAssertEqual(effects.filter { $0.kind == "terminal_close" && $0.paneID == pane }.count, 1,
                       "last shell exit must remove the departed frontend pane")
        XCTAssertEqual(master.state, .ready, "master exited before hook cleanup could run")
        cleanup?()
        XCTAssertEqual(master.state, .stopping)
    }
    func testFocusSelectsOnlyTheCurrentPaneGeneration() throws {
        let master = ControlledMaster()
        var effects: [WorkspaceTerminalEffect] = []
        let selection = WorkspaceController(workspaces: [.init(id: "pod", provider: "", source: "", lastUsed: "", state: "Running", error: nil)])
        selection.select("other")
        XCTAssertTrue(selection.receiveNotification(workspaceID: "pod"))
        let controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in master }, emit: { effects.append($0) })
        controller.onFocus = { selection.select($0) }
        try controller.connect("pod")
        master.ready()
        let launch = try XCTUnwrap(effects.first)
        XCTAssertTrue(controller.report(workspace: "pod", generation: launch.generation, pane: try XCTUnwrap(launch.paneID), kind: "terminal_focus"))
        XCTAssertEqual(selection.snapshot.selectedID, "pod")
        XCTAssertEqual(selection.snapshot.badges, [])
        controller.disconnect("pod")
        selection.select("other")
        XCTAssertTrue(selection.receiveNotification(workspaceID: "pod"))
        XCTAssertFalse(controller.report(workspace: "pod", generation: launch.generation, pane: try XCTUnwrap(launch.paneID), kind: "terminal_focus"))
        XCTAssertEqual(selection.snapshot.selectedID, "other")
        XCTAssertEqual(selection.snapshot.badges, ["pod"])
    }
    func testStoppedOrMissingWorkspaceCancelsReloadAndReleasesTransport() throws {
        for states: [WorkspaceView] in [[], [.init(id: "pod", provider: "", source: "", lastUsed: "", state: "Stopped", error: nil)]] {
            let master = ControlledMaster()
            var launches = 0
            let controller = WorkspaceTerminalController(identity: .init(channel: .development),
                makeTransport: { _ in master }, emit: { if $0.kind == "terminal_launch" { launches += 1 } })
            try controller.connect("pod")
            master.ready()
            try controller.reconnect("pod")
            controller.reconcile(states)
            master.stopped()
            XCTAssertFalse(controller.hasOwnedTransports)
            XCTAssertEqual(launches, 1)
        }
    }
    func testImageCompletionCannotInjectIntoReloadedOrClosedPane() throws {
        let master = ControlledMaster()
        var effects: [WorkspaceTerminalEffect] = []
        let controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in master }, emit: { effects.append($0) })
        try controller.connect("pod")
        master.ready()
        let launch = try XCTUnwrap(effects.first)
        let pane = try XCTUnwrap(launch.paneID)
        XCTAssertNil(controller.imageTarget(workspace: "pod", generation: launch.generation, pane: pane), "image paste must wait for real terminal output")
        XCTAssertTrue(controller.report(workspace: "pod", generation: launch.generation, pane: pane, kind: "terminal_output"))
        XCTAssertEqual(controller.imageTarget(workspace: "pod", generation: launch.generation, pane: pane), master.controlPath)
        XCTAssertTrue(controller.injectText(workspace: "pod", generation: launch.generation, pane: pane, text: "Image pasted: /tmp/image.png "))
        XCTAssertEqual(effects.last?.kind, "terminal_inject")
        XCTAssertEqual(effects.last?.paneID, pane)
        XCTAssertEqual(effects.last?.message, "Image pasted: /tmp/image.png ")
        controller.disconnect("pod")
        let count = effects.count
        XCTAssertNil(controller.imageTarget(workspace: "pod", generation: launch.generation, pane: pane))
        XCTAssertFalse(controller.injectText(workspace: "pod", generation: launch.generation, pane: pane, text: "stale image"))
        XCTAssertEqual(effects.count, count)
    }
    func testFirstOutputStartsIntegrationOnceAndDisconnectCancelsItsGeneration() throws {
        let master = ControlledMaster()
        var effects: [WorkspaceTerminalEffect] = []
        var started: [UUID] = [], cancelled: [UUID] = []
        let controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in master }, emit: { effects.append($0) })
        controller.onFirstOutput = { workspace, generation in
            XCTAssertEqual(workspace, "pod")
            started.append(generation)
            return true
        }
        controller.onDisconnect = { _, generation in cancelled.append(generation) }
        try controller.connect("pod")
        master.ready()
        let launch = try XCTUnwrap(effects.first)
        let pane = try XCTUnwrap(launch.paneID)
        XCTAssertTrue(started.isEmpty, "integration must not delay terminal creation")
        XCTAssertFalse(controller.hasProducedOutput("pod"))
        XCTAssertTrue(controller.report(workspace: "pod", generation: launch.generation, pane: pane, kind: "terminal_output"))
        XCTAssertTrue(controller.hasProducedOutput("pod"))
        XCTAssertTrue(controller.report(workspace: "pod", generation: launch.generation, pane: pane, kind: "terminal_output"))
        XCTAssertEqual(started, [launch.generation])
        controller.disconnect("pod")
        XCTAssertEqual(cancelled, [launch.generation])
        XCTAssertFalse(controller.report(workspace: "pod", generation: launch.generation, pane: pane, kind: "terminal_output"))
        XCTAssertEqual(started.count, 1)
    }
    func testReloadRetriesIntegrationAfterCancelledPreviousJobCompletes() throws {
        let master = ControlledMaster()
        var effects: [WorkspaceTerminalEffect] = []
        var busy = false
        var attempts: [UUID] = []
        let controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in master }, emit: { effects.append($0) })
        controller.onFirstOutput = { _, generation in attempts.append(generation); return !busy }
        try controller.connect("pod")
        master.ready()
        let first = try XCTUnwrap(effects.last)
        XCTAssertTrue(controller.report(workspace: "pod", generation: first.generation, pane: try XCTUnwrap(first.paneID), kind: "terminal_output"))
        busy = true
        try controller.reconnect("pod")
        master.stopped()
        master.ready()
        let replacement = try XCTUnwrap(effects.last)
        XCTAssertNotEqual(first.generation, replacement.generation)
        XCTAssertTrue(controller.report(workspace: "pod", generation: replacement.generation, pane: try XCTUnwrap(replacement.paneID), kind: "terminal_output"))
        busy = false
        controller.retryIntegration("pod")
        controller.retryIntegration("pod")
        XCTAssertEqual(attempts, [first.generation, replacement.generation, replacement.generation])
        XCTAssertFalse(controller.report(workspace: "pod", generation: first.generation, pane: try XCTUnwrap(first.paneID), kind: "terminal_output"))
    }
    func testLifecyclePrerequisiteWaitsForMasterAndRejectsLateReady() throws {
        let master = ControlledMaster()
        var released = 0
        var effects: [WorkspaceTerminalEffect] = []
        let controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in master }, emit: { effects.append($0) })
        try controller.connect("pod")
        master.ready()
        controller.disconnect("pod") { released += 1 }
        XCTAssertEqual(master.state, .stopping)
        XCTAssertEqual(released, 0, "workspace operation started before master cleanup")
        master.onReady?()
        XCTAssertEqual(effects.filter { $0.kind == "terminal_launch" }.count, 1)
        master.stopped()
        XCTAssertEqual(released, 1)
        XCTAssertFalse(controller.hasOwnedTransports)
        controller.disconnect("pod") { released += 1 }
        XCTAssertEqual(released, 2, "idle workspace prerequisite did not complete")
    }
    func testTerminalClientsReuseTheMastersNoServiceRestartProxy() throws {
        let master = ControlledMaster()
        master.proxyCommand = "devpod ssh --stdio pod"
        var effects: [WorkspaceTerminalEffect] = []
        let controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in master }, emit: { effects.append($0) })
        try controller.connect("pod")
        master.ready()
        XCTAssertTrue(effects[0].arguments.contains("ProxyCommand=devpod ssh --stdio pod --start-services=false"))
    }
    func testCloseEffectsObserveAlreadyRemovedPaneState() throws {
        let master = ControlledMaster()
        var controller: WorkspaceTerminalController!
        var closedPanes: [TerminalPaneDescriptor]?
        controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in master }, emit: { effect in
                if effect.kind == "terminal_close" { closedPanes = controller.panes }
            })
        try controller.connect("pod")
        master.ready()
        XCTAssertEqual(controller.panes.count, 1)
        controller.disconnect("pod")
        XCTAssertEqual(closedPanes, [], "close effects must publish the post-close snapshot")
    }

    func testFrontendLaunchFailureReportsErrorAndReleasesLastShell() throws {
        let master = ControlledMaster()
        var effects: [WorkspaceTerminalEffect] = []
        let controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in master }, emit: { effects.append($0) })
        try controller.connect("pod")
        master.ready()
        let launch = effects[0]
        XCTAssertTrue(controller.report(workspace: "pod", generation: launch.generation,
            pane: try XCTUnwrap(launch.paneID), kind: "terminal_launch_failed"))
        XCTAssertEqual(effects.last?.kind, "terminal_error")
        XCTAssertFalse(effects.last?.message?.isEmpty ?? true)
        XCTAssertTrue(controller.panes.isEmpty)
        XCTAssertEqual(master.state, .stopping)
    }

    func testReadinessTimeoutIsReportedAfterRealTransportStops() throws {
        let process = TimeoutMasterProcess()
        let scheduler = TimeoutMasterScheduler()
        var processExited: ((Int32) -> Void)?
        let session = SSHTransportSession(podID: "pod", proxyCommand: nil,
            controlPath: "/tmp/devspace-timeout-test/socket",
            launch: { _, onExit in processExited = onExit; return process },
            check: { _, completion in completion(false) }, scheduler: scheduler)
        var effects: [WorkspaceTerminalEffect] = []
        let controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in session }, emit: { effects.append($0) })
        try controller.connect("pod")
        scheduler.deadline?()
        XCTAssertTrue(process.terminated)
        XCTAssertTrue(effects.isEmpty)
        processExited?(0)
        XCTAssertEqual(effects.map(\.kind), ["terminal_error"])
        XCTAssertTrue(effects.first?.message?.contains("readinessTimedOut") == true)
        XCTAssertFalse(controller.hasOwnedTransports)
    }

    func testReadyMasterEmitsClientLaunchWithoutAnotherTunnel() throws {
        let master = ControlledMaster()
        var effects: [WorkspaceTerminalEffect] = []
        let controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in master }, emit: { effects.append($0) })
        try controller.connect("pod")
        XCTAssertTrue(effects.isEmpty)
        master.ready()
        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(effects[0].kind, "terminal_launch")
        XCTAssertEqual(effects[0].workspaceID, "pod")
        XCTAssertEqual(effects[0].executable, "/usr/bin/ssh")
        XCTAssertTrue(effects[0].arguments.contains("ControlMaster=no"))
        XCTAssertFalse(effects[0].arguments.contains("-R"))
    }

    func testReconnectWaitsForOldMasterExitAndRejectsOldReadyCallback() throws {
        let first = ControlledMaster(), second = ControlledMaster()
        var transports: [ControlledMaster] = [first, second]
        var effects: [WorkspaceTerminalEffect] = []
        let controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in transports.removeFirst() }, emit: { effects.append($0) })
        try controller.connect("pod")
        first.ready()
        let original = effects[0]
        try controller.reconnect("pod")
        XCTAssertEqual(first.state, .stopping)
        XCTAssertEqual(second.state, .idle)
        first.onReady?()
        XCTAssertEqual(effects.filter { $0.kind == "terminal_launch" }.count, 1)
        first.stopped()
        XCTAssertEqual(second.state, .starting)
        second.ready()
        XCTAssertNotEqual(effects.last?.generation, original.generation)
        XCTAssertNotEqual(effects.last?.paneID, original.paneID)
    }

    func testShutdownCannotReconnectFromDelayedCallbacks() throws {
        let master = ControlledMaster()
        var effects: [WorkspaceTerminalEffect] = []
        let controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in master }, emit: { effects.append($0) })
        try controller.connect("pod")
        controller.shutdown()
        master.onReady?()
        master.stopped()
        XCTAssertFalse(effects.contains { $0.kind == "terminal_launch" })
        XCTAssertThrowsError(try controller.connect("pod"))
    }

    func testDisconnectWaitsForHookCleanupBeforeStoppingMaster() throws {
        let master = ControlledMaster()
        let controller = WorkspaceTerminalController(identity: .init(channel: .development),
            makeTransport: { _ in master }, emit: { _ in })
        var cleanup: (() -> Void)?
        controller.beforeDisconnect = { workspace, _, controlPath, completion in
            XCTAssertEqual(workspace, "pod")
            XCTAssertEqual(controlPath, master.controlPath)
            cleanup = completion
        }
        try controller.connect("pod")
        XCTAssertEqual(controller.openedWorkspaces, ["pod"])
        master.ready()

        controller.disconnect("pod")

        XCTAssertEqual(master.state, .ready, "the live SSH master must remain available while hooks are removed")
        XCTAssertTrue(controller.openedWorkspaces.contains("pod"), "disconnect cleanup still owns the live master")
        try XCTUnwrap(cleanup)()
        XCTAssertEqual(master.state, .stopping)
    }
}
