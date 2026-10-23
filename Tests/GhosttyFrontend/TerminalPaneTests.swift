import Foundation
import XCTest
import CGTK
@testable import DevSpaceLinuxApp

final class TerminalPaneTests: XCTestCase {
    func testOptInDesktopClipboardRoundTripWithExternalApplication() throws {
        guard ProcessInfo.processInfo.environment["DEVSPACE_HOST_CLIPBOARD_ACCEPTANCE"] == "1" else {
            throw XCTSkip("requires explicit desktop clipboard acceptance; replaces clipboard with synthetic text")
        }
        gtk_init()
        let marker = "DEVSPACE_DESKTOP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let encoded = Data(marker.utf8).base64EncodedString()
        let launch = try XCTUnwrap(LinuxTerminalLaunch(kind: "terminal_launch", workspaceID: "clipboard-acceptance",
            paneID: UUID(), generation: UUID(), executable: "/bin/sh",
            arguments: ["-c", "stty -echo; printf READY; IFS= read -r line; stty -icanon min 1 time 0; printf '\\033]52;c;\(encoded)\\007COPIED'; line=$(dd bs=1 count=\(marker.count + 9) 2>/dev/null); printf '\\nPASTED:%s\\n' \"$line\"; sleep 30"]))
        let pane = try XCTUnwrap(TerminalPane(launch: launch))
        let window = gtk_window_new()!
        let native = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        defer { pane.dispose(); gtk_window_destroy(native) }
        gtk_window_set_title(native, "DevSpace clipboard acceptance — synthetic text")
        gtk_window_set_default_size(native, 640, 320)
        gtk_window_set_child(native, pane.widget)
        gtk_window_present(native)
        _ = gtk_widget_grab_focus(pane.widget)
        guard pump(until: { pane.text.contains("READY") && gtk_window_is_active(native) != 0 }, timeout: 60) else {
            XCTFail("desktop acceptance window must be active before clipboard write")
            return
        }
        pane.feed("copy\n")
        XCTAssertTrue(pump { pane.text.contains("COPIED") })
        // Separate X11 application exercises the desktop clipboard bridge,
        // rather than inspecting the GTK content provider in this process.
        let reader = Process(), output = Pipe()
        reader.executableURL = URL(fileURLWithPath: "/usr/bin/xclip")
        reader.arguments = ["-selection", "clipboard", "-out"]
        reader.standardOutput = output
        reader.standardError = FileHandle.nullDevice
        try reader.run()
        defer { if reader.isRunning { reader.terminate() } }
        guard pump(until: { !reader.isRunning }) else { XCTFail("external clipboard reader timed out"); return }
        XCTAssertEqual(reader.terminationStatus, 0)
        // Never print an unexpected clipboard value: it could be private.
        let actual = output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertTrue(actual == Data(marker.utf8), "external app must receive the synthetic terminal marker")
        let writer = Process(), input = Pipe()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/xclip")
        writer.arguments = ["-selection", "clipboard", "-in", "-quiet"]
        writer.standardInput = input
        writer.standardOutput = FileHandle.nullDevice
        writer.standardError = FileHandle.nullDevice
        try writer.run()
        defer { if writer.isRunning { writer.terminate() } }
        input.fileHandleForWriting.write(Data((marker + "_EXTERNAL").utf8))
        try input.fileHandleForWriting.close()
        let clipboard = try XCTUnwrap(gdk_display_get_clipboard(try XCTUnwrap(gdk_display_get_default())))
        XCTAssertTrue(pump { gdk_clipboard_is_local(clipboard) == 0 })
        XCTAssertTrue(pane.handleKey(keyval: UInt32(GDK_KEY_v),
            modifiers: GdkModifierType(rawValue: GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue)))
        XCTAssertTrue(pump { pane.text.contains("PASTED:" + marker + "_EXTERNAL") })
    }

    func testHiddenPanesKeepIndependentPTYsAndClosingOnePreservesItsSibling() throws {
        guard ProcessInfo.processInfo.environment["DEVSPACE_PRIVATE_KEY_TEST"] == "1" else {
            throw XCTSkip("requires a private GTK display")
        }
        gtk_init()
        func makePane(_ tag: String) throws -> TerminalPane {
            let launch = try XCTUnwrap(LinuxTerminalLaunch(kind: "terminal_launch", workspaceID: tag,
                paneID: UUID(), generation: UUID(), executable: "/bin/sh",
                arguments: ["-c", "stty -echo; printf READY; while IFS= read -r line; do printf '\\n\(tag):%s\\n' \"$line\"; done"]))
            return try XCTUnwrap(TerminalPane(launch: launch))
        }
        let first = try makePane("first"), second = try makePane("second")
        let window = gtk_window_new()!
        let native = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        let stackWidget = gtk_stack_new()!, stack = OpaquePointer(stackWidget)
        gtk_stack_add_named(stack, first.widget, "first")
        gtk_stack_add_named(stack, second.widget, "second")
        gtk_window_set_default_size(native, 720, 360)
        gtk_window_set_child(native, stackWidget)
        gtk_window_present(native)
        defer { first.dispose(); second.dispose(); gtk_window_destroy(native) }
        XCTAssertTrue(pump { first.text.contains("READY") && second.text.contains("READY") })
        gtk_stack_set_visible_child_name(stack, "second")
        XCTAssertTrue(pump { gtk_widget_get_mapped(first.widget) == 0 && gtk_widget_get_mapped(second.widget) != 0 })
        first.feed("hidden\n")
        XCTAssertTrue(pump { first.text.contains("first:hidden") })
        XCTAssertFalse(second.text.contains("first:hidden"))
        let firstPID = try XCTUnwrap(first.childPID)
        first.dispose()
        XCTAssertTrue(pump { Glibc.kill(firstPID, 0) != 0 && errno == ESRCH })
        second.feed("survived\n")
        XCTAssertTrue(pump { second.text.contains("second:survived") })
        XCTAssertFalse(second.isClosed)
    }

    func testOptInRealWorkspaceRoundTripAndOrderlyDisconnect() throws {
        guard ProcessInfo.processInfo.environment["DEVSPACE_PRIVATE_KEY_TEST"] == "1",
              let workspace = ProcessInfo.processInfo.environment["DEVSPACE_HOST_WORKSPACE"],
              let backend = ProcessInfo.processInfo.environment["DEVSPACE_TEST_BACKEND"] else {
            throw XCTSkip("opt-in authorized real workspace and private display required")
        }
        gtk_init()
        let application = gtk_application_new("com.prakharp.devspace.dev.ghosttyacceptance", GApplicationFlags(rawValue: 0))!
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        var error: UnsafeMutablePointer<GError>?
        XCTAssertNotEqual(g_application_register(UnsafeMutableRawPointer(application).assumingMemoryBound(to: GApplication.self), nil, &error), 0)
        if let error { g_error_free(error) }
        let controller = LinuxApplicationController(application: application, channel: "development",
            backendExecutableURL: URL(fileURLWithPath: backend))
        try controller.start()
        defer {
            controller.requestShutdown()
            XCTAssertTrue(pump(until: { controller.backend.state == .stopped }, timeout: 30))
        }
        XCTAssertTrue(pump(until: { controller.backend.state == .ready }, timeout: 10))
        controller.sendCommand("select", payload: ["workspace_id": workspace])
        controller.sendCommand("connect", payload: ["workspace_id": workspace])
        XCTAssertTrue(pump(until: { controller.window?.pane(forWorkspace: workspace) != nil }, timeout: 60))
        let pane = try XCTUnwrap(controller.window?.pane(forWorkspace: workspace))
        XCTAssertTrue(pump(until: { gtk_widget_get_mapped(pane.widget) != 0
            && !pane.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, timeout: 20))
        pane.feed("unset HISTFILE; printf 'GHOSTTY_%s\\n' 'LIVE_OK'\n")
        XCTAssertTrue(pump(until: { pane.text.contains("GHOSTTY_LIVE_OK") }, timeout: 20),
            "real SSH shell round trip; controlled terminal tail: \(pane.text.suffix(1500))")
        XCTAssertEqual(pane.identity.workspaceID, workspace)
        controller.sendCommand("disconnect", payload: ["workspace_id": workspace])
        XCTAssertTrue(pump(until: { controller.window?.pane(forWorkspace: workspace) == nil }, timeout: 20))
    }

    private func pump(until ready: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !ready() && Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            usleep(1_000)
        }
        return ready()
    }

    func testFinalOutputPrecedesExitAndKeepsPaneIdentity() throws {
        guard ProcessInfo.processInfo.environment["DEVSPACE_PRIVATE_KEY_TEST"] == "1" else {
            throw XCTSkip("requires a private GTK display")
        }
        gtk_init()
        let generation = UUID(), paneID = UUID()
        var events: [(String, [String: String])] = []
        let launch = try XCTUnwrap(LinuxTerminalLaunch(kind: "terminal_launch", workspaceID: "fixture",
            paneID: paneID, generation: generation, executable: "/bin/sh",
            arguments: ["-c", "printf '\\033]7;file://fixture/workspace\\007FINAL'; exit 7"]))
        let pane = try XCTUnwrap(TerminalPane(launch: launch) { events.append(($0, $1)) })
        defer { pane.dispose() }
        XCTAssertTrue(pump { events.contains { $0.0 == "terminal_exit" } })
        XCTAssertTrue(pane.text.contains("FINAL"))
        let output = try XCTUnwrap(events.firstIndex { $0.0 == "terminal_output" })
        let exit = try XCTUnwrap(events.firstIndex { $0.0 == "terminal_exit" })
        XCTAssertLessThan(output, exit)
        XCTAssertEqual(events[exit].1["exit_code"], "7")
        XCTAssertEqual(events[exit].1["pane_id"], paneID.uuidString.lowercased())
        XCTAssertEqual(events[exit].1["generation"], generation.uuidString.lowercased())
        XCTAssertTrue(events.contains { $0.0 == "terminal_directory" && $0.1["directory"] == "/workspace" })
    }

    func testExistingSwiftPTYAcceptsTypingAndResizesFromGTK() throws {
        guard ProcessInfo.processInfo.environment["DEVSPACE_PRIVATE_KEY_TEST"] == "1" else {
            throw XCTSkip("requires a private GTK display")
        }
        gtk_init()
        let launch = try XCTUnwrap(LinuxTerminalLaunch(kind: "terminal_launch", workspaceID: "fixture",
            paneID: UUID(), generation: UUID(), executable: "/bin/sh",
            arguments: ["-c", "stty -echo; printf READY; IFS= read -r line; printf '\\nRECEIVED:%s\\n' \"$line\"; stty size; sleep 30"]))
        let pane = try XCTUnwrap(TerminalPane(launch: launch))
        let window = gtk_window_new()!
        let native = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        defer { pane.dispose(); gtk_window_destroy(native) }
        gtk_window_set_default_size(native, 720, 360)
        gtk_window_set_child(native, pane.widget)
        gtk_window_present(native)
        XCTAssertTrue(pump { pane.text.contains("READY") && pane.ptySize?.columns != 80 })
        let size = try XCTUnwrap(pane.ptySize)
        pane.feed("typed text\n")
        XCTAssertTrue(pump { pane.text.contains("RECEIVED:typed text") && pane.text.contains("\(size.rows) \(size.columns)") })
        pane.dispose()
        XCTAssertNil(pane.ptySize)
    }

    func testOSC52WritesOnlyFromFocusedPaneOnPrivateDisplay() throws {
        guard ProcessInfo.processInfo.environment["DEVSPACE_PRIVATE_KEY_TEST"] == "1" else {
            throw XCTSkip("requires a private GTK display")
        }
        gtk_init()
        let marker = "devspace-private-clipboard-marker"
        let encoded = Data(marker.utf8).base64EncodedString()
        let launch = try XCTUnwrap(LinuxTerminalLaunch(kind: "terminal_launch", workspaceID: "fixture",
            paneID: UUID(), generation: UUID(), executable: "/bin/sh",
            arguments: ["-c", "stty -echo; printf READY; IFS= read -r line; printf '\\033]52;c;\(encoded)\\007'; sleep 30"]))
        let pane = try XCTUnwrap(TerminalPane(launch: launch))
        let window = gtk_window_new()!
        let native = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        defer { pane.dispose(); gtk_window_destroy(native) }
        gtk_window_set_default_size(native, 640, 320)
        gtk_window_set_child(native, pane.widget)
        gtk_window_present(native)
        _ = gtk_widget_grab_focus(pane.widget)
        XCTAssertTrue(pump { pane.text.contains("READY") && gtk_window_is_active(native) != 0 })
        pane.feed("copy\n")
        var result: String?
        XCTAssertTrue(pump {
            guard let display = gdk_display_get_default(), let clipboard = gdk_display_get_clipboard(display) else { return false }
            // Read once the OSC has been received. A self-owned text clipboard
            // can be inspected via its content provider without desktop I/O.
            guard let provider = gdk_clipboard_get_content(clipboard) else { return false }
            var value = GValue()
            _ = g_value_init(&value, g_type_from_name("gchararray"))
            defer { g_value_unset(&value) }
            if gdk_content_provider_get_value(provider, &value, nil) != 0, let text = g_value_get_string(&value) {
                result = String(cString: text)
            }
            return result == marker
        })
        XCTAssertEqual(result, marker)
        let blocked = Data("unfocused-must-not-replace".utf8).base64EncodedString()
        let hiddenLaunch = try XCTUnwrap(LinuxTerminalLaunch(kind: "terminal_launch", workspaceID: "hidden",
            paneID: UUID(), generation: UUID(), executable: "/bin/sh",
            arguments: ["-c", "printf '\\033]52;c;\(blocked)\\007UNFOCUSED'; sleep 30"]))
        let hidden = try XCTUnwrap(TerminalPane(launch: hiddenLaunch))
        defer { hidden.dispose() }
        XCTAssertTrue(pump { hidden.text.contains("UNFOCUSED") })
        let display = try XCTUnwrap(gdk_display_get_default())
        let clipboard = try XCTUnwrap(gdk_display_get_clipboard(display))
        let provider = try XCTUnwrap(gdk_clipboard_get_content(clipboard))
        var value = GValue()
        _ = g_value_init(&value, g_type_from_name("gchararray"))
        defer { g_value_unset(&value) }
        XCTAssertNotEqual(gdk_content_provider_get_value(provider, &value, nil), 0)
        XCTAssertEqual(g_value_get_string(&value).map { String(cString: $0) }, marker)
    }
}
