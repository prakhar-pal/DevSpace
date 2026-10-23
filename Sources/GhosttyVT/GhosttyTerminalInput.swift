import Foundation
import CGhosttyVT

extension GhosttyTerminalEngine {
    public func paste(_ text: String, allowUnsafe: Bool = false) throws -> [GhosttyTerminalEvent] {
        try withTerminal { terminal in
            guard !finished else { throw GhosttyTerminalError.finished }
            let contents = PasteContents(Data(text.utf8))
            let read: GhosttyMimeReaderFn = { userdata, _, writer in
                guard let userdata, let write = writer.write else { return false }
                let contents = Unmanaged<PasteContents>.fromOpaque(userdata).takeUnretainedValue()
                return contents.bytes.withUnsafeBytes {
                    write(writer.userdata, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
                }
            }
            let mimeBytes = Array("text/plain".utf8)
            let result = mimeBytes.withUnsafeBufferPointer { bytes in
                var mime = GhosttyString(ptr: bytes.baseAddress, len: bytes.count)
                return withUnsafePointer(to: &mime) { mime in
                    var paste = GhosttyPaste()
                    paste.size = MemoryLayout<GhosttyPaste>.size
                    paste.location = GHOSTTY_CLIPBOARD_LOCATION_STANDARD
                    paste.source = GHOSTTY_PASTE_SOURCE_CLIPBOARD
                    paste.mimes = mime
                    paste.mimes_len = 1
                    paste.reader = GhosttyMimeReader(read: read, userdata: Unmanaged.passUnretained(contents).toOpaque())
                    paste.allow_unsafe = allowUnsafe
                    return withExtendedLifetime(contents) { ghostty_terminal_paste(terminal, &paste, nil) }
                }
            }
            if result == GHOSTTY_REJECTED { throw GhosttyTerminalError.unsafePaste }
            try Self.check(result)
            return takeEvents()
        }
    }

    public func encodeKey(_ key: GhosttyKey, mods: GhosttyMods = 0,
                          action: GhosttyKeyAction = GHOSTTY_KEY_ACTION_PRESS,
                          utf8: String? = nil, unshifted: UInt32 = 0,
                          consumedMods: GhosttyMods = 0, composing: Bool = false) throws -> Data {
        try withTerminal { terminal in
            guard !finished else { throw GhosttyTerminalError.finished }
            var encoder: GhosttyKeyEncoder?
            try Self.check(ghostty_key_encoder_new(nil, &encoder))
            defer { ghostty_key_encoder_free(encoder) }
            var event: GhosttyKeyEvent?
            try Self.check(ghostty_key_event_new(nil, &event))
            defer { ghostty_key_event_free(event) }
            ghostty_key_encoder_setopt_from_terminal(encoder, terminal)
            ghostty_key_event_set_key(event, key)
            ghostty_key_event_set_action(event, action)
            ghostty_key_event_set_mods(event, mods)
            ghostty_key_event_set_consumed_mods(event, consumedMods)
            ghostty_key_event_set_unshifted_codepoint(event, unshifted)
            ghostty_key_event_set_composing(event, composing)
            let encode = { () throws -> Data in
                var count = 0
                var buffer = [CChar](repeating: 0, count: 64)
                var result = ghostty_key_encoder_encode(encoder, event, &buffer, buffer.count, &count)
                if result == GHOSTTY_OUT_OF_SPACE, count > buffer.count {
                    buffer = [CChar](repeating: 0, count: count)
                    result = ghostty_key_encoder_encode(encoder, event, &buffer, buffer.count, &count)
                }
                try Self.check(result)
                return buffer.withUnsafeBytes { Data($0.prefix(count)) }
            }
            // Native key events borrow UTF-8. Encode while this buffer is alive.
            if let utf8, !utf8.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
                return try utf8.withCString {
                    ghostty_key_event_set_utf8(event, $0, utf8.utf8.count)
                    return try encode()
                }
            }
            return try encode()
        }
    }

    public func encodeFocus(_ focused: Bool) throws -> Data {
        try withTerminal { terminal in
            guard !finished else { return Data() }
            var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(1004, false), value: false)
            try Self.check(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode))
            guard mode.value else { return Data() }
            var bytes = [CChar](repeating: 0, count: 3)
            var count = 0
            try Self.check(ghostty_focus_encode(focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST,
                                               &bytes, bytes.count, &count))
            return bytes.withUnsafeBytes { Data($0.prefix(count)) }
        }
    }

    public func hasMouseTracking() throws -> Bool {
        try withTerminal { terminal in
            var enabled = false
            try Self.check(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &enabled))
            return enabled
        }
    }

    public func encodeMouse(action: GhosttyMouseAction, button: GhosttyMouseButton?,
                            x: Double, y: Double, cellWidth: UInt32, cellHeight: UInt32,
                            mods: GhosttyMods = 0) throws -> Data {
        try withTerminal { terminal in
            guard !finished else { throw GhosttyTerminalError.finished }
            guard Float(x).isFinite, Float(y).isFinite, cellWidth > 0, cellHeight > 0 else { throw GhosttyTerminalError.invalidSize }
            var columns: UInt16 = 0
            var rows: UInt16 = 0
            try Self.check(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &columns))
            try Self.check(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows))
            guard UInt64(columns) * UInt64(cellWidth) <= UInt32.max,
                  UInt64(rows) * UInt64(cellHeight) <= UInt32.max else { throw GhosttyTerminalError.invalidSize }
            if mouseEncoder == nil { try Self.check(ghostty_mouse_encoder_new(nil, &mouseEncoder)) }
            guard let encoder = mouseEncoder else { throw GhosttyTerminalError.closed }
            ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal)
            var size = GhosttyMouseEncoderSize()
            size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
            size.screen_width = UInt32(columns) * cellWidth
            size.screen_height = UInt32(rows) * cellHeight
            size.cell_width = cellWidth
            size.cell_height = cellHeight
            ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
            var event: GhosttyMouseEvent?
            try Self.check(ghostty_mouse_event_new(nil, &event))
            defer { ghostty_mouse_event_free(event) }
            ghostty_mouse_event_set_action(event, action)
            ghostty_mouse_event_set_mods(event, mods)
            ghostty_mouse_event_set_position(event, GhosttyMousePosition(x: Float(x), y: Float(y)))
            if let button { ghostty_mouse_event_set_button(event, button) }
            var bytes = [CChar](repeating: 0, count: 128)
            var count = 0
            try Self.check(ghostty_mouse_encoder_encode(encoder, event, &bytes, bytes.count, &count))
            return bytes.withUnsafeBytes { Data($0.prefix(count)) }
        }
    }
}

private final class PasteContents {
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
}
