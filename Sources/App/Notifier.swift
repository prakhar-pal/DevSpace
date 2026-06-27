import AppKit
import UserNotifications

/// Native notification with a dock-bounce fallback — mirrors the Tauri build's
/// notification plugin + UserAttentionType::Critical fallback. On unsigned/MDM
/// Macs banners are unreliable, so we always fall back to bouncing the dock.
enum Notifier {
    /// Guard against running outside a real app bundle (e.g. bare-binary test
    /// launches), where UNUserNotificationCenter.current() traps.
    private static var inBundle: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard inBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
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
                center.add(UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil
                ))
            default:
                DispatchQueue.main.async { NSApp.requestUserAttention(.criticalRequest) }
            }
        }
    }
}
