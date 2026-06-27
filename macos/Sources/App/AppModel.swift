import SwiftUI
import DevSpaceCore

/// Top-level UI state (the Swift analog of App.tsx): sidebar layout + the
/// workspace session lifecycle (starting / running terminal / shutting down).
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workspaces: [WorkspaceView] = []
    @Published var selectedID: String?
    @Published private(set) var badges: Set<String> = []
    @Published var sidebarOpen = true
    @Published var renaming: String?
    @Published var guideOpen = false

    // Persisted sidebar layout.
    @Published private(set) var order: [String] = []
    @Published private(set) var hidden: [String] = []
    @Published private(set) var aliases: [String: String] = [:]
    @Published var hiddenCollapsed = false { didSet { persist() } }

    // Session lifecycle.
    @Published private(set) var opened: Set<String> = []       // pods with an SSH terminal
    @Published private(set) var starting: Set<String> = []     // pods running `devpod up`
    @Published private(set) var shuttingDown: Set<String> = [] // pods running `devpod stop`
    /// One PTY-backed pane per pod (devpod up log, SSH shell, or devpod stop log).
    @Published private(set) var panes: [String: TerminalPaneModel] = [:]

    private let runner: CommandRunning
    private let loop: PollLoop
    private var layoutLoaded = false

    init(runner: CommandRunning = DevpodCLI(), interval: TimeInterval = 5) {
        self.runner = runner
        loop = PollLoop(runner: runner, interval: interval)
        let l = LayoutStore.load()
        order = l.order
        hidden = l.hidden
        aliases = l.aliases
        hiddenCollapsed = l.hiddenCollapsed
        layoutLoaded = true
        loop.start { [weak self] views in
            DispatchQueue.main.async { self?.apply(views) }
        }
    }

    // MARK: - Poll updates

    private func apply(_ views: [WorkspaceView]) {
        workspaces = views
        let ids = views.map(\.id)
        let newOrder = SidebarLayout.normalizeOrder(order, ids: ids)
        let newHidden = SidebarLayout.pruneHidden(hidden, ids: ids)
        var changed = false
        if newOrder != order { order = newOrder; changed = true }
        if newHidden != hidden { hidden = newHidden; changed = true }
        if changed { persist() }
        reconcileLifecycle()
    }

    /// Mirror of the App.tsx lifecycle effects: auto-open running pods, drop
    /// terminals for stopped/gone pods, clear shutting-down once confirmed.
    private func reconcileLifecycle() {
        let states = byID
        // Auto-connect any running workspace (not mid start/stop).
        for w in workspaces where w.state == "Running" {
            openSSHIfNeeded(w.id)
        }
        // Drop terminals once a pod is explicitly Stopped or gone (not on a
        // transient Unknown/Loading blip).
        for id in opened {
            let s = states[id]?.state
            if s == "Stopped" || states[id] == nil { closePane(id); opened.remove(id) }
        }
        for id in shuttingDown {
            if states[id]?.state == "Stopped" { closePane(id); shuttingDown.remove(id) }
        }
    }

    // MARK: - Derived

    var byID: [String: WorkspaceView] {
        Dictionary(workspaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var split: (visible: [WorkspaceView], hidden: [WorkspaceView]) {
        SidebarLayout.split(
            displayIDs: SidebarLayout.displayIDs(order: order, workspaces: workspaces),
            hidden: Set(hidden),
            byID: byID
        )
    }

    func name(_ id: String) -> String { aliases[id] ?? id }

    // MARK: - Sidebar actions

    func select(_ id: String) {
        selectedID = id
        badges.remove(id)
    }

    func hide(_ id: String) {
        guard !hidden.contains(id) else { return }
        hidden.append(id); persist()
    }

    func unhide(_ id: String) { hidden.removeAll { $0 == id }; persist() }
    func beginRename(_ id: String) { renaming = id }

    func setAlias(_ id: String, _ name: String) {
        aliases = SidebarLayout.setAlias(aliases, id: id, name: name.trimmingCharacters(in: .whitespaces))
        persist()
    }

    func toggleHiddenCollapsed() { hiddenCollapsed.toggle() }

    func applyVisibleOrder(_ ids: [String]) {
        order = SidebarLayout.reorderVisible(order: order, hidden: Set(hidden), newVisibleIDs: ids)
        persist()
    }

    // MARK: - Session lifecycle actions

    /// Defense-in-depth: reject ids that could smuggle CLI flags into an exec
    /// before they reach argv (ids originate from `devpod list`). Mirrors the
    /// validate_id guard the Rust command handlers apply.
    private func validID(_ id: String) -> Bool {
        if (try? Devpod.validateId(id)) != nil { return true }
        Log.write("rejected invalid workspace id: \(id)")
        return false
    }

    func start(_ id: String) {
        guard validID(id) else { return }
        select(id)
        starting.insert(id)
        let pane = TerminalPaneModel(command: "devpod", args: Devpod.upArgs(id))
        pane.onExit = { [weak self] _ in self?.onUpFinished(id) }
        panes[id] = pane
    }

    /// `devpod up` finished: leave the starting state and optimistically mark the
    /// pod Running so the SSH terminal mounts; the next poll confirms.
    private func onUpFinished(_ id: String) {
        starting.remove(id)
        closePane(id)
        if let i = workspaces.firstIndex(where: { $0.id == id }) {
            let w = workspaces[i]
            workspaces[i] = WorkspaceView(
                id: w.id, provider: w.provider, source: w.source,
                lastUsed: w.lastUsed, state: "Running", error: nil
            )
        }
        openSSHIfNeeded(id)
    }

    func stop(_ id: String) {
        guard validID(id) else { return }
        opened.remove(id)
        closePane(id)
        shuttingDown.insert(id)
        let pane = TerminalPaneModel(command: "devpod", args: Devpod.stopArgs(id))
        panes[id] = pane
    }

    func delete(_ id: String) {
        guard validID(id) else { return }
        let r = runner
        DispatchQueue.global(qos: .userInitiated).async { try? Devpod.delete(r, id: id) }
    }

    func openInZed(_ id: String) {
        guard validID(id) else { return }
        let r = runner
        DispatchQueue.global(qos: .userInitiated).async {
            guard (try? Devpod.validateIde("zed")) != nil else { return }
            _ = try? r.run(Devpod.ideArgs(id, ide: "zed"))
        }
    }

    /// Reconnect the SSH shell without restarting the pod.
    func reload(_ id: String) {
        guard validID(id) else { return }
        closePane(id)
        opened.remove(id)
        openSSHIfNeeded(id)
    }

    private func openSSHIfNeeded(_ id: String) {
        guard validID(id) else { return }
        guard !opened.contains(id), !starting.contains(id), !shuttingDown.contains(id) else { return }
        opened.insert(id)
        let pane = TerminalPaneModel(command: "ssh", args: SSH.args(podID: id))
        pane.onExit = { [weak self] _ in self?.onExited(id) }
        panes[id] = pane
        // Stack 7: inject Claude hooks over the tunnel here (best-effort).
    }

    /// SSH session ended (user typed `exit`): stop the pod, show the shutdown log.
    private func onExited(_ id: String) {
        opened.remove(id)
        closePane(id)
        select(id)
        stop(id)
    }

    private func closePane(_ id: String) {
        panes[id]?.terminate()
        panes[id] = nil
    }

    // MARK: - Phase (drives the main pane)

    enum Phase { case starting, shuttingDown, terminal, none }

    func phase(of id: String) -> Phase {
        if starting.contains(id) { return .starting }
        if shuttingDown.contains(id) { return .shuttingDown }
        if opened.contains(id), panes[id] != nil { return .terminal }
        return .none
    }

    private func persist() {
        guard layoutLoaded else { return }
        LayoutStore.save(Layout(
            order: order, hidden: hidden, aliases: aliases, hiddenCollapsed: hiddenCollapsed
        ))
    }
}
