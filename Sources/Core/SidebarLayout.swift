import Foundation

// Pure sidebar ordering/visibility logic, ported from the derivations in
// src/App.tsx and src/components/Sidebar.tsx. Kept UI-free so it can be unit
// tested; the SwiftUI Sidebar consumes these.
public enum SidebarLayout {
    /// Status -> dot color name (mirrors Sidebar.tsx statusColor).
    public static func statusColorName(_ state: String) -> String {
        switch state {
        case "Running": "green"
        case "Stopped": "grey"
        case "Busy": "amber"
        case "Loading": "grey" // not resolved yet — neutral, not an error
        default: "red"
        }
    }

    /// Keep `order` canonical: existing ids in their saved order, then any new
    /// ids appended; ids that no longer exist are dropped.
    public static func normalizeOrder(_ order: [String], ids: [String]) -> [String] {
        let idSet = Set(ids)
        let kept = order.filter { idSet.contains($0) }
        let orderSet = Set(order)
        let added = ids.filter { !orderSet.contains($0) }
        return kept + added
    }

    public static func pruneHidden(_ hidden: [String], ids: [String]) -> [String] {
        let idSet = Set(ids)
        return hidden.filter { idSet.contains($0) }
    }

    /// Display order = saved order first, then any not-yet-ordered ids.
    public static func displayIDs(order: [String], workspaces: [WorkspaceView]) -> [String] {
        let present = Set(workspaces.map(\.id))
        let inOrder = order.filter { present.contains($0) }
        let orderSet = Set(order)
        let rest = workspaces.map(\.id).filter { !orderSet.contains($0) }
        return inOrder + rest
    }

    public static func split(
        displayIDs: [String],
        hidden: Set<String>,
        byID: [String: WorkspaceView]
    ) -> (visible: [WorkspaceView], hidden: [WorkspaceView]) {
        let visible = displayIDs.filter { !hidden.contains($0) }.compactMap { byID[$0] }
        let hiddenWs = displayIDs.filter { hidden.contains($0) }.compactMap { byID[$0] }
        return (visible, hiddenWs)
    }

    /// Move `id` by `delta` steps (-1 = up, +1 = down) within a visible-ids
    /// list. Clamped at the edges; unknown ids are a no-op.
    public static func moveVisible(_ ids: [String], id: String, delta: Int) -> [String] {
        guard let i = ids.firstIndex(of: id) else { return ids }
        let j = min(max(i + delta, 0), ids.count - 1)
        guard j != i else { return ids }
        var out = ids
        out.remove(at: i)
        out.insert(id, at: j)
        return out
    }

    /// Rebuild the master `order` after the visible rows were reordered (e.g. by
    /// a List move), leaving hidden ids in their original slots.
    public static func reorderVisible(
        order: [String],
        hidden: Set<String>,
        newVisibleIDs: [String]
    ) -> [String] {
        var result: [String] = []
        var vi = 0
        for id in order {
            if hidden.contains(id) {
                result.append(id)
            } else if vi < newVisibleIDs.count {
                result.append(newVisibleIDs[vi])
                vi += 1
            }
        }
        return result
    }

    /// Set/clear a friendly name. Empty or equal-to-id clears it.
    public static func setAlias(_ aliases: [String: String], id: String, name: String) -> [String: String] {
        var next = aliases
        if name.isEmpty || name == id {
            next[id] = nil
        } else {
            next[id] = name
        }
        return next
    }

    /// Which hidden rows to render: all when expanded; when collapsed, only the
    /// selected one (so an active session can't become unreachable).
    public static func hiddenRows(
        _ hidden: [WorkspaceView],
        collapsed: Bool,
        selectedID: String?
    ) -> [WorkspaceView] {
        hidden.filter { !collapsed || $0.id == selectedID }
    }
}
