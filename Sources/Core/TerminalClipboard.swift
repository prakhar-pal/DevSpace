import Foundation

/// Observes clipboard writes in terminal output; never answers clipboard reads.
public struct TerminalClipboardDecoder {
    private enum State { case ground, escape, osc, otherString }
    private var state: State = .ground
    private var pendingEscape = false
    private var rejected = false
    private var content = Data()
    private static let maximumDecodedBytes = 65_536
    private static let maximumSequenceBytes = ((maximumDecodedBytes + 2) / 3) * 4 + 5

    public init() {}

    /// Input is still forwarded unchanged to the renderer by the caller.
    /// Only complete, bounded OSC 52 text writes to the clipboard are returned.
    public mutating func consume(_ bytes: Data) -> [String] {
        var writes: [String] = []
        for byte in bytes {
            if byte == 0x18 || byte == 0x1a { reset(); continue }
            switch state {
            case .ground:
                if byte == 0x1b { state = .escape }
            case .escape:
                switch byte {
                case 0x5d: state = .osc
                case 0x50, 0x5f, 0x5e, 0x58: state = .otherString
                case 0x1b: break
                default: state = .ground
                }
            case .osc, .otherString:
                if pendingEscape && byte == 0x5c || state == .osc && byte == 0x07 {
                    if state == .osc, !rejected, (!pendingEscape || byte == 0x5c),
                       let text = clipboardText() { writes.append(text) }
                    reset()
                } else if byte == 0x1b {
                    if pendingEscape { rejected = true }
                    pendingEscape = true
                } else {
                    if pendingEscape { rejected = true; pendingEscape = false }
                    if state == .osc && !rejected {
                        if content.count < Self.maximumSequenceBytes { content.append(byte) }
                        else { rejected = true; content.removeAll(keepingCapacity: false) }
                    }
                }
            }
        }
        return writes
    }

    private func clipboardText() -> String? {
        let fields = content.split(separator: 0x3b, maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0].elementsEqual([0x35, 0x32]),
              fields[1].isEmpty || fields[1].elementsEqual([0x63]),
              let decoded = Data(base64Encoded: Data(fields[2])),
              decoded.base64EncodedData().elementsEqual(fields[2]),
              decoded.count <= Self.maximumDecodedBytes, !decoded.contains(0),
              let text = String(data: decoded, encoding: .utf8) else { return nil }
        return text
    }

    private mutating func reset() {
        state = .ground
        pendingEscape = false
        rejected = false
        content.removeAll(keepingCapacity: false)
    }
}
