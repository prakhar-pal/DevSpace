import AppKit
import DevSpaceCore
import XCTest
@testable import DevSpaceApp

@MainActor
private final class RecordingShortcutExecutor: AppShortcutActionExecuting {
    private(set) var actions: [AppShortcutAction] = []

    func execute(_ action: AppShortcutAction) {
        actions.append(action)
    }
}

private final class ImmediateHandoffTimeoutScheduler: AppModel.HandoffTimeoutScheduling {
    func schedule(after _: TimeInterval, action: @escaping () -> Void) {
        action()
    }
}

private final class ShortcutRunner: CommandRunning, @unchecked Sendable {
    func run(_: [String]) throws -> String { "{}" }
}

@MainActor
final class ShortcutTests: XCTestCase {
    func testTerminalFocusedCommandODefersMonitorAndExecutesOpenInZedOnceAtTerminalBoundary() {
        let recorder = RecordingShortcutExecutor()
        let model = fixtureModel(executor: recorder, selectedRunningWorkspace: "wc-1")
        let terminal = DevSpaceTerminalView(frame: .zero)
        let event = keyEvent(characters: "o")

        XCTAssertTrue(AppModel.shouldDeferPotentialAppShortcutToTerminal(
            event,
            firstResponder: terminal
        ))
        XCTAssertFalse(model.dispatchAppShortcutFromMonitor(event, firstResponder: terminal))
        XCTAssertTrue(model.dispatchAppShortcut(event))
        XCTAssertEqual(recorder.actions, [.openInZed("wc-1")])
    }

    func testNonterminalFocusedCommandRExecutesReloadOnceAtMonitor() {
        let recorder = RecordingShortcutExecutor()
        let model = fixtureModel(executor: recorder, selectedVisibleTerminal: "wc-1")
        let event = keyEvent(characters: "r")

        XCTAssertTrue(model.dispatchAppShortcutFromMonitor(
            event,
            firstResponder: NSView(frame: .zero)
        ))
        XCTAssertEqual(recorder.actions, [.reload("wc-1")])
    }

    func testTerminalFocusedImagePasteResolvesPayloadOnceAtTerminalBoundary() {
        let recorder = RecordingShortcutExecutor()
        let image = PastedImage(data: Data([0x01, 0x02, 0x03]), ext: "png")
        var resolverReads = 0
        let model = fixtureModel(
            executor: recorder,
            selectedVisibleTerminal: "wc-1",
            pastedImageResolver: {
                resolverReads += 1
                return image
            }
        )
        let terminal = DevSpaceTerminalView(frame: .zero)
        let event = keyEvent(characters: "v")

        XCTAssertFalse(model.dispatchAppShortcutFromMonitor(event, firstResponder: terminal))
        XCTAssertEqual(resolverReads, 0)
        XCTAssertTrue(model.dispatchAppShortcut(event))
        XCTAssertEqual(resolverReads, 1)
        XCTAssertEqual(recorder.actions, [.imagePaste(image, to: "wc-1")])
    }

    func testNonPasteShortcutDoesNotResolveImagePayload() {
        let recorder = RecordingShortcutExecutor()
        var resolverReads = 0
        let model = fixtureModel(
            executor: recorder,
            selectedVisibleTerminal: "wc-1",
            pastedImageResolver: {
                resolverReads += 1
                return nil
            }
        )

        XCTAssertTrue(model.dispatchAppShortcut(keyEvent(characters: "r")))
        XCTAssertEqual(resolverReads, 0)
        XCTAssertEqual(recorder.actions, [.reload("wc-1")])
    }

    func testModalCommandVPassthroughDoesNotResolveImagePayload() {
        let recorder = RecordingShortcutExecutor()
        var resolverReads = 0
        let model = fixtureModel(
            executor: recorder,
            selectedVisibleTerminal: "wc-1",
            pastedImageResolver: {
                resolverReads += 1
                return PastedImage(data: Data([0x01]), ext: "png")
            }
        )
        model.renaming = "wc-1"

        XCTAssertFalse(model.dispatchAppShortcut(keyEvent(characters: "v")))
        XCTAssertEqual(resolverReads, 0)
        XCTAssertEqual(recorder.actions, [])
    }

    func testDevpodLifecycleSheetsOwnAppShortcuts() {
        let recorder = RecordingShortcutExecutor()
        let model = fixtureModel(executor: recorder, selectedVisibleTerminal: "wc-1")
        let event = keyEvent(characters: "r")

        model.beginCreation()
        XCTAssertFalse(model.dispatchAppShortcut(event))
        model.cancelCreation()

        model.beginRecreate("wc-1")
        XCTAssertFalse(model.dispatchAppShortcut(event))

        model.cancelRecreate()
        model.beginCreation()
        model.submitCreation(
            repositoryURL: "https://github.com/acme/new.git",
            devpodID: ""
        )
        let escape = keyEvent(characters: "\u{1b}", modifiers: [])
        XCTAssertFalse(model.handleTerminalKeyEquivalent(escape))
        XCTAssertEqual(model.creationPhase, .running)
        XCTAssertNotNil(model.creationPane)
        XCTAssertFalse(model.dispatchAppShortcut(event))
        XCTAssertEqual(recorder.actions, [])
    }

    func testCommandORoutesToOpenInZedForARunningSelectedWorkspace() {
        XCTAssertEqual(AppModel.shortcutRoute(
            event: keyEvent(characters: "o"),
            state: .fixture(selectedID: "wc-1", selectedWorkspaceCanOpenInZed: true)
        ), .action(.openInZed("wc-1")))
    }

    func testCommandODoesNothingWhenSelectedWorkspaceIsNotLive() {
        XCTAssertEqual(AppModel.shortcutRoute(
            event: keyEvent(characters: "o"),
            state: .fixture(selectedID: "wc-1", selectedWorkspaceCanOpenInZed: false)
        ), .handledNoOp)
    }

    func testCommandRConsumesAsNoOpWithoutVisibleTerminal() {
        XCTAssertEqual(AppModel.shortcutRoute(
            event: keyEvent(characters: "r"),
            state: .fixture(selectedID: "wc-1", selectedTerminalIsVisible: false)
        ), .handledNoOp)
    }

    func testModalLeavesDevSpaceCommandsUnhandledButNotCommandQ() {
        let modal = AppShortcutState.fixture(isModalOpen: true)
        XCTAssertEqual(AppModel.shortcutRoute(event: keyEvent(characters: "o"), state: modal), .unhandled)
        XCTAssertEqual(AppModel.shortcutRoute(event: keyEvent(characters: "q"), state: modal), .action(.quit))
    }

    func testTextPasteAndOutOfRangeWorkspaceSelectionPassThrough() {
        XCTAssertEqual(AppModel.shortcutRoute(
            event: keyEvent(characters: "v"), state: .fixture(hasPastedImage: false)
        ), .unhandled)
        XCTAssertEqual(AppModel.shortcutRoute(
            event: keyEvent(characters: "9"), state: .fixture(visibleWorkspaceIDs: ["wc-1"])
        ), .unhandled)
    }

    func testNextTerminalTabShortcutMatchesShiftRetainedCharacter() {
        XCTAssertTrue(AppModel.isNextTerminalTabShortcut("T"))
    }

    func testNextTerminalTabShortcutDoesNotMatchOtherKeys() {
        XCTAssertFalse(AppModel.isNextTerminalTabShortcut("["))
    }

    func testSidebarToggleKeyEquivalentAcceptsUppercaseCommandB() {
        XCTAssertTrue(AppModel.isSidebarToggleKeyEquivalent(
            keyEvent(characters: "B")
        ))
    }

    func testSidebarToggleKeyEquivalentRejectsWrongModifiersAndEventType() {
        XCTAssertFalse(AppModel.isSidebarToggleKeyEquivalent(
            keyEvent(modifiers: [])
        ))
        XCTAssertFalse(AppModel.isSidebarToggleKeyEquivalent(
            keyEvent(modifiers: [.command, .shift])
        ))
        XCTAssertFalse(AppModel.isSidebarToggleKeyEquivalent(
            keyEvent(modifiers: [.control])
        ))
        XCTAssertFalse(AppModel.isSidebarToggleKeyEquivalent(
            keyEvent(type: .keyUp)
        ))
    }

    func testSidebarToggleKeyEquivalentRejectsOtherCommandKey() {
        XCTAssertFalse(AppModel.isSidebarToggleKeyEquivalent(
            keyEvent(characters: "c")
        ))
    }

    func testOnlyTerminalFocusedPotentialAppShortcutsDeferToKeyEquivalentRoute() {
        let terminal = DevSpaceTerminalView(frame: .zero)

        for characters in ["b", "o", "r", "t", "v", "q", "m", "h", "w", "1", "9"] {
            XCTAssertTrue(AppModel.shouldDeferPotentialAppShortcutToTerminal(
                keyEvent(characters: characters),
                firstResponder: terminal
            ), "Expected Cmd+\(characters) to defer")
        }
        XCTAssertTrue(AppModel.shouldDeferPotentialAppShortcutToTerminal(
            keyEvent(characters: "T", modifiers: [.command, .shift]),
            firstResponder: terminal
        ))
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        XCTAssertTrue(AppModel.shouldDeferPotentialAppShortcutToTerminal(
            keyEvent(characters: up, modifiers: [.command, .option]),
            firstResponder: terminal
        ))
        XCTAssertFalse(AppModel.shouldDeferPotentialAppShortcutToTerminal(
            keyEvent(characters: "c"),
            firstResponder: terminal
        ))
        XCTAssertFalse(AppModel.shouldDeferPotentialAppShortcutToTerminal(
            keyEvent(type: .keyUp),
            firstResponder: terminal
        ))
        XCTAssertFalse(AppModel.shouldDeferPotentialAppShortcutToTerminal(
            keyEvent(modifiers: [.control]),
            firstResponder: terminal
        ))
        XCTAssertFalse(AppModel.shouldDeferPotentialAppShortcutToTerminal(
            keyEvent(),
            firstResponder: NSView(frame: .zero)
        ))
    }

    private func keyEvent(
        type: NSEvent.EventType = .keyDown,
        characters: String = "b",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 11
        )!
    }

    private func fixtureModel(
        executor: AppShortcutActionExecuting,
        selectedRunningWorkspace id: String
    ) -> AppModel {
        let model = AppModel(
            runner: ShortcutRunner(),
            interval: 3_600,
            initialWorkspaces: [runningWorkspace(id)],
            startsRuntimeServices: false,
            shortcutActionExecutor: executor
        )
        model.select(id)
        return model
    }

    private func fixtureModel(
        executor: AppShortcutActionExecuting,
        selectedVisibleTerminal id: String,
        pastedImageResolver: @escaping () -> PastedImage? = { nil }
    ) -> AppModel {
        let model = AppModel(
            runner: ShortcutRunner(),
            interval: 3_600,
            initialWorkspaces: [runningWorkspace(id)],
            startsRuntimeServices: false,
            handoffTimeoutScheduler: ImmediateHandoffTimeoutScheduler(),
            shortcutActionExecutor: executor,
            pastedImageResolver: pastedImageResolver
        )
        model.select(id)
        model.connect(id)
        XCTAssertTrue(model.isTerminalVisible(id))
        return model
    }

    private func runningWorkspace(_ id: String) -> WorkspaceView {
        WorkspaceView(
            id: id,
            provider: "test",
            source: "",
            lastUsed: "",
            state: "Running",
            error: nil
        )
    }
}

private extension AppShortcutState {
    static func fixture(
        isModalOpen: Bool = false,
        selectedID: String? = nil,
        selectedTerminalIsVisible: Bool = true,
        selectedWorkspaceCanOpenInZed: Bool = false,
        visibleWorkspaceIDs: [String] = [],
        hasPastedImage: Bool = false
    ) -> Self {
        Self(
            isModalOpen: isModalOpen,
            selectedID: selectedID,
            selectedTerminalIsVisible: selectedTerminalIsVisible,
            selectedWorkspaceCanOpenInZed: selectedWorkspaceCanOpenInZed,
            visibleWorkspaceIDs: visibleWorkspaceIDs,
            pastedImage: hasPastedImage ? PastedImage(data: Data([0]), ext: "png") : nil
        )
    }
}
