import AppKit
import DevSpaceCore
import GhosttyTerminal
import XCTest
@testable import DevSpaceApp

@MainActor
private final class SurfaceShortcutExecutor: AppShortcutActionExecuting {
    private(set) var actions: [AppShortcutAction] = []

    func execute(_ action: AppShortcutAction) {
        actions.append(action)
    }
}

private final class SurfaceImmediateHandoffTimeoutScheduler: AppModel.HandoffTimeoutScheduling {
    func schedule(after _: TimeInterval, action: @escaping () -> Void) {
        action()
    }
}

private final class SurfaceShortcutRunner: CommandRunning, @unchecked Sendable {
    func run(_: [String]) throws -> String { "{}" }
}

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
private final class KeyEquivalentDispatchingWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, performKeyEquivalent(with: event) {
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class TerminalKeyEquivalentTests: XCTestCase {
    func testRealLocalMonitorDefersOnceBeforeApplicationDispatchesFocusedTerminal() {
        let writes = TerminalWriteBuffer()
        let recorder = SurfaceShortcutExecutor()
        let image = PastedImage(data: Data([0x40, 0x50, 0x60]), ext: "png")
        var resolverReads = 0
        var boundaries: [String] = []
        let model = visibleTerminalModel(
            executor: recorder,
            pastedImageResolver: {
                resolverReads += 1
                return image
            },
            shortcutMonitorObserver: { didDefer in
                boundaries.append(didDefer ? "monitor-defer" : "monitor-dispatch")
            }
        )
        let terminal = configuredTerminalView(writes: writes)
        let window = KeyEquivalentDispatchingWindow(
            contentRect: terminal.view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        window.contentView = terminal.view
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(terminal.view))
        drainMainRunLoop()

        terminal.view.handleKeyEquivalent = { event in
            boundaries.append("terminal")
            return model.handleTerminalKeyEquivalent(event)
        }
        model.installKeyMonitor()

        NSApp.sendEvent(keyEvent(
            window: window,
            timestamp: 0.5,
            characters: "v",
            keyCode: 9
        ))
        drainMainRunLoop()

        XCTAssertEqual(boundaries, ["monitor-defer", "terminal"])
        XCTAssertEqual(resolverReads, 1)
        XCTAssertEqual(recorder.actions, [.imagePaste(image, to: "wc-1")])
        XCTAssertEqual(writes.joined(), Data())
    }

    func testOnlyFirstResponderAmongMultipleMountedTerminalsInvokesAppHandler() {
        let backgroundWrites = TerminalWriteBuffer()
        let foregroundWrites = TerminalWriteBuffer()
        let background = configuredTerminalView(writes: backgroundWrites)
        let foreground = configuredTerminalView(writes: foregroundWrites)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        container.addSubview(background.view)
        container.addSubview(foreground.view)
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(foreground.view))
        drainMainRunLoop()

        var backgroundHandlerCalls = 0
        var foregroundHandlerCalls = 0
        background.view.handleKeyEquivalent = { _ in
            backgroundHandlerCalls += 1
            return true
        }
        foreground.view.handleKeyEquivalent = { _ in
            foregroundHandlerCalls += 1
            return true
        }
        let event = keyEvent(
            window: window,
            timestamp: 1,
            characters: "v",
            keyCode: 9
        )

        _ = background.view.performKeyEquivalent(with: event)
        XCTAssertEqual(backgroundHandlerCalls, 0)
        XCTAssertEqual(foregroundHandlerCalls, 0)
        XCTAssertTrue(foreground.view.performKeyEquivalent(with: event))
        XCTAssertEqual(backgroundHandlerCalls, 0)
        XCTAssertEqual(foregroundHandlerCalls, 1)
    }

    func testFocusedKittySurfaceUsesOneOwnerAndPreservesTerminalInput() {
        let writes = TerminalWriteBuffer()
        let recorder = SurfaceShortcutExecutor()
        let image = PastedImage(data: Data([0x10, 0x20, 0x30]), ext: "png")
        var resolvedImage: PastedImage?
        var resolverReads = 0
        let model = visibleTerminalModel(
            executor: recorder,
            pastedImageResolver: {
                resolverReads += 1
                return resolvedImage
            }
        )
        let (view, window, session) = terminalSurface(writes: writes)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        view.handleKeyEquivalent = model.handleTerminalKeyEquivalent
        session.receive("\u{1b}[>7u")
        drainMainRunLoop()

        dispatchThroughWindowKeyEquivalent(keyEvent(
            window: window,
            timestamp: 10,
            characters: "o",
            keyCode: 31
        ))
        dispatchThroughWindowKeyEquivalent(keyEvent(
            window: window,
            timestamp: 11,
            characters: "r",
            keyCode: 15
        ))
        XCTAssertEqual(recorder.actions, [.openInZed("wc-1"), .reload("wc-1")])
        XCTAssertEqual(writes.joined(), Data())

        writes.removeAll()
        dispatchThroughWindowKeyEquivalent(keyEvent(
            window: window,
            timestamp: 12,
            characters: "y",
            keyCode: 16
        ))
        XCTAssertFalse(writes.joined().isEmpty)

        writes.removeAll()
        resolvedImage = image
        resolverReads = 0
        dispatchThroughWindowKeyEquivalent(keyEvent(
            window: window,
            timestamp: 13,
            characters: "v",
            keyCode: 9
        ))
        XCTAssertEqual(resolverReads, 1)
        XCTAssertEqual(recorder.actions.last, .imagePaste(image, to: "wc-1"))
        XCTAssertEqual(writes.joined(), Data())

        writes.removeAll()
        resolvedImage = nil
        resolverReads = 0
        withGeneralPasteboardString("terminal paste") {
            dispatchThroughWindowKeyEquivalent(keyEvent(
                window: window,
                timestamp: 14,
                characters: "v",
                keyCode: 9
            ))
            XCTAssertEqual(writes.joined(), Data("terminal paste".utf8))
        }
        XCTAssertEqual(resolverReads, 1)
    }

    func testFocusedLifecycleTerminalRoutesSystemCommandsBeforeModalPolicy() {
        let recorder = SurfaceShortcutExecutor()
        let model = lifecycleTerminalModel(executor: recorder)
        model.renaming = "wc-1"
        let writes = TerminalWriteBuffer()
        let (view, window, _) = terminalSurface(writes: writes)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        view.handleKeyEquivalent = model.handleTerminalKeyEquivalent

        for (characters, keyCode) in [("q", 12), ("m", 46), ("h", 4), ("w", 13)] {
            XCTAssertTrue(view.performKeyEquivalent(with: keyEvent(
                window: window,
                timestamp: TimeInterval(keyCode),
                characters: characters,
                keyCode: UInt16(keyCode)
            )))
        }

        guard case .starting = model.phase(of: "wc-1") else {
            return XCTFail("Expected a lifecycle log terminal")
        }
        XCTAssertFalse(model.isTerminalVisible("wc-1"))
        XCTAssertEqual(recorder.actions, [.quit, .minimize, .hide, .closeWindow])
        XCTAssertFalse(model.handleTerminalKeyEquivalent(keyEvent(
            window: window,
            timestamp: 20,
            characters: "o",
            keyCode: 31
        )))
        XCTAssertEqual(recorder.actions, [.quit, .minimize, .hide, .closeWindow])
    }

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

    private func keyEvent(
        window: NSWindow,
        timestamp: TimeInterval,
        characters: String = "b",
        keyCode: UInt16 = 11
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func visibleTerminalModel(
        executor: AppShortcutActionExecuting,
        pastedImageResolver: @escaping () -> PastedImage?,
        shortcutMonitorObserver: ((Bool) -> Void)? = nil
    ) -> AppModel {
        let model = AppModel(
            runner: SurfaceShortcutRunner(),
            interval: 3_600,
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            handoffTimeoutScheduler: SurfaceImmediateHandoffTimeoutScheduler(),
            shortcutActionExecutor: executor,
            pastedImageResolver: pastedImageResolver,
            shortcutMonitorObserver: shortcutMonitorObserver
        )
        model.select("wc-1")
        model.connect("wc-1")
        XCTAssertTrue(model.isTerminalVisible("wc-1"))
        return model
    }

    private func lifecycleTerminalModel(
        executor: AppShortcutActionExecuting
    ) -> AppModel {
        let model = AppModel(
            runner: SurfaceShortcutRunner(),
            interval: 3_600,
            initialWorkspaces: [WorkspaceView(
                id: "wc-1",
                provider: "test",
                source: "",
                lastUsed: "",
                state: "Running",
                error: nil
            )],
            startsRuntimeServices: false,
            shortcutActionExecutor: executor,
            pastedImageResolver: { nil }
        )
        model.start("wc-1")
        return model
    }

    private func terminalSurface(
        writes: TerminalWriteBuffer
    ) -> (DevSpaceTerminalView, NSWindow, InMemoryTerminalSession) {
        let terminal = configuredTerminalView(writes: writes)
        let view = terminal.view
        let session = terminal.session
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(view))
        drainMainRunLoop()
        return (view, window, session)
    }

    private func configuredTerminalView(
        writes: TerminalWriteBuffer
    ) -> (view: DevSpaceTerminalView, session: InMemoryTerminalSession) {
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
        return (view, session)
    }

    private func withGeneralPasteboardString(_ string: String, body: () -> Void) {
        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
        defer {
            pasteboard.clearContents()
            let restoredItems = savedItems.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(restoredItems)
        }
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        body()
    }

    private func dispatchThroughWindowKeyEquivalent(_ event: NSEvent) {
        if event.window?.performKeyEquivalent(with: event) != true,
           event.window?.performKeyEquivalent(with: event) != true
        {
            NSApp.sendEvent(event)
        }
        drainMainRunLoop()
    }

    private func drainMainRunLoop() {
        for _ in 0 ..< 10 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }
}
