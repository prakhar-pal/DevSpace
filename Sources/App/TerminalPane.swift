import SwiftUI
import GhosttyTerminal
import GhosttyTheme
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
        // Pass an EMPTY theme so the user's ghostty config fully controls colors.
        // The library's default theme (Afterglow/Alabaster) is otherwise rendered
        // AFTER the user's config and overrides their colors/palette.
        let cfg = GhosttyConfig.resolve()
        let source: TerminalController.ConfigSource = cfg.path.map { .file($0) } ?? .none
        state = TerminalViewState(configSource: source, theme: cfg.theme)

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

/// Resolves the user's Ghostty config for the embedded terminal.
///
/// libghostty rejects the ENTIRE config on any diagnostic, and in this embedded
/// build it can't resolve `theme = <name>` (the built-in theme files aren't
/// shipped — it only searches `~/.config/ghostty/themes`). So we resolve the
/// theme ourselves from the compiled-in GhosttyTheme catalog (no resource files,
/// location-independent) and strip the `theme =` line (plus the trimmed-out
/// `custom-shader*`) from the config we hand to libghostty.
enum GhosttyConfig {
    struct Resolved {
        var path: String?
        var theme: TerminalTheme
    }

    private static let unsupportedKeyPrefixes = ["custom-shader"]

    static func resolve() -> Resolved {
        guard let original = locate() else { return Resolved(path: nil, theme: TerminalTheme()) }
        guard let contents = try? String(contentsOfFile: original, encoding: .utf8) else {
            return Resolved(path: original, theme: TerminalTheme())
        }

        // Resolve `theme = <name>` (last one wins) via the compiled-in catalog.
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let themeName = lines.compactMap { line -> String? in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "theme"
            else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }.last
        let theme = themeName
            .flatMap { GhosttyThemeCatalog.theme(named: $0)?.toTerminalTheme() }
            ?? TerminalTheme()

        // Strip keys libghostty can't resolve here (theme, custom-shader*).
        let mustSanitize = themeName != nil || unsupportedKeyPrefixes.contains(where: contents.contains)
        guard mustSanitize else { return Resolved(path: original, theme: theme) }

        let filtered = lines.filter { line in
            let key = line.split(separator: "=", maxSplits: 1).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if key == "theme" { return false }
            return !unsupportedKeyPrefixes.contains { key.hasPrefix($0) }
        }.joined(separator: "\n")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("devspace-ghostty-\(UUID().uuidString).conf")
        guard (try? filtered.write(to: tmp, atomically: true, encoding: .utf8)) != nil else {
            return Resolved(path: original, theme: theme)
        }
        return Resolved(path: tmp.path, theme: theme)
    }

    private static func locate() -> String? {
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
