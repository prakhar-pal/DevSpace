import Foundation
import XCTest
import CGTK
@testable import DevSpaceLinuxApp

final class TerminalPaneTests: XCTestCase {
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
