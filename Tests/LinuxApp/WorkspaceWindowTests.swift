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
            if CommandLine.arguments.dropFirst().contains("scrolling") {
                try testSidebarScrolling(application)
                g_object_unref(UnsafeMutableRawPointer(application))
                return
            }
            if CommandLine.arguments.dropFirst().contains("organization") {
                try testWorkspaceOrganization(application)
                g_object_unref(UnsafeMutableRawPointer(application))
                return
            }
            if CommandLine.arguments.dropFirst().contains("visibility") {
                try testWorkspaceVisibility(application)
                g_object_unref(UnsafeMutableRawPointer(application))
                return
            }
            if CommandLine.arguments.dropFirst().contains("tabs") {
                try testTerminalTabs(application)
                g_object_unref(UnsafeMutableRawPointer(application))
                return
            }

            let window = WorkspaceWindow(application: application)
            var commands: [(String, [String: String]?)] = []
            defer {
                for command in commands where command.0 == "paste_image" {
                    if let path = command.1?["source_path"] { try? FileManager.default.removeItem(atPath: path) }
                }
            }
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
            let rows = namedWidget("workspace-rows", in: sidebarWidget)!
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
            let status = gtk_widget_get_next_sibling(gtk_widget_get_first_child(sidebarWidget)!)!
            try window.apply(terminalEffect(
                kind: "terminal_launch", workspace: workspace.id, generation: generation, pane: paneID,
                executable: "/bin/sh",
                arguments: ["-c", "printf 'ready\\n\\033]7;file://remote/tmp/a%%20b/%%CE%%B1\\007'; while IFS= read -r input; do printf 'received:%s\\n' \"$input\"; done; exec sleep 30"]
            ))
            try expect(pumpUntil { window.pane(for: identity)?.text.contains("ready") == true },
                       "the validated terminal launch did not render output")
            guard let originalPane = window.pane(for: identity) else {
                throw TestFailure("terminal pane was not retained")
            }
            let appModifiers = GdkModifierType(rawValue: GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue)
            try expect(pumpUntil { originalPane.currentDirectory == "/tmp/a b/α" },
                       "OSC 7 directory was not decoded for editor targeting")
            try expect(commands.contains { $0.0 == "terminal_directory" && $0.1?["directory"] == "/tmp/a b/α" },
                       "directory change was not reported with its pane identity")
            try expect(!window.handleShortcut(keyval: UInt32(GDK_KEY_c), modifiers: GDK_CONTROL_MASK),
                       "app shortcut routing swallowed terminal Ctrl+C")
            try expect(window.handleShortcut(keyval: UInt32(GDK_KEY_2), modifiers: appModifiers),
                       "workspace keyboard selection is missing")
            try expect(commands.last?.0 == "select" && commands.last?.1?["workspace_id"] == otherWorkspace.id,
                       "workspace shortcut selected the wrong id")
            try expect(window.handleShortcut(keyval: UInt32(GDK_KEY_o), modifiers: appModifiers),
                       "Open in Zed shortcut is missing")
            try expect(commands.last?.0 == "open_zed" && commands.last?.1?["workspace_id"] == workspace.id,
                       "editor shortcut did not target the selected workspace")
            try expect(commands.last?.1?["directory"] == "/tmp/a b/α", "editor shortcut lost the active folder")
            try expect(commands.last?.1?["explicit_directory"] == "false",
                       "keyboard-inferred folder disabled the normal editor fallback")
            try expect(window.handleShortcut(keyval: UInt32(GDK_KEY_b), modifiers: appModifiers),
                       "sidebar toggle shortcut is missing")
            let shortcutSidebar = gtk_widget_get_first_child(gtk_window_get_child(window.window))!
            try expect(gtk_widget_get_visible(shortcutSidebar) == 0, "sidebar toggle did not hide it")
            _ = window.handleShortcut(keyval: UInt32(GDK_KEY_b), modifiers: appModifiers)
            try expect(gtk_widget_get_visible(shortcutSidebar) != 0, "sidebar toggle did not restore it")
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
            var requestedMinimum: Int32 = -1
            gtk_widget_get_size_request(sidebar, &requestedMinimum, nil)
            gtk_widget_set_size_request(sidebar, -1, -1)
            gtk_widget_measure(sidebar, GTK_ORIENTATION_HORIZONTAL, -1, &baselineMinimum, &baselineNatural, nil, nil)
            gtk_widget_set_size_request(sidebar, requestedMinimum, -1)
            try expect(requestedMinimum == baselineNatural * 2,
                       "sidebar minimum \(requestedMinimum) is not double its original content width \(baselineNatural)")
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
            try expect(naturalWidth < 560 && minimumWidth <= nameMinimum && naturalWidth <= nameNatural,
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

            let random = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/urandom"))
            let largePixels = random.readData(ofLength: 4100 * 1100 * 4)
            try random.close()
            let largeBytes = largePixels.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }!
            defer { g_bytes_unref(largeBytes) }
            let largeTexture = gdk_memory_texture_new(4100, 1100, GDK_MEMORY_R8G8B8A8, largeBytes, 4100 * 4)!
            gdk_clipboard_set_texture(clipboard, largeTexture)
            g_object_unref(UnsafeMutableRawPointer(largeTexture))
            let imageRequests = commands.filter { $0.0 == "paste_image" }.count
            _ = originalPane.handleKey(keyval: UInt32(GDK_KEY_v), modifiers: copyPasteModifiers)
            _ = pumpUntil(timeout: 0.4) { false }
            try expect(commands.filter { $0.0 == "paste_image" }.count == imageRequests,
                       "frontend created an upload request for a PNG over 16 MiB")
            try expect(containsLabel("16 MiB", in: gtk_window_get_child(window.window)!),
                       "oversized clipboard image has no actionable error")

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
        guard let connect = namedWidget("connect-workspace", in: root) else {
            throw TestFailure("disconnected running workspace has no Connect action")
        }
        _ = gtk_widget_activate(connect)
        try expect(pumpUntil { commands.contains { $0.0 == "connect" && $0.1?["workspace_id"] == "pod" } },
                   "Connect did not target the selected workspace")
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
        window.setConnectionStates(["pod": "connecting"])
        try update("Running")
        try expect(namedWidget("connect-workspace", in: root).map { gtk_widget_is_sensitive($0) == 0 } == true,
                   "in-flight SSH connection still offers another Connect")
        window.setConnectionStates([:])
        try update("Running")
        let identity = TerminalPaneIdentity(workspaceID: "pod", generation: UUID(), paneID: UUID())
        window.apply(try terminalEffect(kind: "terminal_launch", workspace: "pod", generation: identity.generation,
            pane: identity.paneID, executable: "/bin/sh", arguments: ["-c", "printf 'menu-ready\\n'; exec /bin/sleep 30"]))
        try expect(pumpUntil { window.pane(for: identity)?.text.contains("menu-ready") == true }, "menu test shell failed")
        for (name, command) in [("reconnect-workspace", "reconnect"), ("disconnect-workspace", "disconnect")] {
            window.showWorkspaceMenu("pod", relativeTo: root)
            guard let action = namedWidget(name, in: root) else { throw TestFailure("missing session menu action: \(name)") }
            _ = gtk_widget_activate(action)
            try expect(pumpUntil { commands.contains { $0.0 == command && $0.1?["workspace_id"] == "pod" } },
                       "session menu did not target the existing workspace")
        }
        window.closeTerminal(identity)
        try update("Unknown")
        try expect(namedWidget("start-workspace", in: root) == nil, "unknown state offers Start")
        try expect(namedWidget("stop-workspace", in: root) == nil, "unknown state offers Stop")
        print("start-stop=state-aware operation=visible cancellation=targeted")
    }

    private static func testSidebarScrolling(_ application: UnsafeMutablePointer<GtkApplication>) throws {
        let window = WorkspaceWindow(application: application)
        defer { gtk_window_destroy(window.window) }
        let workspaces = (0..<40).map { WorkspaceView(id: "pod-\($0)", provider: "test", source: "", lastUsed: "",
            state: "Stopped", error: nil) }
        window.update(WorkspaceControllerSnapshot(revision: 1, workspaces: workspaces, selectedID: "pod-0",
            layout: Layout(), terminalPanes: []))
        window.present()
        let root = gtk_window_get_child(window.window)!
        guard let scroll = namedWidget("workspace-sidebar-scroll", in: root) else {
            throw TestFailure("long workspace lists have no scrollable sidebar")
        }
        let adjustment = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroll))!
        try expect(pumpUntil { gtk_adjustment_get_upper(adjustment) > gtk_adjustment_get_page_size(adjustment) },
                   "workspace list did not constrain itself to the window height")
        gtk_adjustment_set_value(adjustment, gtk_adjustment_get_upper(adjustment))
        try expect(pumpUntil { gtk_adjustment_get_value(adjustment) > 0 }, "sidebar cannot scroll to lower workspaces")
        var commands: [(String, [String: String]?)] = []
        window.onCommand = { commands.append(($0, $1)) }
        guard let last = namedWidget("select-workspace-pod-39", in: root) else { throw TestFailure("last workspace is absent") }
        _ = gtk_widget_activate(last)
        try expect(pumpUntil { commands.last?.1?["workspace_id"] == "pod-39" }, "scrolled workspace could not be selected")
        try expect(!commands.contains { ["start", "stop"].contains($0.0) }, "scrolling/selection changed workspace lifecycle")
        print("sidebar=scrollable last-workspace=selectable lifecycle=unchanged")
    }

    private static func testWorkspaceOrganization(_ application: UnsafeMutablePointer<GtkApplication>) throws {
        let window = WorkspaceWindow(application: application)
        defer { gtk_window_destroy(window.window) }
        let workspaces = ["pod", "other"].map { WorkspaceView(id: $0, provider: "test", source: "", lastUsed: "",
            state: "Running", error: nil) }
        window.update(WorkspaceControllerSnapshot(revision: 1, workspaces: workspaces, selectedID: "pod",
            layout: Layout(order: ["pod", "other"], aliases: ["pod": "Old name"]), terminalPanes: []))
        window.present()
        var commands: [(String, [String: String]?)] = []
        window.onCommand = { commands.append(($0, $1)) }
        let root = gtk_window_get_child(window.window)!
        try expect(pumpUntil { gtk_widget_get_mapped(root) != 0 }, "organization window did not map")
        window.showWorkspaceMenu("pod", relativeTo: root)
        guard let rename = namedWidget("rename-workspace", in: root) else { throw TestFailure("friendly-name action is missing") }
        _ = gtk_widget_activate(rename)
        let dialog = try waitForDialog(for: window.window)
        defer { g_object_unref(UnsafeMutableRawPointer(dialog)) }
        guard let entry = namedWidget("workspace-friendly-name", in: gtk_window_get_child(dialog)!) else {
            throw TestFailure("friendly-name dialog has no text entry")
        }
        try expect(String(cString: gtk_editable_get_text(OpaquePointer(entry))) == "Old name", "rename did not prefill the saved alias")
        let modifiers = GdkModifierType(rawValue: GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue)
        try expect(!window.handleShortcut(keyval: UInt32(GDK_KEY_2), modifiers: modifiers), "workspace shortcut escaped the modal")
        gtk_editable_set_text(OpaquePointer(entry), " Workspace α ")
        gtk_dialog_response(UnsafeMutableRawPointer(dialog).assumingMemoryBound(to: GtkDialog.self), GTK_RESPONSE_ACCEPT.rawValue)
        try expect(commands.last?.0 == "alias" && commands.last?.1?["workspace_id"] == "pod"
            && commands.last?.1?["name"] == "Workspace α", "rename changed the DevPod ID or lost the Unicode friendly name")
        window.showWorkspaceMenu("pod", relativeTo: root)
        guard let up = namedWidget("move_up-workspace", in: root), let down = namedWidget("move_down-workspace", in: root) else {
            throw TestFailure("workspace ordering actions are missing")
        }
        try expect(gtk_widget_is_sensitive(up) == 0 && gtk_widget_is_sensitive(down) != 0, "reorder boundary actions are incorrect")
        _ = gtk_widget_activate(down)
        try expect(pumpUntil { commands.last?.0 == "move_down" && commands.last?.1?["workspace_id"] == "pod" },
                   "Move Down did not target the workspace ID")
        window.update(WorkspaceControllerSnapshot(revision: 2, workspaces: workspaces, selectedID: "pod",
            layout: Layout(order: ["other", "pod"], aliases: ["pod": "Workspace α"]), terminalPanes: []))
        try expect(containsLabel("Workspace α", in: root), "saved alias did not reach the row")
        let reorder = GdkModifierType(rawValue: modifiers.rawValue | GDK_ALT_MASK.rawValue)
        try expect(window.handleShortcut(keyval: UInt32(GDK_KEY_Up), modifiers: reorder)
            && commands.last?.0 == "move_up", "selected-workspace reorder shortcut is missing")
        try expect(!window.handleShortcut(keyval: UInt32(GDK_KEY_Down), modifiers: reorder), "reorder shortcut exceeded the visible list boundary")
        window.showWorkspaceMenu("pod", relativeTo: root)
        _ = gtk_widget_activate(namedWidget("rename-workspace", in: root)!)
        let cancelled = try waitForDialog(for: window.window)
        defer { g_object_unref(UnsafeMutableRawPointer(cancelled)) }
        let count = commands.count
        gtk_dialog_response(UnsafeMutableRawPointer(cancelled).assumingMemoryBound(to: GtkDialog.self), GTK_RESPONSE_CANCEL.rawValue)
        try expect(commands.count == count, "cancelling rename changed the workspace")
        window.showWorkspaceMenu("pod", relativeTo: root)
        _ = gtk_widget_activate(namedWidget("rename-workspace", in: root)!)
        let failed = try waitForDialog(for: window.window)
        defer { g_object_unref(UnsafeMutableRawPointer(failed)) }
        window.setActionsEnabled(false)
        gtk_dialog_response(UnsafeMutableRawPointer(failed).assumingMemoryBound(to: GtkDialog.self), GTK_RESPONSE_ACCEPT.rawValue)
        try expect(commands.count == count, "backend failure allowed a pending rename to mutate state")
        print("organization=rename-order shortcuts=bounded cancel=nonmutating")
    }

    private static func testTerminalTabs(_ application: UnsafeMutablePointer<GtkApplication>) throws {
        let window = WorkspaceWindow(application: application)
        defer { gtk_window_destroy(window.window) }
        let workspace = WorkspaceView(id: "pod", provider: "test", source: "", lastUsed: "", state: "Running", error: nil)
        window.setConnectionStates(["pod": "connected"])
        window.update(WorkspaceControllerSnapshot(revision: 1, workspaces: [workspace], selectedID: "pod", layout: Layout(), terminalPanes: []))
        window.present()
        let root = gtk_window_get_child(window.window)!
        var commands: [(String, [String: String]?)] = []
        window.onCommand = { commands.append(($0, $1)) }
        let generation = UUID()
        let first = TerminalPaneIdentity(workspaceID: "pod", generation: generation, paneID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!)
        let second = TerminalPaneIdentity(workspaceID: "pod", generation: generation, paneID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        func launch(_ identity: TerminalPaneIdentity, name: String) throws {
            window.apply(try terminalEffect(kind: "terminal_launch", workspace: "pod", generation: generation,
                pane: identity.paneID, executable: "/bin/sh", arguments: ["-c", "printf '\(name)\\n\\033]7;file://remote/tmp/\(name)\\007'; while IFS= read -r input; do printf '\(name):%s\\n' \"$input\"; done"]))
        }
        try launch(first, name: "first")
        try expect(pumpUntil { window.pane(for: first)?.currentDirectory == "/tmp/first" }, "first tab failed to render")
        let firstPane = window.pane(for: first)!
        try expect(namedWidget("terminal-tabs", in: root).map { gtk_widget_get_visible($0) == 0 } ?? true, "single terminal has tab chrome")
        let modifiers = GdkModifierType(rawValue: GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue)
        try expect(window.handleShortcut(keyval: UInt32(GDK_KEY_t), modifiers: modifiers)
            && commands.last?.0 == "new_terminal", "new terminal shortcut is missing")
        try launch(second, name: "second")
        try expect(pumpUntil { window.pane(for: second)?.currentDirectory == "/tmp/second" }, "second tab failed to render")
        let secondPane = window.pane(for: second)!
        firstPane.feed("one\n")
        secondPane.feed("two\n")
        try expect(pumpUntil { firstPane.text.contains("first:one") && secondPane.text.contains("second:two") }, "tab shell round-trips were not independent")
        try expect(!firstPane.text.contains("second:two") && !secondPane.text.contains("first:one"), "input crossed terminal tabs")
        try expect(window.pane(forWorkspace: "pod") === secondPane, "new tab did not become active")
        guard let strip = namedWidget("terminal-tabs", in: root) else { throw TestFailure("multiple terminals have no tab strip") }
        try expect(gtk_widget_get_visible(strip) != 0 && containsButton("first", in: strip) && containsButton("second", in: strip), "tab titles did not follow working directories")
        let firstButton = namedWidget("select-terminal-\(first.paneID.uuidString.lowercased())", in: strip)!
        _ = gtk_widget_activate(firstButton)
        try expect(pumpUntil { window.pane(forWorkspace: "pod") === firstPane }, "clicking the first tab selected the wrong shell")
        try expect(window.handleShortcut(keyval: UInt32(GDK_KEY_o), modifiers: modifiers)
            && commands.last?.1?["directory"] == "/tmp/first", "editor targeting did not follow the active tab")
        try expect(window.handleShortcut(keyval: UInt32(GDK_KEY_Page_Down), modifiers: GDK_CONTROL_MASK)
            && window.pane(forWorkspace: "pod") === secondPane, "next-tab shortcut did not follow creation order")
        try expect(window.handleShortcut(keyval: UInt32(GDK_KEY_Page_Down), modifiers: GDK_CONTROL_MASK)
            && window.pane(forWorkspace: "pod") === firstPane, "tab navigation did not wrap")
        window.update(WorkspaceControllerSnapshot(revision: 2, workspaces: [workspace], selectedID: "pod", layout: Layout(), terminalPanes: []))
        try expect(window.pane(forWorkspace: "pod") === firstPane && window.pane(for: second) === secondPane, "poll recreated a shell or changed the active tab")
        _ = gtk_widget_activate(namedWidget("close-terminal-\(second.paneID.uuidString.lowercased())", in: strip)!)
        try expect(pumpUntil { window.terminalCount == 1 }, "closing one tab did not remove only that shell")
        try expect(window.pane(forWorkspace: "pod") === firstPane && !firstPane.isClosed, "closing a sibling disposed the remaining tab")
        let third = TerminalPaneIdentity(workspaceID: "pod", generation: generation, paneID: UUID())
        try launch(third, name: "third")
        try expect(window.terminalCount == 2, "closing one tab retired the shared connection generation")
        window.closeTerminal(third, reportExit: true)
        window.closeTerminal(first, reportExit: true)
        try expect(commands.filter { $0.0 == "terminal_exit" }.count == 3, "tab closure did not report each shell exit exactly once")
        try expect(!commands.contains { ["connect", "reconnect", "stop", "start"].contains($0.0) }, "tab operations mutated workspace/master lifecycle")
        print("tabs=creation-order active=preserved siblings=independent")
    }

    private static func testWorkspaceVisibility(_ application: UnsafeMutablePointer<GtkApplication>) throws {
        let window = WorkspaceWindow(application: application)
        defer { gtk_window_destroy(window.window) }
        let workspaces = ["visible", "hidden", "selected-hidden"].map {
            WorkspaceView(id: $0, provider: "test", source: "", lastUsed: "", state: "Running", error: nil)
        }
        var revision = 0
        func update(collapsed: Bool) {
            revision += 1
            window.update(WorkspaceControllerSnapshot(revision: UInt64(revision), workspaces: workspaces,
                selectedID: "selected-hidden", layout: Layout(order: workspaces.map(\.id),
                    hidden: ["hidden", "selected-hidden"], hiddenCollapsed: collapsed), terminalPanes: []))
        }
        var commands: [(String, [String: String]?)] = []
        window.onCommand = { commands.append(($0, $1)) }
        update(collapsed: true)
        window.present()
        let root = gtk_window_get_child(window.window)!
        try expect(pumpUntil { gtk_widget_get_mapped(root) != 0 }, "visibility window did not map")
        try expect(namedWidget("select-workspace-hidden", in: root) == nil, "collapsed hidden workspace remains visible")
        try expect(namedWidget("select-workspace-selected-hidden", in: root) != nil, "selected hidden workspace became unreachable")
        let identity = TerminalPaneIdentity(workspaceID: "selected-hidden", generation: UUID(), paneID: UUID())
        window.apply(try terminalEffect(kind: "terminal_launch", workspace: identity.workspaceID,
            generation: identity.generation, pane: identity.paneID, executable: "/bin/sh", arguments: ["-c", "printf ready; exec sleep 30"]))
        try expect(pumpUntil { window.pane(for: identity)?.text.contains("ready") == true }, "hidden workspace terminal failed")
        let pane = window.pane(for: identity)!
        guard let toggle = namedWidget("toggle-hidden-workspaces", in: root) else { throw TestFailure("Hidden toggle is missing") }
        _ = gtk_widget_activate(toggle)
        try expect(pumpUntil { commands.last?.0 == "expand_hidden" }, "Hidden toggle did not expand")
        update(collapsed: false)
        try expect(namedWidget("select-workspace-hidden", in: root) != nil, "expanded hidden workspace is absent")
        try expect(window.pane(for: identity) === pane, "visibility change recreated the terminal")
        window.showWorkspaceMenu("hidden", relativeTo: root)
        guard let show = namedWidget("show-workspace", in: root) else { throw TestFailure("Show action is missing") }
        _ = gtk_widget_activate(show)
        try expect(pumpUntil { commands.last?.0 == "show" && commands.last?.1?["workspace_id"] == "hidden" }, "Show targeted the wrong workspace")
        window.showWorkspaceMenu("visible", relativeTo: root)
        guard let hide = namedWidget("hide-workspace", in: root) else { throw TestFailure("Hide action is missing") }
        _ = gtk_widget_activate(hide)
        try expect(pumpUntil { commands.last?.0 == "hide" && commands.last?.1?["workspace_id"] == "visible" }, "Hide targeted the wrong workspace")
        _ = gtk_widget_activate(namedWidget("toggle-hidden-workspaces", in: root)!)
        try expect(pumpUntil { commands.last?.0 == "collapse_hidden" }, "Hidden toggle did not collapse")
        update(collapsed: true)
        try expect(window.pane(for: identity) === pane, "collapse disposed the selected terminal")
        try expect(!commands.contains { ["connect", "disconnect", "stop", "start"].contains($0.0) }, "visibility changed workspace or SSH lifecycle")
        window.closeTerminal(identity)
        print("visibility=selected-reachable terminal=preserved actions=hide-show")
    }

    private static func activeDialog(for parent: UnsafeMutablePointer<GtkWindow>) -> UnsafeMutablePointer<GtkWindow>? {
        let windows = gtk_window_get_toplevels()!
        for index in 0..<g_list_model_get_n_items(windows) {
            guard let item = g_list_model_get_item(windows, index) else { continue }
            let window = item.assumingMemoryBound(to: GtkWindow.self)
            if gtk_window_get_transient_for(window) == parent { return window }
            g_object_unref(item)
        }
        return nil
    }

    private static func waitForDialog(for parent: UnsafeMutablePointer<GtkWindow>) throws -> UnsafeMutablePointer<GtkWindow> {
        var dialog: UnsafeMutablePointer<GtkWindow>?
        try expect(pumpUntil { dialog = activeDialog(for: parent); return dialog != nil }, "friendly-name dialog did not open")
        return dialog!
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
