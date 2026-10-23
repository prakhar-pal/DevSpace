import Foundation
import CSkia
import CHarfBuzz

struct ShapedTerminalGlyph {
    let id: UInt16
    let cluster: UInt32
    let advance: Float
    let offsetX: Float
    let offsetY: Float
}

/// Shapes with Skia's own typeface tables, so glyph IDs agree with the SkFont
/// that draws them. HarfBuzz owns copies of tables and releases the retained
/// Swift context when the final face reference is destroyed.
final class SkiaShapingFont {
    let typeface: SkiaTypeface
    let font: SkFont
    private let shapingFont: OpaquePointer

    init(typeface: SkiaTypeface, pixels: Float) throws {
        self.typeface = typeface
        self.font = SkFont(typeface, pixels)
        let tables = TypefaceTables(typeface)
        let face = hb_face_create_for_tables({ _, tag, userdata in
            guard let userdata else { return hb_blob_get_empty() }
            let tables = Unmanaged<TypefaceTables>.fromOpaque(userdata).takeUnretainedValue()
            guard let typeface = tables.owner.get() else { return hb_blob_get_empty() }
            let count = typeface.getTableSize(tag)
            guard count > 0, count <= UInt32.max else { return hb_blob_get_empty() }
            let memory = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
            defer { memory.deallocate() }
            guard typeface.getTableData(tag, 0, count, memory) == count else { return hb_blob_get_empty() }
            return hb_blob_create(memory.assumingMemoryBound(to: CChar.self), UInt32(count),
                HB_MEMORY_MODE_DUPLICATE, nil, nil)
        }, Unmanaged.passRetained(tables).toOpaque(), { userdata in
            if let userdata { Unmanaged<TypefaceTables>.fromOpaque(userdata).release() }
        })!
        shapingFont = hb_font_create(face)!
        hb_face_destroy(face)
        hb_ot_font_set_funcs(shapingFont)
        let scale = Int32((pixels * 64).rounded())
        hb_font_set_scale(shapingFont, scale, scale)
    }

    deinit { hb_font_destroy(shapingFont) }

    func shape(_ text: String) throws -> [ShapedTerminalGlyph] {
        guard text.utf8.count <= Int32.max else { throw SkiaTerminalRendererError.invalidSize }
        let buffer = hb_buffer_create()!
        defer { hb_buffer_destroy(buffer) }
        text.withCString { hb_buffer_add_utf8(buffer, $0, Int32(text.utf8.count), 0, Int32(text.utf8.count)) }
        hb_buffer_guess_segment_properties(buffer)
        hb_shape(shapingFont, buffer, nil, 0)
        guard hb_buffer_allocation_successful(buffer) != 0 else { throw SkiaTerminalRendererError.allocationFailed }
        var count: UInt32 = 0
        guard let infos = hb_buffer_get_glyph_infos(buffer, &count),
              let positions = hb_buffer_get_glyph_positions(buffer, nil) else { return [] }
        return (0..<Int(count)).map { index in
            let info = infos[index]
            let position = positions[index]
            return ShapedTerminalGlyph(id: UInt16(exactly: info.codepoint) ?? 0, cluster: info.cluster,
                advance: Float(position.x_advance) / 64,
                offsetX: Float(position.x_offset) / 64, offsetY: -Float(position.y_offset) / 64)
        }
    }
}

private final class TypefaceTables {
    let owner: SkiaTypeface
    init(_ owner: SkiaTypeface) { self.owner = owner }
}
