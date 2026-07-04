import AppKit
import UserNotifications

/// Native notification with a dock-bounce fallback — mirrors the Tauri build's
/// notification plugin + UserAttentionType::Critical fallback. On unsigned/MDM
/// Macs banners are unreliable, so we always fall back to bouncing the dock.
enum Notifier {
    /// Guard against running outside a real app bundle (e.g. bare-binary test
    /// launches), where UNUserNotificationCenter.current() traps.
    private static var inBundle: Bool { Bundle.main.bundleIdentifier != nil }

    /// Retained delegate; UNUserNotificationCenter keeps only a weak reference.
    private static var delegate: NotifierDelegate?

    static func requestPermission() {
        guard inBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Install the notification delegate at launch, before any notification
    /// can be delivered. `onTap` routes a click to the workspace it came
    /// from; `shouldPresent` decides whether a banner shows while the app is
    /// frontmost (suppressed for the pod whose terminal is already on screen).
    static func install(
        onTap: @escaping @MainActor (String) -> Void,
        shouldPresent: @escaping @MainActor (String?) -> Bool
    ) {
        guard inBundle else { return }
        let d = NotifierDelegate(onSelect: onTap, shouldPresent: shouldPresent)
        delegate = d
        UNUserNotificationCenter.current().delegate = d
    }

    static func notify(title: String, body: String, podID: String? = nil) {
        guard inBundle else {
            DispatchQueue.main.async { NSApp.requestUserAttention(.criticalRequest) }
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                if let podID { content.userInfo = ["podID": podID] }
                center.add(UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil
                ))
            default:
                DispatchQueue.main.async { NSApp.requestUserAttention(.criticalRequest) }
            }
        }
    }
}

/// Handles notification delivery + taps. Foreground banners show when the
/// event concerns a workspace other than the one on screen (`shouldPresent`
/// suppresses the selected pod's — its terminal is already visible), and a
/// tap activates the app and selects the originating workspace.
private final class NotifierDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let onSelect: @MainActor (String) -> Void
    private let shouldPresent: @MainActor (String?) -> Bool

    init(
        onSelect: @escaping @MainActor (String) -> Void,
        shouldPresent: @escaping @MainActor (String?) -> Bool
    ) {
        self.onSelect = onSelect
        self.shouldPresent = shouldPresent
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let podID = notification.request.content.userInfo["podID"] as? String
        DispatchQueue.main.async {
            let show = MainActor.assumeIsolated { self.shouldPresent(podID) }
            completionHandler(show ? [.banner, .sound] : [])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let podID = response.notification.request.content.userInfo["podID"] as? String
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let podID {
                MainActor.assumeIsolated { self.onSelect(podID) }
            }
            completionHandler()
        }
    }
}
