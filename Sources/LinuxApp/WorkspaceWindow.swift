import Foundation
import CGTK
import DevSpaceCore

final class WorkspaceWindow {
    let window: UnsafeMutablePointer<GtkWindow>
    private let workspaceRows: UnsafeMutablePointer<GtkBox>
    private let hiddenWorkspaceRows: UnsafeMutablePointer<GtkBox>
    private let terminalContainer: UnsafeMutablePointer<GtkBox>
    private let terminalTabs: UnsafeMutablePointer<GtkBox>
    private let emptyState: UnsafeMutablePointer<GtkWidget>
    private let statusLabel: UnsafeMutablePointer<GtkWidget>
    private let notificationWarningLabel: UnsafeMutablePointer<GtkWidget>
    private let sidebar: UnsafeMutablePointer<GtkWidget>
    private var sidebarMinimumEstablished = false
    private var terminalPanes: [TerminalPaneIdentity: TerminalPane] = [:]
    private var terminalOrder: [TerminalPaneIdentity] = []
    private var activeTerminal: [String: TerminalPaneIdentity] = [:]
    private var terminalRoots: [TerminalPaneIdentity: UnsafeMutablePointer<GtkWidget>] = [:]
    private var retiredTerminalGenerations: [String: Set<UUID>] = [:]
    private var actionsEnabled = true
    private var terminalErrorWorkspace: String?
    private var connectionStates: [String: String] = [:]
    private var workspaceMenu: UnsafeMutablePointer<GtkWidget>?
    private var renameDialog: UnsafeMutablePointer<GtkWidget>?
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
        self.sidebar = sidebarWidget
        gtk_widget_set_hexpand(sidebarWidget, 0)
        gtk_widget_set_margin_top(sidebarWidget, 16)
        gtk_widget_set_margin_bottom(sidebarWidget, 16)
        gtk_widget_set_margin_start(sidebarWidget, 8)
        gtk_widget_set_margin_end(sidebarWidget, 8)

        workspaceRows = UnsafeMutableRawPointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!)
            .assumingMemoryBound(to: GtkBox.self)
        let rowsWidget = UnsafeMutableRawPointer(workspaceRows).assumingMemoryBound(to: GtkWidget.self)
        gtk_widget_set_name(rowsWidget, "workspace-rows")
        let workspaceScroll = gtk_scrolled_window_new()!
        gtk_widget_set_name(workspaceScroll, "workspace-sidebar-scroll")
        gtk_widget_set_vexpand(workspaceScroll, 1)
        gtk_scrolled_window_set_policy(OpaquePointer(workspaceScroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_width(OpaquePointer(workspaceScroll), 1)
        gtk_scrolled_window_set_child(OpaquePointer(workspaceScroll), rowsWidget)
        gtk_box_append(sidebar, workspaceScroll)
        statusLabel = gtk_label_new("")!
        Self.configureSidebarText(statusLabel)
        gtk_label_set_max_width_chars(OpaquePointer(statusLabel), 0)
        gtk_box_append(sidebar, statusLabel)
        notificationWarningLabel = gtk_label_new("")!
        Self.configureSidebarText(notificationWarningLabel)
        gtk_label_set_max_width_chars(OpaquePointer(notificationWarningLabel), 0)
        gtk_widget_set_visible(notificationWarningLabel, 0)
        gtk_box_append(sidebar, notificationWarningLabel)
        hiddenWorkspaceRows = UnsafeMutableRawPointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!)
            .assumingMemoryBound(to: GtkBox.self)
        gtk_box_append(sidebar, UnsafeMutableRawPointer(hiddenWorkspaceRows).assumingMemoryBound(to: GtkWidget.self))

        let separator = gtk_separator_new(GTK_ORIENTATION_VERTICAL)!
        terminalContainer = UnsafeMutableRawPointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!)
            .assumingMemoryBound(to: GtkBox.self)
        let terminalWidget = UnsafeMutableRawPointer(terminalContainer).assumingMemoryBound(to: GtkWidget.self)
        gtk_widget_set_hexpand(terminalWidget, 1)
        gtk_widget_set_vexpand(terminalWidget, 1)
        let tabs = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        terminalTabs = UnsafeMutableRawPointer(tabs).assumingMemoryBound(to: GtkBox.self)
        gtk_widget_set_name(tabs, "terminal-tabs")
        gtk_widget_set_visible(tabs, 0)
        gtk_box_append(terminalContainer, tabs)

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

    func setConnectionStates(_ states: [String: String]) {
        if states != connectionStates { dismissWorkspaceMenu() }
        connectionStates = states
    }

    @discardableResult
    func handleShortcut(keyval: UInt32, modifiers: GdkModifierType) -> Bool {
        let allowed = GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue
        let relevant = allowed | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue
        guard actionsEnabled, renameDialog == nil else { return false }
        if let focus = gtk_window_get_focus(window),
           g_type_check_instance_is_a(UnsafeMutableRawPointer(focus).assumingMemoryBound(to: GTypeInstance.self), gtk_editable_get_type()) != 0 {
            return false
        }
        if modifiers.rawValue & relevant == GDK_CONTROL_MASK.rawValue,
           keyval == UInt32(GDK_KEY_Page_Up) || keyval == UInt32(GDK_KEY_Page_Down),
           let selected = snapshot.selectedID, canMutateTerminal(selected) {
            let panes = terminalOrder.filter { $0.workspaceID == selected }
            guard panes.count > 1 else { return false }
            let index = panes.firstIndex(of: activeTerminal[selected] ?? panes[0]) ?? 0
            selectTerminal(panes[(index + (keyval == UInt32(GDK_KEY_Page_Up) ? -1 : 1) + panes.count) % panes.count])
            return true
        }
        if modifiers.rawValue & relevant == allowed | GDK_ALT_MASK.rawValue,
           keyval == UInt32(GDK_KEY_Up) || keyval == UInt32(GDK_KEY_Down),
           let selected = snapshot.selectedID {
            let ids = visibleWorkspaceIDs
            guard let index = ids.firstIndex(of: selected),
                  keyval == UInt32(GDK_KEY_Up) ? index > 0 : index < ids.count - 1 else { return false }
            onCommand?(keyval == UInt32(GDK_KEY_Up) ? "move_up" : "move_down", ["workspace_id": selected])
            return true
        }
        guard modifiers.rawValue & relevant == allowed else { return false }
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
        guard [UInt32(GDK_KEY_r), UInt32(GDK_KEY_o), UInt32(GDK_KEY_t)].contains(key),
              let workspace = snapshot.workspaces.first(where: { $0.id == snapshot.selectedID }),
              workspace.state == "Running",
              !snapshot.operations.contains(where: { $0.workspaceID == workspace.id }) else { return false }
        if key == UInt32(GDK_KEY_t) {
            guard canMutateTerminal(workspace.id) else { return false }
            onCommand?("new_terminal", ["workspace_id": workspace.id])
        } else if key == UInt32(GDK_KEY_r) {
            guard pane(forWorkspace: workspace.id) != nil else { return false }
            onCommand?("reconnect", ["workspace_id": workspace.id])
        } else {
            onCommand?("open_zed", editorPayload(workspace.id))
        }
        return true
    }

    var titleText: String {
        guard let title = gtk_window_get_title(window) else { return "" }
        return String(cString: title)
    }

    func update(_ next: WorkspaceControllerSnapshot) {
        guard next.revision >= snapshot.revision else { return }
        if next.workspaces != snapshot.workspaces || next.operations != snapshot.operations || next.layout != snapshot.layout {
            dismissWorkspaceMenu()
        }
        let selectionChanged = snapshot.selectedID != next.selectedID
        snapshot = next
        clear(workspaceRows)
        clear(hiddenWorkspaceRows)
        let parts = SidebarLayout.split(
            displayIDs: SidebarLayout.displayIDs(order: next.layout.order, workspaces: next.workspaces),
            hidden: Set(next.layout.hidden), byID: Dictionary(uniqueKeysWithValues: next.workspaces.map { ($0.id, $0) }))
        if next.workspaces.isEmpty {
            gtk_box_append(workspaceRows, gtk_label_new("No workspaces found.")!)
        }
        for workspace in parts.visible {
            appendWorkspace(workspace, selected: workspace.id == next.selectedID,
                            alias: next.layout.aliases[workspace.id], badged: next.badges.contains(workspace.id))
        }
        if !parts.hidden.isEmpty {
            let toggle = gtk_button_new_with_label("\(next.layout.hiddenCollapsed ? "▸" : "▾") Hidden (\(parts.hidden.count))")!
            gtk_widget_set_name(toggle, "toggle-hidden-workspaces")
            gtk_widget_add_css_class(toggle, "flat")
            connectAction(toggle, context: WorkspaceActionContext(window: self,
                kind: next.layout.hiddenCollapsed ? "expand_hidden" : "collapse_hidden", payload: [:]))
            gtk_box_append(hiddenWorkspaceRows, toggle)
            for workspace in SidebarLayout.hiddenRows(parts.hidden, collapsed: next.layout.hiddenCollapsed, selectedID: next.selectedID) {
                appendWorkspace(workspace, selected: workspace.id == next.selectedID,
                    alias: next.layout.aliases[workspace.id], badged: next.badges.contains(workspace.id), into: hiddenWorkspaceRows)
            }
        }
        // Establish the requested floor once from the original content-sized
        // layout. Measuring the constrained widget again would double it on
        // every poll, and growing names must not ratchet the minimum upward.
        if !sidebarMinimumEstablished,
           next.workspaces.contains(where: { $0.state == "Running" || $0.state == "Stopped" }) {
            var natural: Int32 = 0
            gtk_widget_measure(sidebar, GTK_ORIENTATION_HORIZONTAL, -1, nil, &natural, nil, nil)
            gtk_widget_set_size_request(sidebar, natural * 2, -1)
            sidebarMinimumEstablished = true
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
                else {
                    if kind == "terminal_directory" { self?.refreshTerminalTabs() }
                    self?.onCommand?(kind, payload)
                }
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
        terminalOrder.append(pane.identity)
        activeTerminal[pane.identity.workspaceID] = pane.identity

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
        if let identity = activeTerminal[workspaceID], let pane = terminalPanes[identity] { return pane }
        return terminalOrder.first { $0.workspaceID == workspaceID }.flatMap { terminalPanes[$0] }
    }

    func closeTerminal(_ identity: TerminalPaneIdentity, reportExit: Bool = false) {
        guard let pane = terminalPanes.removeValue(forKey: identity) else { return }
        let siblings = terminalOrder.filter { $0.workspaceID == identity.workspaceID }
        let index = siblings.firstIndex(of: identity) ?? 0
        terminalOrder.removeAll { $0 == identity }
        if activeTerminal[identity.workspaceID] == identity {
            let remaining = siblings.filter { $0 != identity }
            activeTerminal[identity.workspaceID] = remaining.isEmpty ? nil : remaining[max(0, index - 1)]
        }
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
        refreshTerminalTabs()
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

    private func canMutateTerminal(_ workspace: String) -> Bool {
        actionsEnabled && connectionStates[workspace] == "connected"
            && snapshot.workspaces.contains { $0.id == workspace && $0.state == "Running" }
            && !snapshot.operations.contains { $0.workspaceID == workspace }
            && pane(forWorkspace: workspace) != nil
    }

    private func selectTerminal(_ identity: TerminalPaneIdentity) {
        guard terminalPanes[identity] != nil, canMutateTerminal(identity.workspaceID) else { return }
        activeTerminal[identity.workspaceID] = identity
        revealSelectedTerminal(focus: true)
    }

    private func refreshTerminalTabs() {
        clear(terminalTabs)
        let panes = terminalOrder.filter { $0.workspaceID == snapshot.selectedID }
        let widget = UnsafeMutableRawPointer(terminalTabs).assumingMemoryBound(to: GtkWidget.self)
        gtk_widget_set_visible(widget, panes.count > 1 ? 1 : 0)
        guard panes.count > 1, let workspace = snapshot.selectedID else { return }
        gtk_widget_set_sensitive(widget, canMutateTerminal(workspace) ? 1 : 0)
        for (index, identity) in panes.enumerated() {
            let directory = terminalPanes[identity]?.currentDirectory
            let name = directory.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? directory : $0 } ?? "\(index + 1)"
            let button = gtk_button_new_with_label(name)!
            gtk_widget_set_name(button, "select-terminal-\(identity.paneID.uuidString.lowercased())")
            gtk_widget_set_hexpand(button, 1)
            gtk_widget_set_tooltip_text(button, directory ?? "Terminal \(index + 1)")
            if activeTerminal[workspace] == identity { gtk_widget_add_css_class(button, "suggested-action") }
            connectAction(button, context: WorkspaceActionContext(window: self, kind: "select_terminal", payload: eventPayload(identity)))
            gtk_box_append(terminalTabs, button)
            let close = gtk_button_new_from_icon_name("window-close-symbolic")!
            gtk_widget_set_name(close, "close-terminal-\(identity.paneID.uuidString.lowercased())")
            gtk_widget_set_tooltip_text(close, "Close terminal \(index + 1)")
            connectAction(close, context: WorkspaceActionContext(window: self, kind: "close_terminal", payload: eventPayload(identity)))
            gtk_box_append(terminalTabs, close)
        }
        let add = gtk_button_new_from_icon_name("list-add-symbolic")!
        gtk_widget_set_tooltip_text(add, "New terminal (Ctrl+Shift+T)")
        connectAction(add, context: WorkspaceActionContext(window: self, kind: "new_terminal", payload: ["workspace_id": workspace]))
        gtk_box_append(terminalTabs, add)
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
        gtk_widget_set_sensitive(UnsafeMutableRawPointer(terminalTabs).assumingMemoryBound(to: GtkWidget.self), enabled ? 1 : 0)
        gtk_widget_set_sensitive(UnsafeMutableRawPointer(workspaceRows).assumingMemoryBound(to: GtkWidget.self), enabled ? 1 : 0)
        gtk_widget_set_sensitive(UnsafeMutableRawPointer(hiddenWorkspaceRows).assumingMemoryBound(to: GtkWidget.self), enabled ? 1 : 0)
        gtk_widget_set_sensitive(emptyState, enabled ? 1 : 0)
        if let workspaceMenu { gtk_widget_set_sensitive(workspaceMenu, enabled ? 1 : 0) }
        if let renameDialog {
            gtk_dialog_set_response_sensitive(UnsafeMutableRawPointer(renameDialog).assumingMemoryBound(to: GtkDialog.self),
                GTK_RESPONSE_ACCEPT.rawValue, enabled ? 1 : 0)
        }
    }

    deinit {
        dismissWorkspaceMenu()
        if let renameDialog {
            gtk_window_destroy(UnsafeMutableRawPointer(renameDialog).assumingMemoryBound(to: GtkWindow.self))
            g_object_unref(UnsafeMutableRawPointer(renameDialog))
        }
        g_object_unref(UnsafeMutableRawPointer(emptyState))
    }

    private func appendWorkspace(_ workspace: WorkspaceView, selected: Bool, alias: String?, badged: Bool,
                                 into destination: UnsafeMutablePointer<GtkBox>? = nil) {
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
        gtk_widget_set_name(button, "select-workspace-\(workspace.id)")
        button.withMemoryRebound(to: GtkButton.self, capacity: 1) {
            gtk_button_set_child($0, UnsafeMutableRawPointer(row).assumingMemoryBound(to: GtkWidget.self))
        }
        gtk_widget_add_css_class(button, "flat")
        if selected { gtk_widget_add_css_class(button, "suggested-action") }
        gtk_widget_set_sensitive(button, actionsEnabled ? 1 : 0)
        connectAction(button, context: WorkspaceActionContext(
            window: self, kind: "select", payload: ["workspace_id": workspace.id]
        ))
        let gesture = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(gesture, 3)
        let pressed = unsafeBitCast(devspaceLinuxWorkspaceMenu as @convention(c)
            (UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void, to: GCallback.self)
        let destroy: GClosureNotify = { data, _ in
            if let data { Unmanaged<WorkspaceActionContext>.fromOpaque(data).release() }
        }
        _ = g_signal_connect_data(UnsafeMutableRawPointer(gesture), "pressed", pressed,
            Unmanaged.passRetained(WorkspaceActionContext(window: self, kind: "menu",
                payload: ["workspace_id": workspace.id])).toOpaque(), destroy, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(button, gesture)
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
        gtk_box_append(destination ?? workspaceRows, UnsafeMutableRawPointer(container).assumingMemoryBound(to: GtkWidget.self))
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
            let phase = connectionStates[workspace.id]
            let connecting = phase == "connecting" || phase == "disconnecting"
            if workspace.state == "Running" {
                gtk_box_append(box, gtk_label_new(phase == "disconnecting" ? "Disconnecting SSH session…"
                    : connecting ? "Connecting to workspace…" : "Workspace is running. Connect to open its terminal.")!)
                let connect = gtk_button_new_with_label(connecting ? "Connecting…" : "Connect")!
                gtk_widget_set_name(connect, "connect-workspace")
                gtk_widget_set_sensitive(connect, actionsEnabled && !connecting ? 1 : 0)
                connectAction(connect, context: WorkspaceActionContext(window: self, kind: "connect",
                    payload: ["workspace_id": workspace.id]))
                gtk_box_append(box, connect)
            } else { gtk_box_append(box, gtk_label_new("Checking workspace status…")!) }
        }
        revealSelectedTerminal()
    }

    func showWorkspaceMenu(_ workspaceID: String, relativeTo source: UnsafeMutablePointer<GtkWidget>, x: Double = 0, y: Double = 0) {
        guard actionsEnabled, let workspace = snapshot.workspaces.first(where: { $0.id == workspaceID }),
              let root = gtk_window_get_child(window) else { return }
        dismissWorkspaceMenu()
        let popover = gtk_popover_new()!
        _ = g_object_ref_sink(UnsafeMutableRawPointer(popover))
        workspaceMenu = popover
        gtk_widget_set_parent(popover, root)
        var point = graphene_point_t(x: Float(x), y: Float(y))
        var target = graphene_point_t()
        if gtk_widget_compute_point(source, root, &point, &target) != 0 {
            var rectangle = GdkRectangle(x: Int32(target.x), y: Int32(target.y), width: 1, height: 1)
            gtk_popover_set_pointing_to(UnsafeMutableRawPointer(popover).assumingMemoryBound(to: GtkPopover.self), &rectangle)
        }
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        gtk_popover_set_child(UnsafeMutableRawPointer(popover).assumingMemoryBound(to: GtkPopover.self), box)
        let busy = snapshot.operations.contains { $0.workspaceID == workspaceID }
        func addAction(_ kind: String, _ title: String, enabled: Bool = true, payload: [String: String]? = nil) {
            let button = gtk_button_new_with_label(title)!
            gtk_widget_set_name(button, "\(kind)-workspace")
            gtk_widget_set_sensitive(button, enabled ? 1 : 0)
            connectAction(button, context: WorkspaceActionContext(window: self, kind: kind,
                payload: payload ?? ["workspace_id": workspaceID]))
            gtk_box_append(UnsafeMutableRawPointer(box).assumingMemoryBound(to: GtkBox.self), button)
        }
        addAction("rename", "Set friendly name…")
        if snapshot.layout.hidden.contains(workspaceID) { addAction("show", "Show") }
        else { addAction("hide", "Hide") }
        if pane(forWorkspace: workspaceID) != nil {
            addAction("new_terminal", "New Terminal", enabled: canMutateTerminal(workspaceID))
            for (kind, label) in [("disconnect", "Disconnect"), ("reconnect", "Reload SSH Session")] {
                addAction(kind, label, enabled: !busy && workspace.state == "Running"
                    && connectionStates[workspaceID] != "disconnecting")
            }
        }
        if let index = visibleWorkspaceIDs.firstIndex(of: workspaceID) {
            addAction("move_up", "Move Up", enabled: index > 0)
            addAction("move_down", "Move Down", enabled: index < visibleWorkspaceIDs.count - 1)
        }
        if workspace.state == "Running", !busy { addAction("open_zed", "Open in Zed", payload: editorPayload(workspaceID)) }
        gtk_popover_popup(UnsafeMutableRawPointer(popover).assumingMemoryBound(to: GtkPopover.self))
    }

    private var visibleWorkspaceIDs: [String] {
        let hidden = Set(snapshot.layout.hidden)
        return SidebarLayout.displayIDs(order: snapshot.layout.order, workspaces: snapshot.workspaces)
            .filter { !hidden.contains($0) }
    }

    private func editorPayload(_ workspace: String) -> [String: String] {
        var payload = ["workspace_id": workspace, "explicit_directory": "false"]
        if let directory = pane(forWorkspace: workspace)?.currentDirectory { payload["directory"] = directory }
        return payload
    }

    fileprivate func performAction(_ kind: String, payload: [String: String]) {
        guard actionsEnabled else { return }
        if kind == "select_terminal" || kind == "close_terminal" {
            guard let workspace = payload["workspace_id"], canMutateTerminal(workspace),
                  let generation = payload["generation"].flatMap(UUID.init(uuidString:)),
                  let pane = payload["pane_id"].flatMap(UUID.init(uuidString:)) else { return }
            let identity = TerminalPaneIdentity(workspaceID: workspace, generation: generation, paneID: pane)
            if kind == "select_terminal" { selectTerminal(identity) }
            else { closeTerminal(identity, reportExit: true) }
        } else if kind == "rename", let workspace = payload["workspace_id"] { beginRename(workspace) }
        else { onCommand?(kind, payload) }
    }

    private func beginRename(_ workspace: String) {
        guard snapshot.workspaces.contains(where: { $0.id == workspace }) else { return }
        if let renameDialog {
            gtk_window_present(UnsafeMutableRawPointer(renameDialog).assumingMemoryBound(to: GtkWindow.self))
            return
        }
        let widget = gtk_dialog_new()!
        _ = g_object_ref_sink(UnsafeMutableRawPointer(widget))
        renameDialog = widget
        let dialog = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkDialog.self)
        let modal = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWindow.self)
        gtk_window_set_title(modal, "Set friendly name")
        gtk_window_set_transient_for(modal, window)
        gtk_window_set_modal(modal, 1)
        gtk_window_set_destroy_with_parent(modal, 1)
        gtk_window_set_default_size(modal, 380, -1)
        let contentWidget = gtk_dialog_get_content_area(dialog)!
        let content = UnsafeMutableRawPointer(contentWidget).assumingMemoryBound(to: GtkBox.self)
        for setMargin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom, gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            setMargin(contentWidget, 16)
        }
        gtk_box_set_spacing(content, 12)
        gtk_box_append(content, gtk_label_new("Workspace \(workspace)")!)
        let entry = gtk_entry_new()!
        gtk_widget_set_name(entry, "workspace-friendly-name")
        gtk_editable_set_text(OpaquePointer(entry), snapshot.layout.aliases[workspace] ?? "")
        gtk_entry_set_activates_default(UnsafeMutableRawPointer(entry).assumingMemoryBound(to: GtkEntry.self), 1)
        gtk_box_append(content, entry)
        _ = gtk_dialog_add_button(dialog, "Cancel", GTK_RESPONSE_CANCEL.rawValue)
        _ = gtk_dialog_add_button(dialog, "Set friendly name", GTK_RESPONSE_ACCEPT.rawValue)
        gtk_dialog_set_default_response(dialog, GTK_RESPONSE_ACCEPT.rawValue)
        let callback = unsafeBitCast(devspaceLinuxRenameResponse as @convention(c)
            (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Void, to: GCallback.self)
        let destroy: GClosureNotify = { data, _ in
            if let data { Unmanaged<RenameContext>.fromOpaque(data).release() }
        }
        _ = g_signal_connect_data(UnsafeMutableRawPointer(widget), "response", callback,
            Unmanaged.passRetained(RenameContext(window: self, workspace: workspace, entry: entry)).toOpaque(),
            destroy, GConnectFlags(rawValue: 0))
        gtk_window_present(modal)
        _ = gtk_widget_grab_focus(entry)
    }

    fileprivate func finishRename(workspace: String, entry: UnsafeMutablePointer<GtkWidget>, response: Int32) {
        guard let dialog = renameDialog else { return }
        let name = String(cString: gtk_editable_get_text(OpaquePointer(entry))).trimmingCharacters(in: .whitespaces)
        renameDialog = nil
        gtk_window_destroy(UnsafeMutableRawPointer(dialog).assumingMemoryBound(to: GtkWindow.self))
        g_object_unref(UnsafeMutableRawPointer(dialog))
        if response == GTK_RESPONSE_ACCEPT.rawValue, actionsEnabled, snapshot.workspaces.contains(where: { $0.id == workspace }) {
            onCommand?("alias", ["workspace_id": workspace, "name": name])
        }
    }

    private func dismissWorkspaceMenu() {
        guard let menu = workspaceMenu else { return }
        workspaceMenu = nil
        gtk_popover_popdown(UnsafeMutableRawPointer(menu).assumingMemoryBound(to: GtkPopover.self))
        if gtk_widget_get_parent(menu) != nil { gtk_widget_unparent(menu) }
        g_object_unref(UnsafeMutableRawPointer(menu))
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

private final class RenameContext {
    weak var window: WorkspaceWindow?
    let workspace: String
    let entry: UnsafeMutablePointer<GtkWidget>
    init(window: WorkspaceWindow, workspace: String, entry: UnsafeMutablePointer<GtkWidget>) {
        self.window = window
        self.workspace = workspace
        self.entry = entry
    }
}

@_cdecl("devspace_linux_rename_response")
private func devspaceLinuxRenameResponse(_ dialog: UnsafeMutableRawPointer?, _ response: Int32, _ data: UnsafeMutableRawPointer?) {
    guard let data else { return }
    let context = Unmanaged<RenameContext>.fromOpaque(data).takeUnretainedValue()
    context.window?.finishRename(workspace: context.workspace, entry: context.entry, response: response)
}

@_cdecl("devspace_linux_workspace_action")
private func devspaceLinuxWorkspaceAction(_ button: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?) {
    guard let data else { return }
    let context = Unmanaged<WorkspaceActionContext>.fromOpaque(data).takeUnretainedValue()
    guard let button, gtk_widget_is_sensitive(button.assumingMemoryBound(to: GtkWidget.self)) != 0 else { return }
    if let popover = gtk_widget_get_ancestor(button.assumingMemoryBound(to: GtkWidget.self), gtk_popover_get_type()) {
        gtk_popover_popdown(UnsafeMutableRawPointer(popover).assumingMemoryBound(to: GtkPopover.self))
    }
    context.window?.performAction(context.kind, payload: context.payload)
    _ = button
}

@_cdecl("devspace_linux_workspace_menu")
private func devspaceLinuxWorkspaceMenu(_ gesture: UnsafeMutableRawPointer?, _ count: Int32,
                                        _ x: Double, _ y: Double, _ data: UnsafeMutableRawPointer?) {
    guard let gesture, let data,
          let source = gtk_event_controller_get_widget(OpaquePointer(gesture)) else { return }
    let context = Unmanaged<WorkspaceActionContext>.fromOpaque(data).takeUnretainedValue()
    if let workspace = context.payload["workspace_id"] {
        context.window?.showWorkspaceMenu(workspace, relativeTo: source, x: x, y: y)
    }
}

@_cdecl("devspace_linux_window_key_pressed")
private func devspaceLinuxWindowKeyPressed(_ controller: UnsafeMutableRawPointer?, _ keyval: UInt32,
                                          _ keycode: UInt32, _ state: UInt32, _ data: UnsafeMutableRawPointer?) -> Int32 {
    guard let data else { return 0 }
    let context = Unmanaged<WorkspaceActionContext>.fromOpaque(data).takeUnretainedValue()
    return context.window?.handleShortcut(keyval: keyval, modifiers: GdkModifierType(rawValue: state)) == true ? 1 : 0
}
