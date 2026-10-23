#if DEVSPACE_GHOSTTY
import Foundation
import CGTK
import DevSpaceGhosttyVT

/// Native GTK text queries use Unicode scalar offsets, not UTF-8 bytes or
/// terminal columns. Own the displayed snapshot so callbacks borrow no engine data.
final class TerminalAccessibility {
    private(set) var scalars: [Unicode.Scalar] = []
    private(set) var caret: UInt32 = 0
    private(set) var selections: [GtkAccessibleTextRange] = []
    private var cells: [(offset: Int, count: Int, column: Int, row: Int, width: Int)] = []
    private var cellWidth: Float = 1
    private var cellHeight: Float = 1

    static let widgetType: GType = {
        var query = GTypeQuery()
        g_type_query(gtk_box_get_type(), &query)
        let type = g_type_register_static_simple(gtk_box_get_type(), "DevSpaceTerminalSurface",
            query.class_size, { raw, _ in
                guard let raw else { return }
                gtk_widget_class_set_accessible_role(raw.assumingMemoryBound(to: GtkWidgetClass.self), GTK_ACCESSIBLE_ROLE_TERMINAL)
            }, query.instance_size, nil, GTypeFlags(rawValue: 0))
        var info = GInterfaceInfo(interface_init: { raw, _ in
            guard let raw else { return }
            let interface = raw.assumingMemoryBound(to: GtkAccessibleTextInterface.self)
            interface.pointee.get_contents = { object, start, end in
                state(object)?.contents(start: Int(start), end: Int(end))
            }
            interface.pointee.get_contents_at = { object, offset, granularity, start, end in
                guard let value = state(object) else { return nil }
                let bounds = value.bounds(offset: Int(offset), granularity: granularity)
                start?.pointee = UInt32(bounds.lowerBound)
                end?.pointee = UInt32(bounds.upperBound)
                return value.contents(start: bounds.lowerBound, end: bounds.upperBound)
            }
            interface.pointee.get_caret_position = { state($0)?.caret ?? 0 }
            interface.pointee.get_selection = { object, count, ranges in
                count?.pointee = 0
                ranges?.pointee = nil
                guard let selected = state(object)?.selections, !selected.isEmpty else { return 0 }
                count?.pointee = UInt(selected.count)
                if let ranges {
                    let memory = g_malloc(gsize(MemoryLayout<GtkAccessibleTextRange>.stride * selected.count))!
                        .assumingMemoryBound(to: GtkAccessibleTextRange.self)
                    for (index, range) in selected.enumerated() { memory[index] = range }
                    ranges.pointee = memory
                }
                return 1
            }
            interface.pointee.get_attributes = { _, _, count, ranges, names, values in
                count?.pointee = 0; ranges?.pointee = nil
                names?.pointee = nil; values?.pointee = nil
                return 0
            }
            interface.pointee.get_default_attributes = { _, names, values in
                names?.pointee = nil; values?.pointee = nil
            }
            interface.pointee.get_extents = { object, start, end, result in
                guard let value = state(object), let result,
                      let rect = value.extents(start: Int(start), end: Int(end)) else { return 0 }
                result.pointee = rect
                return 1
            }
            interface.pointee.get_offset = { object, point, offset in
                guard let value = state(object), let point, let offset,
                      let position = value.offset(at: point.pointee) else { return 0 }
                offset.pointee = UInt32(position)
                return 1
            }
            // A terminal's program owns its caret. Accessibility must not
            // move it by mutating a text buffer behind the PTY's back.
        }, interface_finalize: nil, interface_data: nil)
        g_type_add_interface_static(type, gtk_accessible_text_get_type(), &info)
        return type
    }()

    private static func state(_ object: OpaquePointer?) -> TerminalAccessibility? {
        guard let object, let data = g_object_get_data(UnsafeMutableRawPointer(object).assumingMemoryBound(to: GObject.self), "devspace-terminal-text") else { return nil }
        return Unmanaged<TerminalAccessibility>.fromOpaque(data).takeUnretainedValue()
    }

    func makeWidget(child: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget> {
        let object = g_object_new_with_properties(Self.widgetType, 0, nil, nil)!
        let widget = UnsafeMutableRawPointer(object).assumingMemoryBound(to: GtkWidget.self)
        g_object_set_data_full(object, "devspace-terminal-text",
            Unmanaged.passRetained(self).toOpaque(), { data in
                if let data { Unmanaged<TerminalAccessibility>.fromOpaque(data).release() }
            })
        gtk_orientable_set_orientation(OpaquePointer(widget), GTK_ORIENTATION_VERTICAL)
        gtk_widget_set_hexpand(child, 1)
        gtk_widget_set_vexpand(child, 1)
        gtk_box_append(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkBox.self), child)
        var hidden = GTK_ACCESSIBLE_STATE_HIDDEN, value = GValue()
        gtk_accessible_state_init_value(hidden, &value)
        g_value_set_boolean(&value, 1)
        gtk_accessible_update_state_value(OpaquePointer(child), 1, &hidden, &value)
        g_value_unset(&value)
        return widget
    }

    func update(_ frame: GhosttyTerminalFrame, widget: UnsafeMutablePointer<GtkWidget>, cellWidth: Float, cellHeight: Float) {
        var next: [Unicode.Scalar] = []
        var nextCells: [(Int, Int, Int, Int, Int)] = []
        var nextCaret: UInt32 = 0
        var nextSelections: [GtkAccessibleTextRange] = []
        for (rowIndex, row) in frame.cells.enumerated() {
            for (column, cell) in row.enumerated() where cell.width > 0 {
                if let cursor = frame.cursor, cursor.row == rowIndex, cursor.column == column {
                    nextCaret = UInt32(next.count)
                }
                let text = cell.invisible || cell.text.isEmpty ? " " : cell.text
                let count = text.unicodeScalars.count
                nextCells.append((next.count, count, column, rowIndex, cell.width))
                if cell.selected {
                    if let last = nextSelections.last, last.start + last.length == UInt(next.count) {
                        nextSelections[nextSelections.count - 1].length += UInt(count)
                    } else {
                        nextSelections.append(GtkAccessibleTextRange(start: UInt(next.count), length: UInt(count)))
                    }
                }
                next.append(contentsOf: text.unicodeScalars)
            }
            if rowIndex + 1 < frame.cells.count { next.append("\n") }
        }
        let accessible = OpaquePointer(widget)
        let changed = next != scalars
        let caretChanged = caret != nextCaret
        let selectionChanged = selections.map { $0.start..<($0.start + $0.length) }
            != nextSelections.map { $0.start..<($0.start + $0.length) }
        if changed && !scalars.isEmpty {
            gtk_accessible_text_update_contents(accessible, GTK_ACCESSIBLE_TEXT_CONTENT_CHANGE_REMOVE, 0, UInt32(scalars.count))
        }
        scalars = next; cells = nextCells; caret = nextCaret; selections = nextSelections
        self.cellWidth = cellWidth; self.cellHeight = cellHeight
        if changed && !scalars.isEmpty {
            gtk_accessible_text_update_contents(accessible, GTK_ACCESSIBLE_TEXT_CONTENT_CHANGE_INSERT, 0, UInt32(scalars.count))
        }
        if caretChanged { gtk_accessible_text_update_caret_position(accessible) }
        if selectionChanged { gtk_accessible_text_update_selection_bound(accessible) }
    }

    private func contents(start: Int, end: Int) -> OpaquePointer? {
        let lower = min(max(0, start), scalars.count), upper = min(max(lower, end), scalars.count)
        let bytes = Array(String(String.UnicodeScalarView(scalars[lower..<upper])).utf8)
        return bytes.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
    }

    private func bounds(offset: Int, granularity: GtkAccessibleTextGranularity) -> Range<Int> {
        let position = min(max(0, offset), scalars.count)
        if position == scalars.count { return position..<position }
        if granularity == GTK_ACCESSIBLE_TEXT_GRANULARITY_CHARACTER { return position..<(position + 1) }
        if granularity == GTK_ACCESSIBLE_TEXT_GRANULARITY_LINE || granularity == GTK_ACCESSIBLE_TEXT_GRANULARITY_PARAGRAPH {
            let start = scalars[..<position].lastIndex(of: "\n").map { $0 + 1 } ?? 0
            let end = scalars[position...].firstIndex(of: "\n").map { $0 + 1 } ?? scalars.count
            return start..<end
        }
        var attributes = [PangoLogAttr](repeating: PangoLogAttr(), count: scalars.count + 1)
        String(String.UnicodeScalarView(scalars)).withCString {
            pango_get_log_attrs($0, -1, -1, nil, &attributes, Int32(attributes.count))
        }
        let boundaries = attributes.indices.filter {
            granularity == GTK_ACCESSIBLE_TEXT_GRANULARITY_WORD
                ? attributes[$0].is_word_start != 0 : attributes[$0].is_sentence_start != 0
        }
        return (boundaries.last { $0 <= position } ?? 0)..<(boundaries.first { $0 > position } ?? scalars.count)
    }

    private func extents(start: Int, end: Int) -> graphene_rect_t? {
        guard start >= 0, end >= start, end <= scalars.count else { return nil }
        let included = cells.filter { $0.offset + $0.count > start && $0.offset < max(start + 1, end) }
        guard let first = included.first else { return nil }
        let minX = included.map { Float($0.column) * cellWidth }.min()!
        let maxX = included.map { Float($0.column + $0.width) * cellWidth }.max()!
        let lastRow = included.last!.row
        return graphene_rect_t(origin: graphene_point_t(x: minX, y: Float(first.row) * cellHeight),
            size: graphene_size_t(width: maxX - minX, height: Float(lastRow - first.row + 1) * cellHeight))
    }

    private func offset(at point: graphene_point_t) -> Int? {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0 else { return nil }
        let column = Int(point.x / cellWidth), row = Int(point.y / cellHeight)
        return cells.first { $0.row == row && column >= $0.column && column < $0.column + $0.width }?.offset
    }
}
#endif
