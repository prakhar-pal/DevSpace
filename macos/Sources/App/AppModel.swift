import SwiftUI
import DevSpaceCore

/// Top-level UI state for the app (the Swift analog of App.tsx). Stack 5 covers
/// the sidebar + layout persistence + selection; terminal/action lifecycle
/// (opened/starting/shuttingDown wiring) arrives in Stack 6.
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
    @Published var hiddenCollapsed = false {
        didSet { persist() }
    }

    // Drives the "Reload SSH Session" menu item; populated in Stack 6.
    @Published private(set) var opened: Set<String> = []
    @Published private(set) var starting: Set<String> = []

    private let loop: PollLoop
    private var layoutLoaded = false

    init(runner: CommandRunning = DevpodCLI(), interval: TimeInterval = 5) {
        loop = PollLoop(runner: runner, interval: interval)
        let l = LayoutStore.load()
        order = l.order
        hidden = l.hidden
        aliases = l.aliases
        hiddenCollapsed = l.hiddenCollapsed
        layoutLoaded = true
        // Start polling immediately so the list is ready before first paint
        // (not gated on a window appearing).
        loop.start { [weak self] views in
            DispatchQueue.main.async { self?.apply(views) }
        }
    }

    private func apply(_ views: [WorkspaceView]) {
        workspaces = views
        let ids = views.map(\.id)
        let newOrder = SidebarLayout.normalizeOrder(order, ids: ids)
        let newHidden = SidebarLayout.pruneHidden(hidden, ids: ids)
        var changed = false
        if newOrder != order { order = newOrder; changed = true }
        if newHidden != hidden { hidden = newHidden; changed = true }
        if changed { persist() }
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

    // MARK: - Actions

    func select(_ id: String) {
        selectedID = id
        badges.remove(id)
    }

    func hide(_ id: String) {
        guard !hidden.contains(id) else { return }
        hidden.append(id)
        persist()
    }

    func unhide(_ id: String) {
        hidden.removeAll { $0 == id }
        persist()
    }

    func beginRename(_ id: String) { renaming = id }

    func setAlias(_ id: String, _ name: String) {
        aliases = SidebarLayout.setAlias(
            aliases, id: id, name: name.trimmingCharacters(in: .whitespaces)
        )
        persist()
    }

    func toggleHiddenCollapsed() { hiddenCollapsed.toggle() }

    func applyVisibleOrder(_ ids: [String]) {
        order = SidebarLayout.reorderVisible(order: order, hidden: Set(hidden), newVisibleIDs: ids)
        persist()
    }

    // Stubs implemented in Stack 6 (actions + session lifecycle).
    func stop(_ id: String) { Log.write("stop \(id) [stack 6]") }
    func reload(_ id: String) { Log.write("reload \(id) [stack 6]") }
    func openInZed(_ id: String) { Log.write("open in zed \(id) [stack 6]") }

    private func persist() {
        guard layoutLoaded else { return }
        LayoutStore.save(Layout(
            order: order, hidden: hidden, aliases: aliases, hiddenCollapsed: hiddenCollapsed
        ))
    }
}
