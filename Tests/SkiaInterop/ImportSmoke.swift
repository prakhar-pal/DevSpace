// Compile-only M01 gate against real, unmodified Skia headers. This does not
// establish runtime ownership, GPU presentation or pixel correctness.
import CSkia

func rasterDrawingImports() {
    let info = SkImageInfo.MakeN32Premul(64, 32)
    let surface = SkSurfaces.Raster(info, 0, nil)
    guard let pointer = surface.get(), let canvas = pointer.getCanvas() else {
        return
    }
    withExtendedLifetime(surface) {
        canvas.clear(0xff102030)
        var paint = SkPaint()
        paint.setColor(0xffabcdef)
        let rectangle = SkRect.MakeXYWH(1, 2, 10, 12)
        canvas.drawRect(rectangle, paint)
        textDrawingImports(canvas)
    }
}

func gpuContextImports() {
    var context = GrDirectContexts.MakeGL()
    guard let pointer = context.get() else { return }
    withExtendedLifetime(context) { _ = pointer.flushAndSubmit() }
    context.reset()
}

func textDrawingImports(_ canvas: SkCanvas) {
    let font = SkFont()
    let paint = SkPaint()
    "Ghostty".withCString { text in
        canvas.drawSimpleText(text, 7, SkTextEncoding.kUTF8, 0, 16, font, paint)
    }
}
