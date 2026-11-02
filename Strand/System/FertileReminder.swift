import Foundation
@preconcurrency import UserNotifications

/// A heads-up before and on the first likely fertile day of the cycle (tester request, 2026-11).
///
/// Same footing as `BodyMeasurementReminder`: on-device `UNCalendarNotificationTrigger`s, its own UserDefaults
/// keys, **default off**, and a denied authorisation is surfaced rather than scheduled into a void. Unlike the
/// repeating reminders it arms two one-shot notifications for the current estimate (the evening before and
/// the morning of the first day) and re-arms them whenever the cycle page or card recomputes, so a window that
/// moves, closes or disappears takes its notifications with it.
///
/// A lock screen is read by whoever holds the phone, so the text is **discreet by default**: "Cycle update"
/// rather than anything about fertility. The wearer can switch to the plain wording.
@MainActor
enum FertileReminder {

    private static let eveId = "cycle-fertile-eve"
    private static let startId = "cycle-fertile-start"

    private enum K {
        static let enabled = "cycle.fertileReminder.enabled"
        static let discreet = "cycle.fertileReminder.discreet"
        /// The window start the cycle page last worked out, so a switch flipped elsewhere can arm it.
        static let windowStart = "cycle.fertileReminder.windowStart"
    }

    enum Outcome { case scheduled, denied, off }

    static let enabledKey = K.enabled
    static let discreetKey = K.discreet

    static var enabled: Bool { UserDefaults.standard.bool(forKey: K.enabled) }
    static var discreet: Bool { UserDefaults.standard.object(forKey: K.discreet) as? Bool ?? true }

    /// The morning notification's time and the evening one's, in minutes since midnight.
    static let morningMinutes = 8 * 60
    static let eveningMinutes = 20 * 60

    // MARK: - Enabling

    /// The last window start the cycle page or card worked out, nil when none lies ahead.
    static var storedWindowStart: Date? {
        (UserDefaults.standard.object(forKey: K.windowStart) as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    static func setDiscreet(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: K.discreet)
        reschedule(windowStart: storedWindowStart)
    }

    static func setEnabled(_ on: Bool, windowStart: Date? = storedWindowStart, completion: (@MainActor (Outcome) -> Void)? = nil) {
        guard on else {
            UserDefaults.standard.set(false, forKey: K.enabled)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [eveId, startId])
            completion?(.off)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    UserDefaults.standard.set(true, forKey: K.enabled)
                    reschedule(windowStart: windowStart)
                    completion?(.scheduled)
                case .notDetermined:
                    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        Task { @MainActor in
                            UserDefaults.standard.set(granted, forKey: K.enabled)
                            if granted { reschedule(windowStart: windowStart) }
                            completion?(granted ? .scheduled : .denied)
                        }
                    }
                default:
                    UserDefaults.standard.set(false, forKey: K.enabled)
                    completion?(.denied)
                }
            }
        }
    }

    // MARK: - Scheduling

    /// Arms the two notifications for a window starting on `windowStart` (a local day), or clears them when
    /// there is no window ahead. Only times still in the future are armed.
    static func reschedule(windowStart: Date?, now: Date = Date()) {
        if let windowStart {
            UserDefaults.standard.set(windowStart.timeIntervalSince1970, forKey: K.windowStart)
        } else {
            UserDefaults.standard.removeObject(forKey: K.windowStart)
        }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [eveId, startId])
        guard enabled, let windowStart else { return }
        let cal = Calendar.current
        let day = cal.startOfDay(for: windowStart)
        guard let eveDay = cal.date(byAdding: .day, value: -1, to: day) else { return }

        func at(_ base: Date, _ minutes: Int) -> Date? {
            cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: base)
        }
        let quiet = discreet
        let items: [(String, Date?, String, String)] = [
            (eveId, at(eveDay, eveningMinutes),
             quiet ? String(localized: "Cycle update") : String(localized: "Fertile days start tomorrow"),
             quiet ? String(localized: "Open NOOP to see your cycle.") : String(localized: "A rough estimate from your past cycles. Not birth control.")),
            (startId, at(day, morningMinutes),
             quiet ? String(localized: "Cycle update") : String(localized: "Likely fertile from today"),
             quiet ? String(localized: "Open NOOP to see your cycle.") : String(localized: "A rough estimate from your past cycles. Not birth control.")),
        ]
        for (id, date, title, body) in items {
            guard let date, date > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let components = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            center.add(UNNotificationRequest(identifier: id, content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        }
    }
}
