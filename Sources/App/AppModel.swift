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
    /// PTY-backed panes per pod (a devpod up/stop log, or one or more SSH
    /// terminals). Terminals are tabs: index 0 is the primary session (it
    /// carries the reverse notify tunnel); further ones are extra shells.
    @Published private(set) var panes: [String: [TerminalPaneModel]] = [:]
    /// Which of a pod's panes is the visible/active tab.
    @Published private(set) var activePane: [String: UUID] = [:]

    private let runner: CommandRunning
    private let loop: PollLoop
    private let excluded = ExcludedIDs()
    private let notifyToken: String
    private var listener: NotifyListener?
    private var layoutLoaded = false
    /// Start/stop notification gate: "stopped" fires on the observed
    /// transition; "started" waits until this app has SSH'd into the workspace.
    private var notifyGate = StateNotifyGate()

    // 10s status polling: halves the devpod/kubectl load of 5s while keeping
    // state changes (with the poller's 2-fetch revival debounce) under ~20s.
    init(runner: CommandRunning = DevpodCLI(), interval: TimeInterval = 10) {
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
        // Clicking a notification switches to the workspace it came from;
        // foreground banners are suppressed for the pod already on screen.
        Notifier.install(
            onTap: { [weak self] podID in
                guard let self, byID[podID] != nil else { return }
                select(podID)
            },
            shouldPresent: { [weak self] podID in
                guard let self, let podID else { return true }
                return !(podID == selectedID && NSApp.isActive)
            }
        )
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
        Notifier.notify(title: name(podID), body: message, podID: podID)
    }

    /// Inject the Claude hooks over the tunnel after an SSH connect — off the
    /// open path (it makes ssh round-trips) and best-effort. Each injection is
    /// itself a `devpod ssh` into the workspace, so a success doubles as the
    /// proof-of-connectivity that releases the deferred "started" notification.
    private func injectHooks(_ id: String) {
        let r = runner
        let token = notifyToken
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            var sshOK = false
            if token.isEmpty {
                Log.write("inject: no token — skipping hook injection for pod=\(id)")
            } else {
                do {
                    try Hooks.inject(r, podID: id, token: token)
                    sshOK = true
                    Log.write("inject: hook written to pod=\(id)")
                } catch {
                    Log.write("inject: FAILED pod=\(id): \(error)")
                }
            }
            do {
                try ShellIntegration.inject(r, podID: id)
                sshOK = true
                Log.write("inject: shell integration (OSC 7) written to pod=\(id)")
            } catch {
                Log.write("inject: shell integration FAILED pod=\(id): \(error)")
            }
            if sshOK {
                DispatchQueue.main.async { self?.sshConfirmed(id) }
            }
        }
    }

    /// We reached the pod's workspace over SSH — fire a pending "started"
    /// notification, if the poller's transition is still waiting on it.
    private func sshConfirmed(_ id: String) {
        if notifyGate.confirmSSH(id) { emitStateEvent(id, "started") }
    }

    // MARK: - Poll updates

    private func apply(_ views: [WorkspaceView]) {
        notifyStateTransitions(views)
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

    /// Notify on definitive devpod state transitions (Stopped→Running and
    /// Running→Stopped) observed by the poller. The gate defers "started"
    /// until this app has SSH'd into the workspace (see sshConfirmed(_:));
    /// the event is suppressed when the pod is selected while the app is
    /// active — you're already looking at it (covers self-initiated actions,
    /// whose start/stop logs are on screen).
    private func notifyStateTransitions(_ views: [WorkspaceView]) {
        for (id, event) in notifyGate.observe(views) {
            emitStateEvent(id, event)
        }
    }

    private func emitStateEvent(_ id: String, _ event: String) {
        if id == selectedID, NSApp.isActive { return }
        if id != selectedID { badges.insert(id) }
        Notifier.notify(title: name(id), body: "Workspace \(event)", podID: id)
        Log.write("notify: pod=\(id) \(event)")
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
        // A hidden pod resumes status polling when selected; its cached state
        // is stale, so re-baseline silently instead of firing a catch-up
        // start/stop notification for a long-past transition.
        if hidden.contains(id) { notifyGate.reset(id) }
        selectedID = id
        badges.remove(id)
    }

    func hide(_ id: String) {
        guard !hidden.contains(id) else { return }
        hidden.append(id); persist()
    }

    func unhide(_ id: String) {
        notifyGate.reset(id) // resumes polling — re-baseline silently
        hidden.removeAll { $0 == id }
        persist()
    }
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

    /// Move a visible workspace one step up (-1) or down (+1) in the sidebar.
    /// The explicit counterpart to List drag-reorder, which is unreliable on
    /// macOS with rows this interactive (the selection tap claims mouse-downs).
    func move(_ id: String, by delta: Int) {
        let ids = split.visible.map(\.id)
        let moved = SidebarLayout.moveVisible(ids, id: id, delta: delta)
        guard moved != ids else { return }
        applyVisibleOrder(moved)
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
        setPanes(id, [pane])
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
        setPanes(id, [pane])
    }

    func delete(_ id: String) {
        guard validID(id) else { return }
        let r = runner
        DispatchQueue.global(qos: .userInitiated).async { try? Devpod.delete(r, id: id) }
    }

    /// Open the workspace folder in Zed over the existing SSH alias
    /// (`zed ssh://<id>.devpod/<workdir>`) — effectively instant, unlike the
    /// old `devpod up --ide zed`, which re-runs the whole up/provision flow.
    /// The workdir comes from the alias' ProxyCommand in ~/.ssh/config; the
    /// legacy devpod path remains only as a fallback when the `zed` CLI is
    /// not installed. Only offered for Running workspaces (Sidebar gates it).
    func openInZed(_ id: String) {
        guard validID(id) else { return }
        let r = runner
        DispatchQueue.global(qos: .userInitiated).async {
            // Always hand Zed the pod's URL: the CLI focuses the existing
            // window when the project is already open (verified live — no
            // duplicate workspace is created). App-level activation, the old
            // dedupe, raised Zed's LAST-FOCUSED window, which could be a
            // different pod's project (⌘O appeared to open the wrong
            // workspace). The session check now only guards the fallbacks:
            // re-running the devpod provision flow while a session exists is
            // what duplicates windows.
            let sessionActive = SSH.zedSessionActive(psOutput: Self.processTable(), podID: id)
            let url = SSH.zedRemoteURL(podID: id, workdir: SSH.workdir(podID: id))
            guard let cli = Self.zedCLI() else {
                if sessionActive {
                    Log.write("zed: cli not found; session for \(id) already open — activating Zed")
                    Self.activateZed()
                } else {
                    Log.write("zed: cli not found — falling back to devpod")
                    Self.openViaDevpod(id, runner: r)
                }
                return
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cli)
            proc.arguments = [url]
            // Observe the exit asynchronously — a hung zed process must not
            // pin a shared global-QoS worker the way a blocking wait would.
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    Log.write("zed: opened \(url) via \(cli)")
                } else if sessionActive {
                    Log.write("zed: \(cli) exit \(p.terminationStatus) for \(url); session open — activating instead of devpod fallback")
                    Self.activateZed()
                } else {
                    Log.write("zed: \(cli) exit \(p.terminationStatus) for \(url) — falling back to devpod")
                    Self.openViaDevpod(id, runner: r)
                }
            }
            do {
                try proc.run()
            } catch {
                if sessionActive {
                    Log.write("zed: \(cli) not runnable (\(error)); session open — activating instead of devpod fallback")
                    Self.activateZed()
                } else {
                    Log.write("zed: \(cli) not runnable (\(error)) — falling back to devpod")
                    Self.openViaDevpod(id, runner: r)
                }
            }
        }
    }

    /// The current process table (`ps axww -o command=`), for detecting an
    /// existing Zed remote session. Empty string on failure (treated as "no
    /// session" — worst case we open the duplicate we would have opened anyway).
    private nonisolated static func processTable() -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["axww", "-o", "command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        do {
            try proc.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Bring Zed to the front (the pod's project window is already open).
    private nonisolated static func activateZed() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.zed.Zed") else {
            Log.write("zed: app bundle not found — cannot activate")
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Legacy fallback: `devpod up --ide zed` (slow — re-runs the up flow).
    private nonisolated static func openViaDevpod(_ id: String, runner: CommandRunning) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard (try? Devpod.validateIde("zed")) != nil else { return }
            _ = try? runner.run(Devpod.ideArgs(id, ide: "zed"))
        }
    }

    /// The zed CLI binary. "Install CLI" symlinks it into a bin dir, but plenty
    /// of setups only have the app bundle (whose embedded `cli` is the same
    /// binary) or a shell alias we can't exec — so check known locations
    /// directly instead of trusting PATH.
    private nonisolated static func zedCLI() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/zed",
            "/usr/local/bin/zed",
            "/opt/homebrew/bin/zed",
            "/Applications/Zed.app/Contents/MacOS/cli",
            "\(home)/Applications/Zed.app/Contents/MacOS/cli",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Reconnect the active SSH terminal without restarting the pod (or the
    /// other terminals). Replaced in place so the tab keeps its position; the
    /// primary tab keeps the reverse notify tunnel.
    func reload(_ id: String) {
        guard validID(id) else { return }
        guard opened.contains(id), let list = panes[id], !list.isEmpty else {
            // No session (e.g. it already died): fall back to a full reopen.
            closePane(id)
            opened.remove(id)
            openSSHIfNeeded(id)
            return
        }
        let idx = list.firstIndex { $0.id == activePane[id] } ?? 0
        let old = list[idx]
        old.onExit = nil // its exit must not run the tab-close/stop-pod path
        old.terminate()
        let fresh = makeTerminal(id, tunnel: idx == 0)
        panes[id]?[idx] = fresh
        activePane[id] = fresh.id
    }

    private func openSSHIfNeeded(_ id: String) {
        guard validID(id) else { return }
        guard !opened.contains(id), !starting.contains(id), !shuttingDown.contains(id) else { return }
        opened.insert(id)
        setPanes(id, [makeTerminal(id, tunnel: true)])
        injectHooks(id)
    }

    // MARK: - Terminal tabs

    /// Open another shell to the same pod, as a new active tab.
    func newTerminal(_ id: String) {
        guard validID(id), opened.contains(id), !(panes[id] ?? []).isEmpty else { return }
        let pane = makeTerminal(id, tunnel: false) // the primary carries the tunnel
        panes[id]?.append(pane)
        activePane[id] = pane.id
    }

    /// Close one terminal tab (never the last — exit the shell to stop the pod).
    func closeTerminal(_ id: String, paneID: UUID) {
        guard let list = panes[id], list.count > 1,
              let pane = list.first(where: { $0.id == paneID }) else { return }
        pane.onExit = nil
        pane.terminate()
        removePane(id, paneID: paneID)
    }

    func setActivePane(_ id: String, paneID: UUID) {
        guard panes[id]?.contains(where: { $0.id == paneID }) == true else { return }
        activePane[id] = paneID
    }

    /// Switch to the next (+1) or previous (-1) terminal tab, wrapping around.
    func cycleTab(_ id: String, by delta: Int) {
        guard let list = panes[id], list.count > 1 else { return }
        let idx = list.firstIndex { $0.id == activePane[id] } ?? 0
        activePane[id] = list[(idx + delta + list.count) % list.count].id
    }

    /// The pane the pod's view should show (its active tab).
    func activeModel(_ id: String) -> TerminalPaneModel? {
        guard let list = panes[id], !list.isEmpty else { return nil }
        return list.first { $0.id == activePane[id] } ?? list[0]
    }

    private func makeTerminal(_ id: String, tunnel: Bool) -> TerminalPaneModel {
        let pane = TerminalPaneModel(command: "ssh", args: SSH.args(podID: id, tunnel: tunnel))
        pane.onExit = { [weak self] _ in self?.paneExited(id, paneID: pane.id) }
        return pane
    }

    /// An SSH terminal ended (user typed `exit`, or the connection died).
    /// Extra tabs just close; the LAST terminal keeps the original semantics:
    /// stop the pod and show the shutdown log.
    private func paneExited(_ id: String, paneID: UUID) {
        guard let list = panes[id], list.contains(where: { $0.id == paneID }) else { return }
        if list.count > 1 {
            removePane(id, paneID: paneID)
        } else {
            opened.remove(id)
            closePane(id)
            select(id)
            stop(id)
        }
    }

    private func removePane(_ id: String, paneID: UUID) {
        guard var list = panes[id], let idx = list.firstIndex(where: { $0.id == paneID }) else { return }
        list.remove(at: idx)
        panes[id] = list
        if activePane[id] == paneID, !list.isEmpty {
            activePane[id] = list[max(0, idx - 1)].id
        }
    }

    private func setPanes(_ id: String, _ list: [TerminalPaneModel]) {
        panes[id] = list
        activePane[id] = list.first?.id
    }

    private func closePane(_ id: String) {
        for pane in panes[id] ?? [] {
            pane.onExit = nil
            pane.terminate()
        }
        panes[id] = nil
        activePane[id] = nil
    }

    // MARK: - Phase (drives the main pane)

    enum Phase { case starting, shuttingDown, terminal, none }

    func phase(of id: String) -> Phase {
        if starting.contains(id) { return .starting }
        if shuttingDown.contains(id) { return .shuttingDown }
        if opened.contains(id), !(panes[id] ?? []).isEmpty { return .terminal }
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
        guard let chars = event.charactersIgnoringModifiers else { return event }

        // ⌘⌥↑ / ⌘⌥↓ — move the selected workspace up/down in the sidebar.
        if flags == [.command, .option], renaming == nil, !guideOpen {
            let up = Character(UnicodeScalar(NSUpArrowFunctionKey)!)
            let down = Character(UnicodeScalar(NSDownArrowFunctionKey)!)
            if let c = chars.first, c == up || c == down {
                if let id = selectedID { move(id, by: c == up ? -1 : 1) }
                return nil
            }
            return event
        }

        // ⌘⇧[ / ⌘⇧] — previous / next terminal tab (macOS tab convention).
        // charactersIgnoringModifiers ignores every modifier EXCEPT Shift, so
        // with ⌘⇧ held it yields "{"/"}"; derive the true unshifted key the
        // way libghostty does (characters(byApplyingModifiers: [])).
        if flags == [.command, .shift], renaming == nil, !guideOpen {
            let unshifted = event.characters(byApplyingModifiers: []) ?? chars
            if unshifted == "[" || unshifted == "]" {
                if let id = selectedID, phase(of: id) == .terminal {
                    cycleTab(id, by: unshifted == "]" ? 1 : -1)
                }
                return nil
            }
            return event
        }

        guard flags == [.command] else { return event }

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
        // Cmd+O: open the selected workspace's folder in Zed (same action as
        // the context menu's "Open in Zed"; Running pods only, like the menu).
        if chars == "o" {
            if let id = selectedID, byID[id]?.state == "Running" {
                openInZed(id)
            }
            return nil
        }
        // Cmd+T: open another terminal tab for the selected workspace.
        if chars == "t" {
            if let id = selectedID, phase(of: id) == .terminal {
                newTerminal(id)
            }
            return nil
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
