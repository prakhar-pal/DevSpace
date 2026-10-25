import Foundation
import XCTest
import CSkia
import DevSpaceGhosttyVT
@testable import DevSpaceSkiaRenderer

final class SkiaTerminalRendererTests: XCTestCase {
    func testLatinPromptDoesNotPreventArabicJoining() throws {
        let engine = try GhosttyTerminalEngine(columns: 12, rows: 3)
        _ = try engine.receive(Data("a بب".utf8))
        let renderer = try renderer()
        let font = try renderer.resolvedFont(text: "ب", bold: false, italic: false, scale: 1)
        let expected = try font.shape("بب").map(\.id)
        let layout = try renderer.layout(row: engine.snapshot().cells[0], scale: 1)
        XCTAssertEqual(layout.filter { $0.column >= 2 }.map(\.id), expected)
    }
    private func renderer() throws -> SkiaTerminalRenderer {
        let owner = SkFontMgr_New_FontConfig(nil, SkFontScanner_Make_FreeType())
        guard let manager = owner.get() else { throw SkiaTerminalRendererError.fontUnavailable }
        return try withExtendedLifetime(owner) { try SkiaTerminalRenderer(fontManager: manager, fontSize: 14) }
    }

    func testBackgroundsUseExactTerminalGridCoordinates() throws {
        let engine = try GhosttyTerminalEngine(columns: 8, rows: 3)
        _ = try engine.receive(Data("\u{1b}[48;2;17;34;51m  \u{1b}[0m".utf8))
        let renderer = try renderer()
        let metrics = try renderer.metrics(scale: 1)
        let image = try renderer.rasterize(try engine.snapshot(), width: metrics.cellWidth * 8,
            height: metrics.cellHeight * 3, scale: 1, drawCursor: false)
        XCTAssertEqual(image.pixel(x: 1, y: 1), 0xff112233)
        XCTAssertEqual(image.pixel(x: metrics.cellWidth + 1, y: 1), 0xff112233)
        XCTAssertEqual(image.pixel(x: metrics.cellWidth * 3, y: 1), try engine.snapshot().background)
    }

    func testTextRendersAndClearedRowsDoNotRetainOldGlyphs() throws {
        let engine = try GhosttyTerminalEngine(columns: 12, rows: 3)
        _ = try engine.receive(Data("hello".utf8))
        let renderer = try renderer()
        let metrics = try renderer.metrics(scale: 1)
        let frame = try engine.snapshot()
        let first = try renderer.rasterize(frame, width: metrics.cellWidth * 12, height: metrics.cellHeight * 3,
            scale: 1, drawCursor: false)
        XCTAssertTrue(stride(from: 0, to: first.bytes.count, by: 4).contains {
            first.pixel(x: ($0 / 4) % first.width, y: ($0 / 4) / first.width) != frame.background
        })
        _ = try engine.receive(Data("\r\u{1b}[2K".utf8))
        let cleared = try renderer.rasterize(try engine.snapshot(), width: first.width, height: first.height,
            scale: 1, drawCursor: false)
        XCTAssertTrue(stride(from: 0, to: cleared.bytes.count, by: 4).allSatisfy {
            cleared.pixel(x: ($0 / 4) % cleared.width, y: ($0 / 4) / cleared.width) == frame.background
        })
    }

    func testFractionalScaleAndInvalidDimensions() throws {
        let renderer = try renderer()
        let one = try renderer.metrics(scale: 1)
        let scaled = try renderer.metrics(scale: 1.5)
        XCTAssertGreaterThan(scaled.cellWidth, one.cellWidth)
        XCTAssertGreaterThan(scaled.cellHeight, one.cellHeight)
        XCTAssertThrowsError(try renderer.metrics(scale: .nan))
        let frame = try GhosttyTerminalEngine().snapshot()
        XCTAssertThrowsError(try renderer.rasterize(frame, width: 0, height: 1, scale: 1, drawCursor: false))
    }

    func testSelectionAndDecorationsArePaintedOnTheGrid() throws {
        let engine = try GhosttyTerminalEngine(columns: 8, rows: 3)
        _ = try engine.receive(Data("\u{1b}[4m \u{1b}[0m \u{1b}[9m \u{1b}[0m".utf8))
        try engine.select(startColumn: 1, startRow: 0, endColumn: 1, endRow: 0)
        let renderer = try renderer()
        let metrics = try renderer.metrics(scale: 1)
        let frame = try engine.snapshot()
        let image = try renderer.rasterize(frame, width: metrics.cellWidth * 8,
            height: metrics.cellHeight * 3, scale: 1, drawCursor: false)
        XCTAssertNotEqual(image.pixel(x: metrics.cellWidth + 1, y: 1), frame.background)
        XCTAssertTrue((0..<metrics.cellHeight).contains { image.pixel(x: 1, y: $0) != frame.background }, "underline on a space")
        XCTAssertTrue((0..<metrics.cellHeight).contains { image.pixel(x: metrics.cellWidth * 2 + 1, y: $0) != frame.background }, "strikethrough on a space")
        XCTAssertEqual(image.pixel(x: metrics.cellWidth * 4, y: 1), frame.background)
    }

    func testBeamAndUnderlineCursorsDoNotBecomeSolidBlocks() throws {
        let engine = try GhosttyTerminalEngine(columns: 8, rows: 3)
        let renderer = try renderer()
        let metrics = try renderer.metrics(scale: 1)
        for sequence in ["\u{1b}[6 q", "\u{1b}[4 q"] {
            _ = try engine.receive(Data(sequence.utf8))
            let frame = try engine.snapshot()
            let image = try renderer.rasterize(frame, width: metrics.cellWidth * 8,
                height: metrics.cellHeight * 3, scale: 1)
            XCTAssertEqual(image.pixel(x: metrics.cellWidth / 2, y: metrics.cellHeight / 2), frame.background)
            XCTAssertTrue((0..<metrics.cellHeight).contains { y in
                (0..<metrics.cellWidth).contains { image.pixel(x: $0, y: y) != frame.background }
            })
        }
    }

    func testContextualShapingUsesNeighborCellsAndGridClusters() throws {
        let engine = try GhosttyTerminalEngine(columns: 8, rows: 3)
        _ = try engine.receive(Data("بب".utf8))
        let renderer = try renderer()
        let font = try renderer.resolvedFont(text: "ب", bold: false, italic: false, scale: 1)
        let contextual = try font.shape("بب")
        let isolated = try font.shape("ب")
        XCTAssertNotEqual(contextual.map(\.id), isolated.map(\.id) + isolated.map(\.id))
        let layout = try renderer.layout(row: engine.snapshot().cells[0], scale: 1)
        XCTAssertEqual(layout.map(\.id), contextual.map(\.id))
        XCTAssertEqual(Set(layout.map(\.column)), [0, 1])
        let metrics = try renderer.metrics(scale: 1)
        for glyph in layout {
            XCTAssertGreaterThanOrEqual(glyph.x, Float(glyph.column * metrics.cellWidth) - 1)
        }
    }

    func testBlockCursorKeepsItsGlyphReadableAndUnfocusedCursorIsHollow() throws {
        let engine = try GhosttyTerminalEngine(columns: 8, rows: 3)
        _ = try engine.receive(Data("M\r\u{1b}[2 q".utf8))
        let renderer = try renderer()
        let metrics = try renderer.metrics(scale: 1)
        let frame = try engine.snapshot()
        let image = try renderer.rasterize(frame, width: metrics.cellWidth * 8,
            height: metrics.cellHeight * 3, scale: 1)
        XCTAssertTrue((0..<metrics.cellHeight).contains { y in
            (0..<metrics.cellWidth).contains { image.pixel(x: $0, y: y) != frame.foreground }
        }, "the block cursor must not erase its glyph")
        let hollow = try renderer.rasterize(frame, width: image.width, height: image.height,
            scale: 1, focused: false)
        let noCursor = try renderer.rasterize(frame, width: image.width, height: image.height,
            scale: 1, drawCursor: false)
        XCTAssertEqual(hollow.pixel(x: metrics.cellWidth / 2, y: metrics.cellHeight / 2),
            noCursor.pixel(x: metrics.cellWidth / 2, y: metrics.cellHeight / 2))
    }

    func testWideFallbackAndLongGraphemesRemainClippedAcrossRecreation() throws {
        let renderer = try renderer()
        let engine = try GhosttyTerminalEngine(columns: 10, rows: 3)
        _ = try engine.receive(Data(("中👩‍💻a" + String(repeating: "\u{301}", count: 64)).utf8))
        let frame = try engine.snapshot()
        let metrics = try renderer.metrics(scale: 1)
        let glyphs = try renderer.layout(row: frame.cells[0], scale: 1)
        XCTAssertFalse(glyphs.isEmpty)
        XCTAssertTrue(glyphs.allSatisfy { $0.id != 0 }, "installed fallback fonts should resolve these characters")
        for scale: Float in [1, 1.5, 2, 1] {
            let image = try renderer.rasterize(frame, width: metrics.cellWidth * 10,
                height: metrics.cellHeight * 3, scale: scale, drawCursor: false)
            XCTAssertEqual(image.bytes.count, image.width * image.height * 4)
            XCTAssertEqual(image.pixel(x: image.width - 1, y: image.height - 1), frame.background)
        }
    }

    static let allTests = [
        ("testLatinPromptDoesNotPreventArabicJoining", testLatinPromptDoesNotPreventArabicJoining),
        ("testBackgroundsUseExactTerminalGridCoordinates", testBackgroundsUseExactTerminalGridCoordinates),
        ("testTextRendersAndClearedRowsDoNotRetainOldGlyphs", testTextRendersAndClearedRowsDoNotRetainOldGlyphs),
        ("testFractionalScaleAndInvalidDimensions", testFractionalScaleAndInvalidDimensions),
        ("testSelectionAndDecorationsArePaintedOnTheGrid", testSelectionAndDecorationsArePaintedOnTheGrid),
        ("testBeamAndUnderlineCursorsDoNotBecomeSolidBlocks", testBeamAndUnderlineCursorsDoNotBecomeSolidBlocks),
        ("testContextualShapingUsesNeighborCellsAndGridClusters", testContextualShapingUsesNeighborCellsAndGridClusters),
        ("testBlockCursorKeepsItsGlyphReadableAndUnfocusedCursorIsHollow", testBlockCursorKeepsItsGlyphReadableAndUnfocusedCursorIsHollow),
        ("testWideFallbackAndLongGraphemesRemainClippedAcrossRecreation", testWideFallbackAndLongGraphemesRemainClippedAcrossRecreation),
    ]
}

private extension SkiaTerminalImage {
    func pixel(x: Int, y: Int) -> UInt32 {
        let offset = (y * width + x) * 4
        return UInt32(bytes[offset + 3]) << 24 | UInt32(bytes[offset]) << 16
            | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
    }
}
