import SwiftUI
import GhosttyTerminal
import DevSpaceCore

/// Owns a libghostty terminal surface backed by a host-managed ``PTYSession``.
///
/// Wiring (per the InMemoryTerminalSession contract):
/// - terminal `write` (keystrokes) -> PTY input
/// - terminal `resize` (grid changed) -> PTY winsize; also lazily starts the
///   PTY on the first resize, by which point the surface is attached and the
///   real column/row count is known (so no startup output is dropped)
/// - PTY output -> `session.receive` (rendered by the surface)
/// - PTY exit  -> `session.finish`
@MainActor
final class TerminalHostModel: ObservableObject {
    let state: TerminalViewState
    private let pty = PTYSession()
    private var session: InMemoryTerminalSession!
    private var didStart = false

    /// Command run in the terminal. Stack 2 uses a login shell as the spike;
    /// Stack 6 swaps in `ssh <id>.devpod …`.
    private let command: String
    private let args: [String]

    init(command: String = "/bin/zsh", args: [String] = ["-l"]) {
        self.command = command
        self.args = args
        state = TerminalViewState()

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
                self?.session.finish(exitCode: UInt32(bitPattern: code), runtimeMilliseconds: 0)
            }
        }
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    }

    private func handleResize(_ viewport: InMemoryTerminalViewport) {
        if didStart {
            pty.resize(cols: viewport.columns, rows: viewport.rows)
        } else {
            didStart = true
            Log.write("pty start \(command) \(viewport.columns)x\(viewport.rows)")
            pty.start(path: command, args: args, cols: viewport.columns, rows: viewport.rows)
        }
    }
}

struct TerminalHostView: View {
    @StateObject private var model = TerminalHostModel()
    @FocusState private var focused: Bool

    var body: some View {
        TerminalSurfaceView(context: model.state)
            .terminalFocusOnAppear($focused)
            .background(Color(red: 0.067, green: 0.067, blue: 0.067)) // #111
            .ignoresSafeArea()
    }
}
