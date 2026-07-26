import Foundation
import UserNotifications

/// Foreground presentation delegate for the app's local notifications (wind-down nudge, smart-alarm
/// backup, battery/illness alerts).
///
/// Without a `UNUserNotificationCenterDelegate`, iOS/macOS suppress a notification's banner while the
/// app is in the FOREGROUND (the default). A user testing a reminder with the app open would see
/// nothing and conclude notifications are broken. Returning banner + sound + list here makes them
/// visible whether the app is open or not — matching what the user expects from a reminder.
///
/// Cross-platform (iOS + macOS). Register once at launch:
/// `UNUserNotificationCenter.current().delegate = NotificationPresenter.shared`.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationPresenter()

    private override init() { super.init() }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Handle a tap. The NOOP AI daily coach check-in ("coach-checkin") broadcasts an in-app event so the
    /// UI can open the Coach tab and refresh the brief; every other notification just opens the app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Match on the CATEGORY, not the request id: the snoozed re-fire is a second request
        // ("coach-checkin-snoozed") and would otherwise open the app without running the check-in.
        let request = response.notification.request
        let isCheckIn = request.identifier.hasPrefix("coach-checkin")
            || request.content.categoryIdentifier == CoachCheckIn.Action.category

        if isCheckIn {
            switch response.actionIdentifier {
            case CoachCheckIn.Action.snooze:
                // Handled entirely in the notification centre; the app is not brought forward.
                Task { @MainActor in CoachCheckIn.snooze() }
            case CoachCheckIn.Action.skipToday:
                break   // dismissed for today; tomorrow's repeating trigger is untouched
            default:
                // A tap (or the default action): open the coach and run the check-in.
                NotificationCenter.default.post(name: .noopOpenCoachCheckIn, object: nil)
            }
        }
        completionHandler()
    }
}
