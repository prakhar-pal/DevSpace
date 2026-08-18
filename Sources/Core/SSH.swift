import Foundation

// Port of the SSH argument builder from src-tauri/src/pty.rs (ssh_args) and the
// notify port constants. We connect through the `<id>.devpod` host alias DevPod
// writes into ~/.ssh/config and carry the reverse notification tunnel via -R.
public enum SSH {
    /// Desktop-side notify HTTP listener port (Stack 7).
    public static let listenerPort: UInt16 = 17865
    /// Pod-side reverse-tunnel port the in-pod hook POSTs to.
    public static let podForwardPort: UInt16 = 8765

    /// TERM advertised to the remote container. Fixed to xterm-256color — a
    /// widely available terminfo so prompts/editors render correctly inside the
    /// pod, which won't have ghostty/host-specific terminfo entries. Injected via
    /// `-o SetEnv=TERM=…` since container sshd often lacks `AcceptEnv TERM`.
    public static let remoteTerm = "xterm-256color"

    /// `tunnel: false` skips the reverse notification tunnel — used by the
    /// second and later terminals of a pod, where the primary session already
    /// holds the remote port (a second bind would fail and print a warning
    /// into the terminal).
    public static func args(podID: String, tunnel: Bool = true, proxyCommand: String? = nil) -> [String] {
        var args = [
            "-tt",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "SetEnv=TERM=\(remoteTerm)",
        ]
        if tunnel {
            args += ["-R", "\(podForwardPort):localhost:\(listenerPort)"]
        }
        if let proxyCommand {
            args += ["-o", "ProxyCommand=\(proxyCommand) --start-services=false"]
        }
        args.append("\(podID).devpod")
        return args
    }

    /// Extract a simple, effective DevPod stdio ProxyCommand from `ssh -G` output.
    /// Shell-composed commands and non-DevPod commands are rejected before they
    /// can be passed through to a locally spawned SSH process.
    public static func devpodProxyCommand(effectiveConfig: String) -> String? {
        guard let raw = effectiveConfig.split(separator: "\n").first(where: { $0.hasPrefix("proxycommand ") })
            .map({ String($0.dropFirst("proxycommand ".count)) }),
              raw != "none",
              !raw.contains(where: { ";|&<>\n\r".contains($0) }),
              !raw.contains("`"),
              !raw.contains("$("),
              !raw.contains("${"),
              !raw.contains(where: { "$*?[".contains($0) }),
              !raw.contains("#"),
              let words = shellWords(raw)?.map(normalizeShellWord),
              words.count >= 3,
              (words[0] as NSString).lastPathComponent == "devpod",
              words[1] == "ssh",
              words.contains("--stdio")
        else { return nil }
        return raw
    }

    /// Resolve the effective DevPod ProxyCommand for the host alias. This is
    /// intentionally synchronous: callers run it off the main actor before
    /// constructing their SSH PTY.
    public static func resolveDevpodProxyCommand(podID: String) -> String? {
        do {
            try Devpod.validateId(podID)
        } catch {
            Log.write("ssh-proxy: invalid pod id \(podID)")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "\(podID).devpod"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.write("ssh-proxy: could not launch ssh -G for \(podID): \(error)")
            return nil
        }

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let errorOutput = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            let reason = errorOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n")
                .first
                .map(String.init) ?? "no stderr"
            Log.write("ssh-proxy: ssh -G failed for \(podID) (exit \(process.terminationStatus)): \(reason)")
            return nil
        }
        guard let proxyCommand = devpodProxyCommand(effectiveConfig: output) else {
            Log.write("ssh-proxy: no valid DevPod ProxyCommand for \(podID)")
            return nil
        }
        return proxyCommand
    }

    private static func shellWords(_ input: String) -> [String]? {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var inWord = false

        for character in input {
            if escaped {
                word.append(character)
                escaped = false
                inWord = true
                continue
            }
            if character == "\\" {
                escaped = true
                inWord = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    word.append(character)
                }
                inWord = true
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character.isWhitespace {
                if inWord {
                    words.append(word)
                    word = ""
                    inWord = false
                }
            } else {
                word.append(character)
                inWord = true
            }
        }

        guard !escaped, quote == nil else { return nil }
        if inWord { words.append(word) }
        return words
    }

    private static func normalizeShellWord(_ word: String) -> String {
        guard word.count >= 2,
              (word.first == "'" && word.last == "'") || (word.first == "\"" && word.last == "\"")
        else { return word }
        return String(word.dropFirst().dropLast())
    }

    // MARK: - Remote workspace folder (for `zed ssh://…`)

    /// The workspace folder inside the pod, parsed from the `--workdir "…"`
    /// devpod bakes into the host alias' ProxyCommand in ~/.ssh/config:
    ///
    ///   Host wc-1.devpod
    ///     ProxyCommand "…/devpod" ssh --stdio … wc-1 --workdir "/workspace"
    ///
    /// Cheap and local — no round-trip to the pod. Returns nil when the alias
    /// or workdir is absent (callers fall back to the devpod default).
    public static func parseWorkdir(sshConfig: String, podID: String) -> String? {
        var inBlock = false
        for line in sshConfig.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("host ") {
                inBlock = t.dropFirst(5).trimmingCharacters(in: .whitespaces) == "\(podID).devpod"
                continue
            }
            guard inBlock, t.hasPrefix("ProxyCommand"), let r = t.range(of: "--workdir") else { continue }
            let rest = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("\"") {
                let inner = rest.dropFirst()
                if let end = inner.firstIndex(of: "\"") { return String(inner[..<end]) }
            } else if let word = rest.split(separator: " ").first {
                return String(word)
            }
        }
        return nil
    }

    /// `ssh://<id>.devpod/<workdir>` — the URL `zed` opens a remote folder
    /// with. The host alias carries user + ProxyCommand via ~/.ssh/config, so
    /// no credentials appear here. The workdir is percent-encoded (it lands in
    /// a URL's path component; a space would make the URL unparseable).
    public static func zedRemoteURL(podID: String, workdir: String) -> String {
        let path = workdir.hasPrefix("/") ? workdir : "/\(workdir)"
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "ssh://\(podID).devpod\(encoded)"
    }

    /// The `scp` destination for copying a local file to `remotePath` on the
    /// pod, over the same `<id>.devpod` alias `args`/`zedRemoteURL` rely on —
    /// no new auth. `remotePath` is expected already-resolved (e.g. under
    /// `/tmp`); this is purely mechanical, mirroring `zedRemoteURL`'s split
    /// between "build the locator" (here) and "decide the path" (the caller).
    public static func scpDestination(podID: String, remotePath: String) -> String {
        "\(podID).devpod:\(remotePath)"
    }

    /// Whether Zed already has a remote session to this pod, judged from a
    /// process table (`ps axww -o command=`). While a Zed window has the
    /// project open it keeps ssh processes whose ControlPath lives under a
    /// `zed-ssh-session…` temp dir and that target `<id>.devpod`; they exit
    /// when the window closes (ControlPersist=no). Used to focus the existing
    /// window instead of opening a duplicate. Substring-matching the full
    /// alias ("wc-2.devpod") can't cross-match prefix ids ("wc-2a.devpod").
    public static func zedSessionActive(psOutput: String, podID: String) -> Bool {
        psOutput.split(separator: "\n").contains {
            $0.contains("zed-ssh-session") && $0.contains("\(podID).devpod")
        }
    }

    /// Workdir for a pod from the user's ~/.ssh/config (devpod default
    /// "/workspace" when unavailable).
    public static func workdir(podID: String) -> String {
        let config = (try? String(
            contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8
        )) ?? ""
        return parseWorkdir(sshConfig: config, podID: podID) ?? "/workspace"
    }

    /// Prefer the active terminal's OSC 7-reported remote directory when it
    /// is available. Before the shell reaches its first prompt, retain the
    /// DevPod-configured workspace directory as the Zed launch fallback.
    public static func zedWorkdir(currentDirectory: String?, fallback: String) -> String {
        guard let currentDirectory, !currentDirectory.isEmpty else { return fallback }
        return currentDirectory
    }
}
