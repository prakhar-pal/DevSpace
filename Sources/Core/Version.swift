import Foundation

/// Trivial surface so tests and the app can confirm the Core framework links.
/// Real logic (devpod/poller/notify/hooks/layout/path_env) arrives in later
/// stacks.
public enum DevSpaceCore {
    /// Marketing version, sourced from the app/framework bundle when available.
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    public static let name = "DevSpaceCore"
}
