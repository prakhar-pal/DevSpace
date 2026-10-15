import Foundation

/// Shared macOS/Linux retry limits. A failed replacement master stays on the
/// disruption budget until real terminal output confirms a recovered session.
public struct SSHRecoveryBudget: Sendable {
    public static let startupDelays: [TimeInterval] = [0.5, 1.5]
    public static let disruptionDelays: [TimeInterval] = [3, 5, 8, 13, 21]
    private var established = false
    private var attempts = 0

    public init() {}

    public mutating func didConnect() {
        established = true
        attempts = 0
    }

    public mutating func nextDelay() -> TimeInterval? {
        let delays = established ? Self.disruptionDelays : Self.startupDelays
        guard attempts < delays.count else { return nil }
        defer { attempts += 1 }
        return delays[attempts]
    }
}
