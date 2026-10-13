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
    var hostCommandSent = false
    var hostImageRequested = false
    var hostImageInputSubmitted = false
    var hostImageVerified = false
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
            context.failure = "timed out waiting for real workspace terminal input/output"
            controller.requestShutdown()
        }
        if !context.connectSent,
           window.snapshot.workspaces.contains(where: { $0.id == context.fixture && $0.state == "Running" }) {
            context.connectSent = true
            controller.sendCommand("connect", payload: ["workspace_id": context.fixture])
        }
        if let pane = window.pane(forWorkspace: context.fixture) {
            if !context.hostCommandSent, pane.childPID != nil {
                pane.feed("printf '\\104\\123\\137\\125\\111\\137\\122\\105\\101\\104\\131\\n'; IFS= read -r input; printf '\\104\\123\\137\\125\\111\\137\\111\\116\\120\\125\\124\\072%s\\n' \"$input\"; case \"$input\" in 'Image pasted: '*) image_path=${input#Image pasted: }; image_path=${image_path% }; if [ -f \"$image_path\" ]; then printf '\\104\\123\\137\\125\\111\\137\\111\\115\\101\\107\\105\\137\\102\\131\\124\\105\\123\\072'; base64 -w0 -- \"$image_path\"; else printf '\\104\\123\\137\\125\\111\\137\\111\\115\\101\\107\\105\\137\\115\\111\\123\\123\\111\\116\\107'; fi; rm -f -- \"$image_path\";; esac\n")
                context.hostCommandSent = true
            }
            if !context.hostImageRequested && pane.text.contains("DS_UI_READY") {
                guard setPrivateClipboardImage(), pane.handleKey(
                    keyval: UInt32(GDK_KEY_v),
                    modifiers: GdkModifierType(rawValue: GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue)
                ) else {
                    context.failure = "VTE could not paste the private clipboard image"
                    controller.requestShutdown()
                    return 1
                }
                context.hostImageRequested = true
            }
            if context.hostImageRequested && !context.hostImageInputSubmitted,
               pane.text.contains("Image pasted: /tmp/devspace-paste-") {
                pane.feed("\n")
                context.hostImageInputSubmitted = true
            }
            if !context.hostImageVerified,
               let marker = pane.text.range(of: "DS_UI_IMAGE_BYTES:") {
                let encoded = pane.text[marker.upperBound...].prefix { !$0.isWhitespace }
                let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
                if let image = Data(base64Encoded: String(encoded)), image.starts(with: signature) {
                    context.hostImageVerified = true
                }
            }
            if context.hostImageVerified {
                guard window.snapshot.workspaces.first(where: { $0.id == context.fixture })?.state == "Running" else {
                    context.failure = "closing the real workspace terminal changed workspace lifecycle state"
                    controller.requestShutdown()
                    return 1
                }
                window.closeTerminal(pane.identity, reportExit: true)
                context.terminalClosed = true
                controller.requestShutdown()
            }
        }
        if controller.backend.state == .stopped {
            if context.failure == nil && context.connectSent && context.terminalClosed {
                context.exitCode = 0
                print("host-vte workspace=connected clipboard=image-pasted image-upload=verified close=workspace-preserved")
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
        context.failure = "timed out waiting for workspace and terminal effects"
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
        controller.requestShutdown()
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
        && gtk_widget_get_sensitive(widget) != 0
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
        if context.mode != "crash", context.connectSent, context.terminalClosed,
           context.controller?.backend.state == .stopped {
            print("linux-application snapshot=received terminal=opened stale-effects=rejected shutdown=orderly")
            exit(EXIT_SUCCESS)
        }
        if context.mode != "crash" {
            fputs("LinuxApplicationTests: GTK exited before controlled shutdown completed\n", stderr)
        }
        exit(context.exitCode)
    }
}
