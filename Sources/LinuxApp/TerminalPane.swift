import Foundation
import Glibc
import CGTK
import CVTE

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
    let launch: LinuxTerminalLaunch
    let identity: TerminalPaneIdentity
    let widget: UnsafeMutablePointer<GtkWidget>
    private let terminal: UnsafeMutablePointer<VteTerminal>
    private let onEvent: (String, [String: String]) -> Void
    private(set) var childPID: pid_t?
    private(set) var spawnError: String?
    private(set) var isClosed = false
    private var outputReported = false
    private var exitReported = false

    init?(launch: LinuxTerminalLaunch, onEvent: @escaping (String, [String: String]) -> Void = { _, _ in }) {
        self.launch = launch
        identity = TerminalPaneIdentity(
            workspaceID: launch.workspaceID, generation: launch.generation, paneID: launch.paneID
        )
        self.onEvent = onEvent
        widget = vte_terminal_new()!
        terminal = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: VteTerminal.self)
        _ = g_object_ref_sink(UnsafeMutableRawPointer(widget))
        vte_terminal_set_scrollback_lines(terminal, 10_000)
        vte_terminal_set_size(terminal, 80, 24)
        connectSignals()

        guard spawn(launch) else {
            g_object_unref(UnsafeMutableRawPointer(widget))
            return nil
        }
    }

    var text: String {
        guard let rawText = vte_terminal_get_text_format(terminal, VTE_FORMAT_TEXT) else { return "" }
        defer { g_free(UnsafeMutableRawPointer(rawText)) }
        return String(cString: rawText)
    }

    func feed(_ text: String) {
        guard !isClosed else { return }
        text.withCString { vte_terminal_feed_child(terminal, $0, Int(text.utf8.count)) }
    }

    func resize(columns: Int, rows: Int) {
        guard !isClosed, columns > 0, rows > 0 else { return }
        vte_terminal_set_size(terminal, Int(columns), Int(rows))
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
            vte_terminal_paste_clipboard(terminal)
            return true
        case UInt32(GDK_KEY_r):
            onEvent("reconnect", ["workspace_id": identity.workspaceID])
            return true
        default:
            return false
        }
    }

    var ptySize: (rows: Int32, columns: Int32)? {
        guard !isClosed, let pty = vte_terminal_get_pty(terminal) else { return nil }
        var rows: Int32 = 0
        var columns: Int32 = 0
        guard vte_pty_get_size(pty, &rows, &columns, nil) != 0 else { return nil }
        return (rows, columns)
    }

    func dispose() {
        guard !isClosed else { return }
        isClosed = true
        g_object_unref(UnsafeMutableRawPointer(widget))
    }

    func reportExit() {
        guard !isClosed, !exitReported else { return }
        exitReported = true
        report("terminal_exit")
    }

    fileprivate func contentsChanged() {
        guard !isClosed, !outputReported else { return }
        outputReported = true
        report("terminal_output")
    }

    fileprivate func focusEntered() {
        guard !isClosed else { return }
        report("terminal_focus")
    }

    fileprivate func childExited() {
        reportExit()
    }

    private func spawn(_ launch: LinuxTerminalLaunch) -> Bool {
        let strings = [launch.executable] + launch.arguments
        let allocated = strings.map { strdup($0) }
        guard allocated.allSatisfy({ $0 != nil }) else {
            allocated.compactMap { $0 }.forEach { free($0) }
            return false
        }
        defer { allocated.compactMap { $0 }.forEach { free($0) } }
        var argv = allocated + [nil]

        let envStrings = launch.environment.map { "\($0.key)=\($0.value)" }
        let allocatedEnv = envStrings.map { strdup($0) }
        guard allocatedEnv.allSatisfy({ $0 != nil }) else {
            allocatedEnv.compactMap { $0 }.forEach { free($0) }
            return false
        }
        defer { allocatedEnv.compactMap { $0 }.forEach { free($0) } }
        var envv = allocatedEnv.isEmpty ? nil : allocatedEnv + [nil]

        let context = SpawnContext(self)
        let callback: VteTerminalSpawnAsyncCallback = { _, pid, error, data in
            guard let data else { return }
            let context = Unmanaged<SpawnContext>.fromOpaque(data).takeRetainedValue()
            context.pane?.spawnCompleted(pid: pid, error: error)
        }
        let userData = Unmanaged.passRetained(context).toOpaque()
        argv.withUnsafeMutableBufferPointer { arguments in
            if let workingDirectory = launch.workingDirectory {
                workingDirectory.withCString { cwd in
                    vte_terminal_spawn_async(
                        terminal, VtePtyFlags(rawValue: 0), cwd, arguments.baseAddress!, envv?.withUnsafeMutableBufferPointer { $0.baseAddress } ?? nil,
                        GSpawnFlags(rawValue: 0), nil, nil, nil, -1, nil, callback, userData
                    )
                }
            } else {
                vte_terminal_spawn_async(
                    terminal, VtePtyFlags(rawValue: 0), nil, arguments.baseAddress!,
                    envv?.withUnsafeMutableBufferPointer { $0.baseAddress } ?? nil,
                    GSpawnFlags(rawValue: 0), nil, nil, nil, -1, nil, callback, userData
                )
            }
        }
        return true
    }

    private func spawnCompleted(pid: GPid, error: UnsafeMutablePointer<GError>?) {
        guard !isClosed else { return }
        if let error {
            spawnError = String(cString: error.pointee.message)
            report("terminal_launch_failed")
        } else {
            childPID = pid
        }
    }

    private func connectSignals() {
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let contentsChanged = unsafeBitCast(
            devspaceLinuxVteContentsChanged as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
            to: GCallback.self
        )
        let childExited = unsafeBitCast(
            devspaceLinuxVteChildExited as @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Void,
            to: GCallback.self
        )
        _ = g_signal_connect_data(UnsafeMutableRawPointer(widget), "contents-changed", contentsChanged,
                                  userData, nil, GConnectFlags(rawValue: 0))
        _ = g_signal_connect_data(UnsafeMutableRawPointer(widget), "child-exited", childExited,
                                  userData, nil, GConnectFlags(rawValue: 0))

        let focus = gtk_event_controller_focus_new()!
        gtk_widget_add_controller(widget, focus)
        let focusEntered = unsafeBitCast(
            devspaceLinuxVteFocusEntered as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
            to: GCallback.self
        )
        _ = g_signal_connect_data(UnsafeMutableRawPointer(focus), "enter", focusEntered,
                                  userData, nil, GConnectFlags(rawValue: 0))

        let keyController = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keyController, GTK_PHASE_CAPTURE)
        gtk_widget_add_controller(widget, keyController)
        let keyPressed = unsafeBitCast(
            devspaceLinuxVteKeyPressed as @convention(c)
                (UnsafeMutableRawPointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Int32,
            to: GCallback.self
        )
        _ = g_signal_connect_data(UnsafeMutableRawPointer(keyController), "key-pressed", keyPressed,
                                  userData, nil, GConnectFlags(rawValue: 0))
    }

    private func report(_ kind: String) {
        onEvent(kind, [
            "workspace_id": identity.workspaceID,
            "generation": identity.generation.uuidString.lowercased(),
            "pane_id": identity.paneID.uuidString.lowercased(),
        ])
    }
}

@_cdecl("devspace_linux_vte_contents_changed")
private func devspaceLinuxVteContentsChanged(_ terminal: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?) {
    guard let data else { return }
    Unmanaged<TerminalPane>.fromOpaque(data).takeUnretainedValue().contentsChanged()
    _ = terminal
}

@_cdecl("devspace_linux_vte_child_exited")
private func devspaceLinuxVteChildExited(_ terminal: UnsafeMutableRawPointer?, _ status: Int32, _ data: UnsafeMutableRawPointer?) {
    guard let data else { return }
    Unmanaged<TerminalPane>.fromOpaque(data).takeUnretainedValue().childExited()
    _ = terminal
    _ = status
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

private final class SpawnContext {
    weak var pane: TerminalPane?
    init(_ pane: TerminalPane) { self.pane = pane }
}
