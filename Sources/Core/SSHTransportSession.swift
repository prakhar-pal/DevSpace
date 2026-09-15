import Foundation

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
    var state: SSHTransportSession.State { get }
    var onReady: (() -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    var onStartError: ((SSHTransportSession.StartError) -> Void)? { get set }
    func start()
    func stop()
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
        let processStartUptime: TimeInterval
        let workspaceID: String
        let controlPath: String
    }

    private let root: URL
    private let bundleIdentifier: String
    private let workspaceID: String
    private let processID: Int32
    private let isProcessAlive: (Int32) -> Bool
    private let directory: URL
    public let controlPath: String

    public init(
        root: URL,
        bundleIdentifier: String,
        workspaceID: String,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        isProcessAlive: @escaping (Int32) -> Bool = SSHTransportControlLease.processIsAlive
    ) {
        self.root = root
        self.bundleIdentifier = bundleIdentifier
        self.workspaceID = workspaceID
        self.processID = processID
        self.isProcessAlive = isProcessAlive
        directory = root.appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
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
            try cleanProvenDeadMatchingOwners(fileManager: fileManager)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let owner = Owner(
                bundleIdentifier: bundleIdentifier,
                processID: processID,
                processStartUptime: ProcessInfo.processInfo.systemUptime,
                workspaceID: workspaceID,
                controlPath: controlPath
            )
            let ownerURL = directory.appendingPathComponent("owner.json")
            try JSONEncoder().encode(owner).write(to: ownerURL, options: .atomic)
        } catch let error as Error {
            throw error
        } catch {
            try? fileManager.removeItem(at: directory)
            throw Error.directoryUnavailable
        }
    }

    public func release() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func cleanProvenDeadMatchingOwners(fileManager: FileManager) throws {
        let children = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in children {
            let ownerURL = child.appendingPathComponent("owner.json")
            guard let data = try? Data(contentsOf: ownerURL),
                  let owner = try? JSONDecoder().decode(Owner.self, from: data),
                  owner.bundleIdentifier == bundleIdentifier,
                  owner.workspaceID == workspaceID
            else { continue }
            if isProcessAlive(owner.processID) {
                throw Error.workspaceAlreadyOwned
            }
            try? fileManager.removeItem(at: child)
        }
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
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

    public let controlPath: String
    public private(set) var state: State = .idle
    public private(set) var stderrTail = ""
    public var onReady: (() -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var onStartError: ((StartError) -> Void)?

    private let podID: String
    private let proxyCommand: String?
    private let bundleIdentifier: String?
    private let launch: Launch
    private let check: Check
    private let scheduler: SSHTransportScheduling
    private let controlLease: SSHTransportControlLease?
    private var process: SSHTransportProcess?
    private var generation = UUID()
    private var didReportStartFailure = false

    public convenience init(
        podID: String,
        proxyCommand: String?,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        let channel: String
        switch SSH.buildChannel(bundleIdentifier: bundleIdentifier) {
        case .production: channel = "prod"
        case .development: channel = "dev"
        }
        let bundle = bundleIdentifier ?? "com.prakharp.devspace"
        let lease = SSHTransportControlLease(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("devspace-ssh", isDirectory: true)
                .appendingPathComponent(channel, isDirectory: true),
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
            controlLease: lease
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
        controlLease: SSHTransportControlLease? = nil
    ) {
        self.podID = podID
        self.proxyCommand = proxyCommand
        self.bundleIdentifier = bundleIdentifier
        self.controlPath = controlPath
        self.launch = launch
        self.check = check
        self.scheduler = scheduler
        self.controlLease = controlLease
    }

    public func start() {
        guard state == .idle || state == .exited else { return }
        let newGeneration = UUID()
        generation = newGeneration
        didReportStartFailure = false
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
        generation = UUID()
        state = .stopping
        process?.terminate()
        process = nil
        state = .exited
        controlLease?.release()
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
        process?.terminate()
        process = nil
        controlLease?.release()
        reportStartFailure(.readinessTimedOut, generation: expectedGeneration)
    }

    private func processExited(_ exitCode: Int32, generation expectedGeneration: UUID) {
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

    private func reportStartFailure(_ error: StartError, generation expectedGeneration: UUID) {
        guard generation == expectedGeneration, !didReportStartFailure else { return }
        didReportStartFailure = true
        state = .exited
        controlLease?.release()
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
                try process.run()
                process.waitUntilExit()
                let succeeded = process.terminationStatus == 0
                DispatchQueue.main.async { completion(succeeded) }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }
}

extension SSHTransportSession: SSHTransportControlling {}

private final class FoundationSSHTransportProcess: SSHTransportProcess {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var stderrBuffer = Data()
    private let stderrLock = NSLock()
    private let maximumStderrBytes = 8 * 1024

    init(arguments: [String], onExit: @escaping (Int32) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
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
        try process.run()
    }

    func terminate() {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
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
