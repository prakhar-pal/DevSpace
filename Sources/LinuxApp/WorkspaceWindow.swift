import Foundation
import CGTK
import DevSpaceCore

final class WorkspaceWindow {
    let window: UnsafeMutablePointer<GtkWindow>
    private let workspaceRows: UnsafeMutablePointer<GtkBox>
    private let terminalContainer: UnsafeMutablePointer<GtkBox>
    private let emptyState: UnsafeMutablePointer<GtkWidget>
    private let statusLabel: UnsafeMutablePointer<GtkWidget>
    private let notificationWarningLabel: UnsafeMutablePointer<GtkWidget>
    private var terminalPanes: [TerminalPaneIdentity: TerminalPane] = [:]
    private var terminalRoots: [TerminalPaneIdentity: UnsafeMutablePointer<GtkWidget>] = [:]
    private var actionsEnabled = true
    private var terminalErrorWorkspace: String?
    private(set) var snapshot = WorkspaceControllerSnapshot(
        revision: 0, workspaces: [], selectedID: nil, layout: Layout(), terminalPanes: []
    )
    var onCommand: ((String, [String: String]?) -> Void)?

    var terminalCount: Int { terminalPanes.count }
    var workspaceCount: Int { snapshot.workspaces.count }

    init(application: UnsafeMutablePointer<GtkApplication>) {
        window = gtk_application_window_new(application)!
            .withMemoryRebound(to: GtkWindow.self, capacity: 1) { $0 }
        gtk_window_set_title(window, "DevSpace")
        gtk_window_set_default_size(window, 1120, 720)

        let root = UnsafeMutableRawPointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!)
            .assumingMemoryBound(to: GtkBox.self)
        let sidebar = UnsafeMutableRawPointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!)
            .assumingMemoryBound(to: GtkBox.self)
        let rootWidget = UnsafeMutableRawPointer(root).assumingMemoryBound(to: GtkWidget.self)
        let sidebarWidget = UnsafeMutableRawPointer(sidebar).assumingMemoryBound(to: GtkWidget.self)
        gtk_widget_set_hexpand(sidebarWidget, 0)
        gtk_widget_set_margin_top(sidebarWidget, 16)
        gtk_widget_set_margin_bottom(sidebarWidget, 16)
        gtk_widget_set_margin_start(sidebarWidget, 8)
        gtk_widget_set_margin_end(sidebarWidget, 8)

        workspaceRows = UnsafeMutableRawPointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!)
            .assumingMemoryBound(to: GtkBox.self)
        gtk_box_append(sidebar, UnsafeMutableRawPointer(workspaceRows).assumingMemoryBound(to: GtkWidget.self))
        statusLabel = gtk_label_new("")!
        Self.configureSidebarText(statusLabel)
        gtk_label_set_max_width_chars(OpaquePointer(statusLabel), 0)
        gtk_box_append(sidebar, statusLabel)
        notificationWarningLabel = gtk_label_new("")!
        Self.configureSidebarText(notificationWarningLabel)
        gtk_label_set_max_width_chars(OpaquePointer(notificationWarningLabel), 0)
        gtk_widget_set_visible(notificationWarningLabel, 0)
        gtk_box_append(sidebar, notificationWarningLabel)

        let separator = gtk_separator_new(GTK_ORIENTATION_VERTICAL)!
        terminalContainer = UnsafeMutableRawPointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!)
            .assumingMemoryBound(to: GtkBox.self)
        let terminalWidget = UnsafeMutableRawPointer(terminalContainer).assumingMemoryBound(to: GtkWidget.self)
        gtk_widget_set_hexpand(terminalWidget, 1)
        gtk_widget_set_vexpand(terminalWidget, 1)

        emptyState = gtk_label_new("Select a running workspace to open its terminal.")!
        _ = g_object_ref_sink(UnsafeMutableRawPointer(emptyState))
        gtk_widget_set_hexpand(emptyState, 1)
        gtk_widget_set_vexpand(emptyState, 1)
        gtk_box_append(terminalContainer, emptyState)

        gtk_box_append(root, sidebarWidget)
        gtk_box_append(root, separator)
        gtk_box_append(root, terminalWidget)
        gtk_window_set_child(window, rootWidget)
    }

    func present() {
        gtk_window_present(window)
    }

    var titleText: String {
        guard let title = gtk_window_get_title(window) else { return "" }
        return String(cString: title)
    }

    func update(_ next: WorkspaceControllerSnapshot) {
        guard next.revision >= snapshot.revision else { return }
        let selectionChanged = snapshot.selectedID != next.selectedID
        snapshot = next
        clear(workspaceRows)
        let ordered = next.layout.order.compactMap { id in next.workspaces.first { $0.id == id } }
        let orderedIDs = Set(ordered.map(\.id))
        let workspaces = ordered + next.workspaces.filter { !orderedIDs.contains($0.id) }
        if workspaces.isEmpty {
            gtk_box_append(workspaceRows, gtk_label_new("No workspaces found.")!)
        }
        for workspace in workspaces {
            appendWorkspace(workspace, selected: workspace.id == next.selectedID,
                            alias: next.layout.aliases[workspace.id], badged: next.badges.contains(workspace.id))
        }
        revealSelectedTerminal(focus: selectionChanged)
    }

    func apply(_ effect: WorkspaceTerminalEffect) {
        if effect.kind == "terminal_error" {
            setStatus(effect.message ?? "SSH connection failed")
            terminalErrorWorkspace = effect.workspaceID
            return
        }
        guard let paneID = effect.paneID else { return }
        let identity = TerminalPaneIdentity(
            workspaceID: effect.workspaceID, generation: effect.generation, paneID: paneID
        )
        switch effect.kind {
        case "terminal_launch":
            guard terminalPanes[identity] == nil else { return }
            guard let launch = LinuxTerminalLaunch(
                kind: effect.kind, workspaceID: effect.workspaceID, paneID: paneID,
                generation: effect.generation, executable: effect.executable,
                arguments: effect.arguments
            ) else {
                setStatus("Invalid terminal launch request")
                onCommand?("terminal_launch_failed", eventPayload(identity))
                return
            }
            guard let pane = TerminalPane(launch: launch, onEvent: { [weak self] kind, payload in
                self?.onCommand?(kind, payload)
            }) else {
                setStatus("Terminal could not start")
                onCommand?("terminal_launch_failed", eventPayload(identity))
                return
            }
            openTerminal(pane)
        case "terminal_close":
            closeTerminal(identity)
        case "terminal_inject":
            guard let pane = terminalPanes[identity], let message = effect.message else { return }
            pane.feed(message)
        default:
            break
        }
    }

    func openTerminal(_ pane: TerminalPane) {
        guard terminalPanes[pane.identity] == nil else { return }
        terminalPanes[pane.identity] = pane

        let root = UnsafeMutableRawPointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!)
            .assumingMemoryBound(to: GtkBox.self)
        gtk_widget_set_vexpand(pane.widget, 1)
        gtk_box_append(root, pane.widget)
        let rootWidget = UnsafeMutableRawPointer(root).assumingMemoryBound(to: GtkWidget.self)
        gtk_widget_set_vexpand(rootWidget, 1)
        terminalRoots[pane.identity] = rootWidget
        gtk_box_append(terminalContainer, rootWidget)
        if terminalErrorWorkspace == pane.identity.workspaceID { setStatus("") }
        revealSelectedTerminal(focus: pane.identity.workspaceID == snapshot.selectedID)
    }

    func pane(for identity: TerminalPaneIdentity) -> TerminalPane? {
        terminalPanes[identity]
    }

    func pane(forWorkspace workspaceID: String) -> TerminalPane? {
        terminalPanes.values.first { $0.identity.workspaceID == workspaceID }
    }

    func closeTerminal(_ identity: TerminalPaneIdentity, reportExit: Bool = false) {
        guard let pane = terminalPanes.removeValue(forKey: identity) else { return }
        if reportExit { pane.reportExit() }
        if let root = terminalRoots.removeValue(forKey: identity) { gtk_box_remove(terminalContainer, root) }
        pane.dispose()
        revealSelectedTerminal()
    }

    private func revealSelectedTerminal(focus: Bool = false) {
        let selectedPane = snapshot.selectedID.flatMap { pane(forWorkspace: $0) }
        for (identity, root) in terminalRoots {
            gtk_widget_set_visible(root, identity == selectedPane?.identity ? 1 : 0)
        }
        gtk_widget_set_visible(emptyState, selectedPane == nil ? 1 : 0)
        if focus, let selectedPane { _ = gtk_widget_grab_focus(selectedPane.widget) }
    }

    // Retained for the controlled terminal smoke test in the Task 2 harness.
    func closeTerminal(_ paneID: UUID) {
        guard let identity = terminalPanes.keys.first(where: { $0.paneID == paneID }) else { return }
        closeTerminal(identity)
    }

    func setStatus(_ message: String) {
        terminalErrorWorkspace = nil
        gtk_label_set_text(OpaquePointer(statusLabel), message)
    }

    func setNotificationWarning(_ message: String) {
        gtk_label_set_text(OpaquePointer(notificationWarningLabel), "Notifications unavailable: \(message)")
        gtk_widget_set_visible(notificationWarningLabel, 1)
    }

    func setActionsEnabled(_ enabled: Bool) {
        actionsEnabled = enabled
        refreshActionSensitivity(in: UnsafeMutableRawPointer(workspaceRows).assumingMemoryBound(to: GtkWidget.self))
    }

    deinit {
        g_object_unref(UnsafeMutableRawPointer(emptyState))
    }

    private func appendWorkspace(_ workspace: WorkspaceView, selected: Bool, alias: String?, badged: Bool) {
        let row = UnsafeMutableRawPointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!)
            .assumingMemoryBound(to: GtkBox.self)
        let title = UnsafeMutableRawPointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!)
            .assumingMemoryBound(to: GtkBox.self)
        let statusDot = gtk_label_new(nil)!
        let statusColor = workspace.state == "Running" ? "#2e7d32" : "#808080"
        gtk_label_set_markup(OpaquePointer(statusDot), "<span foreground=\"\(statusColor)\">●</span>")
        gtk_widget_set_tooltip_text(statusDot, workspace.state)
        gtk_box_append(title, statusDot)
        let label = gtk_label_new("\(alias ?? workspace.id)\(badged ? " · ●" : "")")!
        Self.configureSidebarText(label)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(title, label)
        gtk_box_append(row, UnsafeMutableRawPointer(title).assumingMemoryBound(to: GtkWidget.self))

        let button = gtk_button_new()!
        button.withMemoryRebound(to: GtkButton.self, capacity: 1) {
            gtk_button_set_child($0, UnsafeMutableRawPointer(row).assumingMemoryBound(to: GtkWidget.self))
        }
        gtk_widget_add_css_class(button, "flat")
        if selected { gtk_widget_add_css_class(button, "suggested-action") }
        gtk_widget_set_sensitive(button, actionsEnabled ? 1 : 0)
        connectAction(button, context: WorkspaceActionContext(
            window: self, kind: "select", payload: ["workspace_id": workspace.id]
        ))
        gtk_box_append(workspaceRows, button)
    }

    private static func configureSidebarText(_ label: UnsafeMutablePointer<GtkWidget>) {
        gtk_label_set_xalign(OpaquePointer(label), 0)
        gtk_label_set_wrap(OpaquePointer(label), 1)
        gtk_label_set_wrap_mode(OpaquePointer(label), PANGO_WRAP_WORD_CHAR)
        gtk_label_set_max_width_chars(OpaquePointer(label), 24)
    }

    private func connectAction(_ button: UnsafeMutablePointer<GtkWidget>, context: WorkspaceActionContext) {
        let callback = unsafeBitCast(
            devspaceLinuxWorkspaceAction as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
            to: GCallback.self
        )
        let destroy: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<WorkspaceActionContext>.fromOpaque(data).release()
        }
        _ = g_signal_connect_data(
            UnsafeMutableRawPointer(button), "clicked", callback,
            Unmanaged.passRetained(context).toOpaque(), destroy, GConnectFlags(rawValue: 0)
        )
    }

    private func clear(_ box: UnsafeMutablePointer<GtkBox>) {
        while let child = gtk_widget_get_first_child(UnsafeMutableRawPointer(box).assumingMemoryBound(to: GtkWidget.self)) {
            gtk_box_remove(box, child)
        }
    }

    private func eventPayload(_ identity: TerminalPaneIdentity) -> [String: String] {
        ["workspace_id": identity.workspaceID,
         "generation": identity.generation.uuidString.lowercased(),
         "pane_id": identity.paneID.uuidString.lowercased()]
    }

    private func refreshActionSensitivity(in widget: UnsafeMutablePointer<GtkWidget>) {
        if String(cString: gtk_widget_get_css_name(widget)) == "button" {
            gtk_widget_set_sensitive(widget, actionsEnabled ? 1 : 0)
        }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            refreshActionSensitivity(in: current)
            child = gtk_widget_get_next_sibling(current)
        }
    }

}

private final class WorkspaceActionContext {
    weak var window: WorkspaceWindow?
    let kind: String
    let payload: [String: String]
    init(window: WorkspaceWindow, kind: String, payload: [String: String]) {
        self.window = window
        self.kind = kind
        self.payload = payload
    }
}

@_cdecl("devspace_linux_workspace_action")
private func devspaceLinuxWorkspaceAction(_ button: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?) {
    guard let data else { return }
    let context = Unmanaged<WorkspaceActionContext>.fromOpaque(data).takeUnretainedValue()
    context.window?.onCommand?(context.kind, context.payload)
    _ = button
}
