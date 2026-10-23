import Foundation
import Glibc
import XCTest
import CGTK
@testable import DevSpaceCore
@testable import DevSpaceLinuxApp

private final class PrivateClipboardRead {
    var pending = false
    var text = ""
}

final class HerdrClipboardTests: XCTestCase {
    private func pump(until ready: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !ready() && Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            usleep(1_000)
        }
        return ready()
    }

    func testIsolatedHerdrMouseCopyReachesPrivateClipboard() throws {
        guard ProcessInfo.processInfo.environment["DEVSPACE_PRIVATE_KEY_TEST"] == "1",
              let executable = ProcessInfo.processInfo.environment["DEVSPACE_TEST_HERDR"] else {
            throw XCTSkip("requires explicitly private X11 and an installed Herdr executable")
        }
        try acceptance(executable: executable, workspace: nil)
    }

    func testOptInRemoteHerdrCopyTraversesSSHAndOSC52() throws {
        guard ProcessInfo.processInfo.environment["DEVSPACE_PRIVATE_KEY_TEST"] == "1",
              let workspace = ProcessInfo.processInfo.environment["DEVSPACE_HOST_WORKSPACE"],
              let executable = ProcessInfo.processInfo.environment["DEVSPACE_TEST_REMOTE_HERDR"] else {
            throw XCTSkip("requires an authorized workspace, its installed Herdr and private X11")
        }
        try Devpod.validateId(workspace)
        try acceptance(executable: executable, workspace: workspace)
    }

    private func acceptance(executable: String, workspace: String?) throws {
        gtk_init()
        let token = String(UUID().uuidString.lowercased().prefix(8))
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/h-\(token)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("r")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let config = root.appendingPathComponent("c")
        try "onboarding = false\n[terminal]\ndefault_shell = '/bin/sh'\n[update]\nversion_check = false\nmanifest_check = false\n".write(to: config, atomically: true, encoding: .utf8)
        let session = "s\(token)"
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HERDR_") }
        environment.merge(["HOME": root.path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_DATA_HOME": root.appendingPathComponent("data").path,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path, "XDG_RUNTIME_DIR": runtime.path,
            "HERDR_CONFIG_PATH": config.path, "SHELL": "/bin/sh"]) { _, new in new }
        func run(_ path: String, _ arguments: [String], _ env: [String: String]) throws -> Data {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = env
            process.currentDirectoryURL = root
            process.standardOutput = output
            process.standardError = errors
            if path == "/usr/bin/ssh" { try runDesktopSSHMaster(process) }
            else { try runDesktopProcess(process) }
            guard pump(until: { !process.isRunning }) else {
                process.terminate()
                throw NSError(domain: "Herdr test command timeout", code: 1)
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), code: 1)
            }
            return data
        }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let control = runtime.appendingPathComponent("m").path
        var master: Process?
        var remoteRoot: String?
        var remoteEnvironment: [String: String] = [:]
        func remote(_ text: String) throws -> Data {
            try run("/usr/bin/ssh", ["-x"] + SSH.workspaceCommandArgs(podID: workspace!, controlPath: control, command: text),
                    ProcessInfo.processInfo.environment)
        }
        defer {
            if let remoteRoot { _ = try? remote("rm -rf -- " + quote(remoteRoot)) }
            if let master, master.isRunning { master.terminate(); master.waitUntilExit() }
        }
        if let workspace {
            let process = Process()
            var arguments = SSH.masterArgs(podID: workspace,
                proxyCommand: SSH.resolveDevpodProxyCommand(podID: workspace), controlPath: control,
                bundleIdentifier: "com.prakharp.devspace.dev")
            // An isolated clipboard transport owns no notification forward and
            // cannot collide with either running application's remote port.
            let forwarding = try XCTUnwrap(arguments.firstIndex(of: "-R"))
            arguments.removeSubrange(forwarding...forwarding + 1)
            arguments.insert(contentsOf: ["-x", "-o", "BatchMode=yes"], at: arguments.count - 1)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.standardError
            try runDesktopSSHMaster(process)
            master = process
            XCTAssertTrue(pump(until: {
                guard process.isRunning, FileManager.default.fileExists(atPath: control) else { return false }
                return (try? run("/usr/bin/ssh", SSH.controlCheckArgs(podID: workspace, controlPath: control),
                                 ProcessInfo.processInfo.environment)) != nil
            }, timeout: 30), "isolated SSH master ready")
            let created = String(decoding: try remote("mkdir -p \"$HOME/.tmp\" && mktemp -d \"$HOME/.tmp/h-\(token).XXXXXX\""), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard created.hasPrefix("/"), !created.contains("\n"), !created.contains("\0"),
                  created.range(of: "/\\.tmp/h-\(token)\\.[A-Za-z0-9]{6}$", options: .regularExpression) != nil else {
                throw NSError(domain: "invalid remote fixture directory", code: 1)
            }
            remoteRoot = created
            remoteEnvironment = ["HOME": created, "XDG_CONFIG_HOME": created + "/cdir", "XDG_DATA_HOME": created + "/d",
                "XDG_STATE_HOME": created + "/s", "XDG_RUNTIME_DIR": created + "/r",
                "HERDR_CONFIG_PATH": created + "/c", "SHELL": "/bin/sh"]
            _ = try remote("mkdir -p " + quote(created + "/r") + " && chmod 700 " + quote(created + "/r")
                + " && printf %s " + quote(try String(contentsOf: config, encoding: .utf8)) + " > " + quote(created + "/c"))
        }
        func remoteHerdr(_ arguments: [String]) -> String {
            (["exec", "/usr/bin/env", "-u", "HERDR_ENV", "-u", "HERDR_SOCKET_PATH", "-u", "HERDR_CLIENT_SOCKET_PATH",
              "-u", "HERDR_SESSION", "-u", "HERDR_PANE_ID", "-u", "HERDR_WORKSPACE_ID", "-u", "HERDR_TAB_ID"]
                + remoteEnvironment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                + [executable, "--session", session] + arguments).map(quote).joined(separator: " ")
        }
        func command(_ arguments: [String]) throws -> Data {
            if workspace != nil { return try remote(remoteHerdr(arguments)) }
            return try run(executable, ["--session", session] + arguments, environment)
        }
        let unset = ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("HERDR_") }
            .sorted().flatMap { ["-u", $0] }
        var launchArguments = unset + ["HERDR_CONFIG_PATH=\(config.path)", executable, "--session", session]
        var launchExecutable = "/usr/bin/env"
        if let workspace {
            launchExecutable = "/usr/bin/ssh"
            launchArguments = SSH.clientArgs(podID: workspace, proxyCommand: nil, controlPath: control,
                bundleIdentifier: "com.prakharp.devspace.dev")
            launchArguments.insert(contentsOf: ["-x", "-o", "ProxyCommand=/bin/false"], at: launchArguments.count - 1)
            launchArguments.append(remoteHerdr([]))
        }
        let launch = try XCTUnwrap(LinuxTerminalLaunch(kind: "terminal_launch", workspaceID: "herdr-test",
            paneID: UUID(), generation: UUID(), executable: launchExecutable,
            arguments: launchArguments,
            workingDirectory: root.path, environment: environment))
        let pane = try XCTUnwrap(TerminalPane(launch: launch))
        let window = gtk_window_new()!
        let native = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        defer {
            // Only the unique server created by this test, never the caller's.
            _ = try? command(["server", "stop"])
            pane.dispose()
            gtk_window_destroy(native)
        }
        gtk_window_set_default_size(native, 1000, 600)
        gtk_window_set_child(native, pane.widget)
        gtk_window_present(native)
        _ = gtk_widget_grab_focus(pane.widget)
        XCTAssertTrue(pump { !pane.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let created = try XCTUnwrap(JSONSerialization.jsonObject(with: command([
            "workspace", "create", "--cwd", remoteRoot ?? root.path, "--label", "clipboard acceptance", "--focus"
        ])) as? [String: Any])
        let result = try XCTUnwrap(created["result"] as? [String: Any])
        let rootPane = try XCTUnwrap(result["root_pane"] as? [String: Any])
        let paneID = try XCTUnwrap(rootPane["pane_id"] as? String)
        let marker = "HERDR_COPY_\(token)"
        _ = try command(["pane", "run", paneID, "printf 'HERDR_%s\\n' 'COPY_\(token)'"])
        XCTAssertTrue(pump { pane.text.contains(marker) })
        let line = try XCTUnwrap(pane.text.components(separatedBy: "\n").enumerated().first { $0.element.contains(marker) })
        let range = try XCTUnwrap(line.element.range(of: marker))
        let column = line.element[..<range.lowerBound].unicodeScalars.count
        let size = try XCTUnwrap(pane.ptySize)
        let width = Double(gtk_widget_get_width(pane.widget)) / Double(size.columns)
        let height = Double(gtk_widget_get_height(pane.widget)) / Double(size.rows)
        try drag(in: window, widget: pane.widget,
                 // Start inside the text pane. Starting before its first
                 // column hits Herdr's sidebar/divider instead of selecting.
                 from: ((Double(column) + 0.1) * width, (Double(line.offset) + 0.5) * height),
                 to: (Double(column + marker.count + 3) * width, (Double(line.offset) + 0.5) * height))
        let read = PrivateClipboardRead()
        XCTAssertTrue(pump {
            guard let display = gdk_display_get_default(), let clipboard = gdk_display_get_clipboard(display) else { return false }
            if !read.pending && !read.text.contains(marker) {
                read.pending = true
                let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { source, result, data in
                    guard let data else { return }
                    let state = Unmanaged<PrivateClipboardRead>.fromOpaque(data).takeRetainedValue()
                    state.pending = false
                    guard let source, let result else { return }
                    var error: UnsafeMutablePointer<GError>?
                    let text = gdk_clipboard_read_text_finish(OpaquePointer(source), OpaquePointer(result), &error)
                    if let text { state.text = String(cString: text); g_free(text) }
                    if let error { g_error_free(error) }
                }
                gdk_clipboard_read_text_async(clipboard, nil, unsafeBitCast(callback, to: GAsyncReadyCallback.self),
                    Unmanaged.passRetained(read).toOpaque())
            }
            return read.text.contains(marker)
        }, "Herdr copy: row=\(line.offset) col=\(column) grid=\(size) focus=\(gtk_widget_has_focus(pane.widget)) active=\(gtk_window_is_active(native)) clipboard=\(read.text) controlled screen=\(pane.text.suffix(1000))")
        if workspace != nil {
            let display = try XCTUnwrap(gdk_display_get_default())
            let clipboard = try XCTUnwrap(gdk_display_get_clipboard(display))
            XCTAssertNotEqual(gdk_clipboard_is_local(clipboard), 0, "remote OSC52 must be owned by the frontend")
        }
    }

    private func drag(in window: UnsafeMutablePointer<GtkWidget>, widget: UnsafeMutablePointer<GtkWidget>,
                      from: (Double, Double), to: (Double, Double)) throws {
        let x11 = try XCTUnwrap(dlopen("libX11.so.6", RTLD_NOW))
        let xtst = try XCTUnwrap(dlopen("libXtst.so.6", RTLD_NOW))
        let gtk = try XCTUnwrap(dlopen("libgtk-4.so.1", RTLD_NOW))
        defer { dlclose(gtk); dlclose(xtst); dlclose(x11) }
        let open = unsafeBitCast(dlsym(x11, "XOpenDisplay")!, to: (@convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?).self)
        let display = try XCTUnwrap(open(nil))
        defer { _ = unsafeBitCast(dlsym(x11, "XCloseDisplay")!, to: (@convention(c) (UnsafeMutableRawPointer) -> Int32).self)(display) }
        let xid = unsafeBitCast(dlsym(gtk, "gdk_x11_surface_get_xid")!, to: (@convention(c) (UnsafeMutableRawPointer) -> UInt).self)
        let id = xid(UnsafeMutableRawPointer(gtk_native_get_surface(OpaquePointer(window))!))
        let root = unsafeBitCast(dlsym(x11, "XDefaultRootWindow")!, to: (@convention(c) (UnsafeMutableRawPointer) -> UInt).self)(display)
        var x: Int32 = 0, y: Int32 = 0, child: UInt = 0
        _ = unsafeBitCast(dlsym(x11, "XTranslateCoordinates")!, to: (@convention(c) (UnsafeMutableRawPointer, UInt, UInt, Int32, Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<UInt>) -> Int32).self)(display, id, root, 0, 0, &x, &y, &child)
        _ = unsafeBitCast(dlsym(x11, "XSetInputFocus")!, to: (@convention(c) (UnsafeMutableRawPointer, UInt, Int32, UInt) -> Int32).self)(display, id, 2, 0)
        let motion = unsafeBitCast(dlsym(xtst, "XTestFakeMotionEvent")!, to: (@convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32, UInt) -> Int32).self)
        let button = unsafeBitCast(dlsym(xtst, "XTestFakeButtonEvent")!, to: (@convention(c) (UnsafeMutableRawPointer, UInt32, Int32, UInt) -> Int32).self)
        let sync = unsafeBitCast(dlsym(x11, "XSync")!, to: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Int32).self)
        func move(_ point: (Double, Double)) {
            var source = graphene_point_t(x: Float(point.0), y: Float(point.1)), target = graphene_point_t()
            _ = gtk_widget_compute_point(widget, window, &source, &target)
            _ = motion(display, 0, x + Int32(target.x), y + Int32(target.y), 0)
            _ = sync(display, 0)
            _ = pump(until: { false }, timeout: 0.05)
        }
        move(from)
        _ = button(display, 1, 1, 0); _ = sync(display, 0)
        _ = pump(until: { false }, timeout: 0.05)
        move(to)
        _ = button(display, 1, 0, 0); _ = sync(display, 0)
        _ = pump(until: { false }, timeout: 0.05)
    }
}
