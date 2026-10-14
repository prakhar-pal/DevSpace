import Foundation
import CGTK
import DevSpaceCore

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
        shutdownStartedAt = Date()
        window?.setActionsEnabled(false)
        window?.setStatus("Closing terminal connections…")
        sendShutdownIfReady()
    }

    @discardableResult
    func pump() -> Int32 {
        for message in backend.takeReceived() { receive(message) }

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
                window?.update(snapshot)
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
            launchZed(message.payload?["url"])
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

    private func launchZed(_ url: String?) {
        guard let url, url.hasPrefix("ssh://") else {
            window?.setStatus("Invalid remote editor link")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zed", url]
        do {
            try process.run()
        } catch {
            window?.setStatus("Could not launch Zed; install it and add it to PATH")
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
