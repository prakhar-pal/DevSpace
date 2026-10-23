import Foundation
import XCTest
import CGTK
@testable import DevSpaceLinuxApp

final class AccessibilityTests: XCTestCase {
    func testNativeTextInterfaceExposesUnicodeCaretAndSelection() throws {
        guard ProcessInfo.processInfo.environment["DEVSPACE_PRIVATE_KEY_TEST"] == "1" else {
            throw XCTSkip("requires private GTK display")
        }
        gtk_init()
        let view = try GhosttyTerminalView(forceRaster: true)
        let window = gtk_window_new()!
        let native = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        defer { view.dispose(); gtk_window_destroy(native) }
        gtk_window_set_default_size(native, 640, 320)
        gtk_window_set_child(native, view.widget)
        gtk_window_present(native)
        let deadline = Date().addingTimeInterval(3)
        while (gtk_widget_get_mapped(view.widget) == 0 || gtk_widget_get_width(view.widget) == 0
               || gtk_widget_get_height(view.widget) == 0) && Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            usleep(1_000)
        }
        let instance = UnsafeMutableRawPointer(view.widget).assumingMemoryBound(to: GTypeInstance.self)
        XCTAssertNotEqual(g_type_check_instance_is_a(instance, gtk_accessible_text_get_type()), 0,
            "terminal must implement native accessible text, not only a description")
        let raw = try XCTUnwrap(g_type_interface_peek(instance.pointee.g_class, gtk_accessible_text_get_type()))
        let interface = raw.assumingMemoryBound(to: GtkAccessibleTextInterface.self)
        let accessible = OpaquePointer(view.widget)
        try view.receive(Data("界".utf8))
        view.refresh()
        let contents = try XCTUnwrap(interface.pointee.get_contents?(accessible, 0, 1))
        defer { g_bytes_unref(contents) }
        var count: UInt = 0
        let bytes = try XCTUnwrap(g_bytes_get_data(contents, &count))
        XCTAssertEqual(Data(bytes: bytes, count: Int(count)), Data("界".utf8))
        XCTAssertEqual(interface.pointee.get_caret_position?(accessible), 1,
            "accessible offsets count Unicode characters, not terminal columns")
        try view.receive(Data("e\u{301}".utf8))
        view.refresh()
        XCTAssertEqual(interface.pointee.get_caret_position?(accessible), 3,
            "combining scalars each contribute one accessible offset")
        var start: UInt32 = 99, end: UInt32 = 99
        let character = try XCTUnwrap(interface.pointee.get_contents_at?(accessible, 1,
            GTK_ACCESSIBLE_TEXT_GRANULARITY_CHARACTER, &start, &end))
        g_bytes_unref(character)
        XCTAssertEqual(start, 1)
        XCTAssertEqual(end, 2)
        try view.engine.select(startColumn: 0, startRow: 0, endColumn: 1, endRow: 0)
        try view.receive(Data())
        view.refresh()
        var rangeCount: UInt = 0
        var ranges: UnsafeMutablePointer<GtkAccessibleTextRange>?
        XCTAssertNotEqual(interface.pointee.get_selection?(accessible, &rangeCount, &ranges), 0)
        defer { if let ranges { g_free(ranges) } }
        XCTAssertEqual(rangeCount, 1)
        XCTAssertEqual(ranges?.pointee.start, 0)
        XCTAssertEqual(ranges?.pointee.length, 1)
        var extents = graphene_rect_t()
        XCTAssertNotEqual(interface.pointee.get_extents?(accessible, 0, 1, &extents), 0)
        XCTAssertGreaterThan(extents.size.width, 0)
        var point = graphene_point_t(x: extents.size.width * 0.75, y: extents.size.height * 0.5)
        var offset: UInt32 = 99
        XCTAssertNotEqual(interface.pointee.get_offset?(accessible, &point, &offset), 0)
        XCTAssertEqual(offset, 0, "both halves of a wide glyph refer to its character offset")
        try view.engine.clearSelection()
        try view.receive(Data("\u{1b}[2J\u{1b}[HAB\r\nCD".utf8))
        try view.engine.select(startColumn: 0, startRow: 0, endColumn: 0, endRow: 1, rectangle: true)
        view.refresh()
        var rectangleCount: UInt = 0
        var rectangleRanges: UnsafeMutablePointer<GtkAccessibleTextRange>?
        XCTAssertNotEqual(interface.pointee.get_selection?(accessible, &rectangleCount, &rectangleRanges), 0)
        defer { if let rectangleRanges { g_free(rectangleRanges) } }
        XCTAssertEqual(rectangleCount, 2, "rectangular selection must not claim unselected intervening text")
        if rectangleCount == 2 {
            XCTAssertEqual(rectangleRanges?[0].length, 1)
            XCTAssertEqual(rectangleRanges?[1].length, 1)
        }
        try view.receive(Data("\u{1b}[8mSECRET\u{1b}[0m".utf8))
        view.refresh()
        let all = try XCTUnwrap(interface.pointee.get_contents?(accessible, 0, UInt32.max))
        defer { g_bytes_unref(all) }
        var allCount: UInt = 0
        let allBytes = try XCTUnwrap(g_bytes_get_data(all, &allCount))
        XCTAssertFalse(String(decoding: Data(bytes: allBytes, count: Int(allCount)), as: UTF8.self).contains("SECRET"))
        view.dispose()
        let retained = try XCTUnwrap(interface.pointee.get_contents?(accessible, 0, 1))
        g_bytes_unref(retained)
    }
}
