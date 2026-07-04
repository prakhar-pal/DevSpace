import SwiftUI
import AppKit
import DevSpaceCore

/// Top-level UI state (the Swift analog of App.tsx): sidebar layout + the
/// workspace session lifecycle (starting / running terminal / shutting down).
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workspaces: [WorkspaceView] = []
    @Published var selectedID: String? { didSet { updateExcluded() } }
    @Published private(set) var badges: Set<String> = []
    @Published var sidebarOpen = true
    @Published var renaming: String?
    @Published var guideOpen = false

    // Persisted sidebar layout.
    @Published private(set) var order: [String] = []
    @Published private(set) var hidden: [String] = [] { didSet { updateExcluded() } }
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
    private let excluded = ExcludedIDs()
    private let notifyToken: String
    private var listener: NotifyListener?
    private var layoutLoaded = false

    init(runner: CommandRunning = DevpodCLI(), interval: TimeInterval = 5) {
        self.runner = runner
        notifyToken = (try? Notify.loadOrCreateToken()) ?? ""
        loop = PollLoop(runner: runner, interval: interval, excluded: excluded)
        let l = LayoutStore.load()
        order = l.order
        hidden = l.hidden
        aliases = l.aliases
        // Always start with the Hidden section collapsed.
        hiddenCollapsed = true
        layoutLoaded = true
        updateExcluded() // didSet doesn't fire for init assignments
        loop.start { [weak self] views in
            DispatchQueue.main.async { self?.apply(views) }
        }
        startNotifyListener()
        Notifier.requestPermission()
    }

    /// Skip status polling for hidden workspaces — but never the selected one,
    /// so selecting a hidden workspace still resolves its live state.
    private func updateExcluded() {
        var ex = Set(hidden)
        if let sel = selectedID { ex.remove(sel) }
        excluded.set(ex)
    }

    // MARK: - Notifications

    private func startNotifyListener() {
        guard !notifyToken.isEmpty else {
            Log.write("notify: no token — listener disabled")
            return
        }
        let l = NotifyListener(expectedToken: notifyToken) { [weak self] podID, message in
            DispatchQueue.main.async { self?.receiveNotification(podID: podID, message: message) }
        }
        do {
            try l.start()
            listener = l
            Log.write("notify: listening on \(SSH.listenerPort)")
        } catch {
            Log.write("notify: listener bind failed: \(error)")
        }
    }

    /// A pod posted a Claude Code notification: badge it (unless selected) and
    /// show a banner / bounce the dock.
    func receiveNotification(podID: String, message: String) {
        if podID != selectedID { badges.insert(podID) }
        Notifier.notify(title: name(podID), body: message)
    }

    /// Inject the Claude hooks over the tunnel after an SSH connect — off the
    /// open path (it makes ssh round-trips) and best-effort.
    private func injectHooks(_ id: String) {
        guard !notifyToken.isEmpty else { return }
        let r = runner
        let token = notifyToken
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            do {
                try Hooks.inject(r, podID: id, token: token)
                Log.write("inject: hook written to pod=\(id)")
            } catch {
                Log.write("inject: FAILED pod=\(id): \(error)")
            }
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

    /// Window title: "N · name" for the selected workspace, where N is its
    /// 1-based position in the visible sidebar list (the same number ⌘N jumps
    /// to). Hidden-but-selected workspaces have no sequence number, so they
    /// show just the name; no selection falls back to the app name.
    var windowTitle: String {
        guard let id = selectedID else { return "DevSpace" }
        if let i = split.visible.firstIndex(where: { $0.id == id }) {
            return "\(i + 1) · \(name(id))"
        }
        return name(id)
    }

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
        injectHooks(id)
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

    // MARK: - Keyboard shortcuts

    private var keyMonitor: Any?

    /// Cmd+1..9 selects the Nth visible workspace; Cmd+B toggles the sidebar.
    /// A local monitor (capture-phase analog) consumes the event so a focused
    /// terminal doesn't also receive it; suppressed while a modal is open.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags == [.command] else { return event }
        guard let chars = event.charactersIgnoringModifiers else { return event }

        // Standard window/app shortcuts the libghostty surface otherwise swallows
        // (Ghostty binds these to its own actions, which are no-ops when embedded).
        switch chars {
        case "q": NSApp.terminate(nil); return nil
        case "m": NSApp.keyWindow?.performMiniaturize(nil); return nil
        case "h": NSApp.hide(nil); return nil
        case "w": NSApp.keyWindow?.performClose(nil); return nil
        default: break
        }

        guard renaming == nil, !guideOpen else { return event } // modal owns the keyboard

        if chars == "b" {
            sidebarOpen.toggle()
            return nil
        }
        // Cmd+R: reconnect the selected workspace's SSH shell (same action as
        // the context menu's "Reload SSH Session") — only meaningful when a
        // session is actually open.
        if chars == "r" {
            if let id = selectedID, phase(of: id) == .terminal {
                reload(id)
            }
            return nil // consume even when a no-op so the terminal never sees ⌘R
        }
        if let n = Int(chars), (1 ... 9).contains(n) {
            let visible = split.visible
            if n - 1 < visible.count {
                select(visible[n - 1].id)
                return nil
            }
        }
        return event
    }
}
