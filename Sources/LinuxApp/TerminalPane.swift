import Foundation
import Glibc
import CGTK
import CVTE
import DevSpaceCore

struct TerminalPaneIdentity: Hashable {
    let workspaceID: String
    let generation: UUID
    let paneID: UUID
}

struct LinuxTerminalLaunch {
    let workspaceID: String
    let paneID: UUID
    let generation: UUID
    let executable: String
    let arguments: [String]
    let workingDirectory: String?
    let environment: [String: String]

    init?(kind: String, workspaceID: String, paneID: UUID?, generation: UUID,
          executable: String?, arguments: [String], workingDirectory: String? = nil,
          environment: [String: String] = [:]) {
        guard kind == "terminal_launch", !workspaceID.isEmpty,
              let paneID, let executable, executable.hasPrefix("/"),
              !executable.contains("\0"), !arguments.contains(where: { $0.contains("\0") }),
              arguments.count < 256, workingDirectory?.contains("\0") != true,
              environment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") })
        else { return nil }
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.generation = generation
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

final class TerminalPane {
    private static let drainPropertyName = "vte.ext.devspace.drain"
    // VTE requires extension properties to be installed before any terminals.
    private static let drainProperty = vte_install_termprop(drainPropertyName, VTE_PROPERTY_STRING, VtePropertyFlags(rawValue: 0))
    let launch: LinuxTerminalLaunch
    let identity: TerminalPaneIdentity
    let widget: UnsafeMutablePointer<GtkWidget>
    private let terminal: UnsafeMutablePointer<VteTerminal>
    private let onEvent: (String, [String: String]) -> Void
    private let pty = PTYSession()
    private let inputQueue = DispatchQueue(label: "devspace.terminal.input")
    private var clipboardDecoder = TerminalClipboardDecoder()
    private let drainMarker = UUID().uuidString
    private var pendingExit: Int32?
    private var resizeTick: guint = 0
    private var terminalRows: Int32 = 24
    private var terminalColumns: Int32 = 80
    private(set) var childPID: pid_t?
    private(set) var spawnError: String?
    private(set) var isClosed = false
    private var outputReported = false
    private var exitReported = false
    private var signalConnections: [(UnsafeMutableRawPointer, gulong)] = []

    init?(launch: LinuxTerminalLaunch, onEvent: @escaping (String, [String: String]) -> Void = { _, _ in }) {
        self.launch = launch
        identity = TerminalPaneIdentity(
            workspaceID: launch.workspaceID, generation: launch.generation, paneID: launch.paneID
        )
        self.onEvent = onEvent
        guard Self.drainProperty >= 0 else { return nil }
        widget = vte_terminal_new()!
        terminal = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: VteTerminal.self)
        _ = g_object_ref_sink(UnsafeMutableRawPointer(widget))
        vte_terminal_set_scrollback_lines(terminal, 10_000)
        vte_terminal_set_size(terminal, 80, 24)
        applyTheme()
        connectSignals()

        guard spawn(launch) else {
            dispose()
            return nil
        }
    }

    deinit { dispose() }

    var text: String {
        guard let rawText = vte_terminal_get_text_format(terminal, VTE_FORMAT_TEXT) else { return "" }
        defer { g_free(UnsafeMutableRawPointer(rawText)) }
        return String(cString: rawText)
    }

    var currentDirectory: String? {
        guard !isClosed, let uri = vte_terminal_get_current_directory_uri(terminal),
              let components = URLComponents(string: String(cString: uri)), components.scheme == "file",
              let path = components.percentEncodedPath.removingPercentEncoding,
              path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return path
    }

    func feed(_ text: String) {
        guard !isClosed else { return }
        text.withCString { vte_terminal_feed_child(terminal, $0, Int(text.utf8.count)) }
    }

    @discardableResult
    func handleKey(keyval: UInt32, modifiers: GdkModifierType) -> Bool {
        guard !isClosed else { return false }
        let control = GDK_CONTROL_MASK.rawValue
        let shift = GDK_SHIFT_MASK.rawValue
        let disallowed = GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue
        guard modifiers.rawValue & (control | shift | disallowed) == (control | shift) else { return false }
        switch gdk_keyval_to_lower(keyval) {
        case UInt32(GDK_KEY_c):
            vte_terminal_copy_clipboard_format(terminal, VTE_FORMAT_TEXT)
            return true
        case UInt32(GDK_KEY_v):
            pasteClipboard()
            return true
        case UInt32(GDK_KEY_r):
            onEvent("reconnect", ["workspace_id": identity.workspaceID])
            return true
        default:
            return false
        }
    }

    var ptySize: (rows: Int32, columns: Int32)? {
        guard !isClosed, childPID != nil else { return nil }
        return (terminalRows, terminalColumns)
    }

    fileprivate func applyTheme() {
        guard !isClosed else { return }
        var foreground = GdkRGBA()
        gtk_widget_get_color(widget, &foreground)
        foreground = themeColor("theme_text_color") ?? foreground
        let dark = foreground.red + foreground.green + foreground.blue > 1.5
        var background = themeColor("theme_base_color") ?? themeColor("theme_bg_color")
            ?? GdkRGBA(red: dark ? 0.12 : 1, green: dark ? 0.12 : 1, blue: dark ? 0.12 : 1, alpha: 1)
        foreground.alpha = 1
        background.alpha = 1
        vte_terminal_set_color_foreground(terminal, &foreground)
        vte_terminal_set_color_background(terminal, &background)
        vte_terminal_set_color_cursor(terminal, &foreground)
        vte_terminal_set_color_cursor_foreground(terminal, &background)
        if var highlight = themeColor("theme_selected_bg_color"),
           var highlightText = themeColor("theme_selected_fg_color") {
            vte_terminal_set_color_highlight(terminal, &highlight)
            vte_terminal_set_color_highlight_foreground(terminal, &highlightText)
        } else {
            vte_terminal_set_color_highlight(terminal, nil)
            vte_terminal_set_color_highlight_foreground(terminal, nil)
        }
    }

    private func themeColor(_ name: String) -> GdkRGBA? {
        var color = GdkRGBA()
        return gtk_style_context_lookup_color(gtk_widget_get_style_context(widget), name, &color) != 0 ? color : nil
    }

    func dispose() {
        guard !isClosed else { return }
        isClosed = true
        pty.terminate()
        if resizeTick != 0 { gtk_widget_remove_tick_callback(widget, resizeTick); resizeTick = 0 }
        for (object, handler) in signalConnections {
            g_signal_handler_disconnect(object, handler)
            g_object_unref(object)
        }
        signalConnections.removeAll()
        g_object_unref(UnsafeMutableRawPointer(widget))
    }

    func reportExit(code: Int32 = 0) {
        guard !isClosed, !exitReported else { return }
        exitReported = true
        report("terminal_exit", extra: ["exit_code": String(code)])
    }

    fileprivate func contentsChanged() {
        // VTE also emits this signal for map/resize changes on an empty grid.
        // Only actual visible child content establishes terminal readiness.
        guard !isClosed, !outputReported, childPID != nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        outputReported = true
        report("terminal_output")
    }

    fileprivate func focusEntered() {
        guard !isClosed else { return }
        report("terminal_focus")
    }

    fileprivate func directoryChanged() {
        guard !isClosed else { return }
        var payload = ["workspace_id": identity.workspaceID,
            "generation": identity.generation.uuidString.lowercased(),
            "pane_id": identity.paneID.uuidString.lowercased()]
        if let directory = currentDirectory { payload["directory"] = directory }
        onEvent("terminal_directory", payload)
    }

    private func spawn(_ launch: LinuxTerminalLaunch) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: launch.executable, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: launch.executable) else {
            failLaunch("Could not execute \(launch.executable)")
            return true
        }
        if let directory = launch.workingDirectory {
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: directory) else {
                failLaunch("Could not open terminal working directory: \(directory)")
                return true
            }
        }
        pty.onOutput = { [weak self] bytes in
            // One outstanding chunk per pane bounds UI backlog. Input writes
            // use another queue, so a large paste cannot block GTK draining it.
            let delivered = DispatchSemaphore(value: 0)
            TerminalMainDelivery.enqueue { [weak self] in
                defer { delivered.signal() }
                self?.receive(bytes)
            }
            delivered.wait()
        }
        pty.onExit = { [weak self] code in
            TerminalMainDelivery.enqueue { [weak self] in
                guard let self, self.childPID != nil else { return }
                self.finishOutput(code: code)
            }
        }
        childPID = pty.start(path: launch.executable, args: launch.arguments,
            cols: 80, rows: 24, extraEnv: launch.environment, workingDirectory: launch.workingDirectory)
        if childPID == nil {
            failLaunch("Could not create terminal process")
        }
        resizeTick = gtk_widget_add_tick_callback(widget, { _, _, data in
            guard let data else { return 0 }
            Unmanaged<TerminalPane>.fromOpaque(data).takeUnretainedValue().resizePTY()
            return 1
        }, Unmanaged.passUnretained(self).toOpaque(), nil)
        return true
    }

    private func failLaunch(_ message: String) {
        spawnError = message
        // The owning window registers this pane after its initializer returns.
        TerminalMainDelivery.enqueue { [weak self] in
            guard let self, !self.isClosed else { return }
            self.report("terminal_launch_failed")
        }
    }

    private func finishOutput(code: Int32) {
        guard !isClosed else { return }
        pendingExit = code
        // feed() queues parsing on VTE's frame/100 ms fallback scheduler. An
        // invisible extension property after the final bytes is an exact drain
        // boundary, unlike an idle callback or a guessed delay. CAN discards an
        // unfinished control string so it cannot swallow this host marker.
        let marker = "\u{18}\u{1b}]666;\(Self.drainPropertyName)=\(drainMarker)\u{1b}\\"
        marker.withCString { vte_terminal_feed(terminal, $0, marker.utf8.count) }
    }

    private func outputDrained() {
        guard !isClosed, let code = pendingExit else { return }
        pendingExit = nil
        contentsChanged()
        reportExit(code: code)
    }

    private func receive(_ bytes: Data) {
        guard !isClosed else { return }
        let clipboardWrites = clipboardDecoder.consume(bytes)
        bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress { vte_terminal_feed(terminal, base.assumingMemoryBound(to: CChar.self), bytes.count) }
        }
        guard !isClosed, gtk_widget_get_mapped(widget) != 0,
              gtk_widget_has_focus(widget) != 0,
              let root = gtk_widget_get_root(widget),
              gtk_window_is_active(UnsafeMutableRawPointer(root).assumingMemoryBound(to: GtkWindow.self)) != 0,
              let clipboard = gdk_display_get_clipboard(gtk_widget_get_display(widget)) else { return }
        for text in clipboardWrites { text.withCString { gdk_clipboard_set_text(clipboard, $0) } }
    }

    private func resizePTY() {
        guard !isClosed, childPID != nil else { return }
        let rows = Int32(clamping: vte_terminal_get_row_count(terminal))
        let columns = Int32(clamping: vte_terminal_get_column_count(terminal))
        guard rows > 0, columns > 0, rows != terminalRows || columns != terminalColumns else { return }
        terminalRows = rows
        terminalColumns = columns
        inputQueue.async { [pty] in pty.resize(cols: UInt16(clamping: columns), rows: UInt16(clamping: rows)) }
    }

    fileprivate func commit(_ bytes: Data) {
        guard !isClosed else { return }
        inputQueue.async { [pty] in pty.write(bytes) }
    }

    private func connectSignals() {
        let drained: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
            guard let data else { return }
            let pane = Unmanaged<TerminalPane>.fromOpaque(data).takeUnretainedValue()
            // VTE permits only termprop getters inside this signal; queue all
            // other widget/backend work until after signal emission returns.
            guard let value = vte_terminal_get_termprop_string_by_id(pane.terminal, TerminalPane.drainProperty, nil),
                  String(cString: value) == pane.drainMarker else { return }
            TerminalMainDelivery.enqueue { [weak pane] in pane?.outputDrained() }
        }
        connectSignal(UnsafeMutableRawPointer(widget), "termprop-changed::\(Self.drainPropertyName)", unsafeBitCast(drained, to: GCallback.self))
        let mapped: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            guard let data else { return }
            Unmanaged<TerminalPane>.fromOpaque(data).takeUnretainedValue().applyTheme()
        }
        connectSignal(UnsafeMutableRawPointer(widget), "map", unsafeBitCast(mapped, to: GCallback.self))
        if let settings = gtk_settings_get_default() {
            let themeChanged: @convention(c)
                (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
                    guard let data else { return }
                    Unmanaged<TerminalPane>.fromOpaque(data).takeUnretainedValue().applyTheme()
                }
            for setting in ["notify::gtk-theme-name", "notify::gtk-application-prefer-dark-theme"] {
                connectSignal(UnsafeMutableRawPointer(settings), setting, unsafeBitCast(themeChanged, to: GCallback.self))
            }
        }
        let contentsChanged = unsafeBitCast(
            devspaceLinuxVteContentsChanged as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
            to: GCallback.self
        )
        connectSignal(UnsafeMutableRawPointer(widget), "contents-changed", contentsChanged)
        let commit: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt32, UnsafeMutableRawPointer?) -> Void = { _, text, count, data in
            guard let data, let text else { return }
            Unmanaged<TerminalPane>.fromOpaque(data).takeUnretainedValue().commit(Data(bytes: text, count: Int(count)))
        }
        connectSignal(UnsafeMutableRawPointer(widget), "commit", unsafeBitCast(commit, to: GCallback.self))
        let directoryChanged = unsafeBitCast(
            devspaceLinuxVteDirectoryChanged as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
            to: GCallback.self
        )
        connectSignal(UnsafeMutableRawPointer(widget), "current-directory-uri-changed", directoryChanged)

        let focus = gtk_event_controller_focus_new()!
        gtk_widget_add_controller(widget, focus)
        let focusEntered = unsafeBitCast(
            devspaceLinuxVteFocusEntered as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
            to: GCallback.self
        )
        connectSignal(UnsafeMutableRawPointer(focus), "enter", focusEntered)

        let keyController = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keyController, GTK_PHASE_CAPTURE)
        gtk_widget_add_controller(widget, keyController)
        let keyPressed = unsafeBitCast(
            devspaceLinuxVteKeyPressed as @convention(c)
                (UnsafeMutableRawPointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Int32,
            to: GCallback.self
        )
        connectSignal(UnsafeMutableRawPointer(keyController), "key-pressed", keyPressed)
    }

    private func connectSignal(_ object: UnsafeMutableRawPointer, _ name: String, _ callback: GCallback) {
        _ = g_object_ref(object)
        let handler = g_signal_connect_data(
            object, name, callback, Unmanaged.passUnretained(self).toOpaque(), nil, GConnectFlags(rawValue: 0)
        )
        signalConnections.append((object, handler))
    }

    private func report(_ kind: String, extra: [String: String] = [:]) {
        var payload = [
            "workspace_id": identity.workspaceID,
            "generation": identity.generation.uuidString.lowercased(),
            "pane_id": identity.paneID.uuidString.lowercased(),
        ]
        payload.merge(extra) { _, new in new }
        onEvent(kind, payload)
    }

    private func pasteClipboard() {
        guard let display = gdk_display_get_default(),
              let clipboard = gdk_display_get_clipboard(display) else {
            vte_terminal_paste_clipboard(terminal)
            return
        }
        let callback = unsafeBitCast(
            devspaceLinuxClipboardTextureReady as @convention(c)
                (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
            to: GAsyncReadyCallback.self
        )
        let context = ClipboardImageContext(self)
        gdk_clipboard_read_texture_async(
            clipboard, nil, callback, Unmanaged.passRetained(context).toOpaque()
        )
    }

    fileprivate func clipboardTextureReady(_ clipboard: OpaquePointer, _ result: OpaquePointer) {
        var error: UnsafeMutablePointer<GError>?
        let texture = gdk_clipboard_read_texture_finish(clipboard, result, &error)
        if let error { g_error_free(error) }
        defer { if let texture { g_object_unref(UnsafeMutableRawPointer(texture)) } }
        guard !isClosed, gtk_widget_get_mapped(widget) != 0 else { return }
        guard let texture else {
            pasteClipboardText(clipboard)
            return
        }
        guard let sourcePath = privatePNG(from: texture) else {
            onEvent("clipboard_error", ["message": "Could not prepare clipboard image; PNG must be no larger than 16 MiB"])
            return
        }
        onEvent("paste_image", [
            "workspace_id": identity.workspaceID,
            "generation": identity.generation.uuidString.lowercased(),
            "pane_id": identity.paneID.uuidString.lowercased(),
            "source_path": sourcePath,
        ])
    }

    private func pasteClipboardText(_ clipboard: OpaquePointer) {
        let callback = unsafeBitCast(
            devspaceLinuxClipboardTextReady as @convention(c)
                (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
            to: GAsyncReadyCallback.self
        )
        gdk_clipboard_read_text_async(clipboard, nil, callback,
            Unmanaged.passRetained(ClipboardImageContext(self)).toOpaque())
    }

    fileprivate func clipboardTextReady(_ clipboard: OpaquePointer, _ result: OpaquePointer) {
        var error: UnsafeMutablePointer<GError>?
        let content = gdk_clipboard_read_text_finish(clipboard, result, &error)
        if let error { g_error_free(error) }
        defer { if let content { g_free(UnsafeMutableRawPointer(content)) } }
        guard !isClosed, gtk_widget_get_mapped(widget) != 0, let content else { return }
        vte_terminal_paste_text(terminal, content)
    }

    private func privatePNG(from texture: OpaquePointer) -> String? {
        guard let png = gdk_texture_save_to_png_bytes(texture) else { return nil }
        defer { g_bytes_unref(png) }
        var size: gsize = 0
        guard let bytes = g_bytes_get_data(png, &size), size > 8,
              size <= gsize(ImageUpload.maximumBytes) else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devspace-paste-\(UUID().uuidString).png")
        let descriptor = url.path.withCString {
            Glibc.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Glibc.close(descriptor) }

        let count = Int(size)
        var offset = 0
        while offset < count {
            let result = Glibc.write(descriptor, bytes.advanced(by: offset), count - offset)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else {
                _ = url.path.withCString { Glibc.unlink($0) }
                return nil
            }
            offset += result
        }
        return url.path
    }
}

@_cdecl("devspace_linux_vte_contents_changed")
private func devspaceLinuxVteContentsChanged(_ terminal: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?) {
    guard let data else { return }
    Unmanaged<TerminalPane>.fromOpaque(data).takeUnretainedValue().contentsChanged()
    _ = terminal
}

@_cdecl("devspace_linux_vte_focus_entered")
private func devspaceLinuxVteFocusEntered(_ controller: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?) {
    guard let data else { return }
    Unmanaged<TerminalPane>.fromOpaque(data).takeUnretainedValue().focusEntered()
    _ = controller
}

@_cdecl("devspace_linux_vte_key_pressed")
private func devspaceLinuxVteKeyPressed(
    _ controller: UnsafeMutableRawPointer?, _ keyval: UInt32, _ keycode: UInt32,
    _ state: UInt32, _ data: UnsafeMutableRawPointer?
) -> Int32 {
    guard let data else { return 0 }
    let pane = Unmanaged<TerminalPane>.fromOpaque(data).takeUnretainedValue()
    let handled = pane.handleKey(keyval: keyval, modifiers: GdkModifierType(rawValue: state))
    _ = controller
    _ = keycode
    return handled ? 1 : 0
}

/// Always enqueue on GTK's context; invoke() may run inline on a reader thread.
private final class TerminalMainDelivery {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    static func enqueue(_ action: @escaping () -> Void) {
        let delivery = Unmanaged.passRetained(TerminalMainDelivery(action)).toOpaque()
        _ = g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, { data in
            guard let data else { return 0 }
            Unmanaged<TerminalMainDelivery>.fromOpaque(data).takeUnretainedValue().action()
            return 0
        }, delivery, { data in
            if let data { Unmanaged<TerminalMainDelivery>.fromOpaque(data).release() }
        })
    }
}

private final class ClipboardImageContext {
    weak var pane: TerminalPane?
    init(_ pane: TerminalPane) { self.pane = pane }
}

@_cdecl("devspace_linux_clipboard_texture_ready")
private func devspaceLinuxClipboardTextureReady(
    _ source: UnsafeMutableRawPointer?, _ result: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?
) {
    guard let data else { return }
    let context = Unmanaged<ClipboardImageContext>.fromOpaque(data).takeRetainedValue()
    guard let pane = context.pane, let source, let result else { return }
    pane.clipboardTextureReady(OpaquePointer(source), OpaquePointer(result))
}

@_cdecl("devspace_linux_clipboard_text_ready")
private func devspaceLinuxClipboardTextReady(
    _ source: UnsafeMutableRawPointer?, _ result: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?
) {
    guard let data else { return }
    let context = Unmanaged<ClipboardImageContext>.fromOpaque(data).takeRetainedValue()
    guard let pane = context.pane, let source, let result else { return }
    pane.clipboardTextReady(OpaquePointer(source), OpaquePointer(result))
}

@_cdecl("devspace_linux_vte_directory_changed")
private func devspaceLinuxVteDirectoryChanged(_ terminal: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?) {
    guard let data else { return }
    Unmanaged<TerminalPane>.fromOpaque(data).takeUnretainedValue().directoryChanged()
}
