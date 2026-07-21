import Foundation
import UserNotifications

extension Notification.Name {
    /// Posted when the user taps the daily coach check-in notification, so the UI can jump to the Coach
    /// tab and refresh the brief. Fired from `NotificationPresenter.didReceive`.
    static let noopOpenCoachCheckIn = Notification.Name("noop.openCoachCheckIn")
}

/// Proactive coach check-in — a gentle, opt-in DAILY local notification that reminds the user their
/// coaching brief is ready, so the coach reaches out first (Bevel-style) instead of only answering when
/// asked. Tapping it opens the app; the Coach tab then auto-generates "Today's brief" via
/// `AICoachEngine.startBriefIfNeeded()`, so no networking happens in the background — the reminder is a
/// nudge, the brief is produced on open. Reliable on a sideloaded app (no critical-alert entitlement
/// needed) because it rides a repeating calendar trigger that lives in the notification centre.
///
/// Modelled on `WindDownNudge`: same authorization-first gating, same UserDefaults-backed settings, same
/// repeating `UNCalendarNotificationTrigger`. On-device only; nothing is sent anywhere.
@MainActor
enum CoachCheckIn {

    private static let requestId = "coach-checkin"

    // MARK: - Persisted settings (own keys; default OFF, opt-in like every automation)

    private enum K {
        static let enabled = "coachCheckIn.enabled"
        static let time = "coachCheckIn.timeMinutes"   // minutes since midnight; default 08:00
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: K.enabled) }

    /// The CURRENT OS authorization state, re-checked live rather than assumed from the persisted
    /// `isEnabled` flag — that flag only reflects what happened the last time the toggle was touched in
    /// this app, not a permission the user later revoked in iOS Settings.
    static func isCurrentlyAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// The daily fire time as minutes since midnight, clamped to a valid minute-of-day. Defaults to 08:00.
    static var timeMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.time) as? Int ?? 8 * 60
        return min(max(v, 0), 24 * 60 - 1)
    }

    // MARK: - Public API

    /// The result of enabling the check-in — lets the UI react instead of persisting an "on" toggle that
    /// can never fire. `.denied` means notifications are off, so the caller should revert the switch and
    /// point the user at Settings.
    enum EnableOutcome { case scheduled, denied, off }

    /// Enable/disable and (re)schedule. Enabling gates on notification authorization FIRST (mirroring
    /// `WindDownNudge.setEnabled`): if undetermined it asks once and schedules on grant; if already denied
    /// it reports back rather than persisting a dead toggle. `completion` always runs on the main actor.
    static func setEnabled(_ on: Bool, completion: (@MainActor (EnableOutcome) -> Void)? = nil) {
        guard on else {
            UserDefaults.standard.set(false, forKey: K.enabled)
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: [requestId])
            completion?(.off)
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    UserDefaults.standard.set(true, forKey: K.enabled)
                    schedule()
                    completion?(.scheduled)
                case .notDetermined:
                    UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                            Task { @MainActor in
                                if granted {
                                    UserDefaults.standard.set(true, forKey: K.enabled)
                                    schedule()
                                    completion?(.scheduled)
                                } else {
                                    UserDefaults.standard.set(false, forKey: K.enabled)
                                    completion?(.denied)
                                }
                            }
                        }
                default:
                    // .denied (or any future non-authorized case) — don't fake an enabled toggle.
                    UserDefaults.standard.set(false, forKey: K.enabled)
                    completion?(.denied)
                }
            }
        }
    }

    /// Update the daily fire time (minutes since midnight), rescheduling if enabled.
    static func setTimeMinutes(_ minutes: Int) {
        UserDefaults.standard.set(min(max(minutes, 0), 24 * 60 - 1), forKey: K.time)
        if isEnabled { schedule() }
    }

    /// The fire time as a `Date` (today, hour/minute only) for a SwiftUI `.hourAndMinute` DatePicker.
    static var timeAsDate: Date {
        Calendar.current.date(
            bySettingHour: timeMinutes / 60, minute: timeMinutes % 60, second: 0, of: Date()
        ) ?? Date()
    }

    /// Persist the fire time from a picker `Date` (reads hour/minute only), rescheduling if enabled.
    static func setTime(from date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        setTimeMinutes((c.hour ?? 8) * 60 + (c.minute ?? 0))
    }

    // MARK: - Scheduling

    /// Actions offered on the check-in notification, so it can be dealt with from the banner instead of
    /// only by opening the app (or being swiped away and forgotten).
    ///
    /// Deliberately NOT "accept": there is nothing to accept here — the brief doesn't exist yet, it is
    /// generated when the app opens. Offering an accept would be accepting something unseen.
    enum Action {
        static let category = "coach-checkin"
        static let snooze = "coach-checkin-snooze"
        static let skipToday = "coach-checkin-skip"
        /// How long Snooze defers the reminder.
        static let snoozeMinutes = 120
    }

    /// Register the notification category. Called once at launch, before any notification can arrive —
    /// a category referenced by a notification but never registered simply shows no buttons.
    static func registerCategory() {
        let snooze = UNNotificationAction(identifier: Action.snooze,
                                          title: String(localized: "Remind me in 2 hours"),
                                          options: [])
        let skip = UNNotificationAction(identifier: Action.skipToday,
                                        title: String(localized: "Not today"),
                                        options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Action.category,
                                   actions: [snooze, skip],
                                   intentIdentifiers: [],
                                   options: [])
        ])
    }

    /// Defer today's reminder by `snoozeMinutes`, as a ONE-OFF request beside the repeating daily one.
    /// The daily trigger is left untouched, so snoozing today never quietly cancels tomorrow.
    static func snooze() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your coach has today's brief")
        content.body = String(localized: "Open NOOP for your readiness and today's plan.")
        content.sound = .default
        content.categoryIdentifier = Action.category

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(Action.snoozeMinutes * 60), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "\(requestId)-snoozed", content: content, trigger: trigger))
    }

    private static func schedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestId])

        let content = UNMutableNotificationContent()
        // Deliberately GENERIC, and it has to be. This is a REPEATING calendar trigger: its content is
        // fixed when scheduled and reused every day thereafter, without the app running. Naming today's
        // actual readiness would therefore quote whatever was true the last time NOOP was opened —
        // possibly days ago. A stale number in a notification is worse than no number, and this project
        // does not state figures it can't stand behind. The brief itself is generated on open, where the
        // data is current.
        content.title = String(localized: "Your coach has today's brief")
        content.body = String(localized: "Open NOOP for your readiness and today's plan.")
        content.sound = .default
        content.categoryIdentifier = Action.category

        let minute = timeMinutes
        var comps = DateComponents()
        comps.hour = minute / 60
        comps.minute = minute % 60
        // repeats: true → a daily calendar trigger that survives relaunch (it lives in the notification
        // centre, not the process), so the check-in keeps firing each day without the app running.
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: requestId, content: content, trigger: trigger))
    }
}
