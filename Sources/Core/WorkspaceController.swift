import Foundation

/// Owns monotonically-replaced connection tokens. A callback from a previous
/// SSH attempt must never install panes or retry after a reload/stop has begun.
public final class WorkspaceConnectionGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: UUID] = [:]

    public init() {}

    public func begin(workspaceID: String) -> UUID {
        let generation = UUID()
        lock.lock()
        values[workspaceID] = generation
        lock.unlock()
        return generation
    }

    public func isCurrent(_ generation: UUID, workspaceID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values[workspaceID] == generation
    }

    public func invalidate(workspaceID: String) {
        lock.lock()
        values[workspaceID] = UUID()
        lock.unlock()
    }
}

/// Pure lifecycle reconciliation shared by desktop adapters. It intentionally
/// makes no UI or SSH calls; adapters perform the listed effects in their own
/// platform-specific order.
public enum WorkspaceLifecycle {
    public struct Plan: Equatable, Sendable {
        public let seenDefinitive: Set<String>
        public let autoConnect: Set<String>
        public let connect: [String]
        public let disconnect: [String]
        public let stopConfirmed: [String]
    }

    public static func reconcile(
        workspaces: [WorkspaceView],
        seenDefinitive: Set<String>,
        autoConnect: Set<String>,
        opened: Set<String>,
        starting: Set<String>,
        shuttingDown: Set<String>
    ) -> Plan {
        var seen = seenDefinitive
        var intended = autoConnect
        let states = Dictionary(workspaces.map { ($0.id, $0.state) }, uniquingKeysWith: { latest, _ in latest })

        for workspace in workspaces where workspace.state == "Running" || workspace.state == "Stopped" {
            if seen.insert(workspace.id).inserted, workspace.state == "Running" {
                intended.insert(workspace.id)
            }
        }
        for workspace in workspaces where workspace.state == "Stopped" && !starting.contains(workspace.id) {
            intended.remove(workspace.id)
        }

        let connect = workspaces.compactMap { workspace in
            workspace.state == "Running" && intended.contains(workspace.id) ? workspace.id : nil
        }
        let disconnect = opened.filter { states[$0] == nil || states[$0] == "Stopped" }.sorted()
        let stopConfirmed = shuttingDown.filter { states[$0] == "Stopped" }.sorted()
        return Plan(
            seenDefinitive: seen,
            autoConnect: intended,
            connect: connect,
            disconnect: disconnect,
            stopConfirmed: stopConfirmed
        )
    }
}

/// A frontend-neutral portion of the workspace controller. It owns the state
/// that must be identical in SwiftUI and GTK: poll ordering, sidebar layout,
/// selection, and terminal-pane identity. Platform adapters own rendering and
/// report terminal lifecycle effects back to the larger controller.
public struct TerminalPaneDescriptor: Codable, Equatable, Sendable {
    public let id: UUID
    public let workspaceID: String

    public init(id: UUID = UUID(), workspaceID: String) {
        self.id = id
        self.workspaceID = workspaceID
    }
}

public struct WorkspaceControllerSnapshot: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let workspaces: [WorkspaceView]
    public let selectedID: String?
    public let layout: Layout
    public let terminalPanes: [TerminalPaneDescriptor]
    public let operations: [WorkspaceOperationDescriptor]
    public let badges: [String]

    public init(
        revision: UInt64,
        workspaces: [WorkspaceView],
        selectedID: String?,
        layout: Layout,
        terminalPanes: [TerminalPaneDescriptor],
        operations: [WorkspaceOperationDescriptor] = [],
        badges: [String] = []
    ) {
        self.revision = revision
        self.workspaces = workspaces
        self.selectedID = selectedID
        self.layout = layout
        self.terminalPanes = terminalPanes
        self.operations = operations
        self.badges = badges
    }
}

public final class WorkspaceController: @unchecked Sendable {
    public enum TerminalHandoffAction: Equatable, Sendable {
        case revealOriginal
        case restartRemoteShellThenReveal
    }
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var workspaces: [WorkspaceView]
    private var selectedID: String?
    private var layout: Layout
    private var terminalPanes: [TerminalPaneDescriptor] = []
    private var operations: [WorkspaceOperationDescriptor] = []
    private var badges: Set<String> = []

    public init(workspaces: [WorkspaceView] = [], layout: Layout = Layout()) {
        self.workspaces = workspaces
        self.layout = layout
        // A stored layout commonly loads before the first poll. Do not prune
        // it against an empty placeholder list or startup would erase all
        // aliases/order/hidden preferences before DevPod answers.
        if !workspaces.isEmpty {
            normalizeLayout()
        }
    }

    public var snapshot: WorkspaceControllerSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return WorkspaceControllerSnapshot(
            revision: revision,
            workspaces: workspaces,
            selectedID: selectedID,
            layout: layout,
            terminalPanes: terminalPanes,
            operations: operations,
            badges: badges.sorted()
        )
    }

    public func select(_ id: String?) {
        lock.lock()
        selectedID = id
        if let id { badges.remove(id) }
        lock.unlock()
    }

    public static func shouldPresentNotification(
        workspaceID: String, selectedID: String?, applicationIsActive: Bool
    ) -> Bool {
        !applicationIsActive || workspaceID != selectedID
    }

    public func canInstallIntegration(workspaceID: String, ownedControlPath: String?) -> Bool {
        guard let workspace = snapshot.workspaces.first(where: { $0.id == workspaceID }) else { return false }
        return workspace.state == "Running" || (ownedControlPath != nil && workspace.state != "Stopped")
    }

    @discardableResult
    public func receiveNotification(workspaceID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard (try? Devpod.validateId(workspaceID)) != nil,
              workspaces.contains(where: { $0.id == workspaceID }) else { return false }
        if workspaceID != selectedID { badges.insert(workspaceID) }
        return true
    }

    /// Applies only monotonic poll updates. Pane descriptors are deliberately
    /// untouched: a status refresh must never recreate a terminal surface.
    @discardableResult
    public func apply(_ update: PollUpdate) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard update.revision >= revision else { return false }
        revision = update.revision
        workspaces = update.views
        badges.formIntersection(workspaces.map(\.id))
        normalizeLayout()
        return true
    }

    public func setTerminalPanes(_ descriptors: [TerminalPaneDescriptor]) {
        lock.lock()
        terminalPanes = descriptors
        lock.unlock()
    }

    public func setOperations(_ descriptors: [WorkspaceOperationDescriptor]) {
        lock.lock()
        operations = descriptors
        lock.unlock()
    }

    public func setAlias(_ name: String, for workspaceID: String) throws {
        try editLayout(workspaceID) { layout in
            layout.aliases = SidebarLayout.setAlias(layout.aliases, id: workspaceID, name: name)
        }
    }

    public func setHidden(_ hidden: Bool, workspaceID: String) throws {
        try editLayout(workspaceID) { layout in
            if hidden {
                if !layout.hidden.contains(workspaceID) { layout.hidden.append(workspaceID) }
            } else {
                layout.hidden.removeAll { $0 == workspaceID }
            }
        }
    }

    public func moveWorkspace(_ workspaceID: String, delta: Int) throws {
        try editLayout(workspaceID) { layout in
            let hidden = Set(layout.hidden)
            let visible = layout.order.filter { !hidden.contains($0) }
            let moved = SidebarLayout.moveVisible(visible, id: workspaceID, delta: delta)
            layout.order = SidebarLayout.reorderVisible(order: layout.order, hidden: hidden, newVisibleIDs: moved)
        }
    }

    public func setHiddenCollapsed(_ collapsed: Bool) {
        lock.lock()
        layout.hiddenCollapsed = collapsed
        lock.unlock()
    }

    private func editLayout(_ workspaceID: String, _ edit: (inout Layout) -> Void) throws {
        try Devpod.validateId(workspaceID)
        lock.lock()
        defer { lock.unlock() }
        guard workspaces.contains(where: { $0.id == workspaceID }) else {
            throw DevpodError("workspace not found: \(workspaceID)")
        }
        edit(&layout)
    }

    /// Resolve the workspace a completed create operation introduced. This is
    /// shared lifecycle policy: frontends only decide how to present the
    /// operation log and then select the returned id, if any.
    public static func createdWorkspaceID(
        explicitID: String?,
        before: Set<String>,
        after: Set<String>
    ) -> String? {
        if let explicitID {
            return after.contains(explicitID) ? explicitID : nil
        }
        let created = after.subtracting(before)
        return created.count == 1 ? created.first : nil
    }

    /// The shell-integration helper may reconnect or alter the remote shell.
    /// Only restart it after both the helper and the original SSH PTY have
    /// demonstrably succeeded; otherwise preserve the original terminal.
    public static func terminalHandoffAction(
        integrationSucceeded: Bool,
        sshProducedOutput: Bool
    ) -> TerminalHandoffAction {
        integrationSucceeded && sshProducedOutput
            ? .restartRemoteShellThenReveal
            : .revealOriginal
    }

    private func normalizeLayout() {
        let ids = workspaces.map(\.id)
        layout.order = SidebarLayout.normalizeOrder(layout.order, ids: ids)
        layout.hidden = SidebarLayout.pruneHidden(layout.hidden, ids: ids)
    }
}
