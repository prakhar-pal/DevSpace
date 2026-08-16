import AppKit
import GhosttyTerminal
import XCTest
@testable import DevSpaceApp

private final class TerminalWriteBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        values.append(data)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll()
    }

    func joined() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return values.reduce(into: Data()) { $0.append($1) }
    }
}

@MainActor
final class TerminalKeyEquivalentTests: XCTestCase {
    func testKittyModeWritesCommandBOnlyWhenAppHandlerDeclines() {
        let writes = TerminalWriteBuffer()
        let session = InMemoryTerminalSession(
            write: { writes.append($0) },
            resize: { _ in }
        )
        let state = TerminalViewState()
        let view = DevSpaceTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 500)
        )
        view.controller = state.controller
        view.delegate = state
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(view))
        drainMainRunLoop()

        session.receive("\u{1b}[>7u")
        drainMainRunLoop()

        // Establish that this real surface forwards Cmd+B as Kitty bytes when
        // the app handler declines it. libghostty resolves the same event on
        // its second performKeyEquivalent invocation.
        view.handleKeyEquivalent = { _ in false }
        let forwardedEvent = keyEvent(window: window, timestamp: 2)
        writes.removeAll()
        XCTAssertFalse(view.performKeyEquivalent(with: forwardedEvent))
        XCTAssertTrue(view.performKeyEquivalent(with: forwardedEvent))
        drainMainRunLoop()
        XCTAssertEqual(
            writes.joined(),
            Data([0x1b, 0x5b, 0x39, 0x38, 0x3b, 0x39, 0x75]) // ESC[98;9u
        )

        // The app-owned path must return before super on every delivery. Two
        // calls deliberately catch an implementation that calls super and
        // then overwrites its result with true.
        var handlerCalls = 0
        view.handleKeyEquivalent = { event in
            handlerCalls += 1
            return AppModel.isSidebarToggleKeyEquivalent(event)
        }
        let consumedEvent = keyEvent(window: window, timestamp: 3)
        writes.removeAll()
        XCTAssertTrue(view.performKeyEquivalent(with: consumedEvent))
        XCTAssertTrue(view.performKeyEquivalent(with: consumedEvent))
        drainMainRunLoop()
        XCTAssertEqual(handlerCalls, 2)
        XCTAssertEqual(writes.joined(), Data())
    }

    private func keyEvent(window: NSWindow, timestamp: TimeInterval) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "b",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11
        )!
    }

    private func drainMainRunLoop() {
        for _ in 0 ..< 10 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }
}
