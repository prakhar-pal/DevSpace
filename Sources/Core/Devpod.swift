import Foundation

// Port of src-tauri/src/devpod.rs — a thin wrapper around the `devpod` CLI:
// JSON model decoding, command-injection-safe id validation, and the
// list/status/delete commands. The CommandRunning protocol mirrors the Rust
// CommandRunner trait so tests can inject a fake.

public struct DevpodError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct Provider: Decodable, Equatable {
    public var name: String
    public init(name: String = "") { self.name = name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
    enum CodingKeys: String, CodingKey { case name }
}

public struct Source: Decodable, Equatable {
    public var gitRepository: String?
    public var localFolder: String?
    public init(gitRepository: String? = nil, localFolder: String? = nil) {
        self.gitRepository = gitRepository
        self.localFolder = localFolder
    }
    enum CodingKeys: String, CodingKey { case gitRepository, localFolder }
}

public struct Workspace: Decodable, Equatable {
    public var id: String
    public var provider: Provider
    public var source: Source
    public var lastUsed: String
    public var context: String

    enum CodingKeys: String, CodingKey { case id, provider, source, lastUsed, context }

    public init(
        id: String,
        provider: Provider = Provider(),
        source: Source = Source(),
        lastUsed: String = "",
        context: String = ""
    ) {
        self.id = id
        self.provider = provider
        self.source = source
        self.lastUsed = lastUsed
        self.context = context
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? Provider()
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? Source()
        lastUsed = try c.decodeIfPresent(String.self, forKey: .lastUsed) ?? ""
        context = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
    }
}

public struct WorkspaceStatus: Decodable, Equatable {
    public var id: String
    public var state: String
    public init(id: String, state: String) {
        self.id = id
        self.state = state
    }
    enum CodingKeys: String, CodingKey { case id, state }
}

public protocol CommandRunning: Sendable {
    func run(_ args: [String]) throws -> String
}

private final class CommandPipeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func store(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    var snapshot: Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Runs the real `devpod` binary, resolved via PATH (so PathEnv.repair must run
/// first when launched from Finder).
public final class DevpodCLI: CommandRunning, @unchecked Sendable {
    private let runner: DesktopCommandRunner
    public init(environment: [String: String]? = nil) {
        runner = DesktopCommandRunner(executable: "/usr/bin/env", prefix: ["devpod"], environment: environment)
    }
    public var hasActiveCommands: Bool { runner.hasActiveCommands }
    public func cancel() { runner.cancel() }
    public func run(_ args: [String]) throws -> String { try runner.run(args) }
    public func run(_ args: [String], onOutput: (@Sendable (Data) -> Void)?) throws -> String {
        try runner.run(args, onOutput: onOutput)
    }
}

/// Shared pipe draining and cancellation for DevPod and SSH configuration.
final class DesktopCommandRunner: CommandRunning, @unchecked Sendable {
    private let executable: String
    private let prefix: [String]
    private let superviseSSH: Bool
    private let environment: [String: String]?
    private let processLock = NSLock()
    private var activeProcesses: [Process] = []
    private var cancelled = false

    init(executable: String, prefix: [String] = [], environment: [String: String]? = nil,
         superviseSSH: Bool = false) {
        self.executable = executable
        self.prefix = prefix
        self.environment = environment
        self.superviseSSH = superviseSSH
    }

    public var hasActiveCommands: Bool {
        processLock.lock()
        defer { processLock.unlock() }
        return !activeProcesses.isEmpty
    }

    /// Terminate every command currently started by this runner. Completion
    /// still flows through `run`, allowing callers to cleanly serialize state
    /// changes instead of abandoning a child process during backend shutdown.
    public func cancel() {
        processLock.lock()
        cancelled = true
        let processes = activeProcesses
        processLock.unlock()
        for process in processes where process.isRunning {
            process.terminate()
        }
    }

    public func run(_ args: [String]) throws -> String {
        try run(args, onOutput: nil)
    }

    /// Raw chunks preserve UTF-8 split across pipe reads. Observers marshal
    /// them onto their controller queue; both pipes are always drained.
    public func run(_ args: [String], onOutput: (@Sendable (Data) -> Void)?) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = prefix + args
        // Commands must never compete with the backend's NDJSON reader.
        proc.standardInput = FileHandle.nullDevice
        if let environment {
            proc.environment = ProcessInfo.processInfo.environment.merging(environment) { _, supplied in supplied }
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // Serialize spawn/registration with cancellation: shutdown must not
        // miss a child between Process.run() and adding it to the active set.
        processLock.lock()
        guard !cancelled else {
            processLock.unlock()
            throw DevpodError("devpod runner cancelled")
        }
        do {
            if superviseSSH { try runDesktopSSHMaster(proc) }
            else { try runDesktopProcess(proc) }
        } catch {
            processLock.unlock()
            throw DevpodError("failed to spawn devpod: \(error.localizedDescription)")
        }
        activeProcesses.append(proc)
        processLock.unlock()
        defer {
            processLock.lock()
            activeProcesses.removeAll { $0 === proc }
            processLock.unlock()
        }
        // Drain both pipes concurrently: waiting for stdout EOF first can
        // deadlock while the command is blocked on a full stderr buffer.
        let stderr = CommandPipeOutput()
        let stderrRead = DispatchGroup()
        let stderrHandle = errPipe.fileHandleForReading
        stderrRead.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.store(Self.drain(stderrHandle, onOutput: onOutput))
            stderrRead.leave()
        }
        let outData = Self.drain(outPipe.fileHandleForReading, onOutput: onOutput)
        stderrRead.wait()
        let errData = stderr.snapshot
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let msg = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DevpodError(msg)
        }
        return String(decoding: outData, as: UTF8.self)
    }

    private static func drain(_ handle: FileHandle, onOutput: (@Sendable (Data) -> Void)?) -> Data {
        var result = Data()
        var pending = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                if !pending.isEmpty { onOutput?(pending) }
                return result
            }
            result.append(chunk)
            guard let onOutput else { continue }
            pending.append(chunk)
            // Do not mix another pipe's bytes into an incomplete UTF-8 scalar.
            // Retain at most three trailing bytes until this pipe's next read.
            let bytes = Array(pending)
            var end = bytes.count
            var start = end - 1
            while start > 0 && bytes[start] & 0xc0 == 0x80 { start -= 1 }
            let leading = bytes[start]
            let width = leading & 0xf8 == 0xf0 ? 4 : leading & 0xf0 == 0xe0 ? 3 : leading & 0xe0 == 0xc0 ? 2 : 1
            if end - start < width { end = start }
            if end > 0 { onOutput(Data(bytes.prefix(end))) }
            pending = Data(bytes.suffix(bytes.count - end))
        }
    }
}

public enum Devpod {
    public struct CreateRequest: Equatable, Sendable {
        public let repositoryURL: String
        public let id: String?

        public init(repositoryURL: String, id: String?) throws {
            let repositoryURL = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !repositoryURL.isEmpty else {
                throw DevpodError("repository URL is required")
            }
            let normalizedID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalizedID, !normalizedID.isEmpty {
                try Devpod.validateId(normalizedID)
                self.id = normalizedID
            } else {
                self.id = nil
            }
            self.repositoryURL = repositoryURL
        }

        public var args: [String] {
            var result = ["up", "--ide", "none"]
            if let id { result += ["--id", id] }
            result += ["--", repositoryURL]
            return result
        }
    }

    public static func parseList(_ json: String) throws -> [Workspace] {
        do {
            return try JSONDecoder().decode([Workspace].self, from: Data(json.utf8))
        } catch {
            throw DevpodError("\(error)")
        }
    }

    public static func parseStatus(_ json: String) throws -> WorkspaceStatus {
        do {
            return try JSONDecoder().decode(WorkspaceStatus.self, from: Data(json.utf8))
        } catch {
            throw DevpodError("\(error)")
        }
    }

    /// Reject ids that could smuggle CLI flags into the subprocess (e.g. a
    /// leading `-`). Real devpod ids are ASCII alphanumeric with `-`/`_`.
    public static func validateId(_ id: String) throws {
        func alnum(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        let valid = !id.isEmpty
            && id.count <= 64
            && (id.first.map(alnum) ?? false)
            && id.allSatisfy { alnum($0) || $0 == "_" || $0 == "-" }
        guard valid else { throw DevpodError("invalid workspace id: \"\(id)\"") }
    }

    public static func list(_ runner: CommandRunning) throws -> [Workspace] {
        // --skip-pro avoids slow pro-workspace enumeration we don't display.
        let out = try runner.run(["list", "--output", "json", "--skip-pro"])
        return try parseList(out)
    }

    public static func status(_ runner: CommandRunning, id: String) throws -> WorkspaceStatus {
        try validateId(id)
        // `--` terminates flag parsing so a hostile id can't be read as a flag.
        let out = try runner.run(["status", "--output", "json", "--timeout", "10s", "--", id])
        return try parseStatus(out)
    }

    public static func delete(_ runner: CommandRunning, id: String) throws {
        try validateId(id)
        _ = try runner.run(["delete", "--", id])
    }

    // MARK: - Action argument builders (run via a PTY for up/stop, detached for ide)

    /// `devpod up --ide none -- <id>` — start a workspace, streaming its log.
    public static func upArgs(_ id: String) -> [String] {
        ["up", "--ide", "none", "--", id]
    }

    /// `devpod up --recreate --ide none -- <id>` — replace a workspace's
    /// container and stream the provisioning log without opening another IDE.
    public static func recreateArgs(_ id: String) throws -> [String] {
        try validateId(id)
        return ["up", "--recreate", "--ide", "none", "--", id]
    }

    /// `devpod stop -- <id>` — stop a workspace, streaming its shutdown log.
    /// `--` terminates flag parsing so the id can't be read as a flag.
    public static func stopArgs(_ id: String) -> [String] {
        ["stop", "--", id]
    }

    /// `devpod up --ide <ide> -- <id>` — open the workspace in an IDE.
    public static func ideArgs(_ id: String, ide: String) -> [String] {
        ["up", "--ide", ide, "--", id]
    }

    public static func validateIde(_ ide: String) throws {
        let valid = ide.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        guard valid, !ide.isEmpty else { throw DevpodError("invalid ide: \"\(ide)\"") }
    }
}
