import Foundation
import CGhosttyVT

public struct GhosttyTerminalCell: Equatable {
    public let text: String
    public let width: Int
    public let foreground: UInt32
    public let background: UInt32
    public let bold: Bool
    public let italic: Bool
    public let faint: Bool
    public let inverse: Bool
    public let invisible: Bool
    public let blink: Bool
    public let strikethrough: Bool
    public let overline: Bool
    public let underline: Int32
    public let selected: Bool
}

public struct GhosttyTerminalCursor: Equatable {
    public let column: Int
    public let row: Int
    public let visible: Bool
    public let blinking: Bool
    public let style: Int32
}

/// An owned snapshot: no native pointers or borrowed buffers leave the engine.
public struct GhosttyTerminalFrame: Equatable {
    public let revision: UInt64
    public let cells: [[GhosttyTerminalCell]]
    public let dirty: Bool
    public let dirtyRows: [Bool]
    public let foreground: UInt32
    public let background: UInt32
    public let cursor: GhosttyTerminalCursor?
}

extension GhosttyTerminalEngine {
    /// Theme defaults preserve application OSC color overrides; OSC reset then
    /// returns to the most recently configured host theme.
    public func configureColors(foreground: UInt32, background: UInt32) throws {
        try withTerminal { terminal in
            func rgb(_ value: UInt32) -> GhosttyColorRgb {
                GhosttyColorRgb(r: UInt8(truncatingIfNeeded: value >> 16),
                    g: UInt8(truncatingIfNeeded: value >> 8), b: UInt8(truncatingIfNeeded: value))
            }
            var fg = rgb(foreground)
            var bg = rgb(background)
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg))
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg))
            revision &+= 1
        }
    }

    public func snapshot() throws -> GhosttyTerminalFrame {
        try withTerminal { terminal in
            guard let state = renderState else { throw GhosttyTerminalError.closed }
            try releaseExpiredRenderHold(terminal)
            if !renderHeld { try Self.check(ghostty_render_state_update(state, terminal)) }
            var colors = GhosttyRenderStateColors()
            colors.size = MemoryLayout<GhosttyRenderStateColors>.size
            try Self.check(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors))
            var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
            try Self.check(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty))
            var iterator: GhosttyRenderStateRowIterator?
            try Self.check(ghostty_render_state_row_iterator_new(nil, &iterator))
            defer { ghostty_render_state_row_iterator_free(iterator) }
            try Self.check(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator))
            var cells: GhosttyRenderStateRowCells?
            try Self.check(ghostty_render_state_row_cells_new(nil, &cells))
            defer { ghostty_render_state_row_cells_free(cells) }
            var rows: [[GhosttyTerminalCell]] = []
            var dirtyRows: [Bool] = []
            while ghostty_render_state_row_iterator_next(iterator) {
                var rowDirty = false
                try Self.check(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty))
                dirtyRows.append(rowDirty)
                try Self.check(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells))
                var row: [GhosttyTerminalCell] = []
                while ghostty_render_state_row_cells_next(cells) {
                    row.append(try Self.readCell(cells, colors: colors))
                }
                rows.append(row)
            }
            var cursor = GhosttyRenderStateCursor()
            cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
            try Self.check(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor))
            let ownedCursor = cursor.viewport_has_value ? GhosttyTerminalCursor(
                column: Int(cursor.viewport_x), row: Int(cursor.viewport_y), visible: cursor.visible,
                blinking: cursor.blinking, style: cursor.visual_style.rawValue) : nil
            return GhosttyTerminalFrame(revision: revision, cells: rows,
                dirty: dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE, dirtyRows: dirtyRows,
                foreground: Self.color(colors.foreground), background: Self.color(colors.background), cursor: ownedCursor)
        }
    }

    /// A delayed paint must not acknowledge output that arrived after its snapshot.
    @discardableResult
    public func acknowledgeFrame(revision paintedRevision: UInt64) throws -> Bool {
        try withTerminal { _ in
            guard paintedRevision == revision, let renderState else { return false }
            try Self.check(ghostty_render_state_clean(renderState))
            return true
        }
    }

    private static func color(_ rgb: GhosttyColorRgb) -> UInt32 {
        0xff000000 | UInt32(rgb.r) << 16 | UInt32(rgb.g) << 8 | UInt32(rgb.b)
    }

    private static func readCell(_ cells: GhosttyRenderStateRowCells?, colors: GhosttyRenderStateColors) throws -> GhosttyTerminalCell {
        var length: UInt32 = 0
        try check(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length))
        var codepoints = [UInt32](repeating: 0, count: Int(length))
        if length > 0 {
            try codepoints.withUnsafeMutableBufferPointer {
                try check(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, $0.baseAddress))
            }
        }
        let text = String(String.UnicodeScalarView(codepoints.compactMap(Unicode.Scalar.init)))
        var raw: GhosttyCell = 0
        try check(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw))
        var wide = GHOSTTY_CELL_WIDE_NARROW
        try check(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide))
        let width = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : (wide == GHOSTTY_CELL_WIDE_NARROW ? 1 : 0)
        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        try check(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style))
        var foreground = colors.foreground
        var background = colors.background
        // INVALID_VALUE means this cell uses the terminal's default color.
        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &foreground)
        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &background)
        var selected = false
        try check(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected))
        return GhosttyTerminalCell(text: text, width: width, foreground: color(foreground), background: color(background),
            bold: style.bold, italic: style.italic, faint: style.faint, inverse: style.inverse,
            invisible: style.invisible, blink: style.blink, strikethrough: style.strikethrough,
            overline: style.overline, underline: style.underline, selected: selected)
    }
}
