import AppKit
import XCTest
@testable import DevSpaceApp

@MainActor
final class ShortcutTests: XCTestCase {
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
