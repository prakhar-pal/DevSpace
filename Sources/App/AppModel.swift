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
    @Published private var terminalHandoffs: [String: TerminalHandoffState] = [:]
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
    private let handoffTimeout: TimeInterval
#if DEBUG
    private let installManualNotifyHelper = true
#else
    private let installManualNotifyHelper = false
#endif
    private var listener: NotifyListener?
    private var layoutLoaded = false
    /// Start/stop notification gate: "stopped" fires on the observed
    /// transition; "started" waits until this app has SSH'd into the workspace
    /// (or, for pods we don't connect to, until reconcile releases it).
    private var notifyGate = StateNotifyGate()
    /// Pods this app intends to keep a session with: Running at first
    /// sighting, or user started/connected/reloaded. Withdrawn when the pod
    /// stops or the user closes its last shell — reconcile never opens a
    /// session outside this set (`devpod ssh` would wake a stopped pod).
    private var autoConnect: Set<String> = []
    /// Pods whose definitive (Running/Stopped) state has been seen at least
    /// once — first Running sighting seeds `autoConnect`.
    private var seenDefinitive: Set<String> = []

    enum TerminalHandoffAction: Equatable {
        case revealOriginal
        case restartRemoteShellThenReveal
    }

    enum TerminalHandoffEvent: Equatable {
        case firstOutput(paneID: UUID)
        case integrationFinished(paneID: UUID, succeeded: Bool, sshProducedOutputAtIngress: Bool)
        case timedOut(paneID: UUID)
    }

    struct TerminalHandoffState: Equatable {
        let paneID: UUID
        private var sshProducedOutput = false
        private var isPending = true

        init(paneID: UUID) {
            self.paneID = paneID
        }

        mutating func handle(_ event: TerminalHandoffEvent) -> TerminalHandoffAction? {
            guard isPending else { return nil }
            switch event {
            case .firstOutput(let eventPaneID):
                guard eventPaneID == paneID else { return nil }
                sshProducedOutput = true
                return nil
            case .integrationFinished(let eventPaneID, let succeeded, let sshProducedOutputAtIngress):
                guard eventPaneID == paneID else { return nil }
                isPending = false
                return AppModel.terminalHandoffAction(
                    integrationSucceeded: succeeded,
                    sshProducedOutput: sshProducedOutput || sshProducedOutputAtIngress
                )
            case .timedOut(let eventPaneID):
                guard eventPaneID == paneID else { return nil }
                isPending = false
                return .revealOriginal
            }
        }

        mutating func cancel() {
            isPending = false
        }
    }

    nonisolated static func terminalHandoffAction(
        integrationSucceeded: Bool,
        sshProducedOutput: Bool
    ) -> TerminalHandoffAction {
        integrationSucceeded && sshProducedOutput
            ? .restartRemoteShellThenReveal
            : .revealOriginal
    }

    nonisolated static func shouldConfirmSSH(forShellIntegrationSuccess succeeded: Bool) -> Bool {
        succeeded
    }

    static func startTerminalHandoff(
        mountPrimary: () -> Void,
        beginShellIntegration: () -> Void,
        scheduleTimeout: (TimeInterval) -> Void,
        timeout: TimeInterval = 10
    ) {
        mountPrimary()
        beginShellIntegration()
        scheduleTimeout(timeout)
    }

    nonisolated static func elapsedMilliseconds(startedAt: UInt64, now: UInt64) -> UInt64 {
        guard now >= startedAt else { return 0 }
        return (now - startedAt) / 1_000_000
    }

    static func isTerminalReady(hooksFinished: Bool, shellIntegrationFinished: Bool) -> Bool {
        shellIntegrationFinished
    }

    private nonisolated static func logConnection(_ id: String, phase: String, startedAt: UInt64) {
        let elapsed = elapsedMilliseconds(
            startedAt: startedAt,
            now: DispatchTime.now().uptimeNanoseconds
        )
        Log.write("connect pod=\(id) phase=\(phase) elapsed_ms=\(elapsed)")
    }

    // 10s status polling: halves the devpod/kubectl load of 5s while keeping
    // state changes (with the poller's 2-fetch revival debounce) under ~20s.
    init(
        runner: CommandRunning = DevpodCLI(),
        interval: TimeInterval = 10,
        initialWorkspaces: [WorkspaceView] = [],
        startsRuntimeServices: Bool = true,
        handoffTimeout: TimeInterval = 10
    ) {
        self.runner = runner
        self.handoffTimeout = max(0, handoffTimeout)
        notifyToken = startsRuntimeServices ? (try? Notify.loadOrCreateToken()) ?? "" : ""
        loop = PollLoop(runner: runner, interval: interval, excluded: excluded)
        let l = LayoutStore.load()
        order = l.order
        hidden = l.hidden
        aliases = l.aliases
        // Always start with the Hidden section collapsed.
        hiddenCollapsed = true
        layoutLoaded = true
        workspaces = initialWorkspaces
        updateExcluded() // didSet doesn't fire for init assignments
        guard startsRuntimeServices else { return }
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

    /// Inject the Claude hooks after a connect. This is best-effort and must
    /// not delay terminal creation: the user can open a shell while it runs.
    private func injectClaudeHooks(
        _ id: String,
        startedAt: UInt64,
        then completion: @escaping () -> Void = {}
    ) {
        let r = runner
        let token = notifyToken
        let installManualHelper = installManualNotifyHelper
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            var sshOK = false
            Self.logConnection(id, phase: "hook-started", startedAt: startedAt)
            if token.isEmpty {
                Log.write("inject: no token — skipping hook injection for pod=\(id)")
            } else {
                do {
                    try Hooks.inject(
                        r,
                        podID: id,
                        token: token,
                        installManualHelper: installManualHelper
                    )
                    sshOK = true
                    Log.write("inject: hook written to pod=\(id)")
                } catch {
                    Log.write("inject: FAILED pod=\(id): \(error)")
                }
            }
            Self.logConnection(id, phase: "hooks-finished", startedAt: startedAt)
            DispatchQueue.main.async {
                if sshOK { self?.sshConfirmed(id) }
                completion()
            }
        }
    }

    /// Install OSC 7 shell integration concurrently with the initial terminal.
    /// Completion is best-effort; a separate fail-open deadline ensures this
    /// background CLI call can never keep a usable terminal hidden.
    private func injectShellIntegration(
        _ id: String,
        startedAt: UInt64,
        then completion: @escaping (Bool) -> Void = { _ in }
    ) {
        let r = runner
        DispatchQueue.global(qos: .utility).async {
            var sshOK = false
            do {
                try ShellIntegration.inject(r, podID: id)
                sshOK = true
                Log.write("inject: shell integration (OSC 7) written to pod=\(id)")
            } catch {
                Log.write("inject: shell integration FAILED pod=\(id): \(error)")
            }
            Self.logConnection(id, phase: "shell-integration-finished", startedAt: startedAt)
            DispatchQueue.main.async {
                completion(sshOK)
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

    /// Lifecycle reconciliation: keep sessions for intended pods, drop
    /// terminals for stopped/gone pods, clear shutting-down once confirmed.
    ///
    /// Sessions are opened only for pods in `autoConnect` — pods this app has
    /// a standing reason to be connected to (Running at first sighting, or
    /// user started/connected/reloaded). `devpod ssh` WAKES a stopped
    /// workspace, so connecting on any unsolicited Running report resurrects
    /// pods that stopped externally (e.g. a server-side resource optimizer)
    /// whenever a stale Running report slips through. Externally started pods
    /// get the "started" notification (released below) and a Connect card
    /// instead of an automatic session.
    private func reconcileLifecycle() {
        let states = byID
        // First DEFINITIVE sighting of a pod (launch, or created mid-session):
        // if it's Running, a session is expected — that's the app's core UX.
        for w in workspaces where w.state == "Running" || w.state == "Stopped" {
            if seenDefinitive.insert(w.id).inserted, w.state == "Running" {
                autoConnect.insert(w.id)
            }
        }
        for w in workspaces where w.state == "Running" {
            if autoConnect.contains(w.id) { openSSHIfNeeded(w.id) }
        }
        // Drop terminals once a pod is explicitly Stopped or gone (not on a
        // transient Unknown/Loading blip) — and withdraw the standing intent:
        // whoever starts it next (user via Start/Connect, or someone external)
        // decides whether a session opens.
        for w in workspaces where w.state == "Stopped" {
            if !starting.contains(w.id) { autoConnect.remove(w.id) }
        }
        for id in opened {
            let s = states[id]?.state
            if s == "Stopped" || states[id] == nil { closePane(id); opened.remove(id) }
        }
        for id in shuttingDown {
            if states[id]?.state == "Stopped" { closePane(id); shuttingDown.remove(id) }
        }
        // Externally started pods (pending "started", no session planned) get
        // their notification now — with no SSH there is no later confirm, and
        // the RunningDebouncer already vouched for the transition.
        for id in notifyGate.releasePending(notIn: opened.union(starting)) {
            emitStateEvent(id, "started")
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

    /// The bundle's display name — "DevSpaceDev" for dev builds, "DevSpace"
    /// for release (set per-config by scripts/assemble-app.sh). Hardcoding
    /// "DevSpace" here would mislabel the dev build's title bar.
    private static let appDisplayName =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "DevSpace"

    /// Window title: "N · name" for the selected workspace, where N is its
    /// 1-based position in the visible sidebar list (the same number ⌘N jumps
    /// to). Hidden-but-selected workspaces have no sequence number, so they
    /// show just the name; no selection falls back to the app name.
    var windowTitle: String {
        guard let id = selectedID else { return Self.appDisplayName }
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
        autoConnect.insert(id) // user-initiated start: a session is wanted
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
        cancelShellIntegrationHandoff(id)
        opened.remove(id)
        autoConnect.remove(id)
        closePane(id)
        shuttingDown.insert(id)
        let pane = TerminalPaneModel(command: "devpod", args: Devpod.stopArgs(id))
        setPanes(id, [pane])
    }

    func delete(_ id: String) {
        guard validID(id) else { return }
        cancelShellIntegrationHandoff(id)
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
        let currentDirectory = activeModel(id)?.state.workingDirectory
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
            let workdir = SSH.zedWorkdir(
                currentDirectory: currentDirectory,
                fallback: SSH.workdir(podID: id)
            )
            let url = SSH.zedRemoteURL(podID: id, workdir: workdir)
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

    private static let pastedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "tif",
    ]

    /// Extracts a pasted image (raw bytes + its file extension), if the
    /// pasteboard holds one.
    ///
    /// Order matters: copying a FILE in Finder (⌘C) puts both its file URL
    /// AND a synthesized ICON in the `.tiff`/`.png` representations (for
    /// drag visual feedback) — for a document that's the generic macOS
    /// document icon at 1024×1024, not the file's actual pixel content.
    /// Reading `.tiff`/`.png` directly in that case sends the icon instead
    /// of the real image (observed live: a copied screenshot FILE arrived
    /// remotely as a 1024×1024 "PNG file" icon). So a backing file URL is
    /// read from disk first, preserving its real bytes/extension; the
    /// `.tiff`/`.png` pasteboard data is only used as a fallback for a
    /// genuine raw-image clipboard entry with no backing file (e.g. a
    /// screenshot captured straight to the clipboard via ⌘⇧⌃4, or an image
    /// copied from a browser/viewer).
    private static func pastedImage() -> (data: Data, ext: String)? {
        let pb = NSPasteboard.general
        let fileURLs = ((pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? [])
            .filter(\.isFileURL)
        if !fileURLs.isEmpty {
            // A file-backed pasteboard entry that isn't a recognized image
            // (e.g. copying a text file or folder) has nothing to paste —
            // falling back to the icon data here would be the same bug.
            guard let url = fileURLs.first(where: { pastedImageExtensions.contains($0.pathExtension.lowercased()) }),
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return (data, url.pathExtension.lowercased())
        }
        if let png = pb.data(forType: .png) { return (png, "png") }
        guard let tiff = pb.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return (png, "png")
    }

    /// libghostty's own Cmd+V paste (`AppTerminalView.paste(_:)`) reads only
    /// `.string` from the general pasteboard and is a documented no-op when
    /// that's absent (the exact mechanism this whole feature works around
    /// for image-only content). Returning `nil` from the key monitor above
    /// is supposed to suppress that competing Edit-menu-bound action, but
    /// empirically it doesn't reliably: a copied file's plain-text display
    /// name has been observed landing in the terminal ALONGSIDE our own
    /// injected path, from a single ⌘V. Rather than depend on AppKit's
    /// event-dispatch internals, make that competing read harmless: the
    /// pasteboard is snapshotted, cleared, then restored exactly as the
    /// user left it shortly after — long enough for any same-cycle
    /// competing paste to find nothing, brief enough the user never
    /// notices their clipboard changed.
    private static func suppressCompetingPaste() {
        let pb = NSPasteboard.general
        guard let items = pb.pasteboardItems, !items.isEmpty else { return }
        let saved: [[NSPasteboard.PasteboardType: Data]] = items.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in
                item.data(forType: t).map { (t, $0) }
            })
        }
        pb.clearContents()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let restored = saved.map { typesToData -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in typesToData {
                    item.setData(data, forType: type)
                }
                return item
            }
            pb.clearContents()
            pb.writeObjects(restored)
        }
    }

    /// ⌘V with an image on the clipboard: write it to a local temp file
    /// (its real extension preserved — see ``pastedImage()``), scp it to
    /// the pod's /tmp, then inject a path reference Claude Code can read
    /// directly off the container's own disk — no terminal graphics
    /// protocol involved (see code.claude.com/docs/en/common-workflows,
    /// "Work with images": "Provide an image path to Claude"). Best-effort:
    /// scp failure just logs, matching hook injection's convention — no
    /// user-facing error UI for v1.
    private func pasteImage(_ image: (data: Data, ext: String), to id: String) {
        let name = "devspace-paste-\(UUID().uuidString).\(image.ext)"
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try image.data.write(to: localURL)
        } catch {
            Log.write("paste-image: failed writing temp file: \(error)")
            return
        }
        let remotePath = "/tmp/\(name)"
        let dest = SSH.scpDestination(podID: id, remotePath: remotePath)
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            proc.arguments = [
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                localURL.path, dest,
            ]
            proc.terminationHandler = { [weak self] p in
                try? FileManager.default.removeItem(at: localURL)
                guard p.terminationStatus == 0 else {
                    Log.write("paste-image: scp exit \(p.terminationStatus) for \(dest)")
                    return
                }
                Log.write("paste-image: copied to \(dest)")
                DispatchQueue.main.async {
                    self?.activeModel(id)?.injectText("Image pasted: \(remotePath) ")
                }
            }
            do {
                try proc.run()
            } catch {
                try? FileManager.default.removeItem(at: localURL)
                Log.write("paste-image: scp not runnable (\(error))")
            }
        }
    }

    /// Reconnect the active SSH terminal without restarting the pod (or the
    /// other terminals). Replaced in place so the tab keeps its position; the
    /// primary tab keeps the reverse notify tunnel.
    func reload(_ id: String) {
        guard validID(id) else { return }
        guard isTerminalVisible(id) else { return }
        guard opened.contains(id), let list = panes[id], !list.isEmpty else {
            // No session (e.g. it already died): fall back to a full reopen —
            // an explicit user action, so the session intent is restored.
            closePane(id)
            opened.remove(id)
            autoConnect.insert(id)
            openSSHIfNeeded(id)
            return
        }
        cancelShellIntegrationHandoff(id)
        let idx = list.firstIndex { $0.id == activePane[id] } ?? 0
        let old = list[idx]
        old.onExit = nil // its exit must not run the tab-close/stop-pod path
        old.terminate()
        let fresh = makeTerminal(id, tunnel: idx == 0)
        panes[id]?[idx] = fresh
        activePane[id] = fresh.id
    }

    private func openSSHIfNeeded(_ id: String, startedAt: UInt64? = nil) {
        guard validID(id) else { return }
        guard !opened.contains(id), !starting.contains(id), !shuttingDown.contains(id) else { return }
        let attemptStartedAt = startedAt ?? DispatchTime.now().uptimeNanoseconds
        opened.insert(id)
        Self.logConnection(id, phase: "requested", startedAt: attemptStartedAt)
        let pane = makeTerminal(
            id,
            tunnel: true,
            onStart: {
                Self.logConnection(id, phase: "ssh-pty-started", startedAt: attemptStartedAt)
            }
        )
        pane.onFirstOutput = { [weak self, paneID = pane.id] in
            self?.primarySSHProducedOutput(id, paneID: paneID)
        }
        terminalHandoffs[id] = TerminalHandoffState(paneID: pane.id)

        injectClaudeHooks(id, startedAt: attemptStartedAt)
        Self.startTerminalHandoff(
            mountPrimary: {
                self.setPanes(id, [pane])
                Self.logConnection(id, phase: "ssh-pane-mounted", startedAt: attemptStartedAt)
            },
            beginShellIntegration: {
                self.injectShellIntegration(id, startedAt: attemptStartedAt) { [weak self, paneID = pane.id] success in
                    if Self.shouldConfirmSSH(forShellIntegrationSuccess: success) {
                        self?.sshConfirmed(id)
                    }
                    self?.resolveShellIntegration(
                        id,
                        event: .integrationFinished(
                            paneID: paneID,
                            succeeded: success,
                            sshProducedOutputAtIngress: pane.hasReceivedPTYOutput
                        ),
                        startedAt: attemptStartedAt
                    )
                }
            },
            scheduleTimeout: { delay in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, paneID = pane.id] in
                    self?.resolveShellIntegration(
                        id,
                        event: .timedOut(paneID: paneID),
                        startedAt: attemptStartedAt
                    )
                }
            },
            timeout: handoffTimeout
        )
    }

    private func primarySSHProducedOutput(_ id: String, paneID: UUID) {
        guard opened.contains(id),
              panes[id]?.first?.id == paneID,
              var handoff = terminalHandoffs[id]
        else { return }
        _ = handoff.handle(.firstOutput(paneID: paneID))
        terminalHandoffs[id] = handoff
    }

    private func resolveShellIntegration(
        _ id: String,
        event: TerminalHandoffEvent,
        startedAt: UInt64
    ) {
        let paneID: UUID
        switch event {
        case .firstOutput(let id), .integrationFinished(let id, _, _), .timedOut(let id):
            paneID = id
        }
        guard opened.contains(id),
              let pane = panes[id]?.first,
              pane.id == paneID,
              var handoff = terminalHandoffs[id],
              let action = handoff.handle(event)
        else { return }
        pane.onFirstOutput = nil
        terminalHandoffs[id] = nil

        if case .timedOut = event {
            Self.logConnection(id, phase: "shell-integration-timeout", startedAt: startedAt)
        }
        switch action {
        case .revealOriginal:
            break
        case .restartRemoteShellThenReveal:
            pane.restartRemoteShell()
            Self.logConnection(id, phase: "remote-shell-restarted", startedAt: startedAt)
        }
        Self.logConnection(id, phase: "terminal-revealed", startedAt: startedAt)
    }

    private func cancelShellIntegrationHandoff(_ id: String) {
        guard var handoff = terminalHandoffs[id] else { return }
        handoff.cancel()
        terminalHandoffs[id] = nil
    }

    // MARK: - Terminal tabs

    /// Open another shell to the same pod, as a new active tab.
    func newTerminal(_ id: String) {
        guard validID(id), canMutateTerminal(id) else { return }
        let pane = makeTerminal(id, tunnel: false) // the primary carries the tunnel
        panes[id]?.append(pane)
        activePane[id] = pane.id
    }

    /// Close one terminal tab. Closing the LAST tab disconnects from the pod
    /// (shows the status card); the pod itself keeps running.
    func closeTerminal(_ id: String, paneID: UUID) {
        guard canMutateTerminal(id) else { return }
        guard let list = panes[id],
              let pane = list.first(where: { $0.id == paneID }) else { return }
        if list.first?.id == paneID { cancelShellIntegrationHandoff(id) }
        pane.onExit = nil
        pane.terminate()
        if list.count > 1 {
            removePane(id, paneID: paneID)
        } else {
            disconnect(id)
        }
    }

    func setActivePane(_ id: String, paneID: UUID) {
        guard canMutateTerminal(id),
              panes[id]?.contains(where: { $0.id == paneID }) == true
        else { return }
        activePane[id] = paneID
    }

    /// Switch to the next (+1) or previous (-1) terminal tab, wrapping around.
    func cycleTab(_ id: String, by delta: Int) {
        guard canMutateTerminal(id), let list = panes[id], list.count > 1 else { return }
        let idx = list.firstIndex { $0.id == activePane[id] } ?? 0
        activePane[id] = list[(idx + delta + list.count) % list.count].id
    }

    /// The pane the pod's view should show (its active tab).
    func activeModel(_ id: String) -> TerminalPaneModel? {
        guard let list = panes[id], !list.isEmpty else { return nil }
        return list.first { $0.id == activePane[id] } ?? list[0]
    }

    private func makeTerminal(
        _ id: String,
        tunnel: Bool,
        onStart: (() -> Void)? = nil
    ) -> TerminalPaneModel {
        let pane = TerminalPaneModel(command: "ssh", args: SSH.args(podID: id, tunnel: tunnel))
        pane.onExit = { [weak self] _ in self?.paneExited(id, paneID: pane.id) }
        pane.onStart = onStart
        return pane
    }

    /// An SSH terminal ended (user typed `exit`, or the connection died).
    /// Extra tabs just close; the last one DISCONNECTS: the pod is left in
    /// whatever state it's in and its status card takes the pane's place.
    /// (It used to stop the pod — but a shell exit isn't a stop request, and
    /// when the connection died because the pod stopped externally, running
    /// `devpod stop`/reconnect machinery could wake the pod right back up.)
    private func paneExited(_ id: String, paneID: UUID) {
        guard let list = panes[id], list.contains(where: { $0.id == paneID }) else { return }
        if list.first?.id == paneID { cancelShellIntegrationHandoff(id) }
        if list.count > 1 {
            removePane(id, paneID: paneID)
        } else {
            disconnect(id)
        }
    }

    /// Tear down the pod's session and withdraw the auto-connect intent, so
    /// reconcile won't immediately reopen (or wake) it. The status card with
    /// Connect/Start takes over.
    func disconnect(_ id: String) {
        cancelShellIntegrationHandoff(id)
        opened.remove(id)
        autoConnect.remove(id)
        closePane(id)
    }

    /// Explicit user reconnect (status card's Connect / ⌘⏎ on a running pod):
    /// restores the standing session intent and opens the terminal.
    func connect(_ id: String) {
        guard validID(id), byID[id]?.state == "Running" else { return }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        autoConnect.insert(id)
        openSSHIfNeeded(id, startedAt: startedAt)
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
        cancelShellIntegrationHandoff(id)
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

    func isConnecting(_ id: String) -> Bool {
        Self.isConnecting(
            isOpened: opened.contains(id),
            hasPanes: !(panes[id] ?? []).isEmpty,
            isAwaitingShellIntegration: terminalHandoffs[id] != nil
        )
    }

    static func isConnecting(
        isOpened: Bool,
        hasPanes: Bool,
        isAwaitingShellIntegration: Bool = false
    ) -> Bool {
        isOpened && (!hasPanes || isAwaitingShellIntegration)
    }

    func isTerminalVisible(_ id: String) -> Bool {
        Self.isTerminalVisible(
            isAwaitingShellIntegration: terminalHandoffs[id] != nil
        )
    }

    static func isTerminalVisible(isAwaitingShellIntegration: Bool) -> Bool {
        !isAwaitingShellIntegration
    }

    nonisolated static func canMutateTerminal(
        isOpened: Bool,
        hasPanes: Bool,
        isTerminalVisible: Bool
    ) -> Bool {
        isOpened && hasPanes && isTerminalVisible
    }

    func canMutateTerminal(_ id: String) -> Bool {
        Self.canMutateTerminal(
            isOpened: opened.contains(id),
            hasPanes: !(panes[id] ?? []).isEmpty,
            isTerminalVisible: isTerminalVisible(id)
        )
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
    /// The local monitor consumes app shortcuts except terminal-focused Cmd+B,
    /// which is forwarded to DevSpaceTerminalView's key-equivalent boundary;
    /// all app shortcuts are suppressed while a modal is open.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
    }

    func handleTerminalKeyEquivalent(_ event: NSEvent) -> Bool {
        guard renaming == nil, !guideOpen else { return false }
        guard Self.isSidebarToggleKeyEquivalent(event) else { return false }
        sidebarOpen.toggle()
        return true
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

        // ⌘⇧T — next terminal tab, complementing ⌘T for a new tab.
        if flags == [.command, .shift], renaming == nil, !guideOpen {
            if Self.isNextTerminalTabShortcut(chars) {
                if let id = selectedID,
                   phase(of: id) == .terminal,
                   isTerminalVisible(id)
                {
                    cycleTab(id, by: 1)
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

        if Self.isSidebarToggleKeyEquivalent(event) {
            let window = event.window ?? NSApp.keyWindow
            if Self.shouldRouteSidebarToggleToTerminal(
                event,
                firstResponder: window?.firstResponder
            ) {
                return event
            }
            sidebarOpen.toggle()
            return nil
        }
        // Cmd+R: reconnect the selected workspace's SSH shell (same action as
        // the context menu's "Reload SSH Session") — only meaningful when a
        // session is actually open.
        if chars == "r" {
            if let id = selectedID,
               phase(of: id) == .terminal,
               isTerminalVisible(id)
            {
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
            if let id = selectedID,
               phase(of: id) == .terminal,
               isTerminalVisible(id)
            {
                newTerminal(id)
            }
            return nil
        }
        // Cmd+V: an image-bearing pasteboard is copied to the pod and its
        // path injected into the input line (no Enter — user adds their own
        // message). Text-only pastes fall through untouched to libghostty's
        // own paste, and so does everything else (no terminal open, no
        // workspace selected) — nothing here is destructive to suppress.
        if chars == "v" {
            if let image = Self.pastedImage(),
               let id = selectedID,
               phase(of: id) == .terminal,
               isTerminalVisible(id)
            {
                Self.suppressCompetingPaste()
                pasteImage(image, to: id)
                return nil
            }
            return event
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

    static func isNextTerminalTabShortcut(_ charactersIgnoringModifiers: String) -> Bool {
        charactersIgnoringModifiers.caseInsensitiveCompare("t") == .orderedSame
    }

    static func isSidebarToggleShortcut(_ charactersIgnoringModifiers: String) -> Bool {
        charactersIgnoringModifiers.caseInsensitiveCompare("b") == .orderedSame
    }

    static func isSidebarToggleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let chars = event.charactersIgnoringModifiers
        else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return flags == [.command] && isSidebarToggleShortcut(chars)
    }

    static func shouldRouteSidebarToggleToTerminal(
        _ event: NSEvent,
        firstResponder: NSResponder?
    ) -> Bool {
        isSidebarToggleKeyEquivalent(event) && firstResponder is DevSpaceTerminalView
    }
}
