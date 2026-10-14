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
    private var retiredTerminalGenerations: [String: Set<UUID>] = [:]
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

        emptyState = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        _ = g_object_ref_sink(UnsafeMutableRawPointer(emptyState))
        gtk_widget_set_hexpand(emptyState, 1)
        gtk_widget_set_vexpand(emptyState, 1)
        gtk_box_append(terminalContainer, emptyState)

        gtk_box_append(root, sidebarWidget)
        gtk_box_append(root, separator)
        gtk_box_append(root, terminalWidget)
        gtk_window_set_child(window, rootWidget)
        refreshLifecyclePanel()
        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        gtk_widget_add_controller(rootWidget, keys)
        let callback = unsafeBitCast(
            devspaceLinuxWindowKeyPressed as @convention(c)
                (UnsafeMutableRawPointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Int32,
            to: GCallback.self
        )
        let destroy: GClosureNotify = { data, _ in
            if let data { Unmanaged<WorkspaceActionContext>.fromOpaque(data).release() }
        }
        _ = g_signal_connect_data(UnsafeMutableRawPointer(keys), "key-pressed", callback,
            Unmanaged.passRetained(WorkspaceActionContext(window: self, kind: "shortcut", payload: [:])).toOpaque(),
            destroy, GConnectFlags(rawValue: 0))
    }

    func present() {
        gtk_window_present(window)
    }

    @discardableResult
    func handleShortcut(keyval: UInt32, modifiers: GdkModifierType) -> Bool {
        let allowed = GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue
        let relevant = allowed | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue
        guard modifiers.rawValue & relevant == allowed, actionsEnabled else { return false }
        if let focus = gtk_window_get_focus(window),
           g_type_check_instance_is_a(UnsafeMutableRawPointer(focus).assumingMemoryBound(to: GTypeInstance.self), gtk_editable_get_type()) != 0 {
            return false
        }
        let key = gdk_keyval_to_lower(keyval)
        if key == UInt32(GDK_KEY_b), let root = gtk_window_get_child(window),
           let sidebar = gtk_widget_get_first_child(root) {
            let visible: Int32 = gtk_widget_get_visible(sidebar) == 0 ? 1 : 0
            gtk_widget_set_visible(sidebar, visible)
            if let separator = gtk_widget_get_next_sibling(sidebar) { gtk_widget_set_visible(separator, visible) }
            return true
        }
        let shiftedNumbers: [UInt32] = [UInt32(GDK_KEY_exclam), UInt32(GDK_KEY_at), UInt32(GDK_KEY_numbersign),
            UInt32(GDK_KEY_dollar), UInt32(GDK_KEY_percent), UInt32(GDK_KEY_asciicircum),
            UInt32(GDK_KEY_ampersand), UInt32(GDK_KEY_asterisk), UInt32(GDK_KEY_parenleft)]
        let index = (UInt32(GDK_KEY_1)...UInt32(GDK_KEY_9)).contains(key)
            ? Int(key - UInt32(GDK_KEY_1)) : shiftedNumbers.firstIndex(of: key)
        if let index {
            let hidden = Set(snapshot.layout.hidden)
            let ids = SidebarLayout.displayIDs(order: snapshot.layout.order, workspaces: snapshot.workspaces)
                .filter { !hidden.contains($0) }
            guard ids.indices.contains(index) else { return false }
            onCommand?("select", ["workspace_id": ids[index]])
            return true
        }
        guard key == UInt32(GDK_KEY_r) || key == UInt32(GDK_KEY_o),
              let workspace = snapshot.workspaces.first(where: { $0.id == snapshot.selectedID }),
              workspace.state == "Running",
              !snapshot.operations.contains(where: { $0.workspaceID == workspace.id }) else { return false }
        if key == UInt32(GDK_KEY_r) {
            guard pane(forWorkspace: workspace.id) != nil else { return false }
            onCommand?("reconnect", ["workspace_id": workspace.id])
        } else {
            var payload = ["workspace_id": workspace.id]
            if let directory = pane(forWorkspace: workspace.id)?.currentDirectory { payload["directory"] = directory }
            onCommand?("open_zed", payload)
        }
        return true
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
        refreshLifecyclePanel()
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
            guard retiredTerminalGenerations[effect.workspaceID]?.contains(effect.generation) != true else { return }
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
                if kind == "clipboard_error" { self?.setStatus(payload["message"] ?? "Clipboard image unavailable") }
                else { self?.onCommand?(kind, payload) }
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
        refreshLifecyclePanel()
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
        if !terminalPanes.keys.contains(where: {
            $0.workspaceID == identity.workspaceID && $0.generation == identity.generation
        }) {
            retiredTerminalGenerations[identity.workspaceID, default: []].insert(identity.generation)
        }
        revealSelectedTerminal()
        refreshLifecyclePanel()
    }

    private func revealSelectedTerminal(focus: Bool = false) {
        let selectedPane = snapshot.selectedID.flatMap { pane(forWorkspace: $0) }
        for (identity, root) in terminalRoots {
            gtk_widget_set_visible(root, identity == selectedPane?.identity ? 1 : 0)
        }
        let operating = snapshot.operations.contains { $0.workspaceID == snapshot.selectedID }
        gtk_widget_set_visible(emptyState, selectedPane == nil || operating ? 1 : 0)
        if operating {
            for root in terminalRoots.values { gtk_widget_set_visible(root, 0) }
        }
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
        gtk_widget_set_sensitive(UnsafeMutableRawPointer(workspaceRows).assumingMemoryBound(to: GtkWidget.self), enabled ? 1 : 0)
        gtk_widget_set_sensitive(emptyState, enabled ? 1 : 0)
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
        let container = UnsafeMutableRawPointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!)
            .assumingMemoryBound(to: GtkBox.self)
        gtk_widget_set_hexpand(button, 1)
        gtk_box_append(container, button)
        if workspace.state == "Running" {
            let busy = snapshot.operations.contains { $0.workspaceID == workspace.id }
            let stop = gtk_button_new_from_icon_name("media-playback-stop-symbolic")!
            gtk_widget_set_name(stop, "stop-workspace")
            gtk_widget_set_tooltip_text(stop, "Stop \(alias ?? workspace.id)")
            gtk_widget_add_css_class(stop, "flat")
            gtk_widget_set_sensitive(stop, actionsEnabled && !busy ? 1 : 0)
            connectAction(stop, context: WorkspaceActionContext(
                window: self, kind: "stop", payload: ["workspace_id": workspace.id]
            ))
            gtk_box_append(container, stop)
        }
        gtk_box_append(workspaceRows, UnsafeMutableRawPointer(container).assumingMemoryBound(to: GtkWidget.self))
    }

    private func refreshLifecyclePanel() {
        let box = UnsafeMutableRawPointer(emptyState).assumingMemoryBound(to: GtkBox.self)
        clear(box)
        gtk_widget_set_margin_top(emptyState, 24)
        gtk_widget_set_margin_start(emptyState, 24)
        gtk_widget_set_margin_end(emptyState, 24)
        guard let workspace = snapshot.workspaces.first(where: { $0.id == snapshot.selectedID }) else {
            gtk_box_append(box, gtk_label_new("Select a workspace to open its terminal.")!)
            return
        }
        if let operation = snapshot.operations.first(where: { $0.workspaceID == workspace.id }) {
            gtk_box_append(box, gtk_label_new("\(operation.kind.capitalized): \(snapshot.layout.aliases[workspace.id] ?? workspace.id) — \(operation.state)")!)
            let output = gtk_label_new(operation.output)!
            gtk_label_set_xalign(OpaquePointer(output), 0)
            gtk_label_set_yalign(OpaquePointer(output), 0)
            gtk_label_set_wrap(OpaquePointer(output), 1)
            gtk_label_set_wrap_mode(OpaquePointer(output), PANGO_WRAP_WORD_CHAR)
            gtk_label_set_selectable(OpaquePointer(output), 1)
            let scroll = gtk_scrolled_window_new()!
            gtk_widget_set_vexpand(scroll, 1)
            gtk_scrolled_window_set_child(OpaquePointer(scroll), output)
            gtk_box_append(box, scroll)
            if operation.kind == "start" {
                let cancel = gtk_button_new_with_label(operation.state == "cancelling" ? "Cancelling…" : "Cancel")!
                gtk_widget_set_name(cancel, "cancel-operation")
                gtk_widget_set_sensitive(cancel, actionsEnabled && operation.state != "cancelling" ? 1 : 0)
                connectAction(cancel, context: WorkspaceActionContext(
                    window: self, kind: "cancel", payload: ["request_id": operation.id]
                ))
                gtk_box_append(box, cancel)
            }
        } else if workspace.state == "Stopped" {
            gtk_box_append(box, gtk_label_new("Workspace stopped")!)
            let start = gtk_button_new_with_label("Start")!
            gtk_widget_set_name(start, "start-workspace")
            gtk_widget_set_sensitive(start, actionsEnabled ? 1 : 0)
            connectAction(start, context: WorkspaceActionContext(
                window: self, kind: "start", payload: ["workspace_id": workspace.id]
            ))
            gtk_box_append(box, start)
        } else {
            gtk_box_append(box, gtk_label_new(workspace.state == "Running"
                ? "Connecting to workspace…" : "Checking workspace status…")!)
        }
        revealSelectedTerminal()
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
    guard let button, gtk_widget_is_sensitive(button.assumingMemoryBound(to: GtkWidget.self)) != 0 else { return }
    context.window?.onCommand?(context.kind, context.payload)
    _ = button
}

@_cdecl("devspace_linux_window_key_pressed")
private func devspaceLinuxWindowKeyPressed(_ controller: UnsafeMutableRawPointer?, _ keyval: UInt32,
                                          _ keycode: UInt32, _ state: UInt32, _ data: UnsafeMutableRawPointer?) -> Int32 {
    guard let data else { return 0 }
    let context = Unmanaged<WorkspaceActionContext>.fromOpaque(data).takeUnretainedValue()
    return context.window?.handleShortcut(keyval: keyval, modifiers: GdkModifierType(rawValue: state)) == true ? 1 : 0
}
