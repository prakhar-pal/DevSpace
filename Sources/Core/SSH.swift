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

    public static func args(podID: String) -> [String] {
        [
            "-tt",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "SetEnv=TERM=\(remoteTerm)",
            "-R", "\(podForwardPort):localhost:\(listenerPort)",
            "\(podID).devpod",
        ]
    }
}
