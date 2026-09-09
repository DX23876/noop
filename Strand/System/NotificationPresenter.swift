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

    /// K5: wired by the app root (`StrandApp` on macOS, `StrandiOSApp` on iOS) at launch to route a
    /// tapped scheduled morning-brief notification to the Coach screen via `NavRouter.openCoach()`. nil
    /// is a safe no-op (the tap is simply not routed) rather than a crash if this ever fires before the
    /// root has wired it.
    var onCoachBriefTapped: (() -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Handle a tap. Two categories route somewhere; every other notification (wind-down,
    /// smart-alarm, battery/illness) just opens the app to wherever it was.
    ///
    ///  * the NOOP AI daily coach check-in ("coach-checkin") broadcasts an in-app event so the UI can
    ///    open the Coach tab and run the check-in;
    ///  * the scheduled morning brief routes to Coach through the shared `NavRouter`.
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

        if isCheckIn, CoachFeaturePrefs.isEnabled {
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
        } else if request.content.categoryIdentifier == CoachBriefScheduler.notificationCategoryId {
            onCoachBriefTapped?()
        }
        completionHandler()
    }
}
