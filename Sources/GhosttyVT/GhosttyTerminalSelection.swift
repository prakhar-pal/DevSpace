import Foundation
import CGhosttyVT

extension GhosttyTerminalEngine {
    public func selectWord(column: UInt16, row: UInt16) throws {
        try selectSemantic(column: column, row: row, word: true)
    }

    public func selectLine(column: UInt16, row: UInt16) throws {
        try selectSemantic(column: column, row: row, word: false)
    }

    private func selectSemantic(column: UInt16, row: UInt16, word: Bool) throws {
        try withTerminal { terminal in
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_VIEWPORT
            point.value.coordinate = GhosttyPointCoordinate(x: column, y: UInt32(row))
            var reference = GhosttyGridRef()
            reference.size = MemoryLayout<GhosttyGridRef>.size
            try Self.check(ghostty_terminal_grid_ref(terminal, point, &reference))
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            let result: GhosttyResult
            if word {
                var options = GhosttyTerminalSelectWordOptions()
                options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
                options.ref = reference
                result = ghostty_terminal_select_word(terminal, &options, &selection)
            } else {
                var options = GhosttyTerminalSelectLineOptions()
                options.size = MemoryLayout<GhosttyTerminalSelectLineOptions>.size
                options.ref = reference
                result = ghostty_terminal_select_line(terminal, &options, &selection)
            }
            if result == GHOSTTY_NO_VALUE {
                try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil))
            } else {
                try Self.check(result)
                try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection))
            }
            revision &+= 1
        }
    }

    public func scroll(lines: Int) throws {
        try withTerminal { terminal in
            var scroll = GhosttyTerminalScrollViewport()
            scroll.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
            scroll.value.delta = lines
            ghostty_terminal_scroll_viewport(terminal, scroll)
            revision &+= 1
        }
    }

    public func scrollToBottom() throws {
        try withTerminal { terminal in
            var scroll = GhosttyTerminalScrollViewport()
            scroll.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
            ghostty_terminal_scroll_viewport(terminal, scroll)
            revision &+= 1
        }
    }

    public func select(startColumn: UInt16, startRow: UInt16, endColumn: UInt16, endRow: UInt16,
                       rectangle: Bool = false) throws {
        try withTerminal { terminal in
            func reference(_ column: UInt16, _ row: UInt16) throws -> GhosttyGridRef {
                var point = GhosttyPoint()
                point.tag = GHOSTTY_POINT_TAG_VIEWPORT
                point.value.coordinate = GhosttyPointCoordinate(x: column, y: UInt32(row))
                var reference = GhosttyGridRef()
                reference.size = MemoryLayout<GhosttyGridRef>.size
                try Self.check(ghostty_terminal_grid_ref(terminal, point, &reference))
                return reference
            }
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            selection.start = try reference(startColumn, startRow)
            selection.end = try reference(endColumn, endRow)
            selection.rectangle = rectangle
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection))
            revision &+= 1
        }
    }

    public func clearSelection() throws {
        try withTerminal { terminal in
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil))
            revision &+= 1
        }
    }

    public func selectedText() throws -> String? {
        try withTerminal { terminal in
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            let result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection)
            if result == GHOSTTY_NO_VALUE { return nil }
            try Self.check(result)
            return try withUnsafePointer(to: &selection) { try formattedText(terminal, selection: $0) }
        }
    }
}
