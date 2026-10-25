import Foundation

/// Adapts the existing hook/shell installers to an already-owned SSH master.
/// No proxy fallback may create another connection or wake a stopped pod.
public final class SSHWorkspaceCommandRunner: CommandRunning, @unchecked Sendable {
    private let podID: String
    private let controlPath: String
    private let runner = DesktopCommandRunner(executable: "/usr/bin/ssh", superviseSSH: true)
    public init(podID: String, controlPath: String) {
        self.podID = podID
        self.controlPath = controlPath
    }
    public func run(_ args: [String]) throws -> String {
        guard args.count == 6, Array(args.prefix(2)) == ["ssh", "--command"],
              Array(args.suffix(3)) == ["--start-services=false", "--", podID] else {
            throw DevpodError("unsupported workspace integration command")
        }
        return try runner.run(SSH.workspaceCommandArgs(podID: podID, controlPath: controlPath, command: args[2]))
    }
    public func cancel() { runner.cancel() }

    public func cancelNotificationForwarding(bundleIdentifier: String) throws {
        let ports = SSH.ports(bundleIdentifier: bundleIdentifier)
        _ = try runner.run([
            "-S", controlPath, "-O", "cancel", "-R",
            "\(ports.podForwardPort):localhost:\(ports.listenerPort)", "\(podID).devpod",
        ])
    }
}
