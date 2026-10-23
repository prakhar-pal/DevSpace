import Foundation
import CGhosttyVT

@main
struct GhosttySmoke {
    static func main() {
        for _ in 0..<32 { verifyTerminal() }
        print("Pinned libghostty-vt Swift ABI, ANSI parsing and disposal passed")
    }

    private static func verifyTerminal() {
        var handle: GhosttyTerminal?
        precondition(ghostty_terminal_new(nil, &handle, 80, 24) == GHOSTTY_SUCCESS)
        guard let terminal = handle else { fatalError("No terminal") }
        defer { ghostty_terminal_free(terminal) }
        let bytes = Array("hello \u{1b}[31mGhostty\u{1b}[0m".utf8)
        bytes.withUnsafeBufferPointer { ghostty_terminal_vt_write(terminal, $0.baseAddress, $0.count) }
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.trim = true
        var formatterHandle: GhosttyFormatter?
        precondition(ghostty_formatter_terminal_new(nil, &formatterHandle, terminal, options) == GHOSTTY_SUCCESS)
        guard let formatter = formatterHandle else { fatalError("No formatter") }
        defer { ghostty_formatter_free(formatter) }
        var output: UnsafeMutablePointer<UInt8>?
        var length = 0
        precondition(ghostty_formatter_format_alloc(formatter, nil, &output, &length) == GHOSTTY_SUCCESS)
        guard let output else { fatalError("No formatted bytes") }
        defer { ghostty_free(nil, output, length) }
        let text = String(decoding: UnsafeBufferPointer(start: output, count: length), as: UTF8.self)
        precondition(text.trimmingCharacters(in: .whitespacesAndNewlines) == "hello Ghostty",
                     "Terminal did not interpret ANSI styling correctly")
    }
}
