// Run against a real linked Skia library. No GTK and no C++ implementation shim.
import CSkia

@main
struct RasterSmoke {
    static func main() {
        // Exercise repeated destruction and differently sized raster surfaces.
        for index in 0..<64 { verifySurface(width: Int32(32 + index), height: 24) }
        verifyFontRendering()
        print("Skia raster pixels, sk_sp copy/reset and repeated surface disposal passed")
    }

    private static func verifySurface(width: Int32, height: Int32) {
        let info = SkImageInfo.MakeN32Premul(width, height)
        var owner = SkSurfaces.Raster(info, 0, nil)
        guard let surface = owner.get(), let canvas = surface.getCanvas() else {
            fatalError("Could not create a real Skia raster surface")
        }
        precondition(surface.unique(), "Fresh surface must have exactly one owner")
        var secondOwner = owner
        precondition(!surface.unique(), "Copying sk_sp must retain the surface")
        secondOwner.reset()
        precondition(surface.unique(), "Resetting the copy must release its reference")
        withExtendedLifetime(owner) {
            drawAcceptanceSample(on: canvas)

            var pixels = [UInt32](repeating: 0, count: Int(width * height))
            let read = pixels.withUnsafeMutableBytes { bytes in
                surface.readPixels(info, bytes.baseAddress, Int(width) * 4, 0, 0)
            }
            precondition(read, "Raster readback failed")
            precondition(pixels[0] == 0xff102030, "Canvas clear did not reach the pixels")
            precondition(pixels[4 * Int(width) + 3] == 0xffabcdef, "Rectangle was not drawn")
            precondition(pixels[pixels.count - 1] == 0xff102030, "Drawing escaped rectangle bounds")
        }
        owner.reset()
        precondition(owner.get() == nil, "Reset owner retained its old surface")
    }

    private static func verifyFontRendering() {
        let managerOwner = SkFontMgr_New_FontConfig(nil, SkFontScanner_Make_FreeType())
        guard let manager = managerOwner.get() else { fatalError("No system font manager") }
        withExtendedLifetime(managerOwner) {
            let faceOwner = "monospace".withCString { manager.matchFamilyStyle($0, SkFontStyle()) }
            precondition(faceOwner.get() != nil, "Could not resolve a system monospace font")
            let font = SkFont(faceOwner, 16)
            let info = SkImageInfo.MakeN32Premul(128, 32)
            let owner = SkSurfaces.Raster(info, 0, nil)
            guard let surface = owner.get(), let canvas = surface.getCanvas() else { fatalError("No text surface") }
            withExtendedLifetime((owner, faceOwner)) {
                canvas.clear(0xff000000)
                var paint = SkPaint()
                paint.setColor(0xffffffff)
                "Ghostty".withCString { canvas.drawSimpleText($0, 7, SkTextEncoding.kUTF8, 2, 22, font, paint) }
                var pixels = [UInt32](repeating: 0, count: 128 * 32)
                precondition(pixels.withUnsafeMutableBytes {
                    surface.readPixels(info, $0.baseAddress, 128 * 4, 0, 0)
                })
                precondition(pixels.contains(where: { $0 != 0xff000000 }), "Resolved font drew no glyphs")
            }
        }
        print("Skia Fontconfig/FreeType glyph rendering passed")
    }
}
