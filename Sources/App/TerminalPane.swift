import SwiftUI
import GhosttyTerminal
import DevSpaceCore

/// A libghostty terminal surface backed by a host-managed ``PTYSession`` running
/// an arbitrary command (an SSH shell, or a streaming `devpod up`/`devpod stop`
/// log). Generalizes the Stack 2 terminal spike.
///
/// Wiring: terminal keystrokes -> PTY input; grid resize -> PTY winsize (and
/// lazy PTY start on first layout); PTY output -> surface; PTY exit -> onExit.
@MainActor
final class TerminalPaneModel: ObservableObject, Identifiable {
    let id = UUID()
    let state: TerminalViewState
    private let pty = PTYSession()
    private var session: InMemoryTerminalSession!
    private var didStart = false
    private let command: String
    private let args: [String]

    /// Called (on the main actor) when the underlying process exits.
    var onExit: ((Int32) -> Void)?

    init(command: String, args: [String]) {
        self.command = command
        self.args = args
        // Use the same terminal settings as the Ghostty app (font, theme,
        // colors, cursor) by loading the user's ghostty config if present.
        // libghostty falls back to defaults if the file is missing/unparseable.
        state = TerminalViewState(configFilePath: GhosttyConfig.path())

        session = InMemoryTerminalSession(
            write: { [pty] data in pty.write(data) },
            resize: { [weak self] viewport in
                DispatchQueue.main.async { self?.handleResize(viewport) }
            }
        )
        pty.onOutput = { [weak self] data in
            DispatchQueue.main.async { self?.session.receive(data) }
        }
        pty.onExit = { [weak self] code in
            DispatchQueue.main.async {
                guard let self else { return }
                self.session.finish(exitCode: UInt32(bitPattern: code), runtimeMilliseconds: 0)
                self.onExit?(code)
            }
        }
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    }

    private func handleResize(_ viewport: InMemoryTerminalViewport) {
        if didStart {
            pty.resize(cols: viewport.columns, rows: viewport.rows)
        } else {
            didStart = true
            Log.write("pty start \(command) \(args.joined(separator: " ")) \(viewport.columns)x\(viewport.rows)")
            pty.start(path: command, args: args, cols: viewport.columns, rows: viewport.rows)
        }
    }

    func terminate() { pty.terminate() }
}

/// Locates the user's Ghostty config so the embedded terminal inherits the same
/// settings as the Ghostty app. Checks the standard Ghostty search paths.
enum GhosttyConfig {
    static func path() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var candidates: [String] = []
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            candidates.append("\(xdg)/ghostty/config")
        }
        candidates.append("\(home)/.config/ghostty/config")
        candidates.append("\(home)/Library/Application Support/com.mitchellh.ghostty/config")
        return candidates.first { fm.fileExists(atPath: $0) }
    }
}

struct TerminalPaneView: View {
    @ObservedObject var model: TerminalPaneModel
    let focusID: String
    /// Shared, single-source focus binding owned by MainPane. Exactly one pane
    /// (the selected one) is focused; others resign first responder, so a hidden
    /// pane can't steal the keyboard from the visible terminal.
    @FocusState.Binding var focused: String?

    var body: some View {
        TerminalSurfaceView(context: model.state)
            .terminalFocused($focused, equals: focusID)
            .background(Color(red: 0.067, green: 0.067, blue: 0.067)) // #111
    }
}
