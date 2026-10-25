import Foundation
import Glibc
import CGTK

/// XTEST input on an explicitly private Xvfb display, never the user's desktop.
final class NativeKeyInput {
    private let x11: UnsafeMutableRawPointer
    private let xtst: UnsafeMutableRawPointer
    private let gtk: UnsafeMutableRawPointer
    private let display: UnsafeMutableRawPointer

    init() throws {
        guard ProcessInfo.processInfo.environment["DEVSPACE_PRIVATE_KEY_TEST"] == "1",
              let x11 = dlopen("libX11.so.6", RTLD_NOW),
              let xtst = dlopen("libXtst.so.6", RTLD_NOW),
              let gtk = dlopen("libgtk-4.so.1", RTLD_NOW),
              let open = dlsym(x11, "XOpenDisplay"),
              let display = unsafeBitCast(open, to: (@convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?).self)(nil)
        else { throw NativeKeyError.unavailable }
        self.x11 = x11; self.xtst = xtst; self.gtk = gtk; self.display = display
    }

    deinit {
        let close = unsafeBitCast(dlsym(x11, "XCloseDisplay")!, to: (@convention(c) (UnsafeMutableRawPointer) -> Int32).self)
        _ = close(display)
        dlclose(gtk); dlclose(xtst); dlclose(x11)
    }

    func press(_ names: [String], in window: UnsafeMutablePointer<GtkWindow>) {
        let xid = unsafeBitCast(dlsym(gtk, "gdk_x11_surface_get_xid")!,
            to: (@convention(c) (UnsafeMutableRawPointer) -> UInt).self)
        let focus = unsafeBitCast(dlsym(x11, "XSetInputFocus")!,
            to: (@convention(c) (UnsafeMutableRawPointer, UInt, Int32, UInt) -> Int32).self)
        let code = unsafeBitCast(dlsym(x11, "XKeysymToKeycode")!,
            to: (@convention(c) (UnsafeMutableRawPointer, UInt) -> UInt8).self)
        let event = unsafeBitCast(dlsym(xtst, "XTestFakeKeyEvent")!,
            to: (@convention(c) (UnsafeMutableRawPointer, UInt32, Int32, UInt) -> Int32).self)
        let sync = unsafeBitCast(dlsym(x11, "XSync")!,
            to: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Int32).self)
        _ = focus(display, xid(UnsafeMutableRawPointer(gtk_native_get_surface(OpaquePointer(window))!)), 2, 0)
        let codes = names.map { UInt32(code(display, UInt(gdk_keyval_from_name($0)))) }
        for key in codes { _ = event(display, key, 1, 0) }
        for key in codes.reversed() { _ = event(display, key, 0, 0) }
        _ = sync(display, 0)
    }
}

private enum NativeKeyError: Error { case unavailable }
