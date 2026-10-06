import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// Opt-in visual warnings while minimized. No second notification sound competes with speech/strap cues.
@MainActor
enum WorkoutWarningNotifier {
    static func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }

    static func post(_ message: String, stillCurrent: () -> Bool) async {
        guard UserDefaults.standard.bool(forKey: WorkoutFeedbackPreferences.notificationsKey) else { return }
        #if os(iOS)
        guard UIApplication.shared.applicationState != .active else { return }
        #endif
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
              UserDefaults.standard.bool(forKey: WorkoutFeedbackPreferences.notificationsKey), stillCurrent() else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Training warnings")
        content.body = message
        do {
            try await center.add(UNNotificationRequest(identifier: "noop-live-workout-warning", content: content, trigger: nil))
        } catch {
            // The in-app warning remains available; OS delivery is never reported as guaranteed.
        }
    }

    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["noop-live-workout-warning"])
        center.removeDeliveredNotifications(withIdentifiers: ["noop-live-workout-warning"])
    }
}
