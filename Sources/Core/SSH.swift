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
    public static func args(podID: String, tunnel: Bool = true) -> [String] {
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
        args.append("\(podID).devpod")
        return args
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
    /// no credentials appear here.
    public static func zedRemoteURL(podID: String, workdir: String) -> String {
        let path = workdir.hasPrefix("/") ? workdir : "/\(workdir)"
        return "ssh://\(podID).devpod\(path)"
    }

    /// Workdir for a pod from the user's ~/.ssh/config (devpod default
    /// "/workspace" when unavailable).
    public static func workdir(podID: String) -> String {
        let config = (try? String(
            contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8
        )) ?? ""
        return parseWorkdir(sshConfig: config, podID: podID) ?? "/workspace"
    }
}
