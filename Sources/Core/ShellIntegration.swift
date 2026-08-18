import Foundation

// Pod-side shell integration: make bash/zsh report their working directory to
// the terminal via OSC 7 on every prompt. libghostty parses OSC 7 into
// TerminalViewState.workingDirectory, which the terminal tab titles display.
// Stock container shells don't emit OSC 7, so DevSpace appends a small,
// marker-guarded snippet to the pod's rc files (same best-effort `devpod ssh`
// channel Hooks.inject uses).
public enum ShellIntegration {
    static let beginMarker = "# >>> devspace shell integration >>>"
    static let endMarker = "# <<< devspace shell integration <<<"

    /// One snippet for both rc files — the shell is detected at source time.
    /// Guards make re-sourcing (nested shells, `exec bash`) idempotent too.
    /// The file URL's host MUST be `localhost`: ghostty core rejects OSC 7
    /// URLs with a missing host (UriMissingHost) or a non-local hostname
    /// (isLocal check) — both are silently dropped before the pwd action.
    static let snippet = """
    \(beginMarker)
    # Report the shell's cwd to the terminal (OSC 7) so DevSpace tab titles
    # show the current folder. Managed by DevSpace; safe to remove.
    __devspace_osc7() { printf '\\033]7;file://localhost%s\\033\\\\' "$PWD"; }
    if [ -n "$ZSH_VERSION" ]; then
      case " ${precmd_functions[*]:-} " in *" __devspace_osc7 "*) ;; *) precmd_functions+=(__devspace_osc7) ;; esac
    elif [ -n "$BASH_VERSION" ]; then
      case ";${PROMPT_COMMAND:-};" in *"__devspace_osc7"*) ;; *) PROMPT_COMMAND="__devspace_osc7${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;; esac
    fi
    \(endMarker)
    """

    /// The `devpod ssh --command` payload: replace any existing marker block
    /// in ~/.bashrc and ~/.zshrc with the current snippet (delete + append),
    /// so snippet updates self-upgrade on the next connect instead of being
    /// pinned to whatever version was injected first. The snippet travels
    /// base64-encoded so no quoting survives two shells' parsing.
    static func injectScript() -> String {
        let b64 = Data(("\n" + snippet + "\n").utf8).base64EncodedString()
        return "for rc in \"$HOME/.bashrc\" \"$HOME/.zshrc\"; do "
            + "[ -f \"$rc\" ] && sed -i '/\(sedPattern(beginMarker))/,/\(sedPattern(endMarker))/d' \"$rc\"; "
            + "echo \(b64) | base64 -d >> \"$rc\"; "
            + "done"
    }

    /// Escape a marker line for use inside a sed /…/ address.
    private static func sedPattern(_ marker: String) -> String {
        marker
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "/", with: "\\/")
    }

    /// Append the OSC 7 prompt hook to the pod's shell rc files. Idempotent;
    /// best-effort (new shells pick it up — existing prompts are unaffected).
    public static func inject(_ runner: CommandRunning, podID: String) throws {
        try Devpod.validateId(podID)
        _ = try runner.run(["ssh", "--command", injectScript(), "--start-services=false", "--", podID])
    }
}
