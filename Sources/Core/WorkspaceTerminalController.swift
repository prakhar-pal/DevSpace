import Foundation

/// Control effects only; terminal bytes and PTYs remain owned by the frontend.
public struct WorkspaceTerminalEffect: Codable, Equatable, Sendable {
    public let kind: String
    public let workspaceID: String
    public let generation: UUID
    public let paneID: UUID?
    public let executable: String?
    public let arguments: [String]
    public let message: String?
}

/// Called on the controller event queue. An old master retains its lease until
/// onStopped; a reload never starts its replacement before that notification.
public final class WorkspaceTerminalController {
    public var onFirstOutput: ((String, UUID) -> Bool)?
    public var onDisconnect: ((String, UUID) -> Void)?
    public var beforeDisconnect: ((String, UUID, String, @escaping () -> Void) -> Void)?
    public var onFocus: ((String) -> Void)?
    private final class Connection {
        let generation = UUID()
        let transport: SSHTransportControlling
        var panes: [UUID: String?] = [:]
        var producedOutput: Set<UUID> = []
        var hasProducedOutput = false
        var integrationStarted = false
        var stopping = false
        var reconnect = false
        var afterStop: [() -> Void] = []
        init(_ transport: SSHTransportControlling) { self.transport = transport }
    }

    private let identity: DevSpaceRuntimeIdentity
    private let makeTransport: (String) -> SSHTransportControlling
    private let emit: (WorkspaceTerminalEffect) -> Void
    private var connections: [String: Connection] = [:]
    private var shuttingDown = false

    public init(identity: DevSpaceRuntimeIdentity,
                makeTransport: @escaping (String) -> SSHTransportControlling,
                emit: @escaping (WorkspaceTerminalEffect) -> Void) {
        self.identity = identity
        self.makeTransport = makeTransport
        self.emit = emit
    }

    public var panes: [TerminalPaneDescriptor] {
        connections.flatMap { workspace, connection in
            connection.panes.keys.map { TerminalPaneDescriptor(id: $0, workspaceID: workspace) }
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public var hasOwnedTransports: Bool { !connections.isEmpty }
    public var openedWorkspaces: Set<String> { Set(connections.keys) }

    public func hasProducedOutput(_ workspace: String) -> Bool {
        connections[workspace]?.hasProducedOutput == true
    }

    /// Only definitive stop/removal withdraws terminal intent. Unknown status
    /// must not destroy a working shell; a stale queued reload must not reopen it.
    public func reconcile(_ workspaces: [WorkspaceView]) {
        let states = Dictionary(workspaces.map { ($0.id, $0.state) }, uniquingKeysWith: { _, last in last })
        for workspace in Array(connections.keys) where states[workspace] == nil || states[workspace] == "Stopped" {
            disconnect(workspace)
        }
    }

    /// A cancelled installer may finish after a replacement shell produces its
    /// first output. Retry only that current, live, not-yet-accepted generation.
    public func retryIntegration(_ workspace: String) {
        guard let connection = connections[workspace], !connection.stopping,
              !connection.integrationStarted, !connection.producedOutput.isEmpty else { return }
        connection.integrationStarted = onFirstOutput?(workspace, connection.generation) ?? true
    }

    public func controlPath(for workspace: String) -> String? {
        guard let connection = connections[workspace], !connection.stopping,
              connection.transport.state == .ready else { return nil }
        return connection.transport.controlPath
    }

    public func imageTarget(workspace: String, generation: UUID, pane: UUID) -> String? {
        guard let connection = connections[workspace], !connection.stopping,
              connection.generation == generation, connection.transport.state == .ready,
              connection.panes.keys.contains(pane), connection.producedOutput.contains(pane) else { return nil }
        return connection.transport.controlPath
    }
    @discardableResult
    public func injectText(workspace: String, generation: UUID, pane: UUID, text: String) -> Bool {
        guard imageTarget(workspace: workspace, generation: generation, pane: pane) != nil else { return false }
        emit(WorkspaceTerminalEffect(kind: "terminal_inject", workspaceID: workspace, generation: generation,
            paneID: pane, executable: nil, arguments: [], message: text))
        return true
    }

    public func connect(_ workspace: String) throws {
        try Devpod.validateId(workspace)
        guard !shuttingDown else { throw DevpodError("terminal controller is shutting down") }
        if let connection = connections[workspace] {
            if !connection.stopping, connection.transport.state == .ready {
                launchPane(workspace, connection)
            }
            return
        }
        let connection = Connection(makeTransport(workspace))
        connections[workspace] = connection
        connection.transport.onReady = { [weak self, weak connection] in
            guard let self, let connection, self.isCurrent(workspace, connection), !connection.stopping else { return }
            self.launchPane(workspace, connection)
        }
        connection.transport.onStopped = { [weak self, weak connection] in
            guard let self, let connection, self.isCurrent(workspace, connection) else { return }
            // A readiness timeout also stops the transport, but reports its
            // failure immediately after onStopped. Keep that connection until
            // onStartError can publish the reason; only our own stop/reload
            // path is complete at this callback.
            guard connection.stopping else { return }
            self.connections.removeValue(forKey: workspace)
            for completion in connection.afterStop { completion() }
            connection.afterStop.removeAll()
            if connection.reconnect, !self.shuttingDown { try? self.connect(workspace) }
        }
        connection.transport.onExit = { [weak self, weak connection] code in
            guard let self, let connection, self.isCurrent(workspace, connection) else { return }
            if !connection.stopping { self.onDisconnect?(workspace, connection.generation) }
            self.closePanes(workspace, connection)
            self.connections.removeValue(forKey: workspace)
            self.effect("terminal_error", workspace, connection, message: "SSH master exited: \(code)")
        }
        connection.transport.onStartError = { [weak self, weak connection] error in
            guard let self, let connection, self.isCurrent(workspace, connection) else { return }
            self.effect("terminal_error", workspace, connection, message: "SSH connection failed: \(error)")
            if connection.transport.state == .exited { self.connections.removeValue(forKey: workspace) }
        }
        connection.transport.start()
    }

    public func reconnect(_ workspace: String) throws {
        try Devpod.validateId(workspace)
        guard !shuttingDown else { throw DevpodError("terminal controller is shutting down") }
        guard let connection = connections[workspace] else { try connect(workspace); return }
        connection.reconnect = true
        stop(workspace, connection)
    }

    public func disconnect(_ workspace: String) {
        guard let connection = connections[workspace] else { return }
        connection.reconnect = false
        stop(workspace, connection)
    }

    public func disconnect(_ workspace: String, completion: @escaping () -> Void) {
        guard let connection = connections[workspace] else { completion(); return }
        connection.afterStop.append(completion)
        disconnect(workspace)
    }

    public func shutdown() {
        shuttingDown = true
        for (workspace, connection) in connections {
            connection.reconnect = false
            stop(workspace, connection)
        }
    }

    /// Stale terminal events cannot close or modify a replacement pane.
    @discardableResult
    public func report(workspace: String, generation: UUID, pane: UUID,
                       kind: String, directory: String? = nil) -> Bool {
        guard let connection = connections[workspace], !connection.stopping,
              connection.generation == generation, connection.panes.keys.contains(pane) else { return false }
        switch kind {
        case "terminal_focus": onFocus?(workspace)
        case "terminal_output":
            connection.producedOutput.insert(pane)
            connection.hasProducedOutput = true
            retryIntegration(workspace)
        case "terminal_directory": connection.panes[pane] = .some(directory)
        case "terminal_exit", "terminal_launch_failed":
            if kind == "terminal_launch_failed" {
                effect("terminal_error", workspace, connection, message: "Terminal could not start")
            }
            connection.panes.removeValue(forKey: pane)
            connection.producedOutput.remove(pane)
            if kind == "terminal_exit" {
                emit(WorkspaceTerminalEffect(kind: "terminal_close", workspaceID: workspace,
                    generation: generation, paneID: pane, executable: nil, arguments: [], message: nil))
            }
            if connection.panes.isEmpty { disconnect(workspace) }
        default: return false
        }
        return true
    }

    private func isCurrent(_ workspace: String, _ connection: Connection) -> Bool {
        connections[workspace] === connection
    }

    private func launchPane(_ workspace: String, _ connection: Connection) {
        let pane = UUID()
        connection.panes[pane] = .some(nil)
        emit(WorkspaceTerminalEffect(kind: "terminal_launch", workspaceID: workspace,
            generation: connection.generation, paneID: pane, executable: "/usr/bin/ssh",
            arguments: SSH.clientArgs(podID: workspace, proxyCommand: connection.transport.proxyCommand,
                controlPath: connection.transport.controlPath,
                bundleIdentifier: identity.channel.applicationIdentifier), message: nil))
    }

    private func stop(_ workspace: String, _ connection: Connection) {
        guard !connection.stopping else { return }
        connection.stopping = true
        onDisconnect?(workspace, connection.generation)
        let finish = { [weak self, weak connection] in
            guard let self, let connection, self.isCurrent(workspace, connection) else { return }
            self.closePanes(workspace, connection)
            connection.transport.stop()
        }
        if let beforeDisconnect {
            beforeDisconnect(workspace, connection.generation, connection.transport.controlPath, finish)
        } else {
            finish()
        }
    }

    private func closePanes(_ workspace: String, _ connection: Connection) {
        let closing = Array(connection.panes.keys)
        // Effect consumers publish snapshots synchronously. They must observe
        // the closed state rather than resurrecting panes from an old snapshot.
        connection.panes.removeAll()
        connection.producedOutput.removeAll()
        for pane in closing {
            emit(WorkspaceTerminalEffect(kind: "terminal_close", workspaceID: workspace,
                generation: connection.generation, paneID: pane, executable: nil, arguments: [], message: nil))
        }
    }

    private func effect(_ kind: String, _ workspace: String, _ connection: Connection, message: String) {
        emit(WorkspaceTerminalEffect(kind: kind, workspaceID: workspace,
            generation: connection.generation, paneID: nil, executable: nil, arguments: [], message: message))
    }
}
