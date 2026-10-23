import Foundation
import CGhosttyVT

public enum GhosttyTerminalEvent: Equatable {
    case firstOutput
    case writePTY(Data)
    case directory(String?)
    case exited(Int32)
}

public enum GhosttyTerminalError: Error {
    case invalidSize
    case closed
    case finished
    case unsafePaste
    case native(Int32)
}

/// UI-independent terminal state. The host continues to own the PTY. All C
/// access is serialized; borrowed native data never escapes an operation.
/// Events are returned only after parsing finishes, never via reentrant user
/// callbacks. A host must deliver events in order to its existing input queue.
public final class GhosttyTerminalEngine {
    private let lock = NSLock()
    private var terminal: GhosttyTerminal?
    private var pendingEvents: [GhosttyTerminalEvent] = []
    private var hasOutput = false
    var finished = false
    var revision: UInt64 = 0
    var renderState: GhosttyRenderState?
    var mouseEncoder: GhosttyMouseEncoder?
    var renderHeld = false
    private var holdStartedAt: UInt64?
    private var pendingNativeFailure: GhosttyResult?
    private let nowNanoseconds: () -> UInt64

    public convenience init(columns: UInt16 = 80, rows: UInt16 = 24, scrollback: Int = 10_000) throws {
        try self.init(columns: columns, rows: rows, scrollback: scrollback,
                      nowNanoseconds: { DispatchTime.now().uptimeNanoseconds })
    }

    init(columns: UInt16, rows: UInt16, scrollback: Int = 10_000,
         nowNanoseconds: @escaping () -> UInt64) throws {
        self.nowNanoseconds = nowNanoseconds
        guard columns > 0, rows > 0, scrollback >= 0 else { throw GhosttyTerminalError.invalidSize }
        try Self.check(ghostty_terminal_new(nil, &terminal, columns, rows))
        do {
            guard let terminal else { throw GhosttyTerminalError.closed }
            try Self.check(ghostty_render_state_new(nil, &renderState))
            var limit = scrollback
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &limit))
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA,
                Unmanaged.passUnretained(self).toOpaque()))
            let write: GhosttyTerminalWritePtyFn = { _, userdata, bytes, count in
                guard let userdata, let bytes, count > 0 else { return }
                let engine = Unmanaged<GhosttyTerminalEngine>.fromOpaque(userdata).takeUnretainedValue()
                engine.pendingEvents.append(.writePTY(Data(bytes: bytes, count: count)))
            }
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                unsafeBitCast(write, to: UnsafeRawPointer.self)))
            let directory: GhosttyTerminalPwdChangedFn = { _, userdata in
                guard let userdata else { return }
                let engine = Unmanaged<GhosttyTerminalEngine>.fromOpaque(userdata).takeUnretainedValue()
                engine.pendingEvents.append(.directory(engine.readDirectory()))
            }
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED,
                unsafeBitCast(directory, to: UnsafeRawPointer.self)))
            let hold: GhosttyTerminalRenderHoldFn = { terminal, userdata, held in
                guard let userdata else { return }
                let engine = Unmanaged<GhosttyTerminalEngine>.fromOpaque(userdata).takeUnretainedValue()
                if held, let state = engine.renderState {
                    let result = ghostty_render_state_update(state, terminal)
                    if result != GHOSTTY_SUCCESS { engine.pendingNativeFailure = result }
                    engine.holdStartedAt = engine.nowNanoseconds()
                } else { engine.holdStartedAt = nil }
                engine.renderHeld = held
            }
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD,
                unsafeBitCast(hold, to: UnsafeRawPointer.self)))
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    public func receive(_ bytes: Data) throws -> [GhosttyTerminalEvent] {
        lock.lock()
        defer { lock.unlock() }
        let terminal = try openTerminal()
        guard !finished else { throw GhosttyTerminalError.finished }
        revision &+= 1
        bytes.withUnsafeBytes { buffer in
            ghostty_terminal_vt_write(terminal, buffer.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        if let pendingNativeFailure { try Self.check(pendingNativeFailure) }
        if !hasOutput, try !formattedText(terminal).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hasOutput = true
            pendingEvents.append(.firstOutput)
        }
        return takeEvents()
    }

    public func text() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return try formattedText(openTerminal())
    }

    @discardableResult
    public func resize(columns: UInt16, rows: UInt16, cellWidth: UInt32 = 0, cellHeight: UInt32 = 0) throws -> [GhosttyTerminalEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard columns > 0, rows > 0 else { throw GhosttyTerminalError.invalidSize }
        try Self.check(ghostty_terminal_resize(openTerminal(), columns, rows, cellWidth, cellHeight))
        revision &+= 1
        return takeEvents()
    }

    /// Ingestion is synchronous: every previously received byte is already in
    /// terminal state when this returns. No VTE-specific drain marker is needed.
    public func finish(exitCode: Int32) throws -> [GhosttyTerminalEvent] {
        lock.lock()
        defer { lock.unlock() }
        let terminal = try openTerminal()
        guard !finished else { return [] }
        if renderHeld { try releaseRenderHold(terminal) }
        finished = true
        return [.exited(exitCode)]
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard let terminal else { return }
        self.terminal = nil
        if let renderState { ghostty_render_state_free(renderState); self.renderState = nil }
        if let mouseEncoder { ghostty_mouse_encoder_free(mouseEncoder); self.mouseEncoder = nil }
        ghostty_terminal_free(terminal)
        pendingEvents.removeAll()
    }

    private func openTerminal() throws -> GhosttyTerminal {
        guard let terminal else { throw GhosttyTerminalError.closed }
        if let pendingNativeFailure { try Self.check(pendingNativeFailure) }
        return terminal
    }

    func releaseExpiredRenderHold(_ terminal: GhosttyTerminal) throws {
        guard renderHeld, let holdStartedAt else { return }
        let now = nowNanoseconds()
        if now >= holdStartedAt, now - holdStartedAt >= 1_000_000_000 {
            try releaseRenderHold(terminal)
        }
    }

    private func releaseRenderHold(_ terminal: GhosttyTerminal) throws {
        var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &mode))
        renderHeld = false
        holdStartedAt = nil
        revision &+= 1
    }

    func formattedText(_ terminal: GhosttyTerminal, selection: UnsafePointer<GhosttySelection>? = nil) throws -> String {
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.trim = true
        options.unwrap = selection != nil
        options.selection = selection
        var handle: GhosttyFormatter?
        try Self.check(ghostty_formatter_terminal_new(nil, &handle, terminal, options))
        guard let handle else { throw GhosttyTerminalError.closed }
        defer { ghostty_formatter_free(handle) }
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        try Self.check(ghostty_formatter_format_alloc(handle, nil, &bytes, &count))
        guard let bytes else { return "" }
        defer { ghostty_free(nil, bytes, count) }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    // Called by the native parser while the operation lock is already held.
    private func readDirectory() -> String? {
        guard let terminal else { return nil }
        var value = GhosttyString()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &value) == GHOSTTY_SUCCESS,
              let pointer = value.ptr else { return nil }
        let uri = String(decoding: UnsafeBufferPointer(start: pointer, count: value.len), as: UTF8.self)
        guard let components = URLComponents(string: uri), components.scheme == "file",
              let path = components.percentEncodedPath.removingPercentEncoding,
              path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return path
    }

    func withTerminal<T>(_ body: (GhosttyTerminal) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(openTerminal())
    }

    func takeEvents() -> [GhosttyTerminalEvent] {
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        return events
    }

    static func check(_ result: GhosttyResult) throws {
        guard result == GHOSTTY_SUCCESS else { throw GhosttyTerminalError.native(result.rawValue) }
    }
}
