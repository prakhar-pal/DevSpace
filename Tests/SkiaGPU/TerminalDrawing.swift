import Foundation
import CSkia
import DevSpaceGhosttyVT
import DevSpaceSkiaRenderer

// Run the portable renderer on the actual GTK framebuffer, with independently
// asserted pixels in GPUSmoke. No alternate test-only drawing implementation.
func drawAcceptanceSample(on canvas: SkCanvas) {
    do {
        let engine = try GhosttyTerminalEngine(columns: 20, rows: 6)
        _ = try engine.receive(Data(("\u{1b}]11;#102030\u{7}"
            + "\u{1b}[48;2;171;205;239m  \u{1b}[0m\r\n"
            + "Swift بب 中 👩‍💻\r\n\u{1b}[4mSkia\u{1b}[0m").utf8))
        let managerOwner = SkFontMgr_New_FontConfig(nil, SkFontScanner_Make_FreeType())
        guard let manager = managerOwner.get() else { fatalError("font manager unavailable") }
        try withExtendedLifetime(managerOwner) {
            let renderer = try SkiaTerminalRenderer(fontManager: manager)
            let frame = try engine.snapshot()
            precondition(frame.background == 0xff102030, "unexpected native terminal background: \(String(frame.background, radix: 16))")
            try renderer.draw(frame, on: canvas, scale: 1, drawCursor: false)
        }
    } catch { fatalError("terminal GPU drawing failed: \(error)") }
}
