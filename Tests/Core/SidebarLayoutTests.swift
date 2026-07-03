import XCTest
@testable import DevSpaceCore

// Mirrors the sidebar derivations/behaviors from App.tsx + Sidebar.test.tsx.
final class SidebarLayoutTests: XCTestCase {
    private func ws(_ id: String, _ state: String = "Running") -> WorkspaceView {
        WorkspaceView(id: id, provider: "k8s", source: "src", lastUsed: "", state: state, error: nil)
    }

    func testStatusColorMapping() {
        XCTAssertEqual(SidebarLayout.statusColorName("Running"), "green")
        XCTAssertEqual(SidebarLayout.statusColorName("Stopped"), "grey")
        XCTAssertEqual(SidebarLayout.statusColorName("Busy"), "amber")
        XCTAssertEqual(SidebarLayout.statusColorName("Loading"), "grey")
        XCTAssertEqual(SidebarLayout.statusColorName("Unknown"), "red")
    }

    func testNormalizeOrderKeepsExistingAppendsNewDropsGone() {
        let result = SidebarLayout.normalizeOrder(["b", "a", "gone"], ids: ["a", "b", "c"])
        XCTAssertEqual(result, ["b", "a", "c"]) // kept order b,a; dropped gone; appended c
    }

    func testDisplayIDsOrderThenRest() {
        let wss = [ws("a"), ws("b"), ws("c")]
        let ids = SidebarLayout.displayIDs(order: ["c", "a"], workspaces: wss)
        XCTAssertEqual(ids, ["c", "a", "b"])
    }

    func testSplitVisibleAndHidden() {
        let wss = [ws("a"), ws("b"), ws("c")]
        let byID = Dictionary(uniqueKeysWithValues: wss.map { ($0.id, $0) })
        let r = SidebarLayout.split(displayIDs: ["a", "b", "c"], hidden: ["b"], byID: byID)
        XCTAssertEqual(r.visible.map(\.id), ["a", "c"])
        XCTAssertEqual(r.hidden.map(\.id), ["b"])
    }

    func testReorderVisibleLeavesHiddenSlots() {
        // order a,b,c,d with b hidden; reorder visible [a,c,d] -> [d,a,c]
        let result = SidebarLayout.reorderVisible(
            order: ["a", "b", "c", "d"],
            hidden: ["b"],
            newVisibleIDs: ["d", "a", "c"]
        )
        // hidden b keeps its slot (index 1); visible positions get the new order.
        XCTAssertEqual(result, ["d", "b", "a", "c"])
    }

    func testMoveVisibleUpAndDown() {
        XCTAssertEqual(SidebarLayout.moveVisible(["a", "b", "c"], id: "b", delta: -1), ["b", "a", "c"])
        XCTAssertEqual(SidebarLayout.moveVisible(["a", "b", "c"], id: "b", delta: 1), ["a", "c", "b"])
    }

    func testMoveVisibleClampsAtEdges() {
        XCTAssertEqual(SidebarLayout.moveVisible(["a", "b", "c"], id: "a", delta: -1), ["a", "b", "c"])
        XCTAssertEqual(SidebarLayout.moveVisible(["a", "b", "c"], id: "c", delta: 1), ["a", "b", "c"])
    }

    func testMoveVisibleUnknownIDIsNoOp() {
        XCTAssertEqual(SidebarLayout.moveVisible(["a", "b"], id: "zzz", delta: 1), ["a", "b"])
    }

    func testSetAliasClearsOnEmptyOrEqualToID() {
        var a = SidebarLayout.setAlias([:], id: "wc-1", name: "Frontend")
        XCTAssertEqual(a["wc-1"], "Frontend")
        a = SidebarLayout.setAlias(a, id: "wc-1", name: "")
        XCTAssertNil(a["wc-1"])
        a = SidebarLayout.setAlias(["wc-2": "x"], id: "wc-2", name: "wc-2")
        XCTAssertNil(a["wc-2"]) // name == id clears
    }

    func testHiddenRowsCollapseKeepsSelected() {
        let hidden = [ws("h1"), ws("h2"), ws("h3")]
        // Expanded: all shown.
        XCTAssertEqual(
            SidebarLayout.hiddenRows(hidden, collapsed: false, selectedID: nil).map(\.id),
            ["h1", "h2", "h3"]
        )
        // Collapsed: only the selected hidden row stays.
        XCTAssertEqual(
            SidebarLayout.hiddenRows(hidden, collapsed: true, selectedID: "h2").map(\.id),
            ["h2"]
        )
        // Collapsed, nothing selected: none.
        XCTAssertTrue(SidebarLayout.hiddenRows(hidden, collapsed: true, selectedID: nil).isEmpty)
    }
}
