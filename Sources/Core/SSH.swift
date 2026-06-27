import Foundation

// Port of the SSH argument builder from src-tauri/src/pty.rs (ssh_args) and the
// notify port constants. We connect through the `<id>.devpod` host alias DevPod
// writes into ~/.ssh/config and carry the reverse notification tunnel via -R.
public enum SSH {
    /// Desktop-side notify HTTP listener port (Stack 7).
    public static let listenerPort: UInt16 = 17865
    /// Pod-side reverse-tunnel port the in-pod hook POSTs to.
    public static let podForwardPort: UInt16 = 8765

    /// TERM to advertise to the remote container. Validated/sanitized, defaulting
    /// to xterm-256color (mirrors get_sanitized_term).
    static func sanitizedTerm() -> String {
        let term = ProcessInfo.processInfo.environment["TERM"] ?? ""
        let ok = !term.isEmpty && term.allSatisfy {
            ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_"
        }
        return ok ? term : "xterm-256color"
    }

    public static func args(podID: String) -> [String] {
        let term = sanitizedTerm()
        return [
            "-tt",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "SetEnv=TERM=\(term)",
            "-R", "\(podForwardPort):localhost:\(listenerPort)",
            "\(podID).devpod",
        ]
    }
}
