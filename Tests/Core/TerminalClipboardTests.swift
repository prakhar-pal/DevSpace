import XCTest
@testable import DevSpaceCore

final class TerminalClipboardTests: XCTestCase {
    func testClipboardWritesSurviveEveryChunkBoundaryAndBothTerminators() {
        for ending in ["\u{7}", "\u{1b}\\"] {
            let bytes = Data("before\u{1b}]52;c;zrvnlYzwn5mCCmxpbmUy\(ending)after".utf8)
            for split in 0...bytes.count {
                var decoder = TerminalClipboardDecoder()
                let writes = decoder.consume(bytes.prefix(split)) + decoder.consume(bytes.dropFirst(split))
                XCTAssertEqual(writes, ["λ界🙂\nline2"], "split \(split)")
            }
        }
    }

    func testRejectsQueriesPrimarySelectionMalformedTextAndOversizeThenRecovers() {
        var decoder = TerminalClipboardDecoder()
        let oversized = String(repeating: "YWFh", count: 30_000)
        for value in ["52;c;?", "52;p;YWJj", "52;c;%%%", "52;c;AA==", "52;c;/w==", "52;c;\(oversized)"] {
            XCTAssertEqual(decoder.consume(Data("\u{1b}]\(value)\u{7}".utf8)), [])
        }
        XCTAssertEqual(decoder.consume(Data("\u{1b}]52;;YWJj\u{7}".utf8)), ["abc"])
    }

    func testDoesNotInterpretClipboardSequencesInsideOtherControlStrings() {
        for prefix in ["\u{1b}P", "\u{1b}_", "\u{1b}^", "\u{1b}X", "\u{1b}]0;title"] {
            var decoder = TerminalClipboardDecoder()
            XCTAssertEqual(decoder.consume(Data("\(prefix)\u{1b}]52;c;YWJj\u{7}\u{1b}\\".utf8)), [])
            XCTAssertEqual(decoder.consume(Data("\u{1b}]52;c;ZGVm\u{1b}\\".utf8)), ["def"])
        }
    }

    func testCancelledSequenceCannotWriteClipboard() {
        var decoder = TerminalClipboardDecoder()
        XCTAssertEqual(decoder.consume(Data("\u{1b}]52;c;YWJj\u{18}\u{7}".utf8)), [])
        XCTAssertEqual(decoder.consume(Data("\u{1b}]52;c;ZGVm\u{7}".utf8)), ["def"])
    }
}
