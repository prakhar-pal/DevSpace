import Foundation
import Darwin

// Port of src-tauri/src/path_env.rs — repair PATH for GUI (LaunchServices)
// launches, which inherit only a minimal system PATH that omits where `devpod`
// lives (Homebrew, ~/.local/bin). We ask the user's login shell for its PATH
// and merge it into this process's environment so every child (devpod, the PTY,
// ssh's ProxyCommand) inherits it.
public enum PathEnv {
    /// Markers wrapped around $PATH so we can extract it even if rc files print
    /// noise to stdout.
    static let markStart = "__DEVSPACE_PATH_START__"
    static let markEnd = "__DEVSPACE_PATH_END__"

    /// `${PATH}` MUST be brace-delimited: the markers lead with underscores, so
    /// a bare `$PATH__DEVSPACE…` would be parsed by zsh as one (unset) variable.
    static func pathQueryCommand() -> String {
        "echo \"\(markStart)${PATH}\(markEnd)\""
    }

    static func extractPath(_ stdout: String) -> String? {
        guard let start = stdout.range(of: markStart) else { return nil }
        let rest = stdout[start.upperBound...]
        guard let end = rest.range(of: markEnd) else { return nil }
        return String(rest[rest.startIndex ..< end.lowerBound])
    }

    /// Merge `shellPath` into `current`, shell entries first, dropping empties
    /// and duplicates while preserving order within each source.
    static func mergePath(_ current: String, _ shellPath: String) -> String {
        var seen = Set<Substring>()
        var entries: [Substring] = []
        let parts = shellPath.split(separator: ":", omittingEmptySubsequences: false)
            + current.split(separator: ":", omittingEmptySubsequences: false)
        for part in parts {
            if part.isEmpty { continue }
            if seen.insert(part).inserted { entries.append(part) }
        }
        return entries.joined(separator: ":")
    }

    /// Whether a `devpod` executable (following symlinks) is reachable on the
    /// given colon-separated PATH.
    static func devpodIn(_ path: String) -> Bool {
        for dir in path.split(separator: ":", omittingEmptySubsequences: false) {
            if dir.isEmpty { continue }
            let candidate = (String(dir) as NSString).appendingPathComponent("devpod")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue {
                return true
            }
        }
        return false
    }

    /// Query the login shell's PATH and merge it into this process's PATH.
    /// Best-effort: on any failure the existing PATH is left untouched. MUST run
    /// before any thread is spawned (mutates the environment via setenv).
    public static func repair() {
        let env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? ""

        // Fast path: if devpod already resolves, skip the shell spawn entirely.
        if devpodIn(currentPath) { return }

        var fallbacks = ["/opt/homebrew/bin", "/usr/local/bin"]
        if let home = env["HOME"] {
            fallbacks.append((home as NSString).appendingPathComponent(".local/bin"))
        }
        let fallbackStr = fallbacks.joined(separator: ":")

        let shell = env["SHELL"] ?? "/bin/sh"
        var shellPath = ""

        // `-lc` (non-interactive login): sources profiles where Homebrew/PATH is
        // set, but avoids interactive .zshrc that can hang headlessly.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lc", pathQueryCommand()]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        if (try? proc.run()) != nil {
            let deadline = Date().addingTimeInterval(3)
            while proc.isRunning, Date() < deadline {
                usleep(50_000)
            }
            if proc.isRunning {
                proc.terminate()
            } else if proc.terminationStatus == 0 {
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                if let extracted = extractPath(String(decoding: data, as: UTF8.self)) {
                    shellPath = extracted
                }
            }
        }

        let merged = mergePath(currentPath, shellPath)
        let finalPath = mergePath(merged, fallbackStr)
        setenv("PATH", finalPath, 1)
    }
}
