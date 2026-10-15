import Foundation
import CGTK
import DevSpaceCore

private struct EditorRequest: Sendable {
    let workspace: String
    let generation = UUID()
    let url: String
    let explicitDirectory: Bool
}

/// Process inspection never blocks GTK. The main loop alone decides whether
/// a completed probe is still eligible to launch an external application.
private final class EditorFallbackProbe: @unchecked Sendable {
    let request: EditorRequest
    private let lock = NSLock()
    private var activeSession: Bool?

    init(_ request: EditorRequest) {
        self.request = request
        DispatchQueue.global(qos: .utility).async { [self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["axww", "-o", "command="]
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            var output = ""
            if (try? process.run()) != nil {
                output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
            }
            try? pipe.fileHandleForReading.close()
            let active = SSH.zedSessionActive(psOutput: output, podID: request.workspace)
            lock.lock()
            activeSession = active
            lock.unlock()
        }
    }

    var result: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return activeSession
    }
}

enum LinuxApplicationChannel {
    static func applicationIdentifier(_ channel: String) -> String? {
        switch channel {
        case "development": "com.prakharp.devspace.dev"
        case "production": "com.prakharp.devspace"
        default: nil
        }
    }

    static func backendExecutableURL(_ executableURL: URL, environment: [String: String]) -> URL {
        if let path = environment["DEVSPACE_BACKEND"], path.hasPrefix("/"), !path.contains("\0") {
            return URL(fileURLWithPath: path)
        }
        return executableURL.deletingLastPathComponent().appendingPathComponent("DevSpaceLinuxBackend")
    }
}

final class LinuxApplicationController {
    let application: UnsafeMutablePointer<GtkApplication>
    let channel: String
    let backend: BackendClient
    private(set) var window: WorkspaceWindow?
    private var started = false
    private var pumpSource: guint = 0
    private var pendingPollID: String?
    private var nextPollDate = Date.distantPast
    private var shutdownRequested = false
    private var shutdownSent = false
    private var shutdownStartedAt: Date?
    private var shownBackendFailure = false
    private var pendingImageSources: [String: URL] = [:]
    private var editorProcesses: [(process: Process, request: EditorRequest, fallback: Bool)] = []
    private var editorGenerations: [String: UUID] = [:]
    private var editorFallbacks: [EditorFallbackProbe] = []

    init(application: UnsafeMutablePointer<GtkApplication>, channel: String,
         backendExecutableURL: URL? = nil, backendArguments: [String]? = nil) {
        self.application = application
        self.channel = channel
        let backendURL = backendExecutableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("DevSpaceLinuxBackend")
        backend = BackendClient(
            executableURL: backendURL,
            arguments: backendArguments ?? ["--channel", channel],
            channel: channel
        )
    }

    func start() throws {
        guard LinuxApplicationChannel.applicationIdentifier(channel) != nil else {
            throw BackendClientError.invalidChannel
        }
        if started {
            window?.present()
            return
        }
        started = true
        let window = WorkspaceWindow(application: application)
        self.window = window
        window.onCommand = { [weak self] kind, payload in self?.sendCommand(kind, payload: payload) }
        registerNotificationAction()
        connectCloseRequest(window)
        window.present()

        do {
            try backend.start()
        } catch {
            window.setStatus("Workspace backend could not start: \(error)")
            window.setActionsEnabled(false)
        }
        pumpSource = g_timeout_add(16, devspaceLinuxAppPump, Unmanaged.passUnretained(self).toOpaque())
    }

    func sendCommand(_ kind: String, payload: [String: String]? = nil) {
        let imageSource = kind == "paste_image"
            ? payload?["source_path"].map(URL.init(fileURLWithPath:))
            : nil
        guard backend.state == .ready else {
            if let imageSource { try? FileManager.default.removeItem(at: imageSource) }
            window?.setStatus("Workspace backend is not connected")
            return
        }
        do {
            let requestID = try backend.send(kind, payload: payload)
            if ["stop", "recreate", "disconnect", "reconnect", "terminal_exit"].contains(kind),
               let workspace = payload?["workspace_id"] { editorGenerations[workspace] = nil }
            if ["connect", "reconnect", "start", "stop"].contains(kind) { window?.setStatus("") }
            if let imageSource { pendingImageSources[requestID] = imageSource }
        } catch {
            if let imageSource { try? FileManager.default.removeItem(at: imageSource) }
            window?.setStatus(errorMessage(for: error))
        }
    }

    func requestShutdown() {
        guard !shutdownRequested else { return }
        shutdownRequested = true
        editorGenerations.removeAll()
        shutdownStartedAt = Date()
        window?.setActionsEnabled(false)
        window?.setStatus("Closing terminal connections…")
        sendShutdownIfReady()
    }

    @discardableResult
    func pump() -> Int32 {
        for message in backend.takeReceived() { receive(message) }
        let completedEditors = editorProcesses.filter { !$0.process.isRunning }
        editorProcesses.removeAll { !$0.process.isRunning }
        for item in completedEditors where isCurrentEditorRequest(item.request) {
            if item.process.terminationStatus != 0 {
                if item.fallback { window?.setStatus("Could not launch Zed through DevPod") }
                else { beginEditorFallback(item.request) }
            }
        }
        editorFallbacks.removeAll { probe in
            guard let active = probe.result else { return false }
            if isCurrentEditorRequest(probe.request) { performEditorFallback(probe.request, sessionActive: active) }
            return true
        }

        if shutdownRequested {
            sendShutdownIfReady()
            if backend.state == .stopped || backend.state == .failed {
                quitApplication()
                return 0
            }
            // A process that never completes its handshake has not taken
            // ownership of workspace resources; do not strand a closing app.
            if backend.state == .starting,
               Date().timeIntervalSince(shutdownStartedAt ?? Date()) > 3 {
                backend.terminate()
                quitApplication()
                return 0
            }
        } else if backend.state == .ready, pendingPollID == nil, Date() >= nextPollDate {
            requestPoll()
        }

        if case .failed = backend.state {
            discardPendingImageSources()
            window?.setActionsEnabled(false)
            if !shownBackendFailure {
                window?.setStatus(backend.failure ?? "Workspace backend disconnected")
                shownBackendFailure = true
            }
        }
        return 1
    }

    fileprivate func closeRequested() -> Bool {
        if backend.state == .failed || backend.state == .stopped {
            g_application_quit(UnsafeMutableRawPointer(application).assumingMemoryBound(to: GApplication.self))
            return false
        }
        requestShutdown()
        return true
    }

    deinit {
        if started {
            g_action_map_remove_action(OpaquePointer(UnsafeMutableRawPointer(application)), "activate-workspace")
        }
        if pumpSource != 0 { _ = g_source_remove(pumpSource) }
        discardPendingImageSources()
        if backend.state != .stopped { backend.terminate() }
    }

    private func receive(_ message: BackendProtocolMessage) {
        if let requestID = message.id,
           let imageSource = pendingImageSources.removeValue(forKey: requestID) {
            try? FileManager.default.removeItem(at: imageSource)
        }
        if message.id == pendingPollID {
            pendingPollID = nil
            nextPollDate = Date().addingTimeInterval(5)
        }
        switch message.kind {
        case "ready":
            window?.setActionsEnabled(true)
            if let warning = message.payload?["notify_error"] { window?.setNotificationWarning(warning) }
            if shutdownRequested { sendShutdownIfReady() } else { requestPoll() }
        case "snapshot":
            guard let json = message.payload?["json"] else {
                window?.setStatus("Workspace backend sent an empty snapshot")
                return
            }
            do {
                let snapshot = try JSONDecoder().decode(
                    WorkspaceControllerSnapshot.self, from: Data(json.utf8)
                )
                guard snapshot.revision >= (window?.snapshot.revision ?? 0) else { return }
                let connections = message.payload?["connections"].flatMap {
                    try? JSONDecoder().decode([String: String].self, from: Data($0.utf8))
                } ?? [:]
                window?.setConnectionStates(connections)
                window?.update(snapshot)
                editorGenerations = editorGenerations.filter { workspace, _ in
                    snapshot.workspaces.contains { $0.id == workspace && $0.state == "Running" }
                        && !snapshot.operations.contains { $0.workspaceID == workspace }
                }
            } catch {
                window?.setStatus("Workspace backend sent an invalid snapshot")
            }
        case "completed", "cancelled":
            if !shutdownRequested { nextPollDate = .distantPast }
        case "error", "platform_error":
            window?.setStatus(message.payload?["message"] ?? "Workspace operation failed")
        case "platform_info":
            if let text = message.payload?["message"] { window?.setStatus(text) }
        case "platform_notify":
            sendNotification(message.payload ?? [:])
        case "platform_open_zed":
            launchZed(message.payload ?? [:])
        case let kind where kind.hasPrefix("terminal_"):
            guard let json = message.payload?["json"] else {
                window?.setStatus("Workspace backend sent an invalid terminal effect")
                return
            }
            do {
                let effect = try JSONDecoder().decode(WorkspaceTerminalEffect.self, from: Data(json.utf8))
                guard effect.kind == kind else {
                    window?.setStatus("Workspace backend sent a mismatched terminal effect")
                    return
                }
                window?.apply(effect)
            } catch {
                window?.setStatus("Workspace backend sent an invalid terminal effect")
            }
        default:
            break
        }
    }

    private func requestPoll() {
        guard backend.state == .ready, pendingPollID == nil else { return }
        do {
            pendingPollID = try backend.send("poll")
            nextPollDate = Date().addingTimeInterval(5)
        } catch {
            window?.setStatus(errorMessage(for: error))
        }
    }

    private func sendShutdownIfReady() {
        guard shutdownRequested, !shutdownSent else { return }
        if backend.state == .ready {
            do {
                _ = try backend.shutdown()
                shutdownSent = true
            } catch {
                window?.setStatus("Workspace backend shutdown failed: \(error)")
                backend.terminate()
            }
        } else if backend.state == .failed || backend.state == .stopped {
            quitApplication()
        }
    }

    private func connectCloseRequest(_ window: WorkspaceWindow) {
        let callback = unsafeBitCast(
            devspaceLinuxWindowCloseRequested as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32,
            to: GCallback.self
        )
        _ = g_signal_connect_data(
            UnsafeMutableRawPointer(window.window), "close-request", callback,
            Unmanaged.passUnretained(self).toOpaque(), nil, GConnectFlags(rawValue: 0)
        )
    }

    private func sendNotification(_ payload: [String: String]) {
        guard let workspace = payload["workspace_id"],
              let title = payload["title"], let body = payload["message"] else { return }
        guard WorkspaceController.shouldPresentNotification(
            workspaceID: workspace, selectedID: window?.snapshot.selectedID,
            applicationIsActive: window.map { gtk_window_is_active($0.window) != 0 } ?? false
        ) else { return }
        let notification = g_notification_new(title)!
        g_notification_set_body(notification, body)
        g_notification_set_default_action_and_target_value(
            notification, "app.activate-workspace", g_variant_new_string(workspace)
        )
        g_application_send_notification(
            UnsafeMutableRawPointer(application).assumingMemoryBound(to: GApplication.self),
            workspace, notification
        )
        g_object_unref(UnsafeMutableRawPointer(notification))
    }

    private func registerNotificationAction() {
        let parameterType = g_variant_type_new("s")!
        defer { g_variant_type_free(parameterType) }
        let action = g_simple_action_new("activate-workspace", parameterType)!
        let callback = unsafeBitCast(
            devspaceLinuxActivateWorkspace as @convention(c)
                (UnsafeMutableRawPointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void,
            to: GCallback.self
        )
        _ = g_signal_connect_data(
            UnsafeMutableRawPointer(action), "activate", callback,
            Unmanaged.passUnretained(self).toOpaque(), nil, GConnectFlags(rawValue: 0)
        )
        g_action_map_add_action(OpaquePointer(UnsafeMutableRawPointer(application)),
                               OpaquePointer(UnsafeMutableRawPointer(action)))
        g_object_unref(UnsafeMutableRawPointer(action))
    }

    fileprivate func activateWorkspace(_ workspaceID: String) {
        guard let window, window.snapshot.workspaces.contains(where: { $0.id == workspaceID }) else { return }
        window.present()
        sendCommand("select", payload: ["workspace_id": workspaceID])
        if let pane = window.pane(forWorkspace: workspaceID) { _ = gtk_widget_grab_focus(pane.widget) }
    }

    private func launchZed(_ payload: [String: String]) {
        guard let workspace = payload["workspace_id"], (try? Devpod.validateId(workspace)) != nil,
              let url = payload["url"], let components = URLComponents(string: url),
              components.scheme == "ssh", components.host == "\(workspace).devpod",
              components.user == nil, components.password == nil else {
            window?.setStatus("Invalid remote editor link")
            return
        }
        let request = EditorRequest(workspace: workspace, url: url,
                                    explicitDirectory: payload["explicit_directory"] != "false")
        editorGenerations[workspace] = request.generation
        guard isCurrentEditorRequest(request) else { return }
        guard let cli = zedCLI() else { beginEditorFallback(request); return }
        launchEditorProcess(executable: cli, arguments: [url], request: request, fallback: false)
    }

    private func zedCLI() -> String? {
        let environment = ProcessInfo.processInfo.environment
        var candidates = (environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { "\($0)/zed" }
        if let home = environment["HOME"], home.hasPrefix("/") {
            candidates += ["\(home)/.local/bin/zed", "\(home)/.local/zed.app/bin/zed"]
        }
        candidates += ["/usr/local/bin/zed", "/usr/bin/zed"]
        return candidates.first(where: {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: $0)
        })
    }

    private func isCurrentEditorRequest(_ request: EditorRequest) -> Bool {
        !shutdownRequested && backend.state == .ready
            && editorGenerations[request.workspace] == request.generation
            && window?.snapshot.workspaces.contains { $0.id == request.workspace && $0.state == "Running" } == true
            && window?.snapshot.operations.contains { $0.workspaceID == request.workspace } == false
    }

    private func launchEditorProcess(executable: String, arguments: [String], request: EditorRequest, fallback: Bool) {
        guard isCurrentEditorRequest(request) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            editorProcesses.append((process, request, fallback))
        } catch {
            if fallback { window?.setStatus("Could not launch Zed through DevPod") }
            else { beginEditorFallback(request) }
        }
    }

    private func beginEditorFallback(_ request: EditorRequest) {
        guard isCurrentEditorRequest(request) else { return }
        editorFallbacks.removeAll { $0.request.workspace == request.workspace }
        editorFallbacks.append(EditorFallbackProbe(request))
    }

    private func performEditorFallback(_ request: EditorRequest, sessionActive: Bool) {
        if sessionActive {
            // Like macOS app activation: never run DevPod's provisioning flow
            // when a remote Zed session already exists.
            let applications = g_app_info_get_all()
            defer { g_list_free(applications) }
            var node = applications
            var activated = false
            while let entry = node {
                if let raw = entry.pointee.data {
                    let app = OpaquePointer(raw)
                    if !activated, let id = g_app_info_get_id(app), String(cString: id) == "dev.zed.Zed.desktop" {
                        var error: UnsafeMutablePointer<GError>?
                        activated = g_app_info_launch(app, nil, nil, &error) != 0
                        if let error { g_error_free(error) }
                    }
                    g_object_unref(raw)
                }
                node = entry.pointee.next
            }
            if !activated { window?.setStatus("Could not launch Zed; its existing session must be focused manually") }
        } else if request.explicitDirectory {
            window?.setStatus("Could not launch Zed for this folder; install its CLI and try again")
        } else {
            launchEditorProcess(executable: "/usr/bin/env", arguments: ["devpod"] + Devpod.ideArgs(request.workspace, ide: "zed"),
                                request: request, fallback: true)
        }
    }

    private func errorMessage(for error: Error) -> String {
        switch error {
        case BackendClientError.queueFull: "Workspace backend queue is full; reconnect to continue"
        case BackendClientError.frameTooLarge: "Workspace request exceeded the protocol frame limit"
        default: "Workspace backend pipe failed: \(error)"
        }
    }

    private func quitApplication() {
        discardPendingImageSources()
        if let window {
            gtk_window_destroy(window.window)
            self.window = nil
        }
        g_application_quit(UnsafeMutableRawPointer(application).assumingMemoryBound(to: GApplication.self))
    }

    private func discardPendingImageSources() {
        for source in pendingImageSources.values { try? FileManager.default.removeItem(at: source) }
        pendingImageSources.removeAll()
    }
}

@_cdecl("devspace_linux_activate_workspace")
private func devspaceLinuxActivateWorkspace(_ action: UnsafeMutableRawPointer?, _ parameter: OpaquePointer?,
                                            _ data: UnsafeMutableRawPointer?) {
    guard let parameter, let data, let workspace = g_variant_get_string(parameter, nil) else { return }
    Unmanaged<LinuxApplicationController>.fromOpaque(data).takeUnretainedValue()
        .activateWorkspace(String(cString: workspace))
}

@_cdecl("devspace_linux_app_pump")
private func devspaceLinuxAppPump(_ data: UnsafeMutableRawPointer?) -> Int32 {
    guard let data else { return 0 }
    return Unmanaged<LinuxApplicationController>.fromOpaque(data).takeUnretainedValue().pump()
}

@_cdecl("devspace_linux_window_close_requested")
private func devspaceLinuxWindowCloseRequested(_ window: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?) -> Int32 {
    guard let data else { return 0 }
    let controller = Unmanaged<LinuxApplicationController>.fromOpaque(data).takeUnretainedValue()
    _ = window
    return controller.closeRequested() ? 1 : 0
}
