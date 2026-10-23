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
// GtkIMContextSimple's Unicode composition exercises preedit followed by a
// commit on Return, which must insert the composed text rather than Enter.
nativeKeys.press(["Control_L", "Shift_L", "u"], in: nativeWindow)
pump()
for name in ["0", "3", "b", "b", "Return"] { nativeKeys.press([name], in: nativeWindow); pump() }
precondition(writes == Data("λ".utf8), "Unicode IM composition must commit text exactly once")
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
var reviewFailures = 0
func reviewCheck(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); reviewFailures += 1 }
}
writes.removeAll()
view.key(keyval: UInt32(GDK_KEY_KP_Left), keycode: 83, modifiers: GdkModifierType(rawValue: 0), pressed: true)
reviewCheck(writes == Data("\u{1b}OD".utf8), "keypad navigation retains application-cursor semantics")
writes.removeAll()
// Native mode 1035 defaults to ignoring application keypad mode. Disable it
// before requesting DECKPAM, exactly as an application requiring it must do.
try view.receive(Data("\u{1b}[?1035l\u{1b}=".utf8))
view.key(keyval: UInt32(GDK_KEY_KP_Enter), keycode: 104, modifiers: GdkModifierType(rawValue: 0), pressed: true)
reviewCheck(writes == Data("\u{1b}OM".utf8), "keypad Enter retains application-keypad semantics")
try view.receive(Data((0..<(Int(view.grid.rows) + 5)).map { "ROW\($0)\r\n" }.joined().utf8))
func topRow() throws -> String { try view.engine.snapshot().cells[0].map(\.text).joined() }
let liveTop = try topRow()
try view.engine.scroll(lines: -5)
reviewCheck(try topRow() != liveTop, "fixture moved away from live prompt")
view.key(keyval: UInt32(GDK_KEY_a), keycode: 38, modifiers: GdkModifierType(rawValue: 0), pressed: true)
reviewCheck(try topRow() == liveTop, "typing returns viewport to live prompt")
try view.engine.scroll(lines: -5)
try view.paste("hello")
reviewCheck(try topRow() == liveTop, "paste returns viewport to live prompt")
view.dispose()
view.dispose()
gtk_window_destroy(nativeWindow)
setenv("DEVSPACE_GHOSTTY_ALLOW_SOFTWARE_GL", "1", 1)
let failureView = try GhosttyTerminalView()
let failureWindow = gtk_window_new()!
let failureNative = UnsafeMutableRawPointer(failureWindow).assumingMemoryBound(to: GtkWindow.self)
gtk_window_set_default_size(failureNative, 320, 180)
gtk_window_set_child(failureNative, failureView.widget)
gtk_window_present(failureNative)
pump()
let stack = gtk_overlay_get_child(OpaquePointer(failureView.widget))!
let glWidget = gtk_stack_get_child_by_name(OpaquePointer(stack), "gpu")!
let glArea = UnsafeMutableRawPointer(glWidget).assumingMemoryBound(to: GtkGLArea.self)
let syntheticError = g_error_new_literal(g_quark_from_static_string("devspace-test"), 1, "synthetic GL failure")!
gtk_gl_area_set_error(glArea, syntheticError)
g_error_free(syntheticError)
failureView.refresh()
pump()
reviewCheck(failureView.renderPath == "raster", "GL context errors must fall back even when GTK suppresses render")
failureView.dispose()
gtk_window_destroy(failureNative)
if reviewFailures > 0 { exit(1) }
print("Ghostty GTK raster, actual GTK keys/IM commit, paste, pointer selection, resize and disposal passed")
