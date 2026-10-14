import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The small surface a hidden SSH master needs from its backing process. Tests
/// provide a deterministic implementation; the app uses the Foundation one
/// below. The process invokes its supplied exit callback exactly once.
public protocol SSHTransportProcess: AnyObject {
    var stderrTail: String { get }
    func terminate()
}

/// Schedules readiness retries and deadlines. Keeping time behind this
/// protocol makes pre-ready failure classification deterministic in tests.
public protocol SSHTransportScheduling: AnyObject {
    func schedule(after delay: TimeInterval, action: @escaping () -> Void)
}

/// The AppModel-facing lifecycle surface for a workspace's hidden SSH master.
/// Tests use this protocol to drive ready/exit events without a real process.
public protocol SSHTransportControlling: AnyObject {
    var controlPath: String { get }
    var proxyCommand: String? { get }
    var state: SSHTransportSession.State { get }
    var onReady: (() -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    var onStopped: (() -> Void)? { get set }
    var onStartError: ((SSHTransportSession.StartError) -> Void)? { get set }
    func start()
    func stop()
}

public extension SSHTransportControlling {
    var proxyCommand: String? { nil }
}

/// Owns one short ControlMaster socket directory. The metadata allows a later
/// instance to reject a live same-build owner and to remove only a proven-dead
/// owner left behind after a crash.
public final class SSHTransportControlLease {
    public enum Error: Swift.Error, Equatable {
        case workspaceAlreadyOwned
        case directoryUnavailable
    }

    private struct Owner: Codable {
        let bundleIdentifier: String
        let processID: Int32
        let processIdentity: String?
        let workspaceID: String
        let controlPath: String
        let leaseID: UUID
    }

    private let root: URL
    private let bundleIdentifier: String
    private let workspaceID: String
    private let processID: Int32
    private let isProcessAlive: (Int32) -> Bool
    private let processIdentity: (Int32) -> String?
    private let requestControlExit: (String, String) -> Void
    private let directory: URL
    private let claimURL: URL
    private let leaseID = UUID()
    public let controlPath: String

    public init(
        root: URL,
        bundleIdentifier: String,
        workspaceID: String,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        isProcessAlive: @escaping (Int32) -> Bool = SSHTransportControlLease.processIsAlive,
        processIdentity: @escaping (Int32) -> String? = SSHTransportControlLease.processIdentity,
        requestControlExit: ((String, String) -> Void)? = nil
    ) {
        self.root = root
        self.bundleIdentifier = bundleIdentifier
        self.workspaceID = workspaceID
        self.processID = processID
        self.isProcessAlive = isProcessAlive
        self.processIdentity = processIdentity
        self.requestControlExit = requestControlExit ?? Self.sendControlExit
        let key = Self.workspaceKey(workspaceID)
        directory = root.appendingPathComponent(key, isDirectory: true)
        claimURL = root.appendingPathComponent("\(key).owner.json")
        controlPath = directory.appendingPathComponent("master.sock").path
    }

    public func acquire() throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try validateRoot()
            for _ in 0 ..< 2 {
                do {
                    try publishOwnerClaim(fileManager: fileManager)
                    do {
                        try fileManager.createDirectory(
                            at: directory,
                            withIntermediateDirectories: false,
                            attributes: [.posixPermissions: 0o700]
                        )
                    } catch {
                        // The directory may predate this claim (for example
                        // a legacy or corrupt socket). We only own the claim
                        // just published, never that pre-existing directory.
                        releaseClaim()
                        throw Error.directoryUnavailable
                    }
                    return
                } catch {
                    guard fileManager.fileExists(atPath: claimURL.path) else {
                        throw Error.directoryUnavailable
                    }
                    try reclaimProvenDeadOwner(fileManager: fileManager)
                }
            }
            throw Error.directoryUnavailable
        } catch let error as Error {
            throw error
        } catch {
            throw Error.directoryUnavailable
        }
    }

    public func release() {
        let fileManager = FileManager.default
        guard ownsClaim(fileManager: fileManager) else { return }
        try? fileManager.removeItem(at: directory)
        releaseClaim()
    }

    private func releaseClaim() {
        let fileManager = FileManager.default
        guard ownsClaim(fileManager: fileManager) else { return }
        try? fileManager.removeItem(at: claimURL)
    }

    /// The short root lives directly under `/tmp`, where another local user
    /// could pre-create a predictable path. Refuse non-directories, symlinks,
    /// roots owned by another user, and group/world-accessible roots before
    /// publishing any lease metadata beneath them.
    private func validateRoot() throws {
        var info = stat()
        guard lstat(root.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(0o077)) == 0
        else {
            throw Error.directoryUnavailable
        }
    }

    private func ownsClaim(fileManager: FileManager) -> Bool {
        guard let data = try? Data(contentsOf: claimURL),
              let owner = try? JSONDecoder().decode(Owner.self, from: data)
        else { return false }
        return owner.leaseID == leaseID
            && owner.processID == processID
            && owner.workspaceID == workspaceID
            && owner.bundleIdentifier == bundleIdentifier
    }

    private func publishOwnerClaim(fileManager: FileManager) throws {
        let owner = Owner(
            bundleIdentifier: bundleIdentifier,
            processID: processID,
            processIdentity: processIdentity(processID),
            workspaceID: workspaceID,
            controlPath: controlPath,
            leaseID: leaseID
        )
        let temporary = root.appendingPathComponent(".\(UUID().uuidString).owner")
        defer { try? fileManager.removeItem(at: temporary) }
        try JSONEncoder().encode(owner).write(to: temporary, options: .atomic)
        guard link(temporary.path, claimURL.path) == 0 else {
            throw Error.directoryUnavailable
        }
    }

    private func reclaimProvenDeadOwner(fileManager: FileManager) throws {
        guard let data = try? Data(contentsOf: claimURL),
              let owner = try? JSONDecoder().decode(Owner.self, from: data),
              owner.bundleIdentifier == bundleIdentifier,
              owner.workspaceID == workspaceID,
              owner.controlPath == controlPath
        else {
            // A partially-created or unrecognised claim is deliberately left
            // alone. Removing it could kill or hijack someone else's socket.
            throw Error.directoryUnavailable
        }

        if isProcessAlive(owner.processID) {
            guard let recordedIdentity = owner.processIdentity,
                  recordedIdentity == processIdentity(owner.processID)
            else {
                // PID reuse (or an unverifiable process) is not evidence that
                // it is our previous DevSpace process.
                throw Error.directoryUnavailable
            }
            throw Error.workspaceAlreadyOwned
        }

        // The app process is dead, but an orphaned ssh master could still own
        // the socket. Ask that exact control path to exit before removal, then
        // prove the recorded owner remains dead.
        requestControlExit(owner.workspaceID, owner.controlPath)
        guard !isProcessAlive(owner.processID) else {
            throw Error.directoryUnavailable
        }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.removeItem(at: claimURL)
    }

    private static func workspaceKey(_ workspaceID: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in workspaceID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The OS process start time distinguishes a reused PID from the process
    /// that wrote the lease. Returning nil makes ownership conservative.
    public static func processIdentity(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
#if canImport(Darwin)
        var info = proc_bsdinfo()
        let bytes = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard bytes == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
#else
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let closingParen = stat.lastIndex(of: ")")
        else { return nil }
        // Fields after the process name begin at field 3; starttime is field 22.
        let fields = stat[stat.index(after: closingParen)...].split(separator: " ")
        guard fields.count > 19 else { return nil }
        return String(fields[19])
#endif
    }

    private static func sendControlExit(workspaceID: String, controlPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSH.controlExitArgs(podID: workspaceID, controlPath: controlPath)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try runDesktopProcess(process)
            process.waitUntilExit()
        } catch {
            // The lease is still safe to remove because its owning app PID was
            // independently proven dead; a stale or absent socket is normal.
        }
    }
}

public final class MainQueueSSHTransportScheduler: SSHTransportScheduling {
    public init() {}

    public func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
}

/// One non-interactive SSH master and its ControlMaster readiness lifecycle.
/// A workspace has at most one instance; visible terminal panes are clients of
/// its `controlPath` and deliberately never own the reverse forward.
public final class SSHTransportSession {
    public enum State: Equatable {
        case idle
        case starting
        case ready
        case stopping
        case exited
    }

    public enum StartError: Equatable {
        case launchFailed
        case readinessTimedOut
        case exitedBeforeReady(Int32)
        case workspaceAlreadyOwned
        case controlDirectoryUnavailable
    }

    public typealias Launch = (
        _ arguments: [String],
        _ onExit: @escaping (Int32) -> Void
    ) throws -> SSHTransportProcess
    public typealias Check = (
        _ arguments: [String],
        _ completion: @escaping (Bool) -> Void
    ) -> Void
    public typealias Prepare = (_ completion: @escaping (String?) -> Void) -> SSHTransportProcess

    public let controlPath: String
    public private(set) var state: State = .idle
    public private(set) var stderrTail = ""
    public var onReady: (() -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var onStopped: (() -> Void)?
    public var onStartError: ((StartError) -> Void)?

    private let podID: String
    public private(set) var proxyCommand: String?
    private let bundleIdentifier: String?
    private let launch: Launch
    private let check: Check
    private let scheduler: SSHTransportScheduling
    private let controlLease: SSHTransportControlLease?
    private let prepare: Prepare?
    private var preparation: SSHTransportProcess?
    private var preparationGeneration: UUID?
    private var process: SSHTransportProcess?
    private var generation = UUID()
    private var didReportStartFailure = false
    private var pendingStartFailure: (error: StartError, generation: UUID)?

    public convenience init(
        podID: String,
        proxyCommand: String?,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        resolveConfiguration: Bool = false
    ) {
        let channel: String
        switch SSH.buildChannel(bundleIdentifier: bundleIdentifier) {
        case .production: channel = "prod"
        case .development: channel = "dev"
        }
        let bundle = bundleIdentifier ?? "com.prakharp.devspace"
        let lease = SSHTransportControlLease(
            // OpenSSH appends a random suffix while it binds the ControlMaster
            // listener. The per-user macOS temporary directory is too deep for
            // that suffix to fit in a Unix-domain socket path. Scope the short
            // `/tmp` root to this effective user and build channel. Keeping it
            // one directory below sticky `/tmp` lets the lease validate every
            // ancestor it relies on before publishing session metadata.
            root: URL(fileURLWithPath: "/tmp")
                .appendingPathComponent("devspace-ssh-\(geteuid())-\(channel)", isDirectory: true),
            bundleIdentifier: bundle,
            workspaceID: podID
        )
        self.init(
            podID: podID,
            proxyCommand: proxyCommand,
            bundleIdentifier: bundleIdentifier,
            controlPath: lease.controlPath,
            launch: Self.launchFoundationProcess,
            check: Self.runFoundationCheck,
            scheduler: MainQueueSSHTransportScheduler(),
            controlLease: lease,
            prepare: resolveConfiguration ? { completion in
                FoundationSSHConfigProcess(podID: podID, completion: completion)
            } : nil
        )
    }

    public init(
        podID: String,
        proxyCommand: String?,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        controlPath: String,
        launch: @escaping Launch,
        check: @escaping Check,
        scheduler: SSHTransportScheduling,
        controlLease: SSHTransportControlLease? = nil,
        prepare: Prepare? = nil
    ) {
        self.podID = podID
        self.proxyCommand = proxyCommand
        self.bundleIdentifier = bundleIdentifier
        self.controlPath = controlPath
        self.launch = launch
        self.check = check
        self.scheduler = scheduler
        self.controlLease = controlLease
        self.prepare = prepare
    }

    public func start() {
        guard state == .idle || state == .exited else { return }
        let newGeneration = UUID()
        generation = newGeneration
        didReportStartFailure = false
        pendingStartFailure = nil
        state = .starting

        if let controlLease {
            do {
                try controlLease.acquire()
            } catch let error as SSHTransportControlLease.Error {
                switch error {
                case .workspaceAlreadyOwned:
                    reportStartFailure(.workspaceAlreadyOwned, generation: newGeneration)
                case .directoryUnavailable:
                    reportStartFailure(.controlDirectoryUnavailable, generation: newGeneration)
                }
                return
            } catch {
                reportStartFailure(.controlDirectoryUnavailable, generation: newGeneration)
                return
            }
        }

        if let prepare {
            preparationGeneration = newGeneration
            preparation = prepare { [weak self] proxy in
                guard let self, self.preparationGeneration == newGeneration, self.preparation != nil else { return }
                self.preparation = nil
                self.preparationGeneration = nil
                if self.state == .stopping {
                    self.completeStoppingProcess(generation: self.generation)
                    return
                }
                guard self.generation == newGeneration, self.state == .starting else { return }
                self.proxyCommand = proxy
                self.launchMaster(generation: newGeneration)
            }
            scheduler.schedule(after: 15) { [weak self] in
                guard let self, self.preparationGeneration == newGeneration else { return }
                self.readinessDeadlineReached(generation: newGeneration)
            }
            return
        }
        launchMaster(generation: newGeneration)
    }

    private func launchMaster(generation newGeneration: UUID) {
        do {
            process = try launch(
                SSH.masterArgs(
                    podID: podID,
                    proxyCommand: proxyCommand,
                    controlPath: controlPath,
                    bundleIdentifier: bundleIdentifier
                ),
                { [weak self] exitCode in self?.processExited(exitCode, generation: newGeneration) }
            )
        } catch {
            reportStartFailure(.launchFailed, generation: newGeneration)
            return
        }

        runReadinessCheck(generation: newGeneration)
        scheduler.schedule(after: 15) { [weak self] in
            self?.readinessDeadlineReached(generation: newGeneration)
        }
    }

    public func stop() {
        guard state == .starting || state == .ready else { return }
        let stoppingGeneration = UUID()
        generation = stoppingGeneration
        state = .stopping
        if let preparation {
            preparation.terminate()
            return
        }
        Self.requestFoundationControlExit(
            SSH.controlExitArgs(podID: podID, controlPath: controlPath)
        )
        process?.terminate()
        // The lease remains until the process's exit callback. Releasing it
        // here would let a new app start a second master while this one still
        // owns the control socket and remote reverse forward.
        if process == nil {
            completeStoppingProcess(generation: stoppingGeneration)
        }
    }

    private func runReadinessCheck(generation expectedGeneration: UUID) {
        guard generation == expectedGeneration, state == .starting else { return }
        check(SSH.controlCheckArgs(podID: podID, controlPath: controlPath)) { [weak self] isReady in
            guard let self,
                  self.generation == expectedGeneration,
                  self.state == .starting
            else { return }
            if isReady {
                self.state = .ready
                self.onReady?()
            } else {
                self.scheduler.schedule(after: 0.2) { [weak self] in
                    self?.runReadinessCheck(generation: expectedGeneration)
                }
            }
        }
    }

    private func readinessDeadlineReached(generation expectedGeneration: UUID) {
        guard generation == expectedGeneration, state == .starting else { return }
        stderrTail = process?.stderrTail ?? stderrTail
        state = .stopping
        // Do not start AppModel recovery yet. The current master may still
        // own its lease/socket briefly after terminate(), so a successor
        // would incorrectly diagnose itself as another DevSpace instance.
        pendingStartFailure = (.readinessTimedOut, expectedGeneration)
        if let preparation {
            preparation.terminate()
            return
        }
        process?.terminate()
        if process == nil {
            completeStoppingProcess(generation: expectedGeneration)
        }
    }

    private func processExited(_ exitCode: Int32, generation expectedGeneration: UUID) {
        if state == .stopping {
            stderrTail = process?.stderrTail ?? stderrTail
            completeStoppingProcess(generation: expectedGeneration)
            return
        }
        guard generation == expectedGeneration,
              state == .starting || state == .ready
        else { return }
        stderrTail = process?.stderrTail ?? stderrTail
        process = nil
        controlLease?.release()
        if state == .starting {
            reportStartFailure(.exitedBeforeReady(exitCode), generation: expectedGeneration)
        } else {
            state = .exited
            onExit?(exitCode)
        }
    }

    private func completeStoppingProcess(generation expectedGeneration: UUID) {
        process = nil
        state = .exited
        controlLease?.release()
        onStopped?()
        guard let pending = pendingStartFailure,
              pending.generation == expectedGeneration
        else { return }
        pendingStartFailure = nil
        reportStartFailure(pending.error, generation: expectedGeneration)
    }

    private func reportStartFailure(
        _ error: StartError,
        generation expectedGeneration: UUID,
        retainingLeaseUntilExit: Bool = false
    ) {
        guard generation == expectedGeneration, !didReportStartFailure else { return }
        didReportStartFailure = true
        if !retainingLeaseUntilExit {
            state = .exited
            if process == nil { controlLease?.release() }
        }
        onStartError?(error)
    }

    private static func launchFoundationProcess(
        arguments: [String],
        onExit: @escaping (Int32) -> Void
    ) throws -> SSHTransportProcess {
        try FoundationSSHTransportProcess(arguments: arguments, onExit: onExit)
    }

    private static func runFoundationCheck(
        arguments: [String],
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try runDesktopProcess(process)
                process.waitUntilExit()
                let succeeded = process.terminationStatus == 0
                DispatchQueue.main.async { completion(succeeded) }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    private static func requestFoundationControlExit(_ arguments: [String]) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? runDesktopProcess(process)
        }
    }
}

extension SSHTransportSession: SSHTransportControlling {}

private final class FoundationSSHConfigProcess: SSHTransportProcess {
    private let runner = DesktopCommandRunner(executable: "/usr/bin/ssh", superviseSSH: true)
    var stderrTail: String { "" }
    init(podID: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let proxy = SSH.resolveDevpodProxyCommand(podID: podID, runner: self.runner)
            DispatchQueue.main.async { completion(proxy) }
        }
    }
    func terminate() { runner.cancel() }
}

final class FoundationSSHTransportProcess: SSHTransportProcess {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var stderrBuffer = Data()
    private let stderrLock = NSLock()
    private let maximumStderrBytes = 8 * 1024

    init(arguments: [String], onExit: @escaping (Int32) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        #if os(Linux)
        // Avoid Linux epoll read-source teardown races, and do not report exit
        // until the diagnostic pipe has been drained through EOF.
        // ponytail: two blocking readers per master; multiplex with poll if
        // very large workspace counts exhaust dispatch workers.
        let readers = DispatchGroup()
        let output = stdout.fileHandleForReading
        let errors = stderr.fileHandleForReading
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            while !output.availableData.isEmpty {}
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let data = errors.availableData
                guard !data.isEmpty else { break }
                self?.appendStderr(data)
            }
            readers.leave()
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            readers.notify(queue: .main) { onExit(status) }
        }
        do {
            try runDesktopSSHMaster(process)
        } catch {
            // A failed spawn never closes the parent's write ends for us.
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            process.terminationHandler = nil
            throw error
        }
        #else
        stdout.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.appendStderr(data)
        }
        process.terminationHandler = { process in
            self.stdout.fileHandleForReading.readabilityHandler = nil
            self.stderr.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { onExit(process.terminationStatus) }
        }
        try runDesktopSSHMaster(process)
        #endif
    }

    func terminate() {
        #if !os(Linux)
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        #endif
        if process.isRunning { process.terminate() }
    }

    var stderrTail: String {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        return String(decoding: stderrBuffer, as: UTF8.self)
    }

    private func appendStderr(_ data: Data) {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        stderrBuffer.append(data)
        if stderrBuffer.count > maximumStderrBytes {
            stderrBuffer.removeFirst(stderrBuffer.count - maximumStderrBytes)
        }
    }
}
