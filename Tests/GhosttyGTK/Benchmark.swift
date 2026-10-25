import Foundation
import Glibc
import CGTK
import CVTE

/// Private-display, same-process comparison of the actual widgets. Measures
/// ingestion through final visible output and a subsequent frame, not hardware
/// GPU performance or sustained PTY/SSH throughput.
@main struct TerminalBenchmark {
    static func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
    static func main() throws {
        guard ProcessInfo.processInfo.environment["DEVSPACE_PRIVATE_KEY_TEST"] == "1" else {
            fail("benchmark requires an explicitly private display")
        }
        gtk_init()
        let window = gtk_window_new()!
        let native = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        let stackWidget = gtk_stack_new()!
        let stack = OpaquePointer(stackWidget)
        let ghostty = try GhosttyTerminalView(forceRaster: true)
        let vteWidget = vte_terminal_new()!
        let vte = UnsafeMutableRawPointer(vteWidget).assumingMemoryBound(to: VteTerminal.self)
        let font = pango_font_description_from_string("monospace")!
        pango_font_description_set_absolute_size(font, 14 * 1024)
        vte_terminal_set_font(vte, font)
        pango_font_description_free(font)
        vte_terminal_set_scrollback_lines(vte, 10_000)
        gtk_stack_add_named(stack, ghostty.widget, "ghostty")
        gtk_stack_add_named(stack, vteWidget, "vte")
        gtk_window_set_child(native, stackWidget)
        gtk_window_set_default_size(native, 720, 408)
        gtk_window_present(native)
        defer { ghostty.dispose(); gtk_window_destroy(native) }
        func pump() { while g_main_context_iteration(nil, 0) != 0 {} ; usleep(1_000) }
        for _ in 0..<80 { pump() }
        let line = "\u{1b}[38;2;128;180;220m0123456789 abcdefghijklmnopqrstuvwxyz e\u{301} 界\u{1b}[0m\r\n"
        let data = Data((String(repeating: line, count: 4_000) + "BENCHMARK_END\r\n").utf8)
        var results: [String: [Double]] = [:]
        var geometry: [String: [Int]] = [:]
        for renderer in ["vte", "ghostty"] {
            gtk_stack_set_visible_child_name(stack, renderer)
            for _ in 0..<80 { pump() }
            ghostty.refresh()
            // Derive the experimental cell size from the allocated grid rather
            // than assuming a particular installed monospace font. The exact
            // 80x24 check below rejects any nonmatching allocation.
            let cellWidth = renderer == "vte" ? Int(vte_terminal_get_char_width(vte))
                : Int(gtk_widget_get_width(ghostty.widget)) / Int(ghostty.grid.columns)
            let cellHeight = renderer == "vte" ? Int(vte_terminal_get_char_height(vte))
                : Int(gtk_widget_get_height(ghostty.widget)) / Int(ghostty.grid.rows)
            gtk_window_set_default_size(native, Int32(cellWidth * 80), Int32(cellHeight * 24))
            for _ in 0..<80 { ghostty.refresh(); pump() }
            var columns = renderer == "vte" ? Int(vte_terminal_get_column_count(vte)) : Int(ghostty.grid.columns)
            var rows = renderer == "vte" ? Int(vte_terminal_get_row_count(vte)) : Int(ghostty.grid.rows)
            let widget = renderer == "vte" ? vteWidget : ghostty.widget
            // Account for actual theme padding instead of assuming zero insets.
            for _ in 0..<4 where columns != 80 || rows != 24 {
                gtk_window_set_default_size(native,
                    gtk_widget_get_width(widget) + Int32((80 - columns) * cellWidth),
                    gtk_widget_get_height(widget) + Int32((24 - rows) * cellHeight))
                for _ in 0..<80 { ghostty.refresh(); pump() }
                columns = renderer == "vte" ? Int(vte_terminal_get_column_count(vte)) : Int(ghostty.grid.columns)
                rows = renderer == "vte" ? Int(vte_terminal_get_row_count(vte)) : Int(ghostty.grid.rows)
            }
            guard columns == 80, rows == 24 else { fail("unequal benchmark grid: \(renderer) \(columns)x\(rows)") }
            geometry[renderer] = [columns, rows, cellWidth, cellHeight]
            for trial in 0..<10 {
                if renderer == "vte" { vte_terminal_reset(vte, 1, 1) }
                else { try ghostty.receive(Data("\u{1b}c".utf8)) }
                let start = ProcessInfo.processInfo.systemUptime
                if renderer == "vte" {
                    data.withUnsafeBytes { vte_terminal_feed(vte, $0.bindMemory(to: CChar.self).baseAddress, data.count) }
                } else { try ghostty.receive(data) }
                var visible = false
                while ProcessInfo.processInfo.systemUptime - start < 10 {
                    ghostty.refresh()
                    pump()
                    if renderer == "vte", let text = vte_terminal_get_text_format(vte, VTE_FORMAT_TEXT) {
                        visible = String(cString: text).contains("BENCHMARK_END")
                        g_free(text)
                    } else if renderer == "ghostty" { visible = ghostty.text.contains("BENCHMARK_END") }
                    if visible { break }
                }
                guard visible, let clock = gtk_widget_get_frame_clock(widget) else { fail("benchmark output timeout") }
                let frame = gdk_frame_clock_get_frame_counter(clock)
                while gdk_frame_clock_get_frame_counter(clock) <= frame {
                    gtk_widget_queue_draw(widget)
                    pump()
                    guard ProcessInfo.processInfo.systemUptime - start < 10 else { fail("benchmark paint timeout") }
                }
                if trial > 0 { results[renderer, default: []].append((ProcessInfo.processInfo.systemUptime - start) * 1_000) }
            }
        }
        let report: [String: Any] = ["benchmark": "4000 styled Unicode lines, parse-to-next-frame",
            "font": "monospace 14px", "path": "private X11; Ghostty Skia raster; system GTK/VTE",
            "payload_bytes": data.count, "grid_and_cell_pixels": geometry, "milliseconds": results,
            "median_milliseconds": results.mapValues { $0.sorted()[$0.count / 2] }]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
