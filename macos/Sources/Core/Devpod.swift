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

/// Runs the real `devpod` binary, resolved via PATH (so PathEnv.repair must run
/// first when launched from Finder).
public struct DevpodCLI: CommandRunning {
    public init() {}
    public func run(_ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["devpod"] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            throw DevpodError("failed to spawn devpod: \(error.localizedDescription)")
        }
        // Read before wait to avoid deadlocking on a full pipe buffer.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let msg = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DevpodError(msg)
        }
        return String(decoding: outData, as: UTF8.self)
    }
}

public enum Devpod {
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
}
