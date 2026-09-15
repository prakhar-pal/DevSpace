import AppKit
import SwiftUI
import GhosttyTerminal
import GhosttyTheme
import DevSpaceCore

/// Bridges the PTY read queue to the main-actor terminal model. The first
/// byte must be visible to connection-handoff logic before UI delivery runs.
private final class FirstOutputSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func record() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var wasRecorded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// A libghostty terminal surface backed by a host-managed ``PTYSession`` running
/// an arbitrary command (an SSH shell, or a streaming `devpod up`/`devpod stop`
/// log). Generalizes the Stack 2 terminal spike.
///
/// Wiring: terminal keystrokes -> PTY input; grid resize -> PTY winsize (and
/// lazy PTY start on first layout); PTY output -> surface; PTY exit -> onExit.
@MainActor
final class TerminalPaneModel: ObservableObject, Identifiable {
    static let restartRemoteShellCommand = "\u{3}\rreset; exec \"${SHELL:-/bin/sh}\" -i\r"

    let id = UUID()
    let state: TerminalViewState
    private let pty = PTYSession()
    private let firstOutputSignal = FirstOutputSignal()
    private let pasteNormalizer = PasteNewlineNormalizer()
    private var session: InMemoryTerminalSession!
    private var didStart = false
    private var didReportFirstOutput = false
    private var startedAtNanoseconds: UInt64?
    private let command: String
    private let args: [String]

    /// The spawn argv, exposed to the app test target so it can assert that a
    /// visible pane is a multiplex client rather than a reverse-tunnel owner.
    var commandArguments: [String] { args }

    /// Called (on the main actor) when the underlying process exits.
    var onExit: ((Int32) -> Void)?
    /// Called (on the main actor) immediately before the underlying PTY starts.
    var onStart: (() -> Void)?
    /// Called once (on the main actor) before the first PTY bytes are delivered
    /// to Ghostty.
    var onFirstOutput: (() -> Void)?

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
            write: { [pty, pasteNormalizer] data in
                // Host-managed libghostty forwards a bracketed paste's raw LF
                // (\n) bytes; standard terminals send CR (\r) for pasted
                // newlines. Normalize LF→CR inside the paste so kitty-protocol
                // apps (Claude Code) don't read \n as the Ctrl+J key.
                pty.write(pasteNormalizer.normalize(data))
            },
            resize: { [weak self] viewport in
                DispatchQueue.main.async { self?.handleResize(viewport) }
            }
        )
        pty.onOutput = { [weak self, firstOutputSignal] data in
            firstOutputSignal.record()
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.didReportFirstOutput {
                    self.didReportFirstOutput = true
                    self.onFirstOutput?()
                }
                self.session.receive(data)
            }
        }
        pty.onExit = { [weak self] code in
            DispatchQueue.main.async {
                guard let self else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                let runtime = self.startedAtNanoseconds.map { (now - $0) / 1_000_000 } ?? 0
                self.session.finish(exitCode: UInt32(bitPattern: code), runtimeMilliseconds: runtime)
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
            startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
            Log.write("pty start \(command) \(args.joined(separator: " ")) \(viewport.columns)x\(viewport.rows)")
            onStart?()
            pty.start(path: command, args: args, cols: viewport.columns, rows: viewport.rows)
        }
    }

    func terminate() { pty.terminate() }

    /// True as soon as the PTY read queue has observed output, even if its UI
    /// delivery remains queued behind other main-actor work.
    var hasReceivedPTYOutput: Bool { firstOutputSignal.wasRecorded }

    /// Restart only the remote interactive shell while keeping this pane's SSH
    /// process — and therefore its reverse notification tunnel — alive.
    func restartRemoteShell() {
        pty.write(Data(Self.restartRemoteShellCommand.utf8))
    }

    /// Writes host-generated text straight to the pty, bypassing
    /// ``PasteNewlineNormalizer`` — that exists only to fix up libghostty's
    /// bracketed-paste byte stream from a *user* paste; text synthesized
    /// here (e.g. an image-paste path reference) is a single line with no
    /// embedded newlines, so there's nothing to normalize and no Enter is
    /// sent — it just populates the input line, the same as a normal text
    /// paste does.
    func injectText(_ text: String) {
        pty.write(Data(text.utf8))
    }
}

/// Normalizes pasted newlines in the host→pty byte stream.
///
/// libghostty's host-managed I/O backend forwards a bracketed paste's raw LF
/// (`\n`, 0x0A) bytes unchanged, whereas a normal terminal (and standalone
/// Ghostty's exec backend) send CR (`\r`, 0x0D) for pasted newlines — the same
/// byte the Enter key produces. Apps that enable the kitty keyboard protocol
/// (e.g. Claude Code) read a bare `\n` inside a paste as the *Ctrl+J key* and
/// insert a literal `j`, garbling multi-line paste.
///
/// libghostty emits the paste as three separate writes — the start marker
/// (`ESC[200~`), the body, then the end marker (`ESC[201~`) — so we just track
/// whether we're between the markers and convert LF→CR (collapsing CRLF→CR) in
/// the body. A genuine Ctrl+J keypress outside a paste is its own write and is
/// left untouched.
final class PasteNewlineNormalizer: @unchecked Sendable {
    private let lock = NSLock()
    private var inPaste = false

    private static let start = Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]) // ESC[200~
    private static let end = Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]) // ESC[201~

    func normalize(_ data: Data) -> Data {
        lock.lock()
        defer { lock.unlock() }

        if data == Self.start { inPaste = true; return data }
        if data == Self.end { inPaste = false; return data }
        guard inPaste else { return data }

        var out = Data(capacity: data.count)
        var prev: UInt8 = 0
        for b in data {
            if b == 0x0a {
                if prev != 0x0d { out.append(0x0d) } // LF→CR; drop the LF of a CRLF pair
            } else {
                out.append(b)
            }
            prev = b
        }
        return out
    }
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
    let handleKeyEquivalent: (NSEvent) -> Bool

    var body: some View {
        // Focus is driven imperatively by MainPane.focusSelectedTerminal() (the
        // library's FocusState-based `.terminalFocused` binding does not
        // propagate here), so no focus modifier is attached.
        DevSpaceTerminalSurfaceView(
            state: model.state,
            handleKeyEquivalent: handleKeyEquivalent
        )
            .background(Color(red: 0.067, green: 0.067, blue: 0.067)) // #111
    }
}
