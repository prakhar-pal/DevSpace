/// A successful `up` may precede list visibility. Count only successful
/// observations, as on macOS, and never guess among concurrent creations.
public struct WorkspaceCreationDiscovery: Sendable {
    public enum Outcome: Equatable, Sendable {
        case waiting
        case resolved(String?)
    }

    public static let maximumMisses = 3
    private let explicitID: String?
    private let before: Set<String>
    private var misses = 0

    public init(explicitID: String?, before: Set<String>) {
        self.explicitID = explicitID
        self.before = before
    }

    public mutating func observe(_ after: Set<String>) -> Outcome {
        if let id = WorkspaceController.createdWorkspaceID(explicitID: explicitID, before: before, after: after) {
            return .resolved(id)
        }
        if explicitID == nil, after.subtracting(before).count > 1 { return .resolved(nil) }
        misses += 1
        return misses >= Self.maximumMisses ? .resolved(nil) : .waiting
    }
}
