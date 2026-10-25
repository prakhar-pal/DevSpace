import Foundation
import Glibc
import CGTK
import CGPU

/// Actual desktop acceptance without synthetic input or clipboard access.
@main struct HardwareGPUAcceptance {
    static func main() throws {
        precondition(ProcessInfo.processInfo.environment["DEVSPACE_REQUIRE_HARDWARE"] == "1")
        gtk_init()
        for _ in 0..<2 {
            let view = try GhosttyTerminalView()
            let widget = gtk_window_new()!
            let window = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWindow.self)
            gtk_window_set_title(window, "DevSpaceDev — terminal hardware GPU acceptance")
            gtk_window_set_default_size(window, 640, 320)
            gtk_window_set_child(window, view.widget)
            gtk_window_present(window)
            defer { view.dispose(); gtk_window_destroy(window) }
            try view.receive(Data("\u{1b}[48;2;171;205;239m  \u{1b}[0m\r\nSwift بب 中 👩‍💻".utf8))
            func pump(until ready: () -> Bool) {
                let deadline = Date().addingTimeInterval(10)
                while !ready() && Date() < deadline {
                    while g_main_context_iteration(nil, 0) != 0 {}
                    view.refresh()
                    usleep(1_000)
                }
                precondition(ready(), "actual terminal widget must use OpenGL, including after resize")
            }
            pump { view.renderPath == "opengl" }
            let initialGrid = view.grid
            gtk_window_set_default_size(window, 800, 400)
            pump {
                view.grid.columns > initialGrid.columns && view.grid.rows > initialGrid.rows
                    && (try? view.engine.snapshot().dirty) == false
            }
            let overlay = gtk_widget_get_first_child(view.widget)!
            let stack = gtk_overlay_get_child(OpaquePointer(overlay))!
            let area = gtk_stack_get_child_by_name(OpaquePointer(stack), "gpu")!
            gtk_gl_area_make_current(UnsafeMutableRawPointer(area).assumingMemoryBound(to: GtkGLArea.self))
            guard let raw = glGetString(GLenum(GL_RENDERER)) else { fatalError("missing hardware GL renderer") }
            let driver = String(cString: raw)
            precondition(!["llvmpipe", "softpipe", "swrast", "software", "lavapipe", "swiftshader"].contains {
                driver.lowercased().contains($0)
            }, "software renderer does not satisfy hardware acceptance")
            precondition(glGetError() == GLenum(GL_NO_ERROR), "terminal GL operations must not report errors")
            print("Actual terminal widget: OpenGL; renderer: \(driver); resized grid: \(view.grid)")
        }
        print("Actual Ghostty/Skia GTK hardware path, resize and widget recreation passed")
    }
}
