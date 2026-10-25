import CSkia

// The exact same Swift drawing runs on raster and GPU surfaces. Expected
// pixels are independently specified by each test, not derived here.
func drawAcceptanceSample(on canvas: SkCanvas) {
    canvas.clear(0xff102030)
    var paint = SkPaint()
    paint.setColor(0xffabcdef)
    canvas.drawRect(SkRect.MakeXYWH(2, 3, 10, 8), paint)
}
