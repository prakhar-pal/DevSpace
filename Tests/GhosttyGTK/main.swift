import Foundation
import CGTK
import CGhosttyVT
import DevSpaceGhosttyVT

gtk_init()
let useGL = ProcessInfo.processInfo.environment["DEVSPACE_GHOSTTY_TEST_OPENGL"] == "1"
let view = try GhosttyTerminalView(forceRaster: !useGL)
let window = gtk_window_new()!
let nativeWindow = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
gtk_window_set_default_size(nativeWindow, 640, 320)
gtk_window_set_child(nativeWindow, view.widget)
gtk_window_present(nativeWindow)
_ = gtk_widget_grab_focus(view.widget)
func pump() { for _ in 0..<40 { while g_main_context_iteration(nil, 0) != 0 {} ; usleep(1_000) } }
pump()
var writes = Data()
view.onWrite = { writes.append($0) }
let nativeKeys = try NativeKeyInput()
nativeKeys.press(["a"], in: nativeWindow)
pump()
precondition(writes == Data("a".utf8), "real GTK key/IM commit must be delivered once")
writes.removeAll()
nativeKeys.press(["Control_L", "c"], in: nativeWindow)
pump()
precondition(writes == Data([3]), "control key must retain terminal semantics")
writes.removeAll()
try view.receive(Data("hello\u{1b}[?1h".utf8))
view.refresh()
pump()
precondition(view.text.contains("hello"))
precondition(gtk_test_accessible_has_property(OpaquePointer(view.widget), GTK_ACCESSIBLE_PROPERTY_LABEL) != 0,
    "terminal must have an accessible label")
precondition(gtk_test_accessible_has_property(OpaquePointer(view.widget), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION) != 0,
    "visible terminal text must be exposed to accessibility")
precondition(view.renderPath == (useGL ? "opengl" : "raster"))
view.key(keyval: UInt32(GDK_KEY_Up), keycode: 111, modifiers: GdkModifierType(rawValue: 0), pressed: true)
precondition(writes == Data("\u{1b}OA".utf8), "application cursor encoding")
writes.removeAll()
try view.receive(Data("\u{1b}[?2004h".utf8))
try view.paste("hello")
precondition(writes == Data("\u{1b}[200~hello\u{1b}[201~".utf8), "native bracketed paste")
try view.engine.select(startColumn: 0, startRow: 0, endColumn: 4, endRow: 0)
let selected = try view.engine.selectedText()
precondition(selected == "hello")
let initialGrid = view.grid
gtk_window_set_default_size(nativeWindow, 800, 400)
pump()
view.refresh()
precondition(view.grid.columns > initialGrid.columns && view.grid.rows > initialGrid.rows,
    "resize follows actual metrics")
let cellWidth = Double(gtk_widget_get_width(view.widget)) / Double(view.grid.columns)
view.pointer(x: cellWidth * 0.5, y: 4, pressed: true, modifiers: GdkModifierType(rawValue: 0))
view.pointer(x: cellWidth * 4.5, y: 4, pressed: false, modifiers: GdkModifierType(rawValue: 0))
let dragged = try view.engine.selectedText()
precondition(dragged == "hello", "pointer drag selects terminal cells")
view.pointer(x: cellWidth * 2, y: 4, pressed: true, modifiers: GdkModifierType(rawValue: 0), clicks: 2)
let word = try view.engine.selectedText()
precondition(word == "hello", "double click uses native word boundaries")
writes.removeAll()
try view.receive(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
view.scroll(delta: -1, modifiers: GdkModifierType(rawValue: 0))
precondition(String(decoding: writes, as: UTF8.self).contains("\u{1b}[<64;"), "TUI wheel events must reach the PTY")
view.dispose()
view.dispose()
gtk_window_destroy(nativeWindow)
print("Ghostty GTK raster, actual GTK keys/IM commit, paste, pointer selection, resize and disposal passed")
