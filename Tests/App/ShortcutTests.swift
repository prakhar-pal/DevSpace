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
}
