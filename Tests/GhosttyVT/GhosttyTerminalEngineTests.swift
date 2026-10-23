import Foundation
import XCTest
import CGhosttyVT
@testable import DevSpaceGhosttyVT

final class GhosttyTerminalEngineTests: XCTestCase {
    func testFragmentedUnicodeAndANSIProduceVisibleTextOnlyOnce() throws {
        let engine = try GhosttyTerminalEngine(columns: 40, rows: 4)
        XCTAssertEqual(try engine.receive(Data("\u{1b}[31".utf8)), [])
        let bytes = Array("mhello 界e\u{301}\u{1b}[0m".utf8)
        var events: [GhosttyTerminalEvent] = []
        for byte in bytes { events += try engine.receive(Data([byte])) }
        XCTAssertEqual(events.filter { $0 == .firstOutput }.count, 1)
        XCTAssertEqual(try engine.text().trimmingCharacters(in: .whitespacesAndNewlines), "hello 界e\u{301}")
        XCTAssertFalse(try engine.receive(Data(" again".utf8)).contains(.firstOutput))
    }

    func testRepliesAreReturnedWithoutEstablishingVisibleOutput() throws {
        let engine = try GhosttyTerminalEngine(columns: 40, rows: 4)
        XCTAssertEqual(try engine.receive(Data("\u{1b}[6n".utf8)), [.writePTY(Data("\u{1b}[1;1R".utf8))])
        XCTAssertEqual(try engine.text().trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual(try engine.receive(Data("ready".utf8)), [.firstOutput])
    }

    func testAlternateScreenRestoresPrimaryContents() throws {
        let engine = try GhosttyTerminalEngine(columns: 40, rows: 4)
        _ = try engine.receive(Data("primary".utf8))
        _ = try engine.receive(Data("\u{1b}[?1049hsecondary".utf8))
        XCTAssertEqual(try engine.text().trimmingCharacters(in: .whitespacesAndNewlines), "secondary")
        _ = try engine.receive(Data("\u{1b}[?1049l".utf8))
        XCTAssertEqual(try engine.text().trimmingCharacters(in: .whitespacesAndNewlines), "primary")
    }

    func testDirectoryChangesAreValidatedAndCanBeCleared() throws {
        let engine = try GhosttyTerminalEngine()
        XCTAssertEqual(try engine.receive(Data("\u{1b}]7;file://remote/workspace/a%20b\u{1b}\\".utf8)), [.directory("/workspace/a b")])
        XCTAssertEqual(try engine.receive(Data("\u{1b}]7;https://example.com/private\u{7}".utf8)), [.directory(nil)])
        XCTAssertEqual(try engine.receive(Data("\u{1b}]7;\u{7}".utf8)), [.directory(nil)])
    }

    func testResizeReflowsAndPreservesOutputBeforeExit() throws {
        let engine = try GhosttyTerminalEngine(columns: 8, rows: 4)
        _ = try engine.receive(Data("abcdefghijkl".utf8))
        try engine.resize(columns: 16, rows: 4, cellWidth: 9, cellHeight: 18)
        XCTAssertEqual(try engine.text().trimmingCharacters(in: .whitespacesAndNewlines), "abcdefghijkl")
        XCTAssertEqual(try engine.finish(exitCode: 7), [.exited(7)])
        XCTAssertEqual(try engine.finish(exitCode: 9), [])
        XCTAssertEqual(try engine.text().trimmingCharacters(in: .whitespacesAndNewlines), "abcdefghijkl")
        XCTAssertThrowsError(try engine.receive(Data("late output".utf8)))
    }

    func testInvalidSizeAndIdempotentClose() throws {
        XCTAssertThrowsError(try GhosttyTerminalEngine(columns: 0, rows: 4))
        let engine = try GhosttyTerminalEngine()
        XCTAssertThrowsError(try engine.resize(columns: 4, rows: 0))
        engine.close()
        engine.close()
        XCTAssertThrowsError(try engine.receive(Data()))
        XCTAssertThrowsError(try engine.text())
        XCTAssertThrowsError(try engine.finish(exitCode: 0))
    }

    func testOwnedFramePreservesColorsWideCellsAndLongGraphemes() throws {
        let engine = try GhosttyTerminalEngine(columns: 80, rows: 4)
        let grapheme = "e" + String(repeating: "\u{301}", count: 64)
        _ = try engine.receive(Data(("\u{1b}[1;38;2;17;34;51m界\u{1b}[0m" + grapheme).utf8))
        let frame = try engine.snapshot()
        XCTAssertEqual(frame.cells.count, 4)
        XCTAssertEqual(frame.cells[0].count, 80)
        XCTAssertEqual(frame.cells[0][0].text, "界")
        XCTAssertEqual(frame.cells[0][0].width, 2)
        XCTAssertEqual(frame.cells[0][0].foreground, 0xff112233)
        XCTAssertTrue(frame.cells[0][0].bold)
        XCTAssertEqual(frame.cells[0][1].width, 0)
        XCTAssertEqual(frame.cells[0][2].text, grapheme)
        _ = try engine.receive(Data("\r\u{1b}[2Kchanged".utf8))
        XCTAssertEqual(frame.cells[0][0].text, "界", "Snapshots must not retain borrowed C memory")
        XCTAssertEqual(try engine.snapshot().cells[0][0].text, "c")
        engine.close()
        XCTAssertEqual(frame.cells[0][2].text, grapheme, "Owned snapshots remain valid after terminal destruction")
    }

    func testStaleFrameAcknowledgementCannotClearNewOutput() throws {
        let engine = try GhosttyTerminalEngine(columns: 20, rows: 4)
        let first = try engine.snapshot()
        _ = try engine.receive(Data("new".utf8))
        XCTAssertFalse(try engine.acknowledgeFrame(revision: first.revision))
        let current = try engine.snapshot()
        XCTAssertTrue(current.dirty)
        XCTAssertTrue(try engine.acknowledgeFrame(revision: current.revision))
        XCTAssertFalse(try engine.snapshot().dirty)
    }

    func testKeyEncodingUsesTerminalModesAndKeepsUTF8Alive() throws {
        let engine = try GhosttyTerminalEngine()
        XCTAssertEqual(try engine.encodeKey(GHOSTTY_KEY_ARROW_UP), Data("\u{1b}[A".utf8))
        _ = try engine.receive(Data("\u{1b}[?1h".utf8))
        XCTAssertEqual(try engine.encodeKey(GHOSTTY_KEY_ARROW_UP), Data("\u{1b}OA".utf8))
        XCTAssertEqual(try engine.encodeKey(GHOSTTY_KEY_C, mods: GhosttyMods(GHOSTTY_MODS_CTRL), utf8: "c"), Data([3]))
        XCTAssertEqual(try engine.encodeKey(GHOSTTY_KEY_A, utf8: "é"), Data("é".utf8))
        XCTAssertEqual(try engine.encodeKey(GHOSTTY_KEY_A, action: GHOSTTY_KEY_ACTION_RELEASE, utf8: "a"), Data())
        _ = try engine.finish(exitCode: 0)
        XCTAssertThrowsError(try engine.encodeKey(GHOSTTY_KEY_A, utf8: "a"))
    }

    func testFocusReportsOnlyWhenRequested() throws {
        let engine = try GhosttyTerminalEngine()
        XCTAssertEqual(try engine.encodeFocus(true), Data())
        _ = try engine.receive(Data("\u{1b}[?1004h".utf8))
        XCTAssertEqual(try engine.encodeFocus(true), Data("\u{1b}[I".utf8))
        XCTAssertEqual(try engine.encodeFocus(false), Data("\u{1b}[O".utf8))
    }

    func testMouseEncodingHonorsTrackingAndGeometry() throws {
        let engine = try GhosttyTerminalEngine()
        XCTAssertEqual(try engine.encodeMouse(action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_LEFT,
            x: 12, y: 24, cellWidth: 6, cellHeight: 12), Data())
        _ = try engine.receive(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        XCTAssertEqual(try engine.encodeMouse(action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_LEFT,
            x: 12, y: 24, cellWidth: 6, cellHeight: 12), Data("\u{1b}[<0;3;3M".utf8))
        XCTAssertThrowsError(try engine.encodeMouse(action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_LEFT,
            x: .nan, y: 0, cellWidth: 6, cellHeight: 12))
    }

    func testSelectionCopiesOnlyChosenCellsAndRejectsInvalidEndpoints() throws {
        let engine = try GhosttyTerminalEngine(columns: 20, rows: 4)
        _ = try engine.receive(Data("hello world".utf8))
        XCTAssertNil(try engine.selectedText())
        try engine.select(startColumn: 0, startRow: 0, endColumn: 4, endRow: 0)
        XCTAssertEqual(try engine.selectedText(), "hello")
        XCTAssertTrue(try engine.snapshot().cells[0][2].selected)
        XCTAssertFalse(try engine.snapshot().cells[0][6].selected)
        XCTAssertThrowsError(try engine.select(startColumn: 99, startRow: 0, endColumn: 100, endRow: 0))
        try engine.clearSelection()
        XCTAssertNil(try engine.selectedText())
    }

    func testPasteUsesNativeSafetyAndTerminalBracketing() throws {
        let engine = try GhosttyTerminalEngine()
        XCTAssertThrowsError(try engine.paste("a\nb"))
        XCTAssertEqual(try engine.paste("a\nb", allowUnsafe: true), [.writePTY(Data("a\rb".utf8))])
        _ = try engine.receive(Data("\u{1b}[?2004h".utf8))
        let paste = try engine.paste("a\nb")
        let bytes = paste.reduce(into: Data()) { result, event in
            if case let .writePTY(data) = event { result.append(data) }
        }
        XCTAssertEqual(bytes, Data("\u{1b}[200~a\nb\u{1b}[201~".utf8))
        XCTAssertThrowsError(try engine.paste("\u{1b}[201~echo injected"))
    }

    func testScrollbackUsesViewportAndReturnsToBottom() throws {
        let engine = try GhosttyTerminalEngine(columns: 12, rows: 3)
        _ = try engine.receive(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive".utf8))
        func topLine() throws -> String {
            try engine.snapshot().cells[0].map(\.text).joined().trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(try topLine(), "three")
        try engine.scroll(lines: -2)
        XCTAssertEqual(try topLine(), "one")
        try engine.select(startColumn: 0, startRow: 0, endColumn: 2, endRow: 0)
        XCTAssertEqual(try engine.selectedText(), "one")
        try engine.scrollToBottom()
        XCTAssertEqual(try topLine(), "three")
    }

    func testResizeRepliesAreReturnedImmediately() throws {
        let engine = try GhosttyTerminalEngine()
        _ = try engine.receive(Data("\u{1b}[?2048h".utf8))
        let events = try engine.resize(columns: 30, rows: 5, cellWidth: 9, cellHeight: 18)
        XCTAssertTrue(events.contains { if case let .writePTY(data) = $0 { return !data.isEmpty }; return false })
        XCTAssertEqual(try engine.receive(Data()), [], "Resize responses must not wait for later child output")
    }

    func testSynchronizedFramesFreezeThenExpireAndFlushOnExit() throws {
        var now: UInt64 = 0
        let engine = try GhosttyTerminalEngine(columns: 20, rows: 4, nowNanoseconds: { now })
        _ = try engine.receive(Data("old\u{1b}[?2026h\r\u{1b}[2Knew".utf8))
        func topLine() throws -> String {
            try engine.snapshot().cells[0].map(\.text).joined().trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(try topLine(), "old", "Capture the exact frame before a hold, even within one input chunk")
        now = 999_999_999
        XCTAssertEqual(try topLine(), "old")
        now = 1_000_000_000
        XCTAssertEqual(try topLine(), "new", "A program cannot freeze rendering indefinitely")
        _ = try engine.receive(Data("\u{1b}[?2026h\r\u{1b}[2Kfinal".utf8))
        _ = try engine.finish(exitCode: 0)
        XCTAssertEqual(try topLine(), "final", "Exit must reveal output even if the child never ended its hold")
    }

    func testKittyKeyboardReportsPressAndReleaseWhenRequested() throws {
        let engine = try GhosttyTerminalEngine()
        _ = try engine.receive(Data("\u{1b}[>10u".utf8))
        XCTAssertEqual(try engine.encodeKey(GHOSTTY_KEY_A, utf8: "a", unshifted: 97), Data("\u{1b}[97u".utf8))
        XCTAssertEqual(try engine.encodeKey(GHOSTTY_KEY_A, action: GHOSTTY_KEY_ACTION_RELEASE, utf8: "a", unshifted: 97),
            Data("\u{1b}[97;1:3u".utf8))
    }

    static let allTests = [
        ("testFragmentedUnicodeAndANSIProduceVisibleTextOnlyOnce", testFragmentedUnicodeAndANSIProduceVisibleTextOnlyOnce),
        ("testRepliesAreReturnedWithoutEstablishingVisibleOutput", testRepliesAreReturnedWithoutEstablishingVisibleOutput),
        ("testAlternateScreenRestoresPrimaryContents", testAlternateScreenRestoresPrimaryContents),
        ("testDirectoryChangesAreValidatedAndCanBeCleared", testDirectoryChangesAreValidatedAndCanBeCleared),
        ("testResizeReflowsAndPreservesOutputBeforeExit", testResizeReflowsAndPreservesOutputBeforeExit),
        ("testInvalidSizeAndIdempotentClose", testInvalidSizeAndIdempotentClose),
        ("testOwnedFramePreservesColorsWideCellsAndLongGraphemes", testOwnedFramePreservesColorsWideCellsAndLongGraphemes),
        ("testStaleFrameAcknowledgementCannotClearNewOutput", testStaleFrameAcknowledgementCannotClearNewOutput),
        ("testKeyEncodingUsesTerminalModesAndKeepsUTF8Alive", testKeyEncodingUsesTerminalModesAndKeepsUTF8Alive),
        ("testFocusReportsOnlyWhenRequested", testFocusReportsOnlyWhenRequested),
        ("testMouseEncodingHonorsTrackingAndGeometry", testMouseEncodingHonorsTrackingAndGeometry),
        ("testSelectionCopiesOnlyChosenCellsAndRejectsInvalidEndpoints", testSelectionCopiesOnlyChosenCellsAndRejectsInvalidEndpoints),
        ("testPasteUsesNativeSafetyAndTerminalBracketing", testPasteUsesNativeSafetyAndTerminalBracketing),
        ("testScrollbackUsesViewportAndReturnsToBottom", testScrollbackUsesViewportAndReturnsToBottom),
        ("testResizeRepliesAreReturnedImmediately", testResizeRepliesAreReturnedImmediately),
        ("testSynchronizedFramesFreezeThenExpireAndFlushOnExit", testSynchronizedFramesFreezeThenExpireAndFlushOnExit),
        ("testKittyKeyboardReportsPressAndReleaseWhenRequested", testKittyKeyboardReportsPressAndReleaseWhenRequested),
    ]
}
