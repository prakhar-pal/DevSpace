import Foundation
import DevSpaceCore
import CGTK
import CVTE

@main
struct WorkspaceWindowTests {
    static func main() {
        do {
            gtk_init()
            let themeProvider = gtk_css_provider_new()!
            let display = gdk_display_get_default()!
            gtk_css_provider_load_from_string(themeProvider,
                "@define-color theme_base_color #112233; @define-color theme_text_color #eeeeee;")
            gtk_style_context_add_provider_for_display(
                display, OpaquePointer(UnsafeMutableRawPointer(themeProvider)),
                guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
            )
            defer {
                gtk_style_context_remove_provider_for_display(display, OpaquePointer(UnsafeMutableRawPointer(themeProvider)))
                g_object_unref(UnsafeMutableRawPointer(themeProvider))
            }
            let application = gtk_application_new("com.prakharp.devspace.test", GApplicationFlags(rawValue: 0))!
            var registrationError: UnsafeMutablePointer<GError>?
            guard g_application_register(
                UnsafeMutableRawPointer(application).assumingMemoryBound(to: GApplication.self),
                nil,
                &registrationError
            ) != 0 else {
                throw TestFailure("GTK application registration failed")
            }

            if CommandLine.arguments.dropFirst().contains("lifecycle") {
                try testLifecycleControls(application)
                g_object_unref(UnsafeMutableRawPointer(application))
                return
            }

            let window = WorkspaceWindow(application: application)
            var commands: [(String, [String: String]?)] = []
            window.onCommand = { kind, payload in commands.append((kind, payload)) }
            window.present()
            try expect(window.terminalCount == 0, "empty startup created a terminal")

            let workspace = WorkspaceView(
                id: "fixture-pod", provider: "docker", source: "/tmp/project",
                lastUsed: "", state: "Running", error: nil
            )
            let otherWorkspace = WorkspaceView(
                id: "fixture-pod-2", provider: "docker", source: "/tmp/other",
                lastUsed: "", state: "Running", error: nil
            )
            window.update(WorkspaceControllerSnapshot(
                revision: 1, workspaces: [workspace, otherWorkspace], selectedID: "fixture-pod",
                layout: Layout(), terminalPanes: []
            ))
            let root = gtk_window_get_child(window.window)!
            for title in ["Refresh", "Select", "Open", "Reconnect", "Stop", "Start"] {
                try expect(!containsButton(title, in: root), "sidebar retains extra action: \(title)")
            }
            let sidebarWidget = gtk_widget_get_first_child(root)!
            let rows = gtk_widget_get_first_child(sidebarWidget)!
            let firstRow = gtk_widget_get_first_child(rows)!
            let secondRow = gtk_widget_get_next_sibling(firstRow)!
            try expect(gtk_widget_get_next_sibling(secondRow) == nil, "sidebar did not show both workspaces")
            _ = gtk_widget_activate(gtk_widget_get_first_child(secondRow)!)
            try expect(pumpUntil { commands.contains { $0.0 == "select" && $0.1?["workspace_id"] == otherWorkspace.id } },
                       "clicking a workspace row did not select it")
            try expect(!commands.contains { $0.0 == "connect" }, "row selection opened another terminal")
            let generation = UUID()
            let paneID = UUID()
            let identity = TerminalPaneIdentity(workspaceID: workspace.id, generation: generation, paneID: paneID)
            window.apply(try terminalEffect(
                kind: "terminal_error", workspace: otherWorkspace.id, generation: UUID(), pane: UUID(),
                message: "SSH connection failed: readinessTimedOut"
            ))
            let status = gtk_widget_get_next_sibling(rows)!
            try window.apply(terminalEffect(
                kind: "terminal_launch", workspace: workspace.id, generation: generation, pane: paneID,
                executable: "/bin/sh",
                arguments: ["-c", "printf 'ready\\n'; while IFS= read -r input; do printf 'received:%s\\n' \"$input\"; done; exec sleep 30"]
            ))
            try expect(pumpUntil { window.pane(for: identity)?.text.contains("ready") == true },
                       "the validated terminal launch did not render output")
            guard let originalPane = window.pane(for: identity) else {
                throw TestFailure("terminal pane was not retained")
            }
            var background = GdkRGBA()
            vte_terminal_get_color_background_for_draw(
                UnsafeMutableRawPointer(originalPane.widget).assumingMemoryBound(to: VteTerminal.self), &background
            )
            try expect(abs(background.red - 17.0 / 255) < 0.01 && abs(background.blue - 51.0 / 255) < 0.01,
                       "VTE background does not follow the GTK theme")
            let terminalPID = originalPane.childPID
            gtk_css_provider_load_from_string(themeProvider,
                "@define-color theme_base_color #fafafa; @define-color theme_text_color #202020;")
            let settings = UnsafeMutableRawPointer(gtk_settings_get_default()!).assumingMemoryBound(to: GObject.self)
            var preference = GValue()
            _ = g_value_init(&preference, g_type_from_name("gboolean"))
            g_object_get_property(settings, "gtk-application-prefer-dark-theme", &preference)
            g_value_set_boolean(&preference, g_value_get_boolean(&preference) == 0 ? 1 : 0)
            g_object_set_property(settings, "gtk-application-prefer-dark-theme", &preference)
            g_value_unset(&preference)
            try expect(pumpUntil {
                vte_terminal_get_color_background_for_draw(
                    UnsafeMutableRawPointer(originalPane.widget).assumingMemoryBound(to: VteTerminal.self), &background
                )
                return abs(background.red - 250.0 / 255) < 0.01
            }, "theme change did not update the existing terminal")
            try expect(originalPane.childPID == terminalPID && originalPane.text.contains("ready"),
                       "theme change restarted the terminal or erased its contents")
            try expect(String(cString: gtk_label_get_text(OpaquePointer(status))) == "SSH connection failed: readinessTimedOut",
                       "another workspace's successful connection erased the timeout")
            let otherIdentity = TerminalPaneIdentity(
                workspaceID: otherWorkspace.id, generation: UUID(), paneID: UUID()
            )
            window.apply(try terminalEffect(
                kind: "terminal_launch", workspace: otherWorkspace.id,
                generation: otherIdentity.generation, pane: otherIdentity.paneID,
                executable: "/bin/sh", arguments: ["-c", "printf 'background-ready\\n'; exec sleep 30"]
            ))
            try expect(pumpUntil { window.pane(for: otherIdentity)?.text.contains("background-ready") == true },
                       "background workspace terminal did not connect")
            let otherPane = window.pane(for: otherIdentity)!
            try expect(String(cString: gtk_label_get_text(OpaquePointer(status))).isEmpty,
                       "recovered workspace retains a stale SSH timeout in the sidebar")
            try expect(gtk_widget_get_mapped(originalPane.widget) != 0 && gtk_widget_get_mapped(otherPane.widget) == 0,
                       "multiple workspace terminals are visible at once")
            window.update(WorkspaceControllerSnapshot(
                revision: 1, workspaces: [workspace, otherWorkspace], selectedID: otherWorkspace.id,
                layout: Layout(), terminalPanes: []
            ))
            try expect(pumpUntil { gtk_widget_get_mapped(otherPane.widget) != 0 },
                       "selecting another workspace did not reveal its terminal")
            try expect(gtk_widget_get_mapped(originalPane.widget) == 0 && window.pane(for: identity) === originalPane,
                       "switching workspace did not preserve the hidden terminal")
            window.closeTerminal(otherIdentity)
            window.update(WorkspaceControllerSnapshot(
                revision: 1, workspaces: [workspace, otherWorkspace], selectedID: workspace.id,
                layout: Layout(), terminalPanes: []
            ))
            try expect(gtk_widget_get_allocated_height(originalPane.widget) > 500,
                       "the VTE widget did not expand to fill the terminal pane")
            let sidebar = gtk_widget_get_first_child(gtk_window_get_child(window.window))!
            var baselineMinimum: Int32 = 0
            var baselineNatural: Int32 = 0
            gtk_widget_measure(sidebar, GTK_ORIENTATION_HORIZONTAL, -1, &baselineMinimum, &baselineNatural, nil, nil)
            try expect(baselineNatural < 220, "short workspace names still reserve a wide sidebar: \(baselineNatural)")
            window.update(WorkspaceControllerSnapshot(
                revision: 2, workspaces: [workspace, otherWorkspace], selectedID: workspace.id,
                layout: Layout(aliases: [workspace.id: String(repeating: "LongProject", count: 10)]), terminalPanes: []
            ))
            var nameMinimum: Int32 = 0
            var nameNatural: Int32 = 0
            gtk_widget_measure(sidebar, GTK_ORIENTATION_HORIZONTAL, -1, &nameMinimum, &nameNatural, nil, nil)
            window.setStatus("SSH connection failed for fixture-pod. Check the workspace connection and try again.")
            var minimumWidth: Int32 = 0
            var naturalWidth: Int32 = 0
            gtk_widget_measure(sidebar, GTK_ORIENTATION_HORIZONTAL, -1, &minimumWidth, &naturalWidth, nil, nil)
            try expect(naturalWidth < 280 && minimumWidth <= nameMinimum && naturalWidth <= nameNatural,
                       "long sidebar text widened minimum=\(minimumWidth)/\(nameMinimum) natural=\(naturalWidth)/\(nameNatural)")
            try expect(pumpUntil {
                gtk_widget_get_allocated_width(originalPane.widget) >=
                    gtk_widget_get_width(gtk_window_get_child(window.window)) - naturalWidth - 2
            }, "the sidebar consumed expansion space intended for the terminal")
            let originalWidget = originalPane.widget
            originalPane.resize(columns: 100, rows: 30)
            try expect(pumpUntil {
                originalPane.ptySize?.columns == 100 && originalPane.ptySize?.rows == 30
            }, "resizing the VTE widget did not resize its PTY")

            guard let clipboard = gdk_display_get_clipboard(gdk_display_get_default()!) else {
                throw TestFailure("GTK did not provide the private test clipboard")
            }
            gdk_clipboard_set_text(clipboard, "from-shortcut\n")
            let terminalControl = GdkModifierType(rawValue: GDK_CONTROL_MASK.rawValue)
            try expect(!originalPane.handleKey(keyval: UInt32(GDK_KEY_c), modifiers: terminalControl),
                       "plain Ctrl+C was intercepted instead of reaching the shell")
            let copyPasteModifiers = GdkModifierType(
                rawValue: GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue
            )
            try expect(originalPane.handleKey(keyval: UInt32(GDK_KEY_v), modifiers: copyPasteModifiers),
                       "Ctrl+Shift+V was not handled by the terminal")
            try expect(pumpUntil { originalPane.text.contains("received:from-shortcut") },
                       "Ctrl+Shift+V did not paste private clipboard text into the VTE child")
            gdk_clipboard_set_text(clipboard, "must-not-paste-hidden\n")
            _ = originalPane.handleKey(keyval: UInt32(GDK_KEY_v), modifiers: copyPasteModifiers)
            window.update(WorkspaceControllerSnapshot(
                revision: 2, workspaces: [workspace, otherWorkspace], selectedID: otherWorkspace.id,
                layout: Layout(), terminalPanes: []
            ))
            _ = pumpUntil(timeout: 0.3) { false }
            try expect(!originalPane.text.contains("must-not-paste-hidden"),
                       "late clipboard callback pasted into the hidden workspace")
            window.update(WorkspaceControllerSnapshot(
                revision: 2, workspaces: [workspace, otherWorkspace], selectedID: workspace.id,
                layout: Layout(), terminalPanes: []
            ))
            gdk_clipboard_set_text(clipboard, "λ界🙂\nsecond-line\n")
            _ = originalPane.handleKey(keyval: UInt32(GDK_KEY_v), modifiers: copyPasteModifiers)
            try expect(pumpUntil { originalPane.text.contains("received:λ界🙂") && originalPane.text.contains("received:second-line") },
                       "Unicode/multiline clipboard text was not pasted intact")
            vte_terminal_select_all(UnsafeMutableRawPointer(originalPane.widget).assumingMemoryBound(to: VteTerminal.self))
            try expect(originalPane.handleKey(keyval: UInt32(GDK_KEY_c), modifiers: copyPasteModifiers),
                       "Ctrl+Shift+C was not handled by the terminal")
            let copiedText = try readClipboardText(clipboard)
            try expect(copiedText.contains("received:from-shortcut"),
                       "Ctrl+Shift+C did not copy the VTE selection to the private clipboard")

            let bracketed = TerminalPaneIdentity(workspaceID: otherWorkspace.id, generation: UUID(), paneID: UUID())
            window.update(WorkspaceControllerSnapshot(
                revision: 2, workspaces: [workspace, otherWorkspace], selectedID: otherWorkspace.id,
                layout: Layout(), terminalPanes: []
            ))
            window.apply(try terminalEffect(
                kind: "terminal_launch", workspace: otherWorkspace.id, generation: bracketed.generation,
                pane: bracketed.paneID, executable: "/bin/sh", arguments: ["-c",
                    "stty raw -echo; printf '\\033[?2004hBRACKET_READY\\n'; dd bs=1 count=14 2>/dev/null | od -An -tx1; exec sleep 30"]
            ))
            guard let bracketedPane = window.pane(for: bracketed) else { throw TestFailure("bracketed-paste probe failed to launch") }
            try expect(pumpUntil { bracketedPane.text.contains("BRACKET_READY") }, "bracketed-paste probe was not ready")
            gdk_clipboard_set_text(clipboard, "λ")
            _ = bracketedPane.handleKey(keyval: UInt32(GDK_KEY_v), modifiers: copyPasteModifiers)
            try expect(pumpUntil {
                bracketedPane.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    .contains("1b 5b 32 30 30 7e ce bb 1b 5b 32 30 31 7e")
            }, "clipboard text did not retain VTE bracketed-paste framing")
            window.closeTerminal(bracketed)
            window.update(WorkspaceControllerSnapshot(
                revision: 2, workspaces: [workspace, otherWorkspace], selectedID: workspace.id,
                layout: Layout(), terminalPanes: []
            ))

            let pixel = Data([255, 0, 0, 255])
            let imageBytes = pixel.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }!
            defer { g_bytes_unref(imageBytes) }
            guard let texture = gdk_memory_texture_new(1, 1, GDK_MEMORY_R8G8B8A8, imageBytes, 4) else {
                throw TestFailure("private clipboard texture could not be created")
            }
            gdk_clipboard_set_texture(clipboard, texture)
            g_object_unref(UnsafeMutableRawPointer(texture))
            try expect(originalPane.handleKey(keyval: UInt32(GDK_KEY_v), modifiers: copyPasteModifiers),
                       "Ctrl+Shift+V did not handle an image clipboard")
            try expect(pumpUntil {
                commands.contains { $0.0 == "paste_image" }
            }, "Ctrl+Shift+V did not route the clipboard image to the backend")
            let imagePayload = commands.first { $0.0 == "paste_image" }?.1 ?? [:]
            guard let imagePath = imagePayload["source_path"] else {
                throw TestFailure("clipboard image request did not include its temporary PNG")
            }
            defer { try? FileManager.default.removeItem(atPath: imagePath) }
            var imageInfo = stat()
            try expect(lstat(imagePath, &imageInfo) == 0, "clipboard PNG was not written to disk")
            try expect((imageInfo.st_mode & mode_t(0o777)) == 0o600,
                       "clipboard PNG permissions were not private")
            try expect(try Data(contentsOf: URL(fileURLWithPath: imagePath))
                .starts(with: Data([137, 80, 78, 71, 13, 10, 26, 10])),
                       "clipboard image upload source was not a PNG")

            try expect(originalPane.handleKey(keyval: UInt32(GDK_KEY_r), modifiers: copyPasteModifiers),
                       "Ctrl+Shift+R was not handled by the terminal")
            try expect(commands.contains {
                $0.0 == "reconnect" && $0.1? ["workspace_id"] == workspace.id
            }, "Ctrl+Shift+R did not request a reconnect for the bound workspace")

            window.update(WorkspaceControllerSnapshot(
                revision: 2, workspaces: [workspace], selectedID: workspace.id,
                layout: Layout(), terminalPanes: []
            ))
            try expect(window.pane(for: identity)?.widget == originalWidget,
                       "a later workspace snapshot recreated the terminal widget")

            let staleGeneration = UUID()
            try window.apply(terminalEffect(
                kind: "terminal_inject", workspace: workspace.id, generation: staleGeneration,
                pane: paneID, message: "stale-input\n"
            ))
            try window.apply(terminalEffect(
                kind: "terminal_close", workspace: workspace.id, generation: staleGeneration, pane: paneID
            ))
            try expect(window.terminalCount == 1, "a stale close removed the live pane")
            try expect(!originalPane.text.contains("stale-input"), "a stale inject reached the live PTY")

            try window.apply(terminalEffect(
                kind: "terminal_inject", workspace: workspace.id, generation: generation,
                pane: paneID, message: "from-test\n"
            ))
            try expect(pumpUntil { originalPane.text.contains("received:from-test") },
                       "a current inject did not reach the VTE child")

            let callbackData = Unmanaged.passUnretained(originalPane).toOpaque()
            let retainedWidget = UnsafeMutableRawPointer(originalWidget)
            _ = g_object_ref(retainedWidget)
            defer { g_object_unref(retainedWidget) }
            try expect(g_signal_handler_find(retainedWidget, .SIGNAL_MATCH_DATA, 0, 0, nil, nil, callbackData) != 0,
                       "terminal lifecycle callbacks were not registered")
            gdk_clipboard_set_text(clipboard, "must-not-paste-closed\n")
            _ = originalPane.handleKey(keyval: UInt32(GDK_KEY_v), modifiers: copyPasteModifiers)
            window.closeTerminal(identity, reportExit: true)
            _ = pumpUntil(timeout: 0.3) { false }
            try expect(!originalPane.text.contains("must-not-paste-closed"),
                       "late clipboard callback pasted into a disposed terminal")
            try expect(g_signal_handler_find(retainedWidget, .SIGNAL_MATCH_DATA, 0, 0, nil, nil, callbackData) == 0,
                       "disposed terminal retains callbacks into its Swift pane")
            try expect(window.terminalCount == 0, "closing the terminal did not remove its widget")
            try expect(workspace.state == "Running", "closing a terminal changed workspace lifecycle state")
            try expect(commands.contains { $0.0 == "terminal_exit" }, "terminal close was not reported")
            try expect(!commands.contains { ["stop", "delete", "recreate"].contains($0.0) },
                       "closing a terminal issued a workspace lifecycle action")

            window.apply(try terminalEffect(
                kind: "terminal_launch", workspace: workspace.id, generation: generation, pane: UUID(),
                executable: "/bin/sh", arguments: ["-c", "exec sleep 30"]
            ))
            try expect(window.terminalCount == 0, "a launch from a retired connection generation spawned a shell")

            let replacement = TerminalPaneIdentity(workspaceID: workspace.id, generation: UUID(), paneID: UUID())
            window.apply(try terminalEffect(
                kind: "terminal_launch", workspace: workspace.id, generation: replacement.generation,
                pane: replacement.paneID, executable: "/bin/sh", arguments: ["-c", "exec sleep 30"]
            ))
            try expect(window.terminalCount == 1, "a fresh connection generation could not launch")
            let silentPane = window.pane(for: replacement)!
            silentPane.resize(columns: 90, rows: 25)
            _ = gtk_widget_grab_focus(silentPane.widget)
            _ = pumpUntil(timeout: 0.2) { false }
            try expect(!commands.contains {
                $0.0 == "terminal_output" && $0.1?["pane_id"] == replacement.paneID.uuidString.lowercased()
            }, "mapping/resizing a silent VTE child falsely confirmed SSH output")
            window.closeTerminal(replacement)

            gtk_window_destroy(window.window)
            print("workspace-window snapshot-identity=stable stale-generation=rejected close=workspace-preserved")
            g_object_unref(UnsafeMutableRawPointer(application))
        } catch {
            fputs("WorkspaceWindowTests: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func terminalEffect(
        kind: String, workspace: String, generation: UUID, pane: UUID,
        executable: String? = nil, arguments: [String] = [], message: String? = nil
    ) throws -> WorkspaceTerminalEffect {
        let object: [String: Any] = [
            "kind": kind,
            "workspaceID": workspace,
            "generation": generation.uuidString,
            "paneID": pane.uuidString,
            "executable": executable as Any? ?? NSNull(),
            "arguments": arguments,
            "message": message as Any? ?? NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(WorkspaceTerminalEffect.self, from: data)
    }

    private static func testLifecycleControls(_ application: UnsafeMutablePointer<GtkApplication>) throws {
        let window = WorkspaceWindow(application: application)
        defer { gtk_window_destroy(window.window) }
        var commands: [(String, [String: String]?)] = []
        window.onCommand = { commands.append(($0, $1)) }
        window.present()
        func update(_ state: String, operations: String = "[]") throws {
            let json = """
            {"revision":1,"workspaces":[{"id":"pod","provider":"test","source":"/tmp","lastUsed":"","state":"\(state)"}],
             "selectedID":"pod","layout":{},"terminalPanes":[],"badges":[],"operations":\(operations)}
            """
            window.update(try JSONDecoder().decode(WorkspaceControllerSnapshot.self, from: Data(json.utf8)))
            while g_main_context_iteration(nil, 0) != 0 {}
        }
        let root = gtk_window_get_child(window.window)!
        try update("Stopped")
        try expect(commands.isEmpty, "selecting a stopped workspace issued a lifecycle command")
        guard let start = namedWidget("start-workspace", in: root) else {
            throw TestFailure("stopped workspace has no Start action")
        }
        _ = gtk_widget_activate(start)
        try expect(pumpUntil { commands.contains { $0.0 == "start" && $0.1?["workspace_id"] == "pod" } },
                   "Start did not target the selected workspace")
        try update("Stopped", operations: """
        [{"id":"request-42","kind":"start","workspaceID":"pod","state":"running","output":"Preparing λ界🙂"}]
        """)
        try expect(containsLabel("Preparing λ界🙂", in: root), "operation output is not visible")
        try expect(namedWidget("start-workspace", in: root) == nil, "busy workspace offers another Start")
        guard let cancel = namedWidget("cancel-operation", in: root) else { throw TestFailure("start has no Cancel") }
        _ = gtk_widget_activate(cancel)
        try expect(pumpUntil { commands.contains { $0.0 == "cancel" && $0.1?["request_id"] == "request-42" } },
                   "Cancel did not identify its owned operation")
        try update("Running")
        guard let stop = namedWidget("stop-workspace", in: root) else { throw TestFailure("running workspace has no Stop") }
        window.setActionsEnabled(false)
        try expect(gtk_widget_is_sensitive(stop) == 0, "backend failure leaves Stop enabled")
        window.setActionsEnabled(true)
        _ = gtk_widget_activate(stop)
        try expect(pumpUntil { commands.contains { $0.0 == "stop" && $0.1?["workspace_id"] == "pod" } },
                   "Stop did not target the selected workspace")
        window.setStatus("Provider rejected stop")
        try update("Running")
        try expect(containsLabel("Provider rejected stop", in: root), "polling erased the operation failure")
        try update("Unknown")
        try expect(namedWidget("start-workspace", in: root) == nil, "unknown state offers Start")
        try expect(namedWidget("stop-workspace", in: root) == nil, "unknown state offers Stop")
        print("start-stop=state-aware operation=visible cancellation=targeted")
    }

    private static func namedWidget(_ name: String, in widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget>? {
        if String(cString: gtk_widget_get_name(widget)) == name { return widget }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let match = namedWidget(name, in: current) { return match }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }

    private static func containsLabel(_ text: String, in widget: UnsafeMutablePointer<GtkWidget>) -> Bool {
        if String(cString: gtk_widget_get_css_name(widget)) == "label",
           String(cString: gtk_label_get_text(OpaquePointer(widget))).contains(text) { return true }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if containsLabel(text, in: current) { return true }
            child = gtk_widget_get_next_sibling(current)
        }
        return false
    }

    private static func pumpUntil(timeout: TimeInterval = 4, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate()
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(message) }
    }

    private static func readClipboardText(_ clipboard: OpaquePointer) throws -> String {
        let context = ClipboardReadContext()
        let callback = unsafeBitCast(
            clipboardReadFinished as @convention(c)
                (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
            to: GAsyncReadyCallback.self
        )
        gdk_clipboard_read_text_async(clipboard, nil, callback, Unmanaged.passRetained(context).toOpaque())
        try expect(pumpUntil { context.finished }, "private clipboard read timed out")
        return context.text ?? ""
    }

    private static func containsButton(_ title: String, in widget: UnsafeMutablePointer<GtkWidget>) -> Bool {
        if String(cString: gtk_widget_get_css_name(widget)) == "button",
           let label = widget.withMemoryRebound(to: GtkButton.self, capacity: 1) { gtk_button_get_label($0) },
           String(cString: label) == title {
            return true
        }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if containsButton(title, in: current) { return true }
            child = gtk_widget_get_next_sibling(current)
        }
        return false
    }

    private static func countButtons(_ title: String, in widget: UnsafeMutablePointer<GtkWidget>) -> Int {
        let ownMatch = String(cString: gtk_widget_get_css_name(widget)) == "button"
            && widget.withMemoryRebound(to: GtkButton.self, capacity: 1) { button in
                guard let label = gtk_button_get_label(button) else { return false }
                return String(cString: label) == title
            }
        var count = ownMatch ? 1 : 0
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            count += countButtons(title, in: current)
            child = gtk_widget_get_next_sibling(current)
        }
        return count
    }
}

private final class ClipboardReadContext {
    var text: String?
    var finished = false
}

@_cdecl("devspace_linux_test_clipboard_read_finished")
private func clipboardReadFinished(
    _ source: UnsafeMutableRawPointer?, _ result: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?
) {
    guard let data else { return }
    let context = Unmanaged<ClipboardReadContext>.fromOpaque(data).takeRetainedValue()
    if let source, let result {
        let text = gdk_clipboard_read_text_finish(
            OpaquePointer(source), OpaquePointer(result), nil
        )
        if let text {
            context.text = String(cString: text)
            g_free(UnsafeMutableRawPointer(text))
        }
    }
    context.finished = true
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
