#if DEVSPACE_GHOSTTY
import Foundation
import CGTK
import CGPU
import CSkia
import CGhosttyVT
import DevSpaceGhosttyVT
import DevSpaceSkiaRenderer

/// GTK owns presentation and input only. The portable engine and renderer own
/// terminal state and drawing; TerminalPane continues to own the Swift PTY.
final class GhosttyTerminalView {
    let widget: UnsafeMutablePointer<GtkWidget>
    let engine: GhosttyTerminalEngine
    private let renderer: SkiaTerminalRenderer
    private let area: UnsafeMutablePointer<GtkGLArea>
    private let picture: OpaquePointer
    private let stack: OpaquePointer
    private let preeditLabel: UnsafeMutablePointer<GtkWidget>
    private let im: UnsafeMutablePointer<GtkIMContext>
    private var connections: [(UnsafeMutableRawPointer, gulong)] = []
    private var closed = false
    private var dirty = true
    private var rasterRequested: Bool
    private var lastPaint: TimeInterval = 0
    private var lastBlink = true
    private var selectionStart: (UInt16, UInt16)?
    private var pointerPosition: (Double, Double) = (0, 0)
    private var scrollRemainder: Double = 0
    private var pendingKey: (UInt32, UInt32, GdkModifierType)?
    private var composingKey = false
    private var accessibleText: String?
    private(set) var renderPath = "pending"
    private(set) var grid: (columns: UInt16, rows: UInt16) = (80, 24)
    private(set) var currentDirectory: String?
    var onWrite: (Data) -> Void = { _ in }
    var onEvent: (GhosttyTerminalEvent) -> Void = { _ in }
    var onFocus: () -> Void = {}

    init(forceRaster: Bool = false) throws {
        engine = try GhosttyTerminalEngine()
        let owner = SkFontMgr_New_FontConfig(nil, SkFontScanner_Make_FreeType())
        guard let manager = owner.get() else { throw SkiaTerminalRendererError.fontUnavailable }
        renderer = try withExtendedLifetime(owner) { try SkiaTerminalRenderer(fontManager: manager) }
        widget = gtk_overlay_new()!
        _ = g_object_ref_sink(UnsafeMutableRawPointer(widget))
        gtk_widget_set_focusable(widget, 1)
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_vexpand(widget, 1)
        let gl = gtk_gl_area_new()!
        area = UnsafeMutableRawPointer(gl).assumingMemoryBound(to: GtkGLArea.self)
        gtk_gl_area_set_required_version(area, 3, 3)
        gtk_gl_area_set_allowed_apis(area, GDK_GL_API_GL)
        let raster = gtk_picture_new()!
        picture = OpaquePointer(raster)
        gtk_picture_set_can_shrink(picture, 1)
        gtk_picture_set_content_fit(picture, GTK_CONTENT_FIT_FILL)
        let stackWidget = gtk_stack_new()!
        stack = OpaquePointer(stackWidget)
        gtk_overlay_set_child(OpaquePointer(widget), stackWidget)
        gtk_stack_add_named(stack, gl, "gpu")
        gtk_stack_add_named(stack, raster, "raster")
        preeditLabel = gtk_label_new("")!
        gtk_widget_set_halign(preeditLabel, GTK_ALIGN_START)
        gtk_widget_set_valign(preeditLabel, GTK_ALIGN_START)
        gtk_widget_add_css_class(preeditLabel, "osd")
        gtk_widget_set_visible(preeditLabel, 0)
        gtk_overlay_add_overlay(OpaquePointer(widget), preeditLabel)
        rasterRequested = forceRaster
        im = gtk_im_multicontext_new()!
        gtk_im_context_set_client_widget(im, widget)
        connectInput()
        let callback: @convention(c) (UnsafeMutablePointer<GtkGLArea>?, OpaquePointer?, UnsafeMutableRawPointer?) -> gboolean = { _, _, data in
            guard let data else { return 0 }
            Unmanaged<GhosttyTerminalView>.fromOpaque(data).takeUnretainedValue().renderGPU()
            return 1
        }
        connect(UnsafeMutableRawPointer(gl), "render", unsafeBitCast(callback, to: GCallback.self))
    }

    deinit { dispose() }
    var text: String { (try? engine.text()) ?? "" }

    func receive(_ data: Data) throws { deliver(try engine.receive(data)); dirty = true }
    func finish(_ code: Int32) throws { deliver(try engine.finish(exitCode: code)); dirty = true }
    func paste(_ text: String) throws {
        let events = try engine.paste(text)
        try engine.scrollToBottom()
        try engine.clearSelection()
        deliver(events)
        dirty = true
    }

    func sendText(_ text: String) { writeUserInput(Data(text.utf8)) }

    private func writeUserInput(_ bytes: Data) {
        guard !closed, !bytes.isEmpty else { return }
        try? engine.scrollToBottom()
        try? engine.clearSelection()
        dirty = true
        onWrite(bytes)
    }

    func applyTheme() {
        guard !closed else { return }
        var foreground = GdkRGBA()
        gtk_widget_get_color(widget, &foreground)
        let dark = foreground.red + foreground.green + foreground.blue > 1.5
        let background = GdkRGBA(red: dark ? 0.07 : 1, green: dark ? 0.08 : 1,
            blue: dark ? 0.08 : 1, alpha: 1)
        func color(_ value: GdkRGBA) -> UInt32 {
            0xff000000 | UInt32(max(0, min(255, value.red * 255))) << 16
                | UInt32(max(0, min(255, value.green * 255))) << 8
                | UInt32(max(0, min(255, value.blue * 255)))
        }
        try? engine.configureColors(foreground: color(foreground), background: color(background))
        dirty = true
    }

    private func deliver(_ events: [GhosttyTerminalEvent]) {
        for event in events {
            switch event {
            case .writePTY(let bytes): onWrite(bytes)
            case .directory(let directory): currentDirectory = directory; onEvent(event)
            default: onEvent(event)
            }
        }
    }

    func refresh() {
        guard !closed, gtk_widget_get_mapped(widget) != 0 else { return }
        let glWidget = UnsafeMutableRawPointer(area).assumingMemoryBound(to: GtkWidget.self)
        if !rasterRequested, gtk_widget_get_realized(glWidget) != 0,
           gtk_gl_area_get_error(area) != nil || gtk_gl_area_get_context(area) == nil {
            // GTK suppresses its render signal when context creation fails.
            // This check must run independently of renderGPU().
            rasterRequested = true
            dirty = true
        }
        do {
            let scale = Float(gtk_widget_get_scale_factor(widget))
            let metrics = try renderer.metrics(scale: scale)
            let width = Int(gtk_widget_get_width(widget)) * Int(scale)
            let height = Int(gtk_widget_get_height(widget)) * Int(scale)
            guard width > 0, height > 0 else { return }
            let columns = UInt16(clamping: max(1, width / metrics.cellWidth))
            let rows = UInt16(clamping: max(1, height / metrics.cellHeight))
            if grid != (columns, rows) {
                deliver(try engine.resize(columns: columns, rows: rows,
                    cellWidth: UInt32(metrics.cellWidth), cellHeight: UInt32(metrics.cellHeight)))
                grid = (columns, rows)
                dirty = true
            }
            let now = ProcessInfo.processInfo.systemUptime
            let blink = Int(now * 2) % 2 == 0
            guard dirty || blink != lastBlink || now - lastPaint >= 1 else { return }
            lastBlink = blink
            lastPaint = now
            if rasterRequested {
                if renderPath != "raster" {
                    renderPath = "raster"
                    gtk_stack_set_visible_child_name(stack, "raster")
                    fputs("DevSpaceDev: terminal uses Skia raster fallback\n", stderr)
                }
                let frame = try engine.snapshot()
                updateAccessibility(frame)
                positionPreedit(frame)
                let image = try renderer.rasterize(frame, width: width, height: height, scale: scale,
                    focused: gtk_widget_has_focus(widget) != 0, blinkVisible: blink)
                let bytes = image.bytes.withUnsafeBytes { g_bytes_new($0.baseAddress, UInt($0.count))! }
                defer { g_bytes_unref(bytes) }
                if let texture = gdk_memory_texture_new(Int32(width), Int32(height),
                    GDK_MEMORY_R8G8B8A8_PREMULTIPLIED, bytes, UInt(width * 4)) {
                    gtk_picture_set_paintable(picture, texture)
                    g_object_unref(UnsafeMutableRawPointer(texture))
                    try engine.acknowledgeFrame(revision: frame.revision)
                }
            } else { gtk_gl_area_queue_render(area) }
            dirty = false
        } catch { fputs("DevSpaceDev: terminal refresh failed: \(error)\n", stderr) }
    }

    private func renderGPU() {
        guard !closed else { return }
        guard gtk_gl_area_get_error(area) == nil, let raw = glGetString(GLenum(GL_RENDERER)) else {
            rasterRequested = true; dirty = true; return
        }
        let driver = String(cString: raw).lowercased()
        if ProcessInfo.processInfo.environment["DEVSPACE_GHOSTTY_ALLOW_SOFTWARE_GL"] != "1",
           ["llvmpipe", "softpipe", "swrast", "software", "lavapipe", "swiftshader"].contains(where: driver.contains) {
            rasterRequested = true; dirty = true; return
        }
        do {
            let scale = Float(gtk_widget_get_scale_factor(widget))
            let width = gtk_widget_get_width(widget) * Int32(scale)
            let height = gtk_widget_get_height(widget) * Int32(scale)
            guard width > 0, height > 0 else { return }
            var framebuffer: GLint = 0
            glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &framebuffer)
            var info = GrGLFramebufferInfo()
            info.fFBOID = GLuint(framebuffer)
            info.fFormat = GLenum(GL_RGBA8)
            let target = GrBackendRenderTargets.MakeGL(width, height, 0, 0, info)
            // ponytail: per-frame context keeps teardown correct initially;
            // retain per GLArea lifecycle if M05 profiling warrants it.
            let contextOwner = GrDirectContexts.MakeGL()
            guard let context = contextOwner.get(), let recording = devspaceSkiaRecordingContext(context) else {
                rasterRequested = true; dirty = true; return
            }
            let surfaceOwner = SkSurfaces.WrapBackendRenderTarget(recording, target,
                kBottomLeft_GrSurfaceOrigin, kRGBA_8888_SkColorType, SkiaColorSpace(), nil, nil, nil)
            guard let surface = surfaceOwner.get(), let canvas = surface.getCanvas() else {
                rasterRequested = true; dirty = true; return
            }
            try withExtendedLifetime((surfaceOwner, contextOwner)) {
                let frame = try engine.snapshot()
                updateAccessibility(frame)
                positionPreedit(frame)
                try renderer.draw(frame, on: canvas, scale: scale,
                    focused: gtk_widget_has_focus(widget) != 0, blinkVisible: lastBlink)
                _ = context.flushAndSubmit()
                try engine.acknowledgeFrame(revision: frame.revision)
                renderPath = "opengl"
            }
        } catch { rasterRequested = true; dirty = true }
    }

    func key(keyval: UInt32, keycode: UInt32, modifiers: GdkModifierType, pressed: Bool) {
        guard !closed else { return }
        let value = gdk_keyval_to_unicode(keyval)
        let text = Unicode.Scalar(value).flatMap { value >= 32 && value != 127 ? String($0) : nil }
        sendKey(keyval: keyval, modifiers: modifiers, text: pressed ? text : nil, pressed: pressed)
    }

    private func sendKey(keyval: UInt32, modifiers: GdkModifierType, text: String?, pressed: Bool) {
        do {
            let bytes = try engine.encodeKey(Self.nativeKey(keyval), mods: Self.mods(modifiers),
                action: pressed ? GHOSTTY_KEY_ACTION_PRESS : GHOSTTY_KEY_ACTION_RELEASE,
                utf8: text, unshifted: gdk_keyval_to_unicode(gdk_keyval_to_lower(keyval)))
            if pressed { writeUserInput(bytes) }
            else if !bytes.isEmpty { onWrite(bytes) }
        } catch { /* A retained pane after exit is read-only. */ }
    }

    private static func nativeKey(_ value: UInt32) -> GhosttyKey {
        let lower = gdk_keyval_to_lower(value)
        if lower >= 97 && lower <= 122 { return GhosttyKey(rawValue: GHOSTTY_KEY_A.rawValue + Int32(lower - 97)) }
        if lower >= 48 && lower <= 57 { return GhosttyKey(rawValue: GHOSTTY_KEY_DIGIT_0.rawValue + Int32(lower - 48)) }
        if value >= UInt32(GDK_KEY_KP_0) && value <= UInt32(GDK_KEY_KP_9) {
            return GhosttyKey(rawValue: GHOSTTY_KEY_NUMPAD_0.rawValue + Int32(value - UInt32(GDK_KEY_KP_0)))
        }
        if value >= UInt32(GDK_KEY_F1) && value <= UInt32(GDK_KEY_F25) {
            return GhosttyKey(rawValue: GHOSTTY_KEY_F1.rawValue + Int32(value - UInt32(GDK_KEY_F1)))
        }
        switch Int32(value) {
        case GDK_KEY_Return: return GHOSTTY_KEY_ENTER
        case GDK_KEY_KP_Enter: return GHOSTTY_KEY_NUMPAD_ENTER
        case GDK_KEY_KP_Up: return GHOSTTY_KEY_NUMPAD_UP
        case GDK_KEY_KP_Down: return GHOSTTY_KEY_NUMPAD_DOWN
        case GDK_KEY_KP_Left: return GHOSTTY_KEY_NUMPAD_LEFT
        case GDK_KEY_KP_Right: return GHOSTTY_KEY_NUMPAD_RIGHT
        case GDK_KEY_KP_Begin: return GHOSTTY_KEY_NUMPAD_BEGIN
        case GDK_KEY_KP_Home: return GHOSTTY_KEY_NUMPAD_HOME
        case GDK_KEY_KP_End: return GHOSTTY_KEY_NUMPAD_END
        case GDK_KEY_KP_Page_Up: return GHOSTTY_KEY_NUMPAD_PAGE_UP
        case GDK_KEY_KP_Page_Down: return GHOSTTY_KEY_NUMPAD_PAGE_DOWN
        case GDK_KEY_KP_Insert: return GHOSTTY_KEY_NUMPAD_INSERT
        case GDK_KEY_KP_Delete: return GHOSTTY_KEY_NUMPAD_DELETE
        case GDK_KEY_KP_Add: return GHOSTTY_KEY_NUMPAD_ADD
        case GDK_KEY_KP_Subtract: return GHOSTTY_KEY_NUMPAD_SUBTRACT
        case GDK_KEY_KP_Multiply: return GHOSTTY_KEY_NUMPAD_MULTIPLY
        case GDK_KEY_KP_Divide: return GHOSTTY_KEY_NUMPAD_DIVIDE
        case GDK_KEY_KP_Decimal: return GHOSTTY_KEY_NUMPAD_DECIMAL
        case GDK_KEY_KP_Separator: return GHOSTTY_KEY_NUMPAD_SEPARATOR
        case GDK_KEY_KP_Equal: return GHOSTTY_KEY_NUMPAD_EQUAL
        case GDK_KEY_KP_Space: return GHOSTTY_KEY_SPACE
        case GDK_KEY_KP_Tab: return GHOSTTY_KEY_TAB
        case GDK_KEY_KP_F1: return GHOSTTY_KEY_F1
        case GDK_KEY_KP_F2: return GHOSTTY_KEY_F2
        case GDK_KEY_KP_F3: return GHOSTTY_KEY_F3
        case GDK_KEY_KP_F4: return GHOSTTY_KEY_F4
        case GDK_KEY_BackSpace: return GHOSTTY_KEY_BACKSPACE
        case GDK_KEY_Tab, GDK_KEY_ISO_Left_Tab: return GHOSTTY_KEY_TAB
        case GDK_KEY_Escape: return GHOSTTY_KEY_ESCAPE
        case GDK_KEY_Up: return GHOSTTY_KEY_ARROW_UP
        case GDK_KEY_Down: return GHOSTTY_KEY_ARROW_DOWN
        case GDK_KEY_Left: return GHOSTTY_KEY_ARROW_LEFT
        case GDK_KEY_Right: return GHOSTTY_KEY_ARROW_RIGHT
        case GDK_KEY_Home: return GHOSTTY_KEY_HOME
        case GDK_KEY_End: return GHOSTTY_KEY_END
        case GDK_KEY_Page_Up: return GHOSTTY_KEY_PAGE_UP
        case GDK_KEY_Page_Down: return GHOSTTY_KEY_PAGE_DOWN
        case GDK_KEY_Insert: return GHOSTTY_KEY_INSERT
        case GDK_KEY_Delete: return GHOSTTY_KEY_DELETE
        case GDK_KEY_space: return GHOSTTY_KEY_SPACE
        case GDK_KEY_minus, GDK_KEY_underscore: return GHOSTTY_KEY_MINUS
        case GDK_KEY_equal, GDK_KEY_plus: return GHOSTTY_KEY_EQUAL
        case GDK_KEY_bracketleft, GDK_KEY_braceleft: return GHOSTTY_KEY_BRACKET_LEFT
        case GDK_KEY_bracketright, GDK_KEY_braceright: return GHOSTTY_KEY_BRACKET_RIGHT
        case GDK_KEY_backslash, GDK_KEY_bar: return GHOSTTY_KEY_BACKSLASH
        case GDK_KEY_semicolon, GDK_KEY_colon: return GHOSTTY_KEY_SEMICOLON
        case GDK_KEY_apostrophe, GDK_KEY_quotedbl: return GHOSTTY_KEY_QUOTE
        case GDK_KEY_comma, GDK_KEY_less: return GHOSTTY_KEY_COMMA
        case GDK_KEY_period, GDK_KEY_greater: return GHOSTTY_KEY_PERIOD
        case GDK_KEY_slash, GDK_KEY_question: return GHOSTTY_KEY_SLASH
        case GDK_KEY_grave, GDK_KEY_asciitilde: return GHOSTTY_KEY_BACKQUOTE
        default: return GHOSTTY_KEY_UNIDENTIFIED
        }
    }

    private static func mods(_ state: GdkModifierType) -> GhosttyMods {
        var result: GhosttyMods = 0
        for (mask, flag) in [(GDK_SHIFT_MASK, GHOSTTY_MODS_SHIFT), (GDK_CONTROL_MASK, GHOSTTY_MODS_CTRL),
                             (GDK_ALT_MASK, GHOSTTY_MODS_ALT), (GDK_SUPER_MASK, GHOSTTY_MODS_SUPER)] {
            if state.rawValue & mask.rawValue != 0 { result |= GhosttyMods(flag) }
        }
        return result
    }

    private func connectInput() {
        let mapped: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            guard let data else { return }
            Unmanaged<GhosttyTerminalView>.fromOpaque(data).takeUnretainedValue().applyTheme()
        }
        connect(UnsafeMutableRawPointer(widget), "map", unsafeBitCast(mapped, to: GCallback.self))
        if let settings = gtk_settings_get_default() {
            let changed: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
                guard let data else { return }
                Unmanaged<GhosttyTerminalView>.fromOpaque(data).takeUnretainedValue().applyTheme()
            }
            for name in ["notify::gtk-theme-name", "notify::gtk-application-prefer-dark-theme"] {
                connect(UnsafeMutableRawPointer(settings), name, unsafeBitCast(changed, to: GCallback.self))
            }
        }
        let controller = gtk_event_controller_key_new()!
        gtk_widget_add_controller(widget, controller)
        let pressed: @convention(c) (OpaquePointer?, UInt32, UInt32, GdkModifierType, UnsafeMutableRawPointer?) -> gboolean = { controller, value, code, mods, data in
            guard let data else { return 0 }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(data).takeUnretainedValue()
            view.pendingKey = (value, code, mods)
            view.composingKey = gtk_widget_get_visible(view.preeditLabel) != 0
            defer { view.pendingKey = nil }
            if let controller, let event = gtk_event_controller_get_current_event(controller),
               gtk_im_context_filter_keypress(view.im, event) != 0 { return 1 }
            view.key(keyval: value, keycode: code, modifiers: mods, pressed: true)
            return 1
        }
        connect(UnsafeMutableRawPointer(controller), "key-pressed", unsafeBitCast(pressed, to: GCallback.self))
        let released: @convention(c) (OpaquePointer?, UInt32, UInt32, GdkModifierType, UnsafeMutableRawPointer?) -> Void = { controller, value, code, mods, data in
            guard let data else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(data).takeUnretainedValue()
            if let controller, let event = gtk_event_controller_get_current_event(controller),
               gtk_im_context_filter_keypress(view.im, event) != 0 { return }
            view.key(keyval: value, keycode: code, modifiers: mods, pressed: false)
        }
        connect(UnsafeMutableRawPointer(controller), "key-released", unsafeBitCast(released, to: GCallback.self))
        let committed: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { _, text, data in
            guard let data, let text else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(data).takeUnretainedValue()
            if let key = view.pendingKey, !view.composingKey { view.sendKey(keyval: key.0, modifiers: key.2, text: String(cString: text), pressed: true) }
            else { view.writeUserInput(Data(String(cString: text).utf8)) }
        }
        connect(UnsafeMutableRawPointer(im), "commit", unsafeBitCast(committed, to: GCallback.self))
        let preedit: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            guard let data else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(data).takeUnretainedValue()
            var raw: UnsafeMutablePointer<CChar>?
            var attributes: OpaquePointer?
            var cursor: Int32 = 0
            gtk_im_context_get_preedit_string(view.im, &raw, &attributes, &cursor)
            defer { if let raw { g_free(raw) }; if let attributes { pango_attr_list_unref(attributes) } }
            let text = raw.map { String(cString: $0) } ?? ""
            text.withCString { gtk_label_set_text(OpaquePointer(view.preeditLabel), $0) }
            gtk_widget_set_visible(view.preeditLabel, text.isEmpty ? 0 : 1)
            view.positionPreedit()
        }
        connect(UnsafeMutableRawPointer(im), "preedit-changed", unsafeBitCast(preedit, to: GCallback.self))
        let focus = gtk_event_controller_focus_new()!
        gtk_widget_add_controller(widget, focus)
        let entered: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            guard let data else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(data).takeUnretainedValue()
            gtk_im_context_focus_in(view.im)
            if let bytes = try? view.engine.encodeFocus(true) { view.onWrite(bytes) }
            view.dirty = true; view.onFocus()
        }
        let left: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            guard let data else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(data).takeUnretainedValue()
            gtk_im_context_focus_out(view.im)
            view.selectionStart = nil
            if let bytes = try? view.engine.encodeFocus(false) { view.onWrite(bytes) }
            view.dirty = true
        }
        connect(UnsafeMutableRawPointer(focus), "enter", unsafeBitCast(entered, to: GCallback.self))
        connect(UnsafeMutableRawPointer(focus), "leave", unsafeBitCast(left, to: GCallback.self))
        connectPointer()
    }

    private func positionPreedit(_ suppliedFrame: GhosttyTerminalFrame? = nil) {
        let scale = Float(gtk_widget_get_scale_factor(widget))
        guard let frame = suppliedFrame ?? (try? engine.snapshot()), let cursor = frame.cursor,
              let metrics = try? renderer.metrics(scale: scale) else { return }
        let x = Int(Float(cursor.column * metrics.cellWidth) / scale)
        let y = Int(Float(cursor.row * metrics.cellHeight) / scale)
        gtk_widget_set_margin_start(preeditLabel, Int32(x))
        gtk_widget_set_margin_top(preeditLabel, Int32(y))
        var rectangle = GdkRectangle(x: Int32(x), y: Int32(y),
            width: Int32(Float(metrics.cellWidth) / scale), height: Int32(Float(metrics.cellHeight) / scale))
        gtk_im_context_set_cursor_location(im, &rectangle)
    }

    private func updateAccessibility(_ frame: GhosttyTerminalFrame) {
        let text = String(frame.cells.prefix(128).map { row in
            row.prefix(512).filter { $0.width > 0 }.map { $0.invisible || $0.text.isEmpty ? " " : $0.text }.joined()
        }.joined(separator: "\n").prefix(16_384))
        guard text != accessibleText else { return }
        accessibleText = text
        var properties = [GTK_ACCESSIBLE_PROPERTY_LABEL, GTK_ACCESSIBLE_PROPERTY_DESCRIPTION]
        var values = [GValue(), GValue()]
        gtk_accessible_property_init_value(properties[0], &values[0])
        gtk_accessible_property_init_value(properties[1], &values[1])
        defer { g_value_unset(&values[0]); g_value_unset(&values[1]) }
        "Terminal".withCString { g_value_set_string(&values[0], $0) }
        text.withCString { g_value_set_string(&values[1], $0) }
        properties.withUnsafeMutableBufferPointer { properties in
            values.withUnsafeBufferPointer { values in
                gtk_accessible_update_property_value(OpaquePointer(widget), 2, properties.baseAddress, values.baseAddress)
            }
        }
    }

    func pointer(x: Double, y: Double, pressed: Bool, modifiers: GdkModifierType,
                 button: UInt32 = 1, motion: Bool = false, clicks: Int = 1) {
        let scale = Float(gtk_widget_get_scale_factor(widget))
        guard !closed, x.isFinite, y.isFinite, let metrics = try? renderer.metrics(scale: scale) else { return }
        pointerPosition = (x, y)
        if pressed && !motion { _ = gtk_widget_grab_focus(widget) }
        let column = UInt16(max(0, min(Double(grid.columns - 1), x * Double(scale) / Double(metrics.cellWidth))))
        let row = UInt16(max(0, min(Double(grid.rows - 1), y * Double(scale) / Double(metrics.cellHeight))))
        if modifiers.rawValue & GDK_SHIFT_MASK.rawValue == 0, (try? engine.hasMouseTracking()) == true {
            let held = modifiers.rawValue & (GDK_BUTTON1_MASK.rawValue | GDK_BUTTON2_MASK.rawValue | GDK_BUTTON3_MASK.rawValue) != 0
            let effectiveButton = motion ? (modifiers.rawValue & GDK_BUTTON1_MASK.rawValue != 0 ? 1
                : (modifiers.rawValue & GDK_BUTTON2_MASK.rawValue != 0 ? 2 : 3)) : button
            let nativeButton: GhosttyMouseButton? = motion && !held ? nil
                : (effectiveButton == 1 ? GHOSTTY_MOUSE_BUTTON_LEFT : (effectiveButton == 2 ? GHOSTTY_MOUSE_BUTTON_MIDDLE : GHOSTTY_MOUSE_BUTTON_RIGHT))
            if let bytes = try? engine.encodeMouse(action: motion ? GHOSTTY_MOUSE_ACTION_MOTION : (pressed ? GHOSTTY_MOUSE_ACTION_PRESS : GHOSTTY_MOUSE_ACTION_RELEASE),
                button: nativeButton, x: x * Double(scale), y: y * Double(scale), cellWidth: UInt32(metrics.cellWidth), cellHeight: UInt32(metrics.cellHeight), mods: Self.mods(modifiers)) {
                onWrite(bytes)
            }
        } else if button == 1 {
            if pressed && !motion && clicks > 1 {
                if clicks == 2 { try? engine.selectWord(column: column, row: row) }
                else { try? engine.selectLine(column: column, row: row) }
                selectionStart = nil
                dirty = true
                return
            }
            if pressed && !motion { selectionStart = (column, row); try? engine.clearSelection() }
            if let start = selectionStart {
                try? engine.select(startColumn: start.0, startRow: start.1, endColumn: column, endRow: row,
                    rectangle: modifiers.rawValue & GDK_ALT_MASK.rawValue != 0)
                if !pressed && !motion { selectionStart = nil }
                dirty = true
            }
        }
    }

    func scroll(delta: Double, modifiers: GdkModifierType) {
        guard !closed, delta.isFinite else { return }
        scrollRemainder += max(-100, min(100, delta))
        let steps = Int(scrollRemainder)
        scrollRemainder -= Double(steps)
        guard steps != 0 else { return }
        if modifiers.rawValue & GDK_SHIFT_MASK.rawValue == 0, (try? engine.hasMouseTracking()) == true {
            let scale = Float(gtk_widget_get_scale_factor(widget))
            guard let metrics = try? renderer.metrics(scale: scale) else { return }
            for _ in 0..<abs(steps) {
                if let bytes = try? engine.encodeMouse(action: GHOSTTY_MOUSE_ACTION_PRESS,
                    button: steps < 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE,
                    x: pointerPosition.0 * Double(scale), y: pointerPosition.1 * Double(scale),
                    cellWidth: UInt32(metrics.cellWidth), cellHeight: UInt32(metrics.cellHeight), mods: Self.mods(modifiers)) {
                    onWrite(bytes)
                }
            }
        } else { try? engine.scroll(lines: steps * 3); dirty = true }
    }

    private func connectPointer() {
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(click, 0)
        gtk_widget_add_controller(widget, click)
        let pressed: @convention(c) (OpaquePointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void = { gesture, count, x, y, data in
            guard let data, let gesture else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(data).takeUnretainedValue()
            view.pointer(x: x, y: y, pressed: true, modifiers: gtk_event_controller_get_current_event_state(gesture),
                button: gtk_gesture_single_get_current_button(gesture), clicks: Int(count))
        }
        let released: @convention(c) (OpaquePointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void = { gesture, _, x, y, data in
            guard let data, let gesture else { return }
            Unmanaged<GhosttyTerminalView>.fromOpaque(data).takeUnretainedValue().pointer(x: x, y: y, pressed: false,
                modifiers: gtk_event_controller_get_current_event_state(gesture), button: gtk_gesture_single_get_current_button(gesture))
        }
        connect(UnsafeMutableRawPointer(click), "pressed", unsafeBitCast(pressed, to: GCallback.self))
        connect(UnsafeMutableRawPointer(click), "released", unsafeBitCast(released, to: GCallback.self))
        let motion = gtk_event_controller_motion_new()!
        gtk_widget_add_controller(widget, motion)
        let moved: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { controller, x, y, data in
            guard let data, let controller else { return }
            Unmanaged<GhosttyTerminalView>.fromOpaque(data).takeUnretainedValue().pointer(x: x, y: y, pressed: false,
                modifiers: gtk_event_controller_get_current_event_state(controller), motion: true)
        }
        connect(UnsafeMutableRawPointer(motion), "motion", unsafeBitCast(moved, to: GCallback.self))
        let scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL)!
        gtk_widget_add_controller(widget, scroll)
        let scrolled: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> gboolean = { controller, _, y, data in
            guard let data, let controller, y.isFinite else { return 0 }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(data).takeUnretainedValue()
            view.scroll(delta: y, modifiers: gtk_event_controller_get_current_event_state(controller))
            return 1
        }
        connect(UnsafeMutableRawPointer(scroll), "scroll", unsafeBitCast(scrolled, to: GCallback.self))
    }

    private func connect(_ object: UnsafeMutableRawPointer, _ signal: String, _ callback: GCallback) {
        _ = g_object_ref(object)
        connections.append((object, g_signal_connect_data(object, signal, callback,
            Unmanaged.passUnretained(self).toOpaque(), nil, GConnectFlags(rawValue: 0))))
    }

    func dispose() {
        guard !closed else { return }
        closed = true
        gtk_im_context_set_client_widget(im, nil)
        for (object, handler) in connections { g_signal_handler_disconnect(object, handler); g_object_unref(object) }
        connections.removeAll()
        g_object_unref(UnsafeMutableRawPointer(im))
        engine.close()
        g_object_unref(UnsafeMutableRawPointer(widget))
    }
}
#endif
