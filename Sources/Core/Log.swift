import Foundation

/// Debug-only diagnostics log, mirroring the Rust backend's `notify::log`.
///
/// In Debug builds the app's Info.plist carries `DevSpaceLogPath` pointing at
/// `~/Library/Logs/DevSpaceDev.log` (symlinked from `<repo>/.tmp/devspace.log`
/// — the repo lives under the TCC-gated ~/Documents, where an ad-hoc build's
/// first write can block on a consent prompt); lines are appended with a
/// timestamp. In
/// Release builds the key is empty, so every call is a no-op — matching the
/// existing behavior where release builds write no log.
public enum Log {
    private static let path: String? = {
        guard
            let p = Bundle.main.object(forInfoDictionaryKey: "DevSpaceLogPath") as? String,
            !p.isEmpty
        else { return nil }
        return p
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
    }

    /// Whether diagnostics logging is active (true only in Debug builds with a
    /// configured path). Exposed so callers/tests can assert the wiring.
    public static var isEnabled: Bool { path != nil }
}
