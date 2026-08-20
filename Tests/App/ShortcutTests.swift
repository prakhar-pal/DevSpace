import AppKit
import XCTest
@testable import DevSpaceApp

@MainActor
final class ShortcutTests: XCTestCase {
    func testCommandORoutesToOpenInZedForARunningSelectedWorkspace() {
        XCTAssertEqual(AppModel.shortcutRoute(
            event: keyEvent(characters: "o"),
            state: .fixture(selectedID: "wc-1", selectedWorkspaceIsRunning: true)
        ), .action(.openInZed("wc-1")))
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

    func testOnlyTerminalFocusedCommandBOwnsTheKeyEquivalentRoute() {
        let terminal = DevSpaceTerminalView(frame: .zero)

        XCTAssertTrue(AppModel.shouldRouteSidebarToggleToTerminal(
            keyEvent(),
            firstResponder: terminal
        ))
        XCTAssertFalse(AppModel.shouldRouteSidebarToggleToTerminal(
            keyEvent(characters: "c"),
            firstResponder: terminal
        ))
        XCTAssertFalse(AppModel.shouldRouteSidebarToggleToTerminal(
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
}

private extension AppShortcutState {
    static func fixture(
        isModalOpen: Bool = false,
        selectedID: String? = nil,
        selectedTerminalIsVisible: Bool = true,
        selectedWorkspaceIsRunning: Bool = false,
        visibleWorkspaceIDs: [String] = [],
        hasPastedImage: Bool = false
    ) -> Self {
        Self(
            isModalOpen: isModalOpen,
            selectedID: selectedID,
            selectedTerminalIsVisible: selectedTerminalIsVisible,
            selectedWorkspaceIsRunning: selectedWorkspaceIsRunning,
            visibleWorkspaceIDs: visibleWorkspaceIDs,
            pastedImage: hasPastedImage ? PastedImage(data: Data([0]), ext: "png") : nil
        )
    }
}
