import Foundation
import CGTK

@main
struct InputMethodAcceptance {
    static func main() throws {
        gtk_init()
        let view = try GhosttyTerminalView(forceRaster: true)
        let window = gtk_window_new()!
        let native = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        gtk_window_set_default_size(native, 640, 320)
        gtk_window_set_child(native, view.widget)
        gtk_window_present(native)
        _ = gtk_widget_grab_focus(view.widget)
        defer { view.dispose(); gtk_window_destroy(native) }
        func pump() {
            for _ in 0..<100 { while g_main_context_iteration(nil, 0) != 0 {}; usleep(1_000) }
        }
        pump()
        var writes = Data()
        view.onWrite = { writes.append($0) }
        let keys = try NativeKeyInput()
        func check(_ sequence: [[String]], _ expected: String) {
            writes.removeAll()
            for chord in sequence { keys.press(chord, in: native); pump() }
            precondition(writes == Data(expected.utf8),
                "private keyboard fixture: \(sequence), expected \(Array(expected.utf8)), received \(Array(writes))")
        }
        // German XKB differs from US for shifted punctuation, AltGr and dead keys.
        check([["z"]], "z")
        check([["Shift_L", "7"]], "/")
        check([["ISO_Level3_Shift", "q"]], "@")
        check([["dead_acute"], ["e"]], "é")
        print("German XKB layout, shifted punctuation, AltGr and dead-key composition passed")
    }
}
