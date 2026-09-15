import Foundation

/// The small surface a hidden SSH master needs from its backing process. Tests
/// provide a deterministic implementation; the app uses the Foundation one
/// below. The process invokes its supplied exit callback exactly once.
public protocol SSHTransportProcess: AnyObject {
    func terminate()
}

/// Schedules readiness retries and deadlines. Keeping time behind this
/// protocol makes pre-ready failure classification deterministic in tests.
public protocol SSHTransportScheduling: AnyObject {
    func schedule(after delay: TimeInterval, action: @escaping () -> Void)
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
    private var process: SSHTransportProcess?
    private var generation = UUID()
    private var didReportStartFailure = false

    public convenience init(
        podID: String,
        proxyCommand: String?,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        let path = Self.makeControlPath(podID: podID, bundleIdentifier: bundleIdentifier)
        self.init(
            podID: podID,
            proxyCommand: proxyCommand,
            bundleIdentifier: bundleIdentifier,
            controlPath: path,
            launch: Self.launchFoundationProcess,
            check: Self.runFoundationCheck,
            scheduler: MainQueueSSHTransportScheduler()
        )
    }

    public init(
        podID: String,
        proxyCommand: String?,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        controlPath: String,
        launch: @escaping Launch,
        check: @escaping Check,
        scheduler: SSHTransportScheduling
    ) {
        self.podID = podID
        self.proxyCommand = proxyCommand
        self.bundleIdentifier = bundleIdentifier
        self.controlPath = controlPath
        self.launch = launch
        self.check = check
        self.scheduler = scheduler
    }

    public func start() {
        guard state == .idle || state == .exited else { return }
        let newGeneration = UUID()
        generation = newGeneration
        didReportStartFailure = false
        state = .starting

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
        process?.terminate()
        process = nil
        reportStartFailure(.readinessTimedOut, generation: expectedGeneration)
    }

    private func processExited(_ exitCode: Int32, generation expectedGeneration: UUID) {
        guard generation == expectedGeneration,
              state == .starting || state == .ready
        else { return }
        process = nil
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
        onStartError?(error)
    }

    private static func makeControlPath(podID: String, bundleIdentifier: String?) -> String {
        let channel: String
        switch SSH.buildChannel(bundleIdentifier: bundleIdentifier) {
        case .production: channel = "prod"
        case .development: channel = "dev"
        }
        let digest = String(podID.hashValue, radix: 16).replacingOccurrences(of: "-", with: "n")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devspace-ssh", isDirectory: true)
            .appendingPathComponent(channel, isDirectory: true)
            .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            Log.write("ssh-transport: unable to create control directory: \(error)")
        }
        return directory.appendingPathComponent("\(digest.prefix(12)).sock").path
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

private final class FoundationSSHTransportProcess: SSHTransportProcess {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var stderrBuffer = Data()
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

    private func appendStderr(_ data: Data) {
        stderrBuffer.append(data)
        if stderrBuffer.count > maximumStderrBytes {
            stderrBuffer.removeFirst(stderrBuffer.count - maximumStderrBytes)
        }
    }
}
