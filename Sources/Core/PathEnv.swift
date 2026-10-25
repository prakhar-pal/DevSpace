import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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
        #if !os(Linux)
        if devpodIn(currentPath) { return }
        #endif

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
        // Profiles must never consume the backend's protocol handshake (or an
        // interactive terminal's input) while discovering executable paths.
        proc.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        defer { try? outPipe.fileHandleForReading.close() }
        if (try? runDesktopProcess(proc)) != nil {
            // Read while the shell runs: profiles can fill the pipe or leave
            // stdout open in a background child after the shell has exited.
            // Complete markers, not EOF, delimit this best-effort query.
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            var descriptor = pollfd(fd: outPipe.fileHandleForReading.fileDescriptor,
                                    events: Int16(POLLIN), revents: 0)
            while ProcessInfo.processInfo.systemUptime < deadline, output.count < 1_048_576 {
                let ready = poll(&descriptor, 1, 50)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 { continue }
                let count = read(descriptor.fd, &buffer, buffer.count)
                if count <= 0 { break }
                output.append(contentsOf: buffer.prefix(count))
                if let extracted = extractPath(String(decoding: output, as: UTF8.self)) {
                    shellPath = extracted
                    break
                }
            }
            if proc.isRunning {
                proc.terminate()
            }
        }

        #if os(Linux)
        // Desktop PATH also needs profile-installed Zed and SSH helpers even
        // when DevPod already resolves. Explicit launcher overrides win.
        let merged = mergePath(shellPath, currentPath)
        let finalPath = mergePath(fallbackStr, merged)
        #else
        let merged = mergePath(currentPath, shellPath)
        let finalPath = mergePath(merged, fallbackStr)
        #endif
        setenv("PATH", finalPath, 1)
    }
}
