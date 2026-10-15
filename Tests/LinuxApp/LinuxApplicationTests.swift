import Foundation
import Glibc
import CGTK

private final class TestContext {
    let python: String
    let fixture: String
    let mode: String
    let application: UnsafeMutablePointer<GtkApplication>
    var controller: LinuxApplicationController?
    var startedAt = Date()
    var failureObservedAt: Date?
    var connectSent = false
    var terminalClosed = false
    var imagePasteSent = false
    var imagePastePath: String?
    var notificationActivated = false
    var editorProbeSent = false
    var hostCommandSent = false
    var hostShellVerified = false
    var hostShellVerifiedAt: Date?
    var hostClosedIdentity: TerminalPaneIdentity?
    var hostReopened = false
    var hostImageCheckSent = false
    var hostImageVerified = false
    var hostSelectionSent = false
    var hostNotificationSent = false
    var hostDedSent = false
    var hostIntegrationVerified = false
    var failure: String?
    var exitCode: Int32 = 1

    init(python: String, fixture: String, mode: String, application: UnsafeMutablePointer<GtkApplication>) {
        self.python = python
        self.fixture = fixture
        self.mode = mode
        self.application = application
    }
}

@_cdecl("devspace_linux_app_test_activate")
private func activate(_ rawApplication: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?) {
    guard let rawApplication, let data else { return }
    let context = Unmanaged<TestContext>.fromOpaque(data).takeUnretainedValue()
    let application = UnsafeMutableRawPointer(rawApplication).assumingMemoryBound(to: GtkApplication.self)
    let hostMode = context.mode == "host"
    let channel = hostMode ? (ProcessInfo.processInfo.environment["DEVSPACE_TEST_CHANNEL"] ?? "production")
        : "development"
    let controller = LinuxApplicationController(
        application: application,
        channel: channel,
        backendExecutableURL: URL(fileURLWithPath: context.python),
        backendArguments: hostMode ? ["--channel", channel] : [context.fixture, context.mode]
    )
    context.controller = controller
    do {
        try controller.start()
        _ = g_timeout_add(10, testTick, Unmanaged.passUnretained(context).toOpaque())
    } catch {
        context.failure = "start failed: \(error)"
        g_application_quit(UnsafeMutableRawPointer(application).assumingMemoryBound(to: GApplication.self))
    }
}

@_cdecl("devspace_linux_app_test_tick")
private func testTick(_ data: UnsafeMutableRawPointer?) -> Int32 {
    guard let data else { return 0 }
    let context = Unmanaged<TestContext>.fromOpaque(data).takeUnretainedValue()
    guard let controller = context.controller, let window = controller.window else { return 1 }
    if context.mode == "host" {
        if Date().timeIntervalSince(context.startedAt) > 90 && context.failure == nil {
            let pane = window.pane(forWorkspace: context.fixture)
            context.failure = "timed out waiting for real workspace shell round-trip " +
                "pane=\(pane == nil ? "absent" : "present") " +
                "child=\(pane?.childPID != nil ? "started" : pane?.spawnError == nil ? "pending" : "failed") " +
                "ready=\(pane?.text.contains("DS_UI_READY") == true) " +
                "shell=\(pane?.text.contains("DS_UI_SHELL_OK") == true) " +
                "workspace=\(window.snapshot.workspaces.first(where: { $0.id == context.fixture })?.state ?? "absent") " +
                "connect=\(context.connectSent) reopen=\(context.hostClosedIdentity != nil) " +
                "selection=\(context.hostSelectionSent) notify=\(context.hostNotificationSent) ded=\(context.hostDedSent)"
            controller.requestShutdown()
        }
        if !context.connectSent,
           window.snapshot.workspaces.contains(where: { $0.id == context.fixture && $0.state == "Running" }) {
            context.connectSent = true
            controller.sendCommand("connect", payload: ["workspace_id": context.fixture])
        }
        if let pane = window.pane(forWorkspace: context.fixture) {
            if pane.identity == context.hostClosedIdentity {
                context.failure = "reconnect reused the closed terminal identity"
                controller.requestShutdown()
                return 1
            }
            if !context.hostCommandSent, pane.childPID != nil {
                pane.feed("unset HISTFILE; printf '\\104\\123\\137\\125\\111\\137\\122\\105\\101\\104\\131\\n'; printf '\\104\\123\\137\\125\\111\\137\\123\\110\\105\\114\\114\\137\\117\\113\\n'\n")
                context.hostCommandSent = true
            }
            if pane.text.contains("DS_UI_READY") && pane.text.contains("DS_UI_SHELL_OK") {
                context.hostShellVerified = true
                if context.hostShellVerifiedAt == nil { context.hostShellVerifiedAt = Date() }
            }
            if context.hostShellVerified {
                if ProcessInfo.processInfo.environment["DEVSPACE_HOST_UI_INTEGRATION"] == "1",
                   context.hostClosedIdentity != nil, !context.hostIntegrationVerified {
                    verifyHostIntegration(context, pane: pane, window: window, controller: controller)
                    return 1
                }
                if ProcessInfo.processInfo.environment["DEVSPACE_HOST_UI_IMAGE"] == "1",
                   !context.hostImageVerified {
                    verifyHostImage(context, pane: pane, controller: controller)
                    return 1
                }
                if let path = ProcessInfo.processInfo.environment["DEVSPACE_HOST_UI_SCREENSHOT"] {
                    guard Date().timeIntervalSince(context.hostShellVerifiedAt ?? Date()) >= 0.2 else { return 1 }
                    guard captureWindow(window.window, at: path) else {
                        context.failure = "could not capture the owned GTK window"
                        controller.requestShutdown()
                        return 1
                    }
                }
                guard window.snapshot.workspaces.first(where: { $0.id == context.fixture })?.state == "Running" else {
                    context.failure = "closing the real workspace terminal changed workspace lifecycle state"
                    controller.requestShutdown()
                    return 1
                }
                window.closeTerminal(pane.identity, reportExit: true)
                if context.hostClosedIdentity == nil {
                    context.hostClosedIdentity = pane.identity
                    context.hostCommandSent = false
                    context.hostShellVerified = false
                    context.hostShellVerifiedAt = nil
                    controller.sendCommand("reconnect", payload: ["workspace_id": context.fixture])
                    return 1
                }
                context.hostReopened = true
                context.terminalClosed = true
                controller.requestShutdown()
            }
        }
        if controller.backend.state == .stopped {
            if context.failure == nil && context.connectSent && context.terminalClosed && context.hostReopened {
                context.exitCode = 0
            }
            g_application_quit(UnsafeMutableRawPointer(context.application).assumingMemoryBound(to: GApplication.self))
            return 0
        }
        if case .failed = controller.backend.state, context.failure == nil {
            context.failure = controller.backend.failure ?? "real workspace backend failed"
            controller.requestShutdown()
        }
        return 1
    }
    if context.mode == "crash" {
        if case .failed = controller.backend.state {
            if context.failureObservedAt == nil { context.failureObservedAt = Date() }
            let root = gtk_window_get_child(window.window)!
            let actionButtons = countWidgets(root, cssName: "button")
            let enabledButtons = countEnabledButtons(root)
            let failureIsVisible = containsLabel(root, containing: "backend output closed unexpectedly")
            if window.workspaceCount == 1 && actionButtons > 0 && enabledButtons == 0 && failureIsVisible {
                context.exitCode = 0
                print("linux-application backend-failure=visible actions=disabled gtk=responsive")
                controller.requestShutdown()
                return 1
            }
            if Date().timeIntervalSince(context.failureObservedAt ?? Date()) > 2 {
                context.failure = "backend failure did not reach the GTK recovery UI"
                controller.requestShutdown()
            }
        }
        return 1
    }
    if Date().timeIntervalSince(context.startedAt) > 8 {
        context.failure = context.mode == "zed-failure"
            ? "Zed launch failure did not become visible while the terminal remained usable"
            : "timed out waiting for workspace and terminal effects"
        controller.requestShutdown()
    }

    if window.workspaceCount == 1 && !context.connectSent {
        context.connectSent = true
        controller.sendCommand("connect", payload: ["workspace_id": "fixture-pod"])
    }

    let identity = TerminalPaneIdentity(
        workspaceID: "fixture-pod",
        generation: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        paneID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    )
    if !context.terminalClosed,
       let pane = window.pane(for: identity), pane.text.contains("received:from-app") {
        if context.mode == "zed-failure" {
            guard let root = gtk_window_get_child(window.window),
                  containsLabel(root, containing: "Could not launch Zed"), countEnabledButtons(root) > 0,
                  !pane.isClosed else { return 1 }
            if !context.editorProbeSent {
                pane.feed("editor-error-probe\n")
                context.editorProbeSent = true
                return 1
            }
            guard pane.text.contains("received:editor-error-probe") else { return 1 }
        } else if context.mode == "zed-success" {
            guard let record = ProcessInfo.processInfo.environment["DEVSPACE_TEST_ZED_RECORD"],
                  FileManager.default.fileExists(atPath: record) else { return 1 }
        } else if context.mode == "zed-stale" {
            guard let record = ProcessInfo.processInfo.environment["DEVSPACE_TEST_ZED_RECORD"],
                  let started = ProcessInfo.processInfo.environment["DEVSPACE_TEST_ZED_STARTED"],
                  FileManager.default.fileExists(atPath: started) else { return 1 }
            if context.failureObservedAt == nil {
                controller.sendCommand("disconnect", payload: ["workspace_id": "fixture-pod"])
                context.failureObservedAt = Date()
                return 1
            }
            guard Date().timeIntervalSince(context.failureObservedAt!) > 0.8 else { return 1 }
            if FileManager.default.fileExists(atPath: record) {
                context.failure = "stale editor completion launched DevPod after disconnect"
                controller.requestShutdown()
                return 1
            }
        } else if !context.notificationActivated {
            let actions = OpaquePointer(UnsafeMutableRawPointer(context.application))
            guard g_action_group_has_action(actions, "activate-workspace") != 0 else {
                context.failure = "notification workspace activation action is missing"
                controller.requestShutdown()
                return 1
            }
            for workspace in ["missing-pod", identity.workspaceID] {
                let target = g_variant_ref_sink(g_variant_new_string(workspace))!
                g_action_group_activate_action(actions, "activate-workspace", target)
                g_variant_unref(target)
            }
            guard window.pane(for: identity) === pane, window.terminalCount == 1,
                  gtk_window_get_focus(window.window) == pane.widget else {
                context.failure = "notification activation failed to focus the existing terminal"
                controller.requestShutdown()
                return 1
            }
            guard let root = gtk_window_get_child(window.window),
                  containsLabel(root, containing: "fixture listener unavailable"),
                  containsLabel(root, containing: "fixture SSH error") else {
                context.failure = "snapshot refresh erased an integration warning or operation error"
                controller.requestShutdown()
                return 1
            }
            context.notificationActivated = true
            return 1
        }
        if !context.imagePasteSent {
            let imageURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("devspace-paste-\(UUID().uuidString).png")
            let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
            guard FileManager.default.createFile(atPath: imageURL.path, contents: pngSignature,
                                                 attributes: [.posixPermissions: 0o600]) else {
                context.failure = "could not create temporary clipboard image"
                controller.requestShutdown()
                return 1
            }
            context.imagePastePath = imageURL.path
            context.imagePasteSent = true
            controller.sendCommand("paste_image", payload: [
                "workspace_id": identity.workspaceID,
                "generation": identity.generation.uuidString.lowercased(),
                "pane_id": identity.paneID.uuidString.lowercased(),
                "source_path": imageURL.path,
            ])
            return 1
        }
        if let imagePath = context.imagePastePath, FileManager.default.fileExists(atPath: imagePath) {
            return 1
        }
        guard window.snapshot.workspaces.first?.state == "Running" else {
            context.failure = "closing the pane changed the workspace state"
            controller.requestShutdown()
            return 1
        }
        window.closeTerminal(identity, reportExit: true)
        context.terminalClosed = true
        if context.mode == "normal" {
            let actions = OpaquePointer(UnsafeMutableRawPointer(context.application))
            guard g_action_group_has_action(actions, "quit") != 0 else {
                context.failure = "application has no orderly Quit action for relaunch"
                controller.requestShutdown()
                return 1
            }
            g_action_group_activate_action(actions, "quit", nil)
        } else { controller.requestShutdown() }
    }

    if controller.backend.state == .stopped {
        if context.failure == nil && context.connectSent && context.terminalClosed {
            context.exitCode = 0
            print("linux-application snapshot=received terminal=opened stale-effects=rejected shutdown=orderly")
        }
        g_application_quit(UnsafeMutableRawPointer(context.application).assumingMemoryBound(to: GApplication.self))
        return 0
    }
    if case .failed = controller.backend.state, context.failure == nil {
        context.failure = controller.backend.failure ?? "backend failed"
        controller.requestShutdown()
    }
    return 1
}

private func captureWindow(_ window: UnsafeMutablePointer<GtkWindow>, at path: String) -> Bool {
    let widget = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWidget.self)
    let width = gtk_widget_get_width(widget)
    let height = gtk_widget_get_height(widget)
    guard width > 0, height > 0,
          let renderer = gtk_native_get_renderer(OpaquePointer(UnsafeMutableRawPointer(window))) else { return false }
    let paintable = gtk_widget_paintable_new(widget)!
    defer { g_object_unref(UnsafeMutableRawPointer(paintable)) }
    let snapshot = gtk_snapshot_new()!
    gdk_paintable_snapshot(paintable, snapshot, Double(width), Double(height))
    guard let node = gtk_snapshot_free_to_node(snapshot) else { return false }
    defer { gsk_render_node_unref(node) }
    guard let texture = gsk_renderer_render_texture(renderer, node, nil) else { return false }
    defer { g_object_unref(UnsafeMutableRawPointer(texture)) }
    guard gdk_texture_save_to_png(texture, path) != 0 else { return false }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    return true
}

private func verifyHostImage(_ context: TestContext, pane: TerminalPane,
                             controller: LinuxApplicationController) {
    let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2ioAAAAASUVORK5CYII="
    if !context.imagePasteSent {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devspace-paste-\(UUID().uuidString).png")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(base64Encoded: png),
                                             attributes: [.posixPermissions: 0o600]) else {
            context.failure = "could not create private host image fixture"
            controller.requestShutdown()
            return
        }
        context.imagePastePath = url.path
        context.imagePasteSent = true
        controller.sendCommand("paste_image", payload: [
            "workspace_id": pane.identity.workspaceID,
            "generation": pane.identity.generation.uuidString.lowercased(),
            "pane_id": pane.identity.paneID.uuidString.lowercased(),
            "source_path": url.path,
        ])
        return
    }
    if !context.hostImageCheckSent {
        guard let range = pane.text.range(of: "/tmp/devspace-paste-[A-Fa-f0-9-]+\\.png",
                                         options: .regularExpression) else { return }
        let path = String(pane.text[range])
        // The allowlisted generated filename contains no shell metacharacters.
        // Ctrl+U clears the injected prompt text before the verification command.
        pane.feed("\u{15}[ \"$(base64 -w0 \(path))\" = '\(png)' ] && printf '\\104\\123\\137\\125\\111\\137\\111\\115\\101\\107\\105\\137\\117\\113\\n'; rm -f -- \(path); [ ! -e \(path) ] && printf '\\104\\123\\137\\125\\111\\137\\111\\115\\101\\107\\105\\137\\103\\114\\105\\101\\116\\n'\n")
        context.hostImageCheckSent = true
        return
    }
    if pane.text.contains("DS_UI_IMAGE_OK"), pane.text.contains("DS_UI_IMAGE_CLEAN"),
       let source = context.imagePastePath, !FileManager.default.fileExists(atPath: source) {
        context.hostImageVerified = true
    }
}

private func verifyHostIntegration(_ context: TestContext, pane: TerminalPane,
                                   window: WorkspaceWindow, controller: LinuxApplicationController) {
    if context.notificationActivated {
        guard window.snapshot.selectedID == context.fixture,
              gtk_window_get_focus(window.window) == pane.widget else { return }
        context.hostIntegrationVerified = true
        return
    }
    if !context.hostSelectionSent {
        guard let other = window.snapshot.workspaces.first(where: { $0.id != context.fixture }) else {
            context.failure = "notification badge check requires another listed workspace"
            controller.requestShutdown()
            return
        }
        controller.sendCommand("select", payload: ["workspace_id": other.id])
        context.hostSelectionSent = true
        return
    }
    if !context.hostNotificationSent {
        guard window.snapshot.selectedID != context.fixture else { return }
        pane.feed("DEVSPACE_PROD_POD_FORWARD_PORT=1 ~/.devspace-notify Stop\n")
        context.hostNotificationSent = true
        return
    }
    guard window.snapshot.badges.contains(context.fixture) else { return }
    if !context.hostDedSent {
        pane.feed("DEVSPACE_PROD_POD_FORWARD_PORT=1 bash -ic 'ded /tmp'\n")
        context.hostDedSent = true
        return
    }
    guard let record = ProcessInfo.processInfo.environment["DEVSPACE_HOST_UI_ZED_RECORD"],
          let argument = try? String(contentsOfFile: record, encoding: .utf8),
          argument == "ssh://\(context.fixture).devpod/tmp\n" else { return }
    let target = g_variant_ref_sink(g_variant_new_string(context.fixture))!
    g_action_group_activate_action(OpaquePointer(UnsafeMutableRawPointer(context.application)),
                                  "activate-workspace", target)
    g_variant_unref(target)
    context.notificationActivated = true
}

private func setPrivateClipboardImage() -> Bool {
    guard let display = gdk_display_get_default(),
          let clipboard = gdk_display_get_clipboard(display) else { return false }
    let pixel = Data([255, 0, 0, 255])
    guard let bytes = pixel.withUnsafeBytes({ g_bytes_new($0.baseAddress, gsize($0.count)) }) else {
        return false
    }
    defer { g_bytes_unref(bytes) }
    guard let texture = gdk_memory_texture_new(1, 1, GDK_MEMORY_R8G8B8A8, bytes, 4) else { return false }
    gdk_clipboard_set_texture(clipboard, texture)
    g_object_unref(UnsafeMutableRawPointer(texture))
    return true
}

private func countWidgets(_ widget: UnsafeMutablePointer<GtkWidget>, cssName: String) -> Int {
    var count = String(cString: gtk_widget_get_css_name(widget)) == cssName ? 1 : 0
    var child = gtk_widget_get_first_child(widget)
    while let current = child {
        count += countWidgets(current, cssName: cssName)
        child = gtk_widget_get_next_sibling(current)
    }
    return count
}

private func countEnabledButtons(_ widget: UnsafeMutablePointer<GtkWidget>) -> Int {
    let isEnabledButton = String(cString: gtk_widget_get_css_name(widget)) == "button"
        && gtk_widget_is_sensitive(widget) != 0
    var count = isEnabledButton ? 1 : 0
    var child = gtk_widget_get_first_child(widget)
    while let current = child {
        count += countEnabledButtons(current)
        child = gtk_widget_get_next_sibling(current)
    }
    return count
}

private func containsLabel(_ widget: UnsafeMutablePointer<GtkWidget>, containing text: String) -> Bool {
    if String(cString: gtk_widget_get_css_name(widget)) == "label",
       let label = gtk_label_get_text(OpaquePointer(widget)), String(cString: label).contains(text) {
        return true
    }
    var child = gtk_widget_get_first_child(widget)
    while let current = child {
        if containsLabel(current, containing: text) { return true }
        child = gtk_widget_get_next_sibling(current)
    }
    return false
}

@main
struct LinuxApplicationTests {
    static func main() {
            guard CommandLine.arguments.count == 4 else {
            fputs("LinuxApplicationTests: expected Python, fixture, and mode\n", stderr)
            exit(EXIT_FAILURE)
        }
        guard LinuxApplicationChannel.applicationIdentifier("development") == "com.prakharp.devspace.dev",
              LinuxApplicationChannel.applicationIdentifier("production") == "com.prakharp.devspace",
              LinuxApplicationChannel.applicationIdentifier("other") == nil else {
            fputs("LinuxApplicationTests: channel identity validation failed\n", stderr)
            exit(EXIT_FAILURE)
        }
        let appURL = URL(fileURLWithPath: "/bundle/bin/DevSpaceDev")
        guard LinuxApplicationChannel.backendExecutableURL(appURL, environment: [:]).path ==
                "/bundle/bin/DevSpaceLinuxBackend",
              LinuxApplicationChannel.backendExecutableURL(
                appURL, environment: ["DEVSPACE_BACKEND": "/private/test-backend"]
              ).path == "/private/test-backend" else {
            fputs("LinuxApplicationTests: backend executable lookup ignored its launcher environment\n", stderr)
            exit(EXIT_FAILURE)
        }
        let channel = CommandLine.arguments[3] == "host"
            ? (ProcessInfo.processInfo.environment["DEVSPACE_TEST_CHANNEL"] ?? "production")
            : "development"
        let identifier = LinuxApplicationChannel.applicationIdentifier(channel)!
        let application = gtk_application_new(identifier, GApplicationFlags(rawValue: 0))!
        let context = TestContext(
            python: CommandLine.arguments[1], fixture: CommandLine.arguments[2], mode: CommandLine.arguments[3],
            application: application
        )
        let callback = unsafeBitCast(
            activate as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
            to: GCallback.self
        )
        _ = g_signal_connect_data(application, "activate", callback,
                                  Unmanaged.passUnretained(context).toOpaque(), nil, GConnectFlags(rawValue: 0))
        _ = g_application_run(UnsafeMutableRawPointer(application).assumingMemoryBound(to: GApplication.self), 0, nil)
        if let failure = context.failure {
            fputs("LinuxApplicationTests: \(failure)\n", stderr)
            exit(EXIT_FAILURE)
        }
        if context.mode == "host", context.connectSent, context.terminalClosed,
           context.controller?.backend.state == .stopped {
            print("host-vte workspace=connected shell=round-trip close=workspace-preserved reopen=new-pane-round-trip")
            if context.hostImageVerified { print("image=uploaded-verified-cleaned") }
            if context.hostIntegrationVerified { print("integration=helper-badge-ded-routed") }
            exit(EXIT_SUCCESS)
        }
        if context.mode != "crash", context.connectSent, context.terminalClosed,
           context.controller?.backend.state == .stopped {
            if context.mode == "zed-failure" {
                print("zed-failure=visible terminal=round-trip actions=enabled")
            }
            print("linux-application snapshot=received terminal=opened stale-effects=rejected shutdown=orderly")
            exit(EXIT_SUCCESS)
        }
        if context.mode != "crash" {
            fputs("LinuxApplicationTests: GTK exited before controlled shutdown completed\n", stderr)
        }
        exit(context.exitCode)
    }
}
