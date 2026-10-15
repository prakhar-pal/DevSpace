import Foundation

public struct WorkspaceOperationDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let workspaceID: String?
    public let state: String
    public let output: String

    public init(id: String, kind: String, workspaceID: String?, state: String, output: String) {
        self.id = id
        self.kind = kind
        self.workspaceID = workspaceID
        self.state = state
        self.output = output
    }
}

/// Called on the controller's main queue. Each operation owns its CLI runner,
/// so cancelling provisioning cannot permanently disable polling or other jobs.
public final class WorkspaceCommandController {
    private final class Job {
        let runner = DevpodCLI()
        let message: BackendProtocolMessage
        let workspace: String?
        var output = Data()
        var cancelled = false
        init(_ message: BackendProtocolMessage, workspace: String?) {
            self.message = message
            self.workspace = workspace
        }
    }

    private let operations = WorkspaceOperationGate()
    private var jobs: [String: Job] = [:]
    private var stopping = false

    public init() {}

    public var onChange: (() -> Void)?

    public var snapshot: [WorkspaceOperationDescriptor] {
        jobs.keys.sorted().compactMap { key in
            guard let job = jobs[key] else { return nil }
            return WorkspaceOperationDescriptor(
                id: key, kind: job.message.kind,
                workspaceID: job.workspace,
                state: job.cancelled ? "cancelling" : "running",
                output: String(decoding: job.output, as: UTF8.self))
        }
    }

    public var hasActiveCommands: Bool {
        jobs.values.contains { $0.runner.hasActiveCommands }
    }

    public func submit(
        _ message: BackendProtocolMessage,
        prepare: (@escaping () -> Void) -> Void = { $0() },
        completion: @escaping (BackendProtocolMessage) -> Void
    ) throws {
        guard !stopping else { throw DevpodError("workspace commands are shutting down") }
        let key = message.id ?? UUID().uuidString
        guard jobs[key] == nil else { throw DevpodError("operation request is already active") }
        let args = try BackendWorkspaceCommands.arguments(message)
        let rawWorkspace = message.payload?["workspace_id"]?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let workspace = rawWorkspace.flatMap { $0.isEmpty ? nil : $0 }
        guard !jobs.values.contains(where: { $0.workspace == workspace }) else {
            throw DevpodError("workspace operation is already active")
        }
        let job = Job(message, workspace: workspace)
        jobs[key] = job
        onChange?()
        prepare { [weak self] in
            guard let self, !self.stopping, self.jobs[key] === job else { return }
            operations.submit(
                operation: {
                    let beforeIDs: Set<String>
                    let explicitID: String?
                    if message.kind == "create" {
                        let request = try Devpod.CreateRequest(
                            repositoryURL: message.payload?["repository"] ?? "",
                            id: message.payload?["workspace_id"])
                        explicitID = request.id
                        beforeIDs = Set(try Devpod.list(job.runner).map(\.id))
                        if let explicitID, beforeIDs.contains(explicitID) {
                            throw DevpodError("a workspace named \(explicitID) already exists")
                        }
                    } else {
                        beforeIDs = []
                        explicitID = nil
                    }
                    _ = try job.runner.run(
                        args,
                        onOutput: { [weak self] chunk in
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.jobs[key] === job else { return }
                                job.output.append(chunk)
                                if job.output.count > 16 * 1024 {
                                    job.output = Data(job.output.suffix(16 * 1024))
                                }
                                self.onChange?()
                            }
                        })
                    var payload = ["command": message.kind]
                    if message.kind == "create" {
                        let afterIDs = Set(try Devpod.list(job.runner).map(\.id))
                        if let created = WorkspaceController.createdWorkspaceID(
                            explicitID: explicitID, before: beforeIDs, after: afterIDs)
                        {
                            payload["created_id"] = created
                        }
                    }
                    return BackendProtocolMessage(
                        id: message.id, kind: "completed", payload: payload)
                },
                completion: { [weak self] result in
                    guard let self, self.jobs[key] === job else { return }
                    self.jobs.removeValue(forKey: key)
                    self.onChange?()
                    if job.cancelled {
                        completion(BackendProtocolMessage(id: message.id, kind: "cancelled"))
                    } else {
                        switch result {
                        case let .success(response): completion(response)
                        case let .failure(error):
                            completion(
                                BackendProtocolMessage(
                                    id: message.id, kind: "error",
                                    payload: ["message": String(describing: error)]))
                        }
                    }
                })
        }
    }

    public func cancel(_ requestID: String) throws {
        guard let job = jobs[requestID] else { throw DevpodError("operation not found") }
        job.cancelled = true
        job.runner.cancel()
        onChange?()
    }

    public func shutdown() {
        stopping = true
        operations.cancelAll()
        for job in jobs.values {
            job.cancelled = true
            job.runner.cancel()
        }
    }
}
