import Foundation

/// Workspace operations accepted over the private frontend/backend pipe.
/// Callers schedule execution off the protocol reader and report failures
/// against the original request ID.
public enum BackendWorkspaceCommands {
    public static func execute(
        _ message: BackendProtocolMessage,
        runner: CommandRunning
    ) throws -> BackendProtocolMessage {
        _ = try runner.run(arguments(message))
        return BackendProtocolMessage(id: message.id, kind: "completed", payload: ["command": message.kind])
    }

    public static func arguments(_ message: BackendProtocolMessage) throws -> [String] {
        let payload = message.payload ?? [:]
        let args: [String]
        if message.kind == "create" {
            let request = try Devpod.CreateRequest(
                repositoryURL: payload["repository"] ?? "",
                id: payload["workspace_id"]
            )
            args = request.args
        } else {
            let id = payload["workspace_id"] ?? ""
            try Devpod.validateId(id)
            switch message.kind {
            case "start": args = Devpod.upArgs(id)
            case "stop": args = Devpod.stopArgs(id)
            case "recreate": args = try Devpod.recreateArgs(id)
            case "delete": args = ["delete", "--", id]
            default: throw DevpodError("unsupported workspace command: \(message.kind)")
            }
        }
        return args
    }
}
