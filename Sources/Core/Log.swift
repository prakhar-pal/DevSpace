import Foundation
#if os(Linux)
import Glibc
#endif

/// Debug-only diagnostics log, mirroring the Rust backend's `notify::log`.
///
/// In Debug builds the app's Info.plist carries `DevSpaceLogPath` pointing at
/// `~/Library/Logs/DevSpaceDev.log` (symlinked from `<repo>/.tmp/devspace.log`
/// — the repo lives under the TCC-gated ~/Documents, where an ad-hoc build's
/// first write can block on a consent prompt); lines are appended with a
/// timestamp. In
/// Release builds the key is empty, so every call is a no-op — matching the
/// existing behavior where release builds write no log.
/// Linux Debug development builds append to the private XDG state directory;
/// production channels and Release builds never enable Linux diagnostics.
public enum Log {
    private static let path: String? = {
        #if os(Linux)
        #if DEBUG
        guard ProcessInfo.processInfo.environment["DEVSPACE_BUILD_CHANNEL"] == "development" else { return nil }
        return DevSpacePaths.current.stateDirectory.appendingPathComponent("devspace.log").path
        #else
        return nil
        #endif
        #else
        guard
            let p = Bundle.main.object(forInfoDictionaryKey: "DevSpaceLogPath") as? String,
            !p.isEmpty
        else { return nil }
        return p
        #endif
    }()

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func write(_ message: String) {
        guard let path else { return }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let url = URL(fileURLWithPath: path)
        #if os(Linux)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & 0o077 == 0 else { return }
        let descriptor = Glibc.open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { return }
        defer { _ = Glibc.close(descriptor) }
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              fileInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileInfo.st_uid == geteuid(), fchmod(descriptor, 0o600) == 0 else { return }
        data.withUnsafeBytes { bytes in
            _ = Glibc.write(descriptor, bytes.baseAddress, bytes.count)
        }
        #else
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        #endif
    }

    /// Whether diagnostics logging is active (true only in Debug builds with a
    /// configured path). Exposed so callers/tests can assert the wiring.
    public static var isEnabled: Bool { path != nil }
}
