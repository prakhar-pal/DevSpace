import Foundation
import XCTest
import CGTK
@testable import DevSpaceLinuxApp

final class AccessibilityBusTests: XCTestCase {
    func testPrivateATSPIBusCanReadTerminalTextAndCaret() throws {
        guard ProcessInfo.processInfo.environment["DEVSPACE_PRIVATE_ATSPI_TEST"] == "1",
              ProcessInfo.processInfo.environment["DEVSPACE_PRIVATE_KEY_TEST"] == "1" else {
            throw XCTSkip("requires explicitly isolated accessibility bus and display")
        }
        gtk_init()
        let view = try GhosttyTerminalView(forceRaster: true)
        let window = gtk_window_new()!
        let native = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        defer { view.dispose(); gtk_window_destroy(native) }
        gtk_window_set_default_size(native, 640, 320)
        gtk_window_set_child(native, view.widget)
        gtk_window_present(native)
        XCTAssertTrue(pump { gtk_widget_get_width(view.widget) > 0 && gtk_widget_get_mapped(view.widget) != 0 })
        try view.receive(Data("界e\u{301}".utf8))
        view.refresh()

        func call(_ transport: [String], _ destination: String, _ path: String,
                  _ method: String, _ arguments: [String] = []) throws -> OpaquePointer {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gdbus")
            process.arguments = ["call"] + transport + ["--dest", destination, "--object-path", path, "--method", method] + arguments
            process.standardOutput = output; process.standardError = errors
            try process.run()
            guard pump(until: { !process.isRunning }, timeout: 10) else {
                process.terminate()
                throw NSError(domain: "private AT-SPI query timed out", code: 1)
            }
            guard process.terminationStatus == 0 else {
                throw NSError(domain: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), code: 1)
            }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            var error: UnsafeMutablePointer<GError>?
            let variant = text.withCString { g_variant_parse(nil, $0, nil, nil, &error) }
            if let error { g_error_free(error) }
            return try XCTUnwrap(variant)
        }
        func string(_ value: OpaquePointer, _ index: Int) -> String {
            let child = g_variant_get_child_value(value, UInt(index))!
            defer { g_variant_unref(child) }
            return String(cString: g_variant_get_string(child, nil))
        }
        let addressReply = try call(["--session"], "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus.GetAddress")
        defer { g_variant_unref(addressReply) }
        let transport = ["--address", string(addressReply, 0)]
        var queue = [("org.a11y.atspi.Registry", "/org/a11y/atspi/accessible/root")]
        var terminal: (String, String)?
        var visited = Set<String>()
        while !queue.isEmpty && visited.count < 64 {
            let node = queue.removeFirst()
            guard visited.insert(node.0 + node.1).inserted else { continue }
            let role = try call(transport, node.0, node.1, "org.a11y.atspi.Accessible.GetRoleName")
            let name = string(role, 0)
            g_variant_unref(role)
            if name == "terminal" { terminal = node; break }
            let reply = try call(transport, node.0, node.1, "org.a11y.atspi.Accessible.GetChildren")
            let children = g_variant_get_child_value(reply, 0)!
            for index in 0..<g_variant_n_children(children) {
                let child = g_variant_get_child_value(children, index)!
                queue.append((string(child, 0), string(child, 1)))
                g_variant_unref(child)
            }
            g_variant_unref(children); g_variant_unref(reply)
        }
        let target = try XCTUnwrap(terminal, "private AT-SPI tree must expose the terminal role")
        let contents = try call(transport, target.0, target.1, "org.a11y.atspi.Text.GetText", ["0", "1"])
        defer { g_variant_unref(contents) }
        XCTAssertEqual(string(contents, 0), "界")
        let caret = try call(transport, target.0, target.1, "org.freedesktop.DBus.Properties.Get",
                             ["org.a11y.atspi.Text", "CaretOffset"])
        let wrapped = g_variant_get_child_value(caret, 0)!
        let position = g_variant_get_variant(wrapped)!
        XCTAssertEqual(g_variant_get_int32(position), 3)
        g_variant_unref(position); g_variant_unref(wrapped); g_variant_unref(caret)
        try view.engine.select(startColumn: 0, startRow: 0, endColumn: 1, endRow: 0)
        try view.receive(Data())
        view.refresh()
        let selection = try call(transport, target.0, target.1, "org.a11y.atspi.Text.GetSelection", ["0"])
        let start = g_variant_get_child_value(selection, 0)!, end = g_variant_get_child_value(selection, 1)!
        XCTAssertEqual(g_variant_get_int32(start), 0)
        XCTAssertEqual(g_variant_get_int32(end), 1)
        g_variant_unref(start); g_variant_unref(end); g_variant_unref(selection)
    }

    private func pump(until ready: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !ready() && Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            usleep(1_000)
        }
        return ready()
    }
}
