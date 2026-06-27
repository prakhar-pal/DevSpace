import Foundation
import Darwin
import CPTY

/// A pseudo-terminal session: forks a child process attached to a PTY, streams
/// its output, accepts input, and tracks resize + exit.
///
/// This is the host-managed PTY that backs the libghostty terminal surface
/// (libghostty in this build renders + handles input but does not own a PTY).
/// It is also the foundation the SSH session in Stack 6 builds on.
public final class PTYSession: @unchecked Sendable {
    private let lock = NSLock()
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var started = false

    /// Called with raw bytes read from the PTY (on a background queue).
    public var onOutput: ((Data) -> Void)?
    /// Called once with the child's exit code when the PTY closes.
    public var onExit: ((Int32) -> Void)?

    public init() {}

    /// Spawn `path` with `args` in a PTY of the given size. No-op if already
    /// started. `path` must be an absolute executable path (no PATH search).
    public func start(
        path: String,
        args: [String],
        cols: UInt16,
        rows: UInt16,
        extraEnv: [String: String] = [:]
    ) {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()

        // Build argv/envp in the PARENT so the child only makes async-signal-safe
        // calls (execve/_exit) — avoids the classic fork-in-a-threaded-process
        // malloc deadlock.
        var argv = Self.cArray([path] + args)
        var envp = Self.cArray(Self.buildEnv(extraEnv))

        var master: Int32 = 0
        let pid = devspace_forkpty(&master, rows, cols)
        if pid < 0 {
            Self.freeCArray(argv)
            Self.freeCArray(envp)
            onExit?(-1)
            return
        }
        if pid == 0 {
            // CHILD
            _ = execve(argv[0], &argv, &envp)
            _exit(127)
        }

        // PARENT (argv/envp are intentionally leaked; the child copied them via exec)
        lock.lock()
        masterFD = master
        childPID = pid
        lock.unlock()
        startReading()
    }

    public func write(_ data: Data) {
        lock.lock(); let fd = masterFD; lock.unlock()
        guard fd >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, base + off, raw.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    public func resize(cols: UInt16, rows: UInt16) {
        lock.lock(); let fd = masterFD; lock.unlock()
        guard fd >= 0 else { return }
        _ = devspace_set_winsize(fd, rows, cols)
    }

    public func terminate() {
        lock.lock(); let pid = childPID; lock.unlock()
        if pid > 0 { kill(pid, SIGTERM) }
        readSource?.cancel()
    }

    // MARK: - Reading

    private func startReading() {
        let src = DispatchSource.makeReadSource(
            fileDescriptor: masterFD,
            queue: DispatchQueue.global(qos: .userInteractive)
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = buf.withUnsafeMutableBytes { ptr in
                read(self.masterFD, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                self.onOutput?(Data(buf[0 ..< n]))
            } else {
                self.readSource?.cancel()
                self.reap()
            }
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let fd = self.masterFD
            self.masterFD = -1
            self.lock.unlock()
            if fd >= 0 { close(fd) }
        }
        readSource = src
        src.resume()
    }

    private func reap() {
        lock.lock(); let pid = childPID; lock.unlock()
        var status: Int32 = 0
        if pid > 0 { waitpid(pid, &status, 0) }
        // Decode wait status into a conventional exit code.
        let code: Int32 = (status & 0x7F) == 0
            ? (status >> 8) & 0xFF
            : 128 + (status & 0x7F)
        onExit?(code)
    }

    // MARK: - Helpers

    private static func cArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var arr = strings.map { strdup($0) } as [UnsafeMutablePointer<CChar>?]
        arr.append(nil)
        return arr
    }

    private static func freeCArray(_ arr: [UnsafeMutablePointer<CChar>?]) {
        for p in arr where p != nil { free(p) }
    }

    private static func buildEnv(_ extra: [String: String]) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        for (k, v) in extra { env[k] = v }
        return env.map { "\($0.key)=\($0.value)" }
    }
}
