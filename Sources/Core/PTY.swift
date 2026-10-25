import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import CPTY

/// A pseudo-terminal session: forks a child process attached to a PTY, streams
/// its output, accepts input, and tracks resize + exit.
///
/// This is the host-managed PTY that backs the libghostty terminal surface
/// (libghostty in this build renders + handles input but does not own a PTY).
/// It is also the foundation the SSH session in Stack 6 builds on.
public final class PTYSession: @unchecked Sendable {
    private enum Lifecycle {
        case idle
        case running
        case terminated
    }

    private let lock = NSLock()
    // Descriptor use and close share one lock, so a recycled fd cannot receive
    // bytes intended for an old terminal. UI callers must enqueue writes/resize.
    private let ioLock = NSLock()
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    #if os(Linux)
    private var exitSource: DispatchSourceTimer?
    private var outputFinished = false
    private var pendingExitCode: Int32?
    private var childExitObserved = false
    private var groupCleanupScheduled = false
    #endif
    private var lifecycle: Lifecycle = .idle
    private var reapStarted = false
    private var reapInProgress = false

    /// Called with raw bytes read from the PTY (on a background queue).
    public var onOutput: ((Data) -> Void)?
    /// Called once with the child's exit code when the PTY closes.
    public var onExit: ((Int32) -> Void)?

    public init() {}

    /// Spawn `program` with `args` in a PTY of the given size. No-op if already
    /// started. `program` is resolved via PATH through `/usr/bin/env`, so a bare
    /// name (`ssh`, `devpod`) or an absolute path (`/bin/zsh`) both work.
    @discardableResult
    public func start(
        path program: String,
        args: [String],
        cols: UInt16,
        rows: UInt16,
        extraEnv: [String: String] = [:],
        workingDirectory: String? = nil
    ) -> Int32? {
        lock.lock()
        guard lifecycle == .idle else {
            lock.unlock()
            return nil
        }
        lifecycle = .running
        lock.unlock()

        // Build argv/envp in the PARENT so the child only makes async-signal-safe
        // calls (execve/_exit) — avoids the classic fork-in-a-threaded-process
        // malloc deadlock. Exec /usr/bin/env so `program` is resolved via PATH.
        var argv = Self.cArray(["/usr/bin/env", program] + args)
        var envp = Self.cArray(Self.buildEnv(extraEnv))
        let directory = workingDirectory.flatMap { strdup($0) }
        defer {
            Self.freeCArray(argv)
            Self.freeCArray(envp)
            free(directory)
        }

        var master: Int32 = 0
        let pid = devspace_forkpty(&master, rows, cols)
        if pid < 0 {
            lock.lock()
            lifecycle = .terminated
            lock.unlock()
            onExit?(-1)
            return nil
        }
        if pid == 0 {
            // CHILD
            if let directory, chdir(directory) != 0 { _exit(127) }
            _ = execve(argv[0]!, &argv, &envp)
            _exit(127)
        }

        // PARENT: fork copied argv/envp; this process can free its own copies.
        lock.lock()
        masterFD = master
        childPID = pid
        lock.unlock()
        startReading()
        startExitWatcher()
        return pid
    }

    public func write(_ data: Data) {
        ioLock.lock()
        defer { ioLock.unlock() }
        lock.lock(); let fd = masterFD; lock.unlock()
        guard fd >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                #if canImport(Darwin)
                let n = Darwin.write(fd, base + off, raw.count - off)
                #else
                let n = Glibc.write(fd, base + off, raw.count - off)
                #endif
                if n <= 0 { break }
                off += n
            }
        }
    }

    public func resize(cols: UInt16, rows: UInt16) {
        ioLock.lock()
        defer { ioLock.unlock() }
        lock.lock(); let fd = masterFD; lock.unlock()
        guard fd >= 0 else { return }
        _ = devspace_set_winsize(fd, rows, cols)
    }

    public func terminate() {
        lock.lock()
        lifecycle = .terminated
        let pid = childPID
        let source = readSource
        #if os(Linux)
        if pid > 0 { kill(pid, SIGTERM) }
        #endif
        lock.unlock()
        #if !os(Linux)
        if pid > 0 { kill(pid, SIGTERM) }
        #endif
        #if os(Linux)
        if pid > 0 { scheduleGroupCleanup(pid) }
        #endif
        source?.cancel()
        #if !os(Linux)
        if pid > 0 {
            DispatchQueue.global(qos: .utility).async { self.reap() }
        }
        #endif
    }

    // MARK: - Reading

    private func startReading() {
        #if os(Linux)
        // Linux libdispatch can deliver a freed epoll muxnote during read-source
        // teardown (swift-corelibs-libdispatch#949). Keep descriptor ownership
        // with a blocking reader instead; only this reader closes the master.
        let fd = masterFD
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                onOutput?(Data(buffer.prefix(count)))
            }
            ioLock.lock()
            lock.lock()
            masterFD = -1
            outputFinished = true
            let exitCode = pendingExitCode
            pendingExitCode = nil
            lock.unlock()
            _ = Glibc.close(fd)
            ioLock.unlock()
            if let exitCode { onExit?(exitCode) }
            reap()
        }
        #else
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
            self.ioLock.lock()
            self.lock.lock()
            let fd = self.masterFD
            self.masterFD = -1
            self.lock.unlock()
            if fd >= 0 { close(fd) }
            self.ioLock.unlock()
        }
        readSource = src
        src.resume()
        #endif
    }

    private func startExitWatcher() {
        #if os(Linux)
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now(), repeating: .milliseconds(50))
        source.setEventHandler { [weak self] in self?.observeChildExit() }
        lock.lock()
        guard !reapStarted else {
            lock.unlock()
            source.cancel()
            source.resume()
            return
        }
        exitSource = source
        source.resume()
        lock.unlock()
        #endif
    }

    #if os(Linux)
    private func observeChildExit() {
        lock.lock()
        guard !reapStarted, !reapInProgress, !childExitObserved, childPID > 0 else {
            lock.unlock()
            return
        }
        let pid = childPID
        // Observe without reaping: the reserved leader PID also protects its
        // process-group identity until the PTY reader has drained and closed.
        var info = siginfo_t()
        let exited = waitid(P_PID, UInt32(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_signo == SIGCHLD
        if exited { childExitObserved = true }
        lock.unlock()
        if exited { scheduleGroupCleanup(pid) }
    }

    private func scheduleGroupCleanup(_ pid: pid_t) {
        lock.lock()
        guard childPID == pid, !reapStarted, !groupCleanupScheduled else { lock.unlock(); return }
        groupCleanupScheduled = true
        lock.unlock()
        for (delay, signal) in [(0.25, SIGHUP), (1.0, SIGKILL)] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if self.childPID == pid && !self.reapStarted { kill(-pid, signal) }
                self.lock.unlock()
            }
        }
    }
    #endif

    private func reap() {
        lock.lock()
        guard !reapStarted, !reapInProgress else {
            lock.unlock()
            return
        }
        reapInProgress = true
        let pid = childPID
        lock.unlock()

        guard pid > 0 else { return }
        var status: Int32 = 0
        #if os(Linux)
        // Wait without releasing the PID reservation. Once exited, perform the
        // actual reap and clear its identity under the signaling lock.
        var info = siginfo_t()
        while waitid(P_PID, UInt32(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
        lock.lock()
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        childPID = -1
        lock.unlock()
        #else
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        #endif
        finishReap(pid: pid, status: status)
    }

    private func finishReap(pid: pid_t, status: Int32) {
        let code: Int32 = (status & 0x7F) == 0
            ? (status >> 8) & 0xFF
            : 128 + (status & 0x7F)
        lock.lock()
        guard !reapStarted else {
            lock.unlock()
            return
        }
        reapStarted = true
        reapInProgress = false
        childPID = -1
        lifecycle = .terminated
        #if os(Linux)
        let source = exitSource
        exitSource = nil
        let deliverExit = outputFinished
        if !deliverExit { pendingExitCode = code }
        #endif
        lock.unlock()
        #if os(Linux)
        source?.cancel()
        if deliverExit { onExit?(code) }
        #else
        onExit?(code)
        #endif
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
