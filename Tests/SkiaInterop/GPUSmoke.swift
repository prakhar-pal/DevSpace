import CSkia
import CGTK
import CGPU
import Foundation

@main
struct GPUSmoke {
    private static var loop: OpaquePointer!
    private static var window: UnsafeMutablePointer<GtkWidget>!
    private static var currentArea: UnsafeMutablePointer<GtkGLArea>!
    private static var frames = 0
    private static var initialWidth: Int32 = 0
    private static var observedResize = false
    private static var completedWindows = 0
    private static var idleQueued = false

    static func main() {
        gtk_init()
        loop = g_main_loop_new(nil, 0)
        makeWindow()
        _ = g_timeout_add(20_000, { _ in
            fputs("GPU acceptance timed out before rendering and resize completed\n", stderr)
            exit(1)
        }, nil)
        g_main_loop_run(loop)
        gtk_window_destroy(UnsafeMutableRawPointer(window!).assumingMemoryBound(to: GtkWindow.self))
        g_main_loop_unref(loop)
        print("Skia GTK GPU pixels, resize, widget recreation and context disposal passed")
    }

    private static func makeWindow() {
        frames = 0
        initialWidth = 0
        observedResize = false
        window = gtk_window_new()
        let nativeWindow = UnsafeMutableRawPointer(window!).assumingMemoryBound(to: GtkWindow.self)
        gtk_window_set_title(nativeWindow, "DevSpaceDev — Skia renderer acceptance")
        gtk_window_set_default_size(nativeWindow, 320, 180)
        let area = gtk_gl_area_new()!
        let glArea = UnsafeMutableRawPointer(area).assumingMemoryBound(to: GtkGLArea.self)
        currentArea = glArea
        gtk_gl_area_set_required_version(glArea, 3, 3)
        gtk_gl_area_set_allowed_apis(glArea, GDK_GL_API_GL)
        gtk_window_set_child(nativeWindow, area)
        let callback: @convention(c) (UnsafeMutablePointer<GtkGLArea>?, OpaquePointer?, UnsafeMutableRawPointer?) -> gboolean = { area, _, _ in
            guard let area else { return 0 }
            GPUSmoke.render(area)
            return 1
        }
        _ = g_signal_connect_data(UnsafeMutableRawPointer(area), "render",
            unsafeBitCast(callback, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
        gtk_window_present(nativeWindow)
    }

    private static func render(_ area: UnsafeMutablePointer<GtkGLArea>) {
        guard gtk_gl_area_get_error(area) == nil else { fatalError("GTK could not create an OpenGL context") }
        guard let rawRenderer = glGetString(GLenum(GL_RENDERER)) else { fatalError("No GL renderer") }
        let renderer = String(cString: rawRenderer)
        if frames == 0 {
            print("OpenGL renderer: \(renderer)")
            if ProcessInfo.processInfo.environment["DEVSPACE_REQUIRE_HARDWARE"] == "1" {
                let name = renderer.lowercased()
                if ["llvmpipe", "softpipe", "swrast", "software", "lavapipe", "swiftshader"].contains(where: name.contains) {
                    fputs("Hardware acceptance unavailable: the host provides software OpenGL\n", stderr)
                    exit(77)
                }
            }
        }
        let widget = UnsafeMutableRawPointer(area).assumingMemoryBound(to: GtkWidget.self)
        let scale = gtk_widget_get_scale_factor(widget)
        let width = gtk_widget_get_width(widget) * scale
        let height = gtk_widget_get_height(widget) * scale
        if initialWidth == 0 { initialWidth = width }
        if width != initialWidth { observedResize = true }
        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &framebuffer)
        var info = GrGLFramebufferInfo()
        info.fFBOID = GLuint(framebuffer)
        info.fFormat = GLenum(GL_RGBA8)
        let target = GrBackendRenderTargets.MakeGL(width, height, 0, 0, info)
        var contextOwner = GrDirectContexts.MakeGL()
        guard let context = contextOwner.get() else { fatalError("Skia could not create a GL context") }
        guard let recordingContext = devspaceSkiaRecordingContext(context) else {
            fatalError("Missing recording context")
        }
        var surfaceOwner = SkSurfaces.WrapBackendRenderTarget(recordingContext, target,
            kBottomLeft_GrSurfaceOrigin, kRGBA_8888_SkColorType, SkiaColorSpace(), nil, nil, nil)
        guard let surface = surfaceOwner.get(), let canvas = surface.getCanvas() else {
            fatalError("Skia could not wrap the GTK framebuffer")
        }
        withExtendedLifetime((surfaceOwner, contextOwner)) {
            drawAcceptanceSample(on: canvas)
            _ = context.flushAndSubmit()
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes {
                glReadPixels(0, 0, 1, 1, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), $0.baseAddress)
            }
            precondition(pixel == [0x10, 0x20, 0x30, 0xff], "GPU framebuffer clear did not match raster colors")
            pixel.withUnsafeMutableBytes {
                glReadPixels(3, height - 5, 1, 1, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), $0.baseAddress)
            }
            precondition(pixel == [0xab, 0xcd, 0xef, 0xff], "GPU rectangle did not match raster colors")
        }
        surfaceOwner.reset()
        contextOwner.reset()
        frames += 1
        // Queue the next render after this frame has finished. Invalidating a
        // widget from inside its own render callback can lose the request.
        // Use current state rather than a pointer to a potentially destroyed widget.
        guard !idleQueued else { return }
        idleQueued = true
        _ = g_idle_add({ _ in
            GPUSmoke.nextFrame()
            return 0
        }, nil)
    }

    private static func nextFrame() {
        idleQueued = false
        let nativeWindow = UnsafeMutableRawPointer(window!).assumingMemoryBound(to: GtkWindow.self)
        if frames >= 3 && observedResize {
            completedWindows += 1
            if completedWindows == 2 { g_main_loop_quit(loop); return }
            gtk_window_destroy(nativeWindow)
            makeWindow()
            return
        }
        gtk_window_set_default_size(nativeWindow, 480, 240)
        gtk_gl_area_queue_render(currentArea)
    }
}
