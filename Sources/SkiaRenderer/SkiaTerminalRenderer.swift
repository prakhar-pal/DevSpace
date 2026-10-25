import Foundation
import CSkia
import DevSpaceGhosttyVT

public enum SkiaTerminalRendererError: Error {
    case invalidSize
    case fontUnavailable
    case allocationFailed
}

public struct SkiaTerminalMetrics {
    public let cellWidth: Int
    public let cellHeight: Int
    public let baseline: Float
}

public struct SkiaTerminalImage {
    public let width: Int
    public let height: Int
    /// RGBA8888 premultiplied pixels, tightly packed.
    public let bytes: Data
}

/// Serial-use drawing component with no windowing, GTK, clipboard or PTY code.
/// A platform supplies its font manager and, for GPU rendering, its SkCanvas.
public final class SkiaTerminalRenderer {
    private let manager: SkiaFontManager
    private let family: String
    private let fontSize: Float
    private var fonts: [FontKey: SkiaShapingFont] = [:]
    private var requests: [FontRequest: SkiaShapingFont] = [:]
    private var raster: SkiaSurface?
    private var rasterWidth = 0
    private var rasterHeight = 0
    private var rowCache: [Int: CachedTerminalRow] = [:]
    private var cachedScale: Float = 0

    public init(fontManager: SkFontMgr, fontFamily: String = "monospace", fontSize: Float = 14) throws {
        guard fontSize.isFinite, fontSize > 0 else { throw SkiaTerminalRendererError.invalidSize }
        // Keep C++ templates private to this module: Swift currently fails to
        // deserialize this initializer when it exposes sk_sp<SkFontMgr>.
        // The caller lends a pointer; acquire exactly one native reference,
        // then let sk_sp release it with the renderer's lifetime.
        fontManager.ref()
        self.manager = SkiaFontManager(fontManager)
        self.family = fontFamily
        self.fontSize = fontSize
    }

    public func metrics(scale: Float) throws -> SkiaTerminalMetrics {
        let base = try resolvedFont(text: "M", bold: false, italic: false, scale: scale)
        var metrics = SkFontMetrics()
        _ = base.font.getMetrics(&metrics)
        let advance = "M".withCString { base.font.measureText($0, 1, SkTextEncoding.kUTF8, nil) }
        let width = ceil(advance)
        let height = ceil(metrics.fDescent - metrics.fAscent + max(0, metrics.fLeading))
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width < Float(Int32.max), height < Float(Int32.max) else { throw SkiaTerminalRendererError.invalidSize }
        return SkiaTerminalMetrics(cellWidth: Int(width), cellHeight: Int(height), baseline: ceil(-metrics.fAscent))
    }

    public func rasterize(_ frame: GhosttyTerminalFrame, width: Int, height: Int, scale: Float,
                          drawCursor: Bool = true, focused: Bool = true, blinkVisible: Bool = true) throws -> SkiaTerminalImage {
        guard width > 0, height > 0, width <= Int32.max, height <= Int32.max,
              width <= Int.max / 4 / height else { throw SkiaTerminalRendererError.invalidSize }
        let info = SkImageInfo.Make(Int32(width), Int32(height), kRGBA_8888_SkColorType,
                                   kPremul_SkAlphaType, SkiaColorSpace())
        if raster == nil || rasterWidth != width || rasterHeight != height {
            raster = SkSurfaces.Raster(info, 0, nil)
            rasterWidth = width
            rasterHeight = height
        }
        guard let owner = raster, let surface = owner.get(), let canvas = surface.getCanvas() else {
            throw SkiaTerminalRendererError.allocationFailed
        }
        return try withExtendedLifetime(owner) {
            try draw(frame, on: canvas, scale: scale, drawCursor: drawCursor,
                     focused: focused, blinkVisible: blinkVisible)
            var bytes = Data(count: width * height * 4)
            guard bytes.withUnsafeMutableBytes({ surface.readPixels(info, $0.baseAddress, width * 4, 0, 0) }) else {
                throw SkiaTerminalRendererError.allocationFailed
            }
            return SkiaTerminalImage(width: width, height: height, bytes: bytes)
        }
    }

    public func draw(_ frame: GhosttyTerminalFrame, on canvas: SkCanvas, scale: Float,
                     drawCursor: Bool = true, focused: Bool = true, blinkVisible: Bool = true) throws {
        let metrics = try metrics(scale: scale)
        if cachedScale != scale { rowCache.removeAll(keepingCapacity: true); cachedScale = scale }
        rowCache = rowCache.filter { $0.key < frame.cells.count }
        canvas.clear(frame.background)
        var paint = SkPaint()
        for (rowIndex, row) in frame.cells.enumerated() {
            for (column, cell) in row.enumerated() {
                paint.setColor(cell.inverse != cell.selected ? cell.foreground : cell.background)
                canvas.drawRect(SkRect.MakeXYWH(Float(column * metrics.cellWidth), Float(rowIndex * metrics.cellHeight),
                    Float(metrics.cellWidth), Float(metrics.cellHeight)), paint)
            }
        }
        for (rowIndex, row) in frame.cells.enumerated() {
            let glyphs = try preparedRow(row, index: rowIndex, scale: scale)
            for glyph in glyphs {
                // Clip each covered cell independently so selection/color changes
                // can bisect a ligature without breaking contextual shaping.
                for column in glyph.column..<min(row.count, glyph.column + glyph.columns) {
                    let cell = row[column]
                    if cell.invisible || (cell.blink && !blinkVisible) { continue }
                    paint.setColor(cell.inverse != cell.selected ? cell.background : cell.foreground)
                    if cell.faint { paint.setAlphaf(0.5) }
                    _ = canvas.save()
                    canvas.clipRect(SkRect.MakeXYWH(Float(column * metrics.cellWidth), Float(rowIndex * metrics.cellHeight),
                        Float(metrics.cellWidth), Float(metrics.cellHeight)), false)
                    var id = glyph.id
                    withUnsafePointer(to: &id) {
                        canvas.drawSimpleText($0, 2, SkTextEncoding.kGlyphID, glyph.x,
                            Float(rowIndex * metrics.cellHeight) + metrics.baseline + glyph.y, glyph.font.font, paint)
                    }
                    canvas.restore()
                }
            }
            for (column, cell) in row.enumerated() {
                if cell.invisible || (cell.blink && !blinkVisible) { continue }
                paint.setColor(cell.inverse != cell.selected ? cell.background : cell.foreground)
                if cell.faint { paint.setAlphaf(0.5) }
                let x = Float(column * metrics.cellWidth)
                let y = Float(rowIndex * metrics.cellHeight)
                let thickness = max(1, scale)
                func line(_ offset: Float) {
                    canvas.drawRect(SkRect.MakeXYWH(x, y + offset, Float(metrics.cellWidth), thickness), paint)
                }
                if cell.underline != 0 { line(min(Float(metrics.cellHeight) - thickness, metrics.baseline + thickness)) }
                if cell.underline == 2 { line(Float(metrics.cellHeight) - thickness * 3) }
                if cell.strikethrough { line(metrics.baseline * 0.6) }
                if cell.overline { line(0) }
            }
        }
        if drawCursor, let cursor = frame.cursor, cursor.visible,
           !focused || !cursor.blinking || blinkVisible,
           frame.cells.indices.contains(cursor.row), frame.cells[cursor.row].indices.contains(cursor.column) {
            paint.setColor(frame.foreground)
            let x = Float(cursor.column * metrics.cellWidth)
            let y = Float(cursor.row * metrics.cellHeight)
            let thickness = max(1, scale)
            let cell = frame.cells[cursor.row][cursor.column]
            let width = Float(max(1, cell.width) * metrics.cellWidth)
            switch focused ? cursor.style : 3 {
            case 0:
                canvas.drawRect(SkRect.MakeXYWH(x, y, thickness, Float(metrics.cellHeight)), paint)
            case 2:
                canvas.drawRect(SkRect.MakeXYWH(x, y + Float(metrics.cellHeight) - thickness,
                    width, thickness), paint)
            case 3:
                canvas.drawRect(SkRect.MakeXYWH(x, y, width, thickness), paint)
                canvas.drawRect(SkRect.MakeXYWH(x, y + Float(metrics.cellHeight) - thickness, width, thickness), paint)
                canvas.drawRect(SkRect.MakeXYWH(x, y, thickness, Float(metrics.cellHeight)), paint)
                canvas.drawRect(SkRect.MakeXYWH(x + width - thickness, y, thickness, Float(metrics.cellHeight)), paint)
            default:
                let rectangle = SkRect.MakeXYWH(x, y, width, Float(metrics.cellHeight))
                canvas.drawRect(rectangle, paint)
                // Redraw shaped glyphs through the block, including ligatures
                // that start before the cursor cell.
                paint.setColor(frame.background)
                _ = canvas.save()
                canvas.clipRect(rectangle, false)
                for glyph in try preparedRow(frame.cells[cursor.row], index: cursor.row, scale: scale)
                    where glyph.column <= cursor.column && glyph.column + glyph.columns > cursor.column && !cell.invisible {
                    var id = glyph.id
                    withUnsafePointer(to: &id) {
                        canvas.drawSimpleText($0, 2, SkTextEncoding.kGlyphID, glyph.x,
                            y + metrics.baseline + glyph.y, glyph.font.font, paint)
                    }
                }
                canvas.restore()
            }
        }
    }

    private func preparedRow(_ row: [GhosttyTerminalCell], index: Int, scale: Float) throws -> [TerminalGlyph] {
        if let cached = rowCache[index], cached.cells == row { return cached.glyphs }
        let glyphs = try layout(row: row, scale: scale)
        // Bound retained native font/glyph resources even for pathological
        // terminal sizes. Rows outside this budget are shaped without caching.
        if index < 128 && row.count <= 512 {
            rowCache[index] = CachedTerminalRow(cells: row, glyphs: glyphs)
        } else { rowCache.removeValue(forKey: index) }
        return glyphs
    }

    /// Shape neighboring cells together, then anchor each HarfBuzz cluster to
    /// the terminal grid. The terminal owns column order; this is not a bidi
    /// paragraph layout. Wide-cell tails never add a second glyph.
    func layout(row: [GhosttyTerminalCell], scale: Float) throws -> [TerminalGlyph] {
        let metrics = try metrics(scale: scale)
        var result: [TerminalGlyph] = []
        var runText = ""
        var runFont: SkiaShapingFont?
        var runScript: UInt32?
        var starts: [(offset: Int, column: Int)] = []
        var endColumn = 0
        func flush() throws {
            guard let font = runFont, !starts.isEmpty else { return }
            let glyphs = try font.shape(runText)
            let clusters = Array(Set(glyphs.map { Int($0.cluster) })).sorted()
            var spans: [Int: (column: Int, columns: Int)] = [:]
            var startIndex = 0
            for (index, cluster) in clusters.enumerated() {
                while startIndex + 1 < starts.count && starts[startIndex + 1].offset <= cluster { startIndex += 1 }
                let column = starts[startIndex].column
                var next = startIndex + 1
                let nextCluster = index + 1 < clusters.count ? clusters[index + 1] : runText.utf8.count
                while next < starts.count && starts[next].offset < nextCluster { next += 1 }
                let limit = next < starts.count ? starts[next].column : endColumn
                spans[cluster] = (column, max(1, limit - column))
            }
            var advances: [Int: Float] = [:]
            for glyph in glyphs {
                let cluster = Int(glyph.cluster)
                guard let span = spans[cluster] else { continue }
                result.append(TerminalGlyph(id: glyph.id, column: span.column, columns: span.columns,
                    x: Float(span.column * metrics.cellWidth) + advances[cluster, default: 0] + glyph.offsetX,
                    y: glyph.offsetY, font: font))
                advances[cluster, default: 0] += glyph.advance
            }
            starts.removeAll(keepingCapacity: true)
            runText = ""
            runFont = nil
            runScript = nil
        }
        for (column, cell) in row.enumerated() where cell.width > 0 {
            if cell.text.isEmpty { try flush(); continue }
            let font = try resolvedFont(text: cell.text, bold: cell.bold, italic: cell.italic, scale: scale)
            if let previous = runFont, previous !== font { try flush() }
            let script = SkiaShapingFont.scriptTag(cell.text)
            if let previous = runScript, let script, previous != script { try flush() }
            runFont = font
            if let script { runScript = script }
            starts.append((runText.utf8.count, column))
            runText += cell.text
            endColumn = column + cell.width
        }
        try flush()
        return result
    }

    func resolvedFont(text: String, bold: Bool, italic: Bool, scale: Float) throws -> SkiaShapingFont {
        let pixels = fontSize * scale
        guard scale.isFinite, scale > 0, pixels.isFinite, pixels > 0,
              pixels < Float(Int32.max) / 64 else { throw SkiaTerminalRendererError.invalidSize }
        let request = FontRequest(text: text, bold: bold, italic: italic, pixels: pixels)
        if let cached = requests[request] { return cached }
        guard let manager = manager.get() else { throw SkiaTerminalRendererError.fontUnavailable }
        let style = bold ? (italic ? SkFontStyle.BoldItalic() : SkFontStyle.Bold())
                         : (italic ? SkFontStyle.Italic() : SkFontStyle.Normal())
        var owner = family.withCString { manager.matchFamilyStyle($0, style) }
        guard owner.get() != nil else { throw SkiaTerminalRendererError.fontUnavailable }
        for scalar in text.unicodeScalars where scalar.value != 0x200d && !(0xfe00...0xfe0f).contains(scalar.value) {
            if owner.get()!.unicharToGlyph(Int32(scalar.value)) == 0 {
                let fallback = family.withCString { manager.matchFamilyStyleCharacter($0, style, nil, 0, Int32(scalar.value)) }
                if fallback.get() != nil { owner = fallback }
            }
        }
        let key = FontKey(id: owner.get()!.uniqueID(), pixels: pixels)
        let resolved: SkiaShapingFont
        if let cached = fonts[key] { resolved = cached }
        else {
            resolved = try SkiaShapingFont(typeface: owner, pixels: pixels)
            if fonts.count >= 64 { fonts.removeAll(keepingCapacity: true) }
            fonts[key] = resolved
        }
        if requests.count >= 512 { requests.removeAll(keepingCapacity: true) }
        requests[request] = resolved
        return resolved
    }
}

struct TerminalGlyph {
    let id: UInt16
    let column: Int
    let columns: Int
    let x: Float
    let y: Float
    let font: SkiaShapingFont
}

private struct CachedTerminalRow {
    let cells: [GhosttyTerminalCell]
    let glyphs: [TerminalGlyph]
}

private struct FontKey: Hashable { let id: UInt32; let pixels: Float }
private struct FontRequest: Hashable { let text: String; let bold: Bool; let italic: Bool; let pixels: Float }
