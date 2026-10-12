import Foundation

public enum ImageUpload {
    public static func upload(_ runner: CommandRunning, podID: String, controlPath: String, source: URL) throws -> String {
        try Devpod.validateId(podID)
        guard !controlPath.isEmpty else { throw DevpodError("image upload requires an owned SSH master") }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 16 * 1024 * 1024 else {
            throw DevpodError("clipboard image must be a regular PNG file no larger than 16 MiB")
        }
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        guard file.readData(ofLength: 8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw DevpodError("clipboard image is not PNG")
        }
        let remote = "/tmp/devspace-paste-\(UUID().uuidString).png"
        // Never silently open another SSH connection if the owned master dies.
        _ = try runner.run(["-o", "ControlMaster=no", "-o", "ControlPath=\(controlPath)",
            "-o", "ProxyCommand=/bin/false", "-o", "BatchMode=yes", "--", source.path,
            SSH.scpDestination(podID: podID, remotePath: remote)])
        return remote
    }
}

public final class SSHUploadRunner: CommandRunning, @unchecked Sendable {
    private let runner = DesktopCommandRunner(executable: "/usr/bin/scp", superviseSSH: true)
    public init() {}
    public func run(_ args: [String]) throws -> String { try runner.run(args) }
    public func cancel() { runner.cancel() }
    public var hasActiveCommands: Bool { runner.hasActiveCommands }
}
