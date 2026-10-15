import Foundation
import Glibc
import DevSpaceCore

private func requestedIdentity() -> DevSpaceRuntimeIdentity {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let index = arguments.firstIndex(of: "--channel"), arguments.indices.contains(index + 1),
          let channel = DevSpaceRuntimeIdentity.Channel(rawValue: arguments[index + 1])
    else {
        return DevSpaceRuntimeIdentity(environment: ProcessInfo.processInfo.environment)
    }
    return DevSpaceRuntimeIdentity(channel: channel)
}

// Repair before constructing runners, queues or services. Shell startup output
// is captured by PathEnv, never emitted onto the private protocol channel.
PathEnv.repair()
if CommandLine.arguments.contains("--print-path") {
    print(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
    exit(0)
}
private let outputLock = NSLock()
private let outputQueue = DispatchQueue(label: "devspace.protocol-output")
private var pendingOutputBytes = 0
// Broken frontend pipes are shutdown events, not permission to abandon owned
// subprocesses through SIGPIPE's default immediate process termination.
private let ignoreBrokenPipe = Glibc.signal(SIGPIPE, SIG_IGN)

private func send(_ message: BackendProtocolMessage) -> Bool {
    guard let line = try? message.encodeLine() else { return false }
    outputLock.lock()
    guard line.count <= BackendProtocol.maximumFrameBytes,
          pendingOutputBytes <= BackendProtocol.maximumFrameBytes - line.count else {
        outputLock.unlock()
        DispatchQueue.main.async { shutdownExitStatus = 1; shutdown(nil) }
        return false
    }
    pendingOutputBytes += line.count
    outputLock.unlock()
    _ = ignoreBrokenPipe
    outputQueue.async {
        let written = line.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = Glibc.write(STDOUT_FILENO, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        outputLock.lock()
        pendingOutputBytes -= line.count
        outputLock.unlock()
        if !written {
            DispatchQueue.main.async {
                shutdownExitStatus = 1
                shutdown(nil)
            }
        }
    }
    return true
}

private func fail(_ message: String) {
    FileHandle.standardError.write(Data("DevSpaceLinuxBackend: \(message)\n".utf8))
    shutdownExitStatus = 1
    shutdown(nil)
}

private func sendSnapshot(_ id: String?, from controller: WorkspaceController) -> Bool {
    var states = terminals.connectionStates
    for (workspace, recovery) in sshRecoveries where states[workspace] == nil {
        if recovery.waiting { states[workspace] = "connecting" }
        else if recovery.failed { states[workspace] = "failed" }
    }
    guard let data = try? JSONEncoder().encode(controller.snapshot),
          let json = String(data: data, encoding: .utf8),
          let stateData = try? JSONEncoder().encode(states),
          let connections = String(data: stateData, encoding: .utf8)
    else { return false }
    return send(BackendProtocolMessage(id: id, kind: "snapshot", payload: ["json": json, "connections": connections]))
}

let identity = requestedIdentity()
Log.write("Linux backend starting")
let paths = DevSpacePaths(platform: .linux, channel: identity.channel)
let controller = WorkspaceController(layout: LayoutStore.load(paths: paths))
let operations = WorkspaceOperationGate()
let workspaceCommands = WorkspaceCommandController()
let devpod = DevpodCLI()
var handshaken = false
var stopping = false
var shutdownExitStatus: Int32 = 0
var pollGeneration: UInt64 = 0
var seenDefinitive: Set<String> = []
var autoConnect: Set<String> = []
var starting: Set<String> = []
var stateNotifyGate = StateNotifyGate()
var statusDebouncer = RunningDebouncer()
var notifyListener: NotifyListener?
var notifyToken = ""
private final class IntegrationJob {
    let workspace: String
    let runner: CommandRunning
    private let cancelCommand: () -> Void
    var cancelled = false
    init(workspace: String, controlPath: String?) {
        self.workspace = workspace
        if let controlPath {
            let command = SSHWorkspaceCommandRunner(podID: workspace, controlPath: controlPath)
            runner = command
            cancelCommand = { command.cancel() }
        } else {
            let command = DevpodCLI()
            runner = command
            cancelCommand = { command.cancel() }
        }
    }
    func cancel() { cancelled = true; cancelCommand() }
}
private var integrationJobs: [UUID: IntegrationJob] = [:]
private final class UploadJob {
    let workspace: String
    let runner = SSHUploadRunner()
    var cancelled = false
    init(workspace: String) { self.workspace = workspace }
    func cancel() { cancelled = true; runner.cancel() }
}
private var uploadJobs: [UUID: UploadJob] = [:]
private final class SSHRecovery {
    var budget = SSHRecoveryBudget()
    var generation = UUID()
    var waiting = false
    var failed = false
}
private var sshRecoveries: [String: SSHRecovery] = [:]
let terminals = WorkspaceTerminalController(identity: identity,
    makeTransport: { workspace in
        SSHTransportSession(podID: workspace, proxyCommand: nil,
                            bundleIdentifier: identity.channel.applicationIdentifier,
                            resolveConfiguration: true)
    }, emit: { effect in
        guard let data = try? JSONEncoder().encode(effect),
              let json = String(data: data, encoding: .utf8) else { return }
        let panesChanged = effect.kind == "terminal_launch" || effect.kind == "terminal_close"
        if panesChanged { controller.setTerminalPanes(terminals.panes) }
        _ = send(BackendProtocolMessage(kind: effect.kind, payload: ["json": json]))
        if panesChanged { _ = sendSnapshot(nil, from: controller) }
    })

workspaceCommands.onChange = {
    controller.setOperations(workspaceCommands.snapshot)
    if handshaken && !stopping { _ = sendSnapshot(nil, from: controller) }
}

terminals.onConnectionChange = {
    if handshaken && !stopping { _ = sendSnapshot(nil, from: controller) }
}

terminals.onFirstOutput = { workspace, generation in
    if let recovery = sshRecoveries[workspace] {
        recovery.budget.didConnect()
        recovery.generation = UUID()
        recovery.waiting = false
        recovery.failed = false
    }
    if stateNotifyGate.confirmSSH(workspace) { emitStateNotification(workspace, event: "started") }
    if integrationJobs.values.contains(where: { $0.workspace == workspace }) { return false }
    do { try installIntegration(workspace, requestID: nil, generation: generation) }
    catch {
        _ = terminals.finishShellIntegration(workspace: workspace, generation: generation, succeeded: false)
        _ = send(BackendProtocolMessage(kind: "platform_error", payload: ["message": "Claude integration unavailable: \(error)"]))
    }
    return true
}
terminals.onDisconnect = { workspace, _ in
    for job in integrationJobs.values where job.workspace == workspace { job.cancel() }
    for job in uploadJobs.values where job.workspace == workspace { job.cancel() }
}
terminals.beforeDisconnect = { workspace, _, controlPath, completion in
    guard terminals.hasProducedOutput(workspace) else { completion(); return }
    removeHooksWhenIntegrationSettles(workspace, controlPath: controlPath, completion: completion)
}
terminals.onFocus = { workspace in controller.select(workspace) }
terminals.onLastPaneClosed = { workspace in
    autoConnect.remove(workspace)
    sshRecoveries[workspace] = nil
}
terminals.onFailure = { workspace, failure in
    guard !stopping, autoConnect.contains(workspace),
          !controller.snapshot.operations.contains(where: { $0.workspaceID == workspace }) else { return }
    let recovery = sshRecoveries[workspace] ?? SSHRecovery()
    if case .disruption = failure, sshRecoveries[workspace] == nil { recovery.budget.didConnect() }
    sshRecoveries[workspace] = recovery
    if failure == .startup(.workspaceAlreadyOwned) {
        recovery.waiting = false
        recovery.failed = true
        _ = sendSnapshot(nil, from: controller)
    } else { scheduleRecovery(workspace, recovery: recovery) }
}

private func beginConnection(_ workspace: String, reload: Bool = false) throws {
    let recovery = SSHRecovery()
    sshRecoveries[workspace] = recovery
    do {
        if reload { try terminals.reconnect(workspace) }
        else { try terminals.connect(workspace) }
    } catch {
        recovery.failed = true
        throw error
    }
}

private func scheduleRecovery(_ workspace: String, recovery: SSHRecovery) {
    guard sshRecoveries[workspace] === recovery, !stopping, autoConnect.contains(workspace) else { return }
    guard let delay = recovery.budget.nextDelay() else {
        recovery.waiting = false
        recovery.failed = true
        _ = sendSnapshot(nil, from: controller)
        return
    }
    recovery.waiting = true
    recovery.failed = false
    let generation = UUID()
    recovery.generation = generation
    _ = sendSnapshot(nil, from: controller)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        guard recoveryIsCurrent(workspace, recovery: recovery, generation: generation) else { return }
        // Never trust an earlier Running poll when reconnecting: inactivity
        // shutdown may have happened during the backoff. Status cannot wake it.
        operations.submit(operation: { try Devpod.status(devpod, id: workspace) }, completion: { result in
            guard recoveryIsCurrent(workspace, recovery: recovery, generation: generation) else { return }
            switch result {
            case .success(let status) where status.state == "Running":
                recovery.waiting = false
                do { try terminals.connect(workspace) }
                catch {
                    _ = send(BackendProtocolMessage(kind: "platform_error", payload: ["message": "SSH retry failed for \(workspace): \(error)"]))
                    scheduleRecovery(workspace, recovery: recovery)
                }
            case .success:
                autoConnect.remove(workspace)
                sshRecoveries[workspace] = nil
                _ = sendSnapshot(nil, from: controller)
            case .failure:
                scheduleRecovery(workspace, recovery: recovery)
            }
        })
    }
}

private func recoveryIsCurrent(_ workspace: String, recovery: SSHRecovery, generation: UUID) -> Bool {
    !stopping && sshRecoveries[workspace] === recovery && recovery.generation == generation
        && autoConnect.contains(workspace) && !terminals.openedWorkspaces.contains(workspace)
        && !controller.snapshot.operations.contains { $0.workspaceID == workspace }
}

private func emitStateNotification(_ workspace: String, event: String) {
    guard !stopping, controller.receiveNotification(workspaceID: workspace) else { return }
    _ = send(BackendProtocolMessage(kind: "platform_notify", payload: [
        "workspace_id": workspace,
        "title": controller.snapshot.layout.aliases[workspace] ?? workspace,
        "message": "Workspace \(event)", "event": event,
    ]))
    _ = sendSnapshot(nil, from: controller)
}

private func installIntegration(_ workspace: String, requestID: String?, generation: UUID? = nil) throws {
    try Devpod.validateId(workspace)
    let controlPath = terminals.controlPath(for: workspace)
    guard controller.canInstallIntegration(workspaceID: workspace, ownedControlPath: controlPath) else {
        throw DevpodError("workspace is not running: \(workspace)")
    }
    guard !integrationJobs.values.contains(where: { $0.workspace == workspace }) else {
        throw DevpodError("Claude integration installation already in progress")
    }
    // The first-output path always has a ready owned master. The explicit
    // installation command can also be used without an open terminal.
    let id = UUID(), job = IntegrationJob(workspace: workspace, controlPath: controlPath), token = notifyToken
    let notificationAvailable = !token.isEmpty && notifyListener != nil
    integrationJobs[id] = job
    DispatchQueue.global(qos: .utility).async {
        let shellResult = Result { try ShellIntegration.inject(job.runner, podID: workspace, token: token) }
        DispatchQueue.main.async {
            guard !stopping, !job.cancelled, let generation else { return }
            let succeeded: Bool
            if case .success = shellResult { succeeded = true } else { succeeded = false }
            _ = terminals.finishShellIntegration(workspace: workspace, generation: generation, succeeded: succeeded)
        }
        let hooksResult = Result {
            guard notificationAvailable else { throw DevpodError("notification listener unavailable") }
            try Hooks.inject(job.runner, podID: workspace, token: token,
                             installManualHelper: identity.channel == .development)
        }
        DispatchQueue.main.async {
            integrationJobs.removeValue(forKey: id)
            guard !stopping else { return }
            if job.cancelled {
                if let requestID { _ = send(BackendProtocolMessage(id: requestID, kind: "cancelled")) }
                terminals.retryIntegration(workspace)
                return
            }
            var failures: [String] = []
            if case .failure = shellResult { failures.append("Shell integration could not be installed") }
            if case .failure = hooksResult { failures.append("Claude notification hooks could not be installed; existing invalid settings are left untouched") }
            if failures.isEmpty {
                if let requestID { _ = send(BackendProtocolMessage(id: requestID, kind: "completed")) }
            } else {
                // CLI diagnostics may contain encoded credentials; never forward
                // installation commands or their raw stderr into UI/logs.
                _ = send(BackendProtocolMessage(id: requestID, kind: requestID == nil ? "platform_error" : "error",
                    payload: ["message": failures.joined(separator: "; ")]))
            }
            terminals.retryIntegration(workspace)
        }
    }
}

private func removeHooksWhenIntegrationSettles(
    _ workspace: String,
    controlPath: String,
    completion: @escaping () -> Void
) {
    guard !integrationJobs.values.contains(where: { $0.workspace == workspace }) else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            removeHooksWhenIntegrationSettles(workspace, controlPath: controlPath, completion: completion)
        }
        return
    }
    let runner = SSHWorkspaceCommandRunner(podID: workspace, controlPath: controlPath)
    DispatchQueue.global(qos: .utility).async {
        let result = Result {
            // Withdraw our forward before checking the peer. Concurrent
            // disconnects then agree on whether any notification tunnel remains.
            try runner.cancelNotificationForwarding(bundleIdentifier: identity.channel.applicationIdentifier)
            let otherPort = identity.channel == .development
                ? PodPortRouting.productionPort : PodPortRouting.developmentPort
            try Hooks.remove(runner, podID: workspace, preservingTunnelOnPort: otherPort)
        }
        DispatchQueue.main.async {
            if case .failure = result, !stopping {
                _ = send(BackendProtocolMessage(kind: "platform_error", payload: [
                    "message": "Claude notification hooks could not be removed from \(workspace)",
                ]))
            }
            completion()
        }
    }
}

private func pasteImage(_ message: BackendProtocolMessage) throws {
    let payload = message.payload ?? [:]
    guard let sourcePath = payload["source_path"], !sourcePath.contains("\0") else {
        throw DevpodError("clipboard image source is missing")
    }
    let source = URL(fileURLWithPath: sourcePath)
    var info = stat()
    guard source.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
          source.lastPathComponent.hasPrefix("devspace-paste-"), source.pathExtension == "png",
          lstat(source.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
          info.st_uid == geteuid(), (info.st_mode & mode_t(0o077)) == 0 else {
        throw DevpodError("clipboard image source must be a private generated temporary PNG")
    }
    guard let workspace = payload["workspace_id"], let generation = UUID(uuidString: payload["generation"] ?? ""),
          let pane = UUID(uuidString: payload["pane_id"] ?? ""),
          let controlPath = terminals.imageTarget(workspace: workspace, generation: generation, pane: pane),
          uploadJobs.count < 4 else {
        try? FileManager.default.removeItem(at: source)
        throw DevpodError("clipboard image target is stale or busy")
    }
    let id = UUID(), job = UploadJob(workspace: workspace)
    uploadJobs[id] = job
    DispatchQueue.global(qos: .userInitiated).async {
        let result = Result { try ImageUpload.upload(job.runner, podID: workspace, controlPath: controlPath, source: source) }
        try? FileManager.default.removeItem(at: source)
        DispatchQueue.main.async {
            uploadJobs.removeValue(forKey: id)
            guard !stopping else { return }
            if job.cancelled { _ = send(BackendProtocolMessage(id: message.id, kind: "cancelled")); return }
            switch result {
            case let .success(remote):
                guard terminals.injectText(workspace: workspace, generation: generation, pane: pane, text: "Image pasted: \(remote) ") else {
                    _ = send(BackendProtocolMessage(id: message.id, kind: "error", payload: ["message": "Image target was closed; no text was pasted"]))
                    return
                }
                _ = send(BackendProtocolMessage(id: message.id, kind: "completed"))
            case .failure:
                _ = send(BackendProtocolMessage(id: message.id, kind: "error", payload: ["message": "Clipboard image upload failed; no text was pasted"]))
            }
        }
    }
}

private func startNotifyListener() -> [String: String] {
    do {
        let token = try Notify.loadOrCreateToken(paths: paths)
        var port = SSH.ports(identity: identity).listenerPort
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--notify-port"), arguments.indices.contains(index + 1) {
            guard let requested = UInt16(arguments[index + 1]) else { throw DevpodError("invalid notification port") }
            port = requested
        }
        let listener = NotifyListener(expectedToken: token, port: port, onNotify: { workspace, message in
            DispatchQueue.main.async {
                guard !stopping, controller.receiveNotification(workspaceID: workspace) else { return }
                let title = controller.snapshot.layout.aliases[workspace] ?? workspace
                _ = send(BackendProtocolMessage(kind: "platform_notify", payload: [
                    "workspace_id": workspace, "title": title, "message": message,
                ]))
                _ = sendSnapshot(nil, from: controller)
            }
        }, onDide: { payload in
            DispatchQueue.main.async {
                guard !stopping,
                      controller.snapshot.workspaces.contains(where: { $0.id == payload.podID && $0.state == "Running" }),
                      !controller.snapshot.operations.contains(where: { $0.workspaceID == payload.podID }),
                      (try? Devpod.validateId(payload.podID)) != nil,
                      payload.path.hasPrefix("/"), !payload.path.contains("\0") else { return }
                _ = send(BackendProtocolMessage(kind: "platform_open_zed", payload: [
                    "workspace_id": payload.podID,
                    "url": SSH.zedRemoteURL(podID: payload.podID, workdir: payload.path),
                    "explicit_directory": "true",
                ]))
            }
        })
        try listener.start()
        notifyListener = listener
        notifyToken = token
        return ["notify_port": String(listener.listeningPort ?? port)]
    } catch {
        // Failure must leave polling/terminal actions and sidebar badges usable.
        FileHandle.standardError.write(Data("DevSpaceLinuxBackend: notifications unavailable: \(error)\n".utf8))
        return ["notify_error": String(describing: error)]
    }
}

private func handle(_ message: BackendProtocolMessage) {
    guard !stopping else { return }
    guard handshaken || message.kind == "handshake" else {
        fail("handshake required before \(message.kind)")
        return
    }

    switch message.kind {
    case "open_zed":
        do {
            let workspace = message.payload?["workspace_id"] ?? ""
            try Devpod.validateId(workspace)
            guard controller.snapshot.workspaces.contains(where: { $0.id == workspace && $0.state == "Running" }),
                  !controller.snapshot.operations.contains(where: { $0.workspaceID == workspace }) else {
                throw DevpodError("workspace is not available for the editor")
            }
            let directory = message.payload?["directory"]
            guard directory == nil || (directory!.hasPrefix("/") && !directory!.contains("\0")) else {
                throw DevpodError("editor folder must be an absolute path")
            }
            _ = send(BackendProtocolMessage(kind: "platform_open_zed", payload: [
                "workspace_id": workspace,
                "url": SSH.zedRemoteURL(podID: workspace,
                    workdir: SSH.zedWorkdir(currentDirectory: directory, fallback: SSH.workdir(podID: workspace))),
                "explicit_directory": directory == nil || message.payload?["explicit_directory"] == "false" ? "false" : "true",
            ]))
            _ = send(BackendProtocolMessage(id: message.id, kind: "completed"))
        } catch {
            _ = send(BackendProtocolMessage(id: message.id, kind: "error", payload: ["message": String(describing: error)]))
        }
    case "paste_image":
        do { try pasteImage(message) }
        catch { _ = send(BackendProtocolMessage(id: message.id, kind: "error", payload: ["message": String(describing: error)])) }
    case "install_hooks":
        do { try installIntegration(message.payload?["workspace_id"] ?? "", requestID: message.id) }
        catch { _ = send(BackendProtocolMessage(id: message.id, kind: "error", payload: ["message": String(describing: error)])) }
    case "handshake":
        guard !handshaken else { fail("duplicate handshake"); return }
        handshaken = true
        let notificationStatus = startNotifyListener()
        guard send(BackendProtocolMessage(
            id: message.id,
            kind: "ready",
            payload: [
                "channel": identity.channel.rawValue,
                "application_id": identity.channel.applicationIdentifier,
                "protocol_version": "\(BackendProtocol.version)",
            ].merging(notificationStatus) { _, status in status }
        )) else { fail("could not write handshake response"); return }

    case "ping":
        guard send(BackendProtocolMessage(id: message.id, kind: "pong")) else {
            fail("could not write ping response")
            return
        }

    case "snapshot":
        guard sendSnapshot(message.id, from: controller) else {
            fail("could not encode state snapshot")
            return
        }

    case "select":
        do {
            let id = message.payload?["workspace_id"] ?? ""
            try Devpod.validateId(id)
            guard controller.snapshot.workspaces.contains(where: { $0.id == id }) else {
                throw DevpodError("workspace not found: \(id)")
            }
            controller.select(id)
            _ = sendSnapshot(message.id, from: controller)
        } catch {
            _ = send(BackendProtocolMessage(id: message.id, kind: "error", payload: ["message": String(describing: error)]))
        }

    case "alias", "hide", "show", "move_up", "move_down", "collapse_hidden", "expand_hidden":
        do {
            let workspace = message.payload?["workspace_id"] ?? ""
            switch message.kind {
            case "alias":
                guard let name = message.payload?["name"] else { throw DevpodError("alias name is required") }
                try controller.setAlias(name, for: workspace)
            case "hide", "show": try controller.setHidden(message.kind == "hide", workspaceID: workspace)
            case "move_up", "move_down": try controller.moveWorkspace(workspace, delta: message.kind == "move_up" ? -1 : 1)
            default: controller.setHiddenCollapsed(message.kind == "collapse_hidden")
            }
            LayoutStore.save(controller.snapshot.layout, paths: paths)
            _ = sendSnapshot(message.id, from: controller)
        } catch {
            _ = send(BackendProtocolMessage(id: message.id, kind: "error", payload: ["message": String(describing: error)]))
        }

    case "new_terminal":
        do {
            let workspace = message.payload?["workspace_id"] ?? ""
            try Devpod.validateId(workspace)
            guard controller.snapshot.workspaces.contains(where: { $0.id == workspace && $0.state == "Running" }),
                  !controller.snapshot.operations.contains(where: { $0.workspaceID == workspace }),
                  terminals.controlPath(for: workspace) != nil, terminals.connectionStates[workspace] == "connected" else {
                throw DevpodError("new terminal requires a ready SSH session: \(workspace)")
            }
            try terminals.connect(workspace)
            controller.setTerminalPanes(terminals.panes)
            _ = sendSnapshot(nil, from: controller)
            _ = send(BackendProtocolMessage(id: message.id, kind: "completed"))
        } catch {
            _ = send(BackendProtocolMessage(id: message.id, kind: "error", payload: ["message": String(describing: error)]))
        }

    case "connect", "reconnect", "disconnect":
        do {
            let workspace = message.payload?["workspace_id"] ?? ""
            try Devpod.validateId(workspace)
            if message.kind == "disconnect" {
                autoConnect.remove(workspace)
                sshRecoveries[workspace] = nil
                terminals.disconnect(workspace)
                _ = sendSnapshot(nil, from: controller)
            } else {
                guard controller.snapshot.workspaces.contains(where: { $0.id == workspace && $0.state == "Running" }) else {
                    throw DevpodError("workspace is not running: \(workspace)")
                }
                guard !controller.snapshot.operations.contains(where: { $0.workspaceID == workspace }) else {
                    throw DevpodError("workspace is busy: \(workspace)")
                }
                autoConnect.insert(workspace)
                controller.select(workspace)
                _ = sendSnapshot(nil, from: controller)
                if message.kind == "reconnect" { try beginConnection(workspace, reload: true) }
                else if terminals.connectionStates[workspace] == "disconnecting"
                    || (!terminals.openedWorkspaces.contains(workspace)
                        && (sshRecoveries[workspace] == nil || sshRecoveries[workspace]?.failed == true)) {
                    try beginConnection(workspace)
                }
            }
            _ = send(BackendProtocolMessage(id: message.id, kind: "completed"))
        } catch {
            _ = send(BackendProtocolMessage(id: message.id, kind: "error", payload: ["message": String(describing: error)]))
        }

    case "terminal_output", "terminal_directory", "terminal_focus", "terminal_exit", "terminal_launch_failed", "terminal_retry":
        let payload = message.payload ?? [:]
        guard let workspace = payload["workspace_id"],
              let generationString = payload["generation"], let generation = UUID(uuidString: generationString),
              let paneString = payload["pane_id"], let pane = UUID(uuidString: paneString),
              let exitCode = Int32(payload["exit_code"] ?? "0"),
              terminals.report(workspace: workspace, generation: generation, pane: pane,
                               kind: message.kind, directory: payload["directory"], exitCode: exitCode,
                               explicitClose: payload["explicit_close"] == "true") else {
            _ = send(BackendProtocolMessage(id: message.id, kind: "error", payload: ["message": "invalid or stale terminal event"]))
            return
        }
        controller.setTerminalPanes(terminals.panes)
        _ = sendSnapshot(message.id, from: controller)

    case "poll":
        let requestID = message.id
        let submittedGeneration = pollGeneration
        operations.submit(
            operation: {
                let workspaces = try Devpod.list(devpod)
                return (workspaces, Poller.fetchStatuses(devpod, workspaces))
            },
            completion: { result in
                guard submittedGeneration == pollGeneration else {
                    // Re-read rather than acknowledging a pre-operation state.
                    // Preserve the request ID so the GTK poll gate stays live.
                    handle(message)
                    return
                }
                switch result {
                case let .success(fetched):
                    let views = Poller.merge(fetched.0, statusDebouncer.filter(fetched.1))
                    let previousIDs = Set(controller.snapshot.workspaces.map(\.id))
                    let revision = controller.snapshot.revision &+ 1
                    _ = controller.apply(PollUpdate(revision: revision, views: views))
                    for removed in previousIDs.subtracting(views.map(\.id)) { stateNotifyGate.forget(removed) }
                    for (workspace, event) in stateNotifyGate.observe(views) {
                        emitStateNotification(workspace, event: event)
                    }
                    if !views.contains(where: { $0.id == controller.snapshot.selectedID }) {
                        controller.select(views.first(where: { $0.state == "Running" })?.id ?? views.first?.id)
                    }
                    let liveIDs = Set(views.map(\.id))
                    sshRecoveries = sshRecoveries.filter { workspace, _ in
                        liveIDs.contains(workspace) && !views.contains { $0.id == workspace && $0.state == "Stopped" }
                    }
                    autoConnect.formIntersection(liveIDs)
                    starting.formIntersection(liveIDs)
                    let plan = WorkspaceLifecycle.reconcile(
                        workspaces: views,
                        seenDefinitive: seenDefinitive,
                        autoConnect: autoConnect,
                        opened: terminals.openedWorkspaces,
                        starting: starting,
                        shuttingDown: []
                    )
                    seenDefinitive = plan.seenDefinitive
                    autoConnect = plan.autoConnect
                    let activeOperations = controller.snapshot.operations
                    let busyWorkspaces = Set(activeOperations.compactMap(\.workspaceID))
                    let creating = activeOperations.contains { $0.kind == "create" }
                    for id in Array(starting) where !busyWorkspaces.contains(id)
                        && views.contains(where: { $0.id == id && $0.state == "Running" }) {
                        starting.remove(id)
                    }
                    terminals.reconcile(views)
                    for workspace in plan.connect where !creating && !busyWorkspaces.contains(workspace)
                        && !terminals.openedWorkspaces.contains(workspace) && sshRecoveries[workspace] == nil {
                        do { try beginConnection(workspace) }
                        catch { _ = send(BackendProtocolMessage(kind: "platform_error", payload: [
                            "message": "Could not connect to running workspace \(workspace): \(error)",
                        ])) }
                    }
                    // Match macOS's no-auto-wake policy for external starts.
                    // Intended connections still require first output, even
                    // if their master failed and is waiting for explicit retry.
                    for workspace in stateNotifyGate.releasePending(
                        notIn: autoConnect.union(terminals.openedWorkspaces).union(starting)
                    ) { emitStateNotification(workspace, event: "started") }
                    _ = sendSnapshot(requestID, from: controller)
                case let .failure(error):
                    _ = send(BackendProtocolMessage(
                        id: requestID,
                        kind: "error",
                        payload: ["message": "poll failed: \(error)"]
                    ))
                }
            }
        )

    case "create", "start", "stop", "delete", "recreate":
        do {
            let workspace = message.payload?["workspace_id"]
            if let workspace, message.kind == "start" {
                try Devpod.validateId(workspace)
                sshRecoveries[workspace] = nil
                autoConnect.insert(workspace)
                starting.insert(workspace)
            } else if let workspace, ["stop", "delete", "recreate"].contains(message.kind) {
                sshRecoveries[workspace] = nil
                autoConnect.remove(workspace)
                starting.remove(workspace)
            }
            try workspaceCommands.submit(message, prepare: { ready in
                if ["stop", "delete", "recreate"].contains(message.kind), let workspace {
                    terminals.disconnect(workspace, completion: ready)
                } else { ready() }
            }) { response in
                if message.kind == "start", response.kind != "completed", let workspace {
                    autoConnect.remove(workspace)
                    starting.remove(workspace)
                }
                if message.kind == "recreate", response.kind == "completed", let workspace {
                    autoConnect.insert(workspace)
                    starting.insert(workspace)
                    controller.select(workspace)
                }
                pollGeneration &+= 1
                if let created = response.payload?["created_id"] { controller.select(created) }
                _ = send(response)
            }
        } catch {
            _ = send(BackendProtocolMessage(id: message.id, kind: "error", payload: ["message": String(describing: error)]))
        }

    case "cancel":
        do {
            try workspaceCommands.cancel(message.payload?["request_id"] ?? "")
            _ = send(BackendProtocolMessage(id: message.id, kind: "completed"))
        } catch {
            _ = send(BackendProtocolMessage(id: message.id, kind: "error", payload: ["message": String(describing: error)]))
        }

    case "shutdown":
        shutdown(message.id)

    default:
        _ = send(BackendProtocolMessage(
            id: message.id, kind: "error", payload: ["message": "unsupported command \(message.kind)"]
        ))
    }
}

private func shutdown(_ requestID: String?) {
    guard !stopping else { return }
    stopping = true
    sshRecoveries.removeAll()
    notifyListener?.stop()
    notifyListener = nil
    for job in integrationJobs.values { job.cancel() }
    for job in uploadJobs.values { job.cancel() }
    operations.cancelAll()
    workspaceCommands.shutdown()
    devpod.cancel()
    terminals.shutdown()
    finishShutdown(requestID)
}

private func finishShutdown(_ requestID: String?) {
    guard !terminals.hasOwnedTransports, !devpod.hasActiveCommands, !workspaceCommands.hasActiveCommands,
          integrationJobs.isEmpty, uploadJobs.isEmpty else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { finishShutdown(requestID) }
        return
    }
    _ = send(BackendProtocolMessage(id: requestID, kind: "stopped"))
    let status = shutdownExitStatus
    outputQueue.async { exit(status) }
}

// SSH callbacks/timers require a live main queue. Blocking stdin reads belong
// to a reader thread; control events are serialized on the main queue.
DispatchQueue.global(qos: .userInitiated).async {
    let decoder = BackendProtocolLineDecoder()
    do {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // One POSIX read returns available bytes. Foundation's length-
            // based reader can wait to fill its buffer on a long-lived pipe.
            let count = Glibc.read(STDIN_FILENO, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw DevpodError("stdin read failed: \(errno)")
            }
            for line in try decoder.append(Data(buffer.prefix(count))) {
                let message = try BackendProtocolMessage.decode(line)
                DispatchQueue.main.sync { handle(message) }
            }
        }
        try decoder.finish()
        DispatchQueue.main.async { shutdown(nil) }
    } catch {
        FileHandle.standardError.write(Data("DevSpaceLinuxBackend: invalid protocol message: \(error)\n".utf8))
        DispatchQueue.main.async {
            shutdownExitStatus = 1
            shutdown(nil)
        }
    }
}
dispatchMain()
