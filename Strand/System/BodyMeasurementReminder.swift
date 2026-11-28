import Foundation
@preconcurrency import UserNotifications
import StrandAnalytics
import StrandCore

/// Measurement reminders — a weekly tape reminder and an optional daily weigh-in one.
///
/// Built on the same footing as `WindDownNudge`: repeating `UNCalendarNotificationTrigger`s, its own
/// UserDefaults keys, on-device only, and **default off** like every other notification in the project.
///
/// It also inherits that file's hard-won lesson about authorisation. `requestAuthorization` only shows
/// the system dialog while the status is `.notDetermined`; once denied it returns without a prompt, so
/// scheduling unconditionally leaves the app cheerfully arming reminders the OS will never deliver and
/// nothing in the UI to explain the silence. Denial is surfaced instead.
///
/// **Why a weekly default for the tape.** Circumferences move slowly and are measured with error; a
/// daily reminder invites daily measurement, which produces a series where the noise is larger than
/// the signal and a chart that looks like progress or decline depending on the day. Weekly is the
/// cadence at which a real change can outgrow the method's own spread.
@MainActor
enum BodyMeasurementReminder {

    private static let weeklyRequestId = "body-measurement-weekly"
    private static let dailyRequestId = "body-weigh-in-daily"

    private enum K {
        static let weeklyEnabled = "body.reminder.weekly.enabled"
        static let weeklyWeekday = "body.reminder.weekly.weekday"   // 1 = Sunday … 7 = Saturday
        static let weeklyMinutes = "body.reminder.weekly.minutes"   // minutes since midnight
        static let dailyEnabled = "body.reminder.daily.enabled"
        static let dailyMinutes = "body.reminder.daily.minutes"
        /// The weekdays the weigh-in reminder comes on (1 = Sunday ... 7 = Saturday); absent = every day.
        static let dailyWeekdays = "body.reminder.daily.weekdays"
        /// The last day a weigh-in was logged in NOOP, so that day's reminder stays quiet.
        static let lastWeighInDay = "body.reminder.daily.lastWeighInDay"
    }

    enum Outcome { case scheduled, denied, off }

    // MARK: - Settings

    static var weeklyEnabled: Bool { UserDefaults.standard.bool(forKey: K.weeklyEnabled) }
    static var dailyEnabled: Bool { UserDefaults.standard.bool(forKey: K.dailyEnabled) }

    /// Defaults to Sunday morning: a rest day for most people, and before the day's food and water
    /// have moved the numbers.
    static var weeklyWeekday: Int {
        get { min(max(UserDefaults.standard.object(forKey: K.weeklyWeekday) as? Int ?? 1, 1), 7) }
        set { UserDefaults.standard.set(min(max(newValue, 1), 7), forKey: K.weeklyWeekday) }
    }

    static var weeklyMinutes: Int {
        get { clampMinute(UserDefaults.standard.object(forKey: K.weeklyMinutes) as? Int ?? 8 * 60) }
        set { UserDefaults.standard.set(clampMinute(newValue), forKey: K.weeklyMinutes) }
    }

    static var dailyMinutes: Int {
        get { clampMinute(UserDefaults.standard.object(forKey: K.dailyMinutes) as? Int ?? 7 * 60) }
        set { UserDefaults.standard.set(clampMinute(newValue), forKey: K.dailyMinutes) }
    }

    /// The weekdays the weigh-in reminder comes on, 1 = Sunday ... 7 = Saturday; empty means every day.
    static var dailyWeekdays: Set<Int> {
        get { Set((UserDefaults.standard.array(forKey: K.dailyWeekdays) as? [Int] ?? []).filter { (1...7).contains($0) }) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: K.dailyWeekdays) }
    }

    /// A weigh-in was logged on `day`: that day's reminder is taken back (owner, 2026-11-26), and the next ones armed.
    static func noteWeighIn(day: String) {
        UserDefaults.standard.set(day, forKey: K.lastWeighInDay)
        refresh()
    }

    private static func clampMinute(_ value: Int) -> Int { min(max(value, 0), 24 * 60 - 1) }

    /// How many weigh-in reminders are armed ahead. Each is a single date, so a day with a weigh-in can be
    /// skipped; opening the app re-arms the rolling window.
    private static let dailyAhead = 14

    // MARK: - Enabling

    /// Turns a reminder on or off, surfacing a denied authorisation rather than scheduling into a void.
    static func setEnabled(_ on: Bool, daily: Bool,
                           completion: (@MainActor (Outcome) -> Void)? = nil) {
        let key = daily ? K.dailyEnabled : K.weeklyEnabled
        guard on else {
            UserDefaults.standard.set(false, forKey: key)
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: daily ? [dailyRequestId] + (0..<dailyAhead).map { "\(dailyRequestId)-\($0)" }
                                       : [weeklyRequestId])
            completion?(.off)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    UserDefaults.standard.set(true, forKey: key)
                    schedule()
                    completion?(.scheduled)
                case .notDetermined:
                    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        Task { @MainActor in
                            UserDefaults.standard.set(granted, forKey: key)
                            if granted { schedule() }
                            completion?(granted ? .scheduled : .denied)
                        }
                    }
                default:
                    UserDefaults.standard.set(false, forKey: key)
                    completion?(.denied)
                }
            }
        }
    }

    /// Re-arms whatever is currently enabled. Safe to call on launch and after a settings edit.
    static func refresh() {
        guard weeklyEnabled || dailyEnabled else { return }
        schedule()
    }

    // MARK: - Scheduling

    private static func schedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [weeklyRequestId, dailyRequestId]
                                                 + (0..<dailyAhead).map { "\(dailyRequestId)-\($0)" })

        if weeklyEnabled {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Measurement day")
            content.body = String(localized: "Same tape, same spots, same time of day — that consistency is what makes the trend readable.")
            content.sound = .default
            var components = DateComponents()
            components.weekday = weeklyWeekday
            components.hour = weeklyMinutes / 60
            components.minute = weeklyMinutes % 60
            center.add(UNNotificationRequest(
                identifier: weeklyRequestId, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)))
        }

        if dailyEnabled {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Weigh-in")
            content.body = String(localized: "Before breakfast, after the bathroom. Day-to-day noise is normal — the trend is what moves.")
            content.sound = .default
            // Single dates rather than one repeating trigger: a repeating one cannot skip the day that already
            // has a weigh-in, nor the weekdays left out.
            let weighed = UserDefaults.standard.string(forKey: K.lastWeighInDay).map { Set([$0]) } ?? []
            let times = WeightTracker.reminderTimes(after: Date(), minutes: dailyMinutes, weekdays: dailyWeekdays,
                                                    weighedInDays: weighed, count: dailyAhead)
            for (i, time) in times.enumerated() {
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: time)
                center.add(UNNotificationRequest(
                    identifier: "\(dailyRequestId)-\(i)", content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
            }
        }
    }
}
