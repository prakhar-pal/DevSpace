import XCTest
@testable import DevSpaceCore

// Mirrors layout.rs tests.
final class LayoutTests: XCTestCase {
    func testRoundTrips() {
        var l = Layout()
        l.order = ["a", "b"]
        l.hidden = ["c"]
        l.aliases["a"] = "Alpha"
        l.hiddenCollapsed = true
        let parsed = Layout.parse(Layout.serialize(l))
        XCTAssertEqual(parsed.order, ["a", "b"])
        XCTAssertEqual(parsed.hidden, ["c"])
        XCTAssertEqual(parsed.aliases["a"], "Alpha")
        XCTAssertTrue(parsed.hiddenCollapsed)
    }

    func testMalformedIsDefault() {
        let l = Layout.parse("not json{{")
        XCTAssertTrue(l.order.isEmpty && l.hidden.isEmpty && l.aliases.isEmpty)
        XCTAssertFalse(l.hiddenCollapsed)
    }

    func testMissingFieldsDefaultToEmpty() {
        let l = Layout.parse("{}")
        XCTAssertTrue(l.order.isEmpty && l.hidden.isEmpty && l.aliases.isEmpty)
        let l2 = Layout.parse(#"{"order":["x"]}"#)
        XCTAssertEqual(l2.order, ["x"])
        XCTAssertTrue(l2.hidden.isEmpty && l2.aliases.isEmpty)
    }

    func testSnakeCaseHiddenCollapsedKey() {
        // The on-disk key is snake_case for compatibility with existing files.
        let l = Layout.parse(#"{"hidden_collapsed":true}"#)
        XCTAssertTrue(l.hiddenCollapsed)
        XCTAssertTrue(Layout.serialize(l).contains("hidden_collapsed"))
    }
}
