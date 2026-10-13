import Foundation
import StrandAnalytics

/// The next moment the strap alarm will actually buzz, and how its times read, for every screen that
/// states them (the Alarms screen and Today).
///
/// One gated resolver on purpose: the Alarms screen once carried several readouts of this fact that could
/// disagree. Every caller passes its own clock, so two lines drawn from one tick resolve the same moment.
/// Every time goes through the Clock setting (`AppClock`), so Today and the Alarms screen cannot show one
/// alarm in two formats.
enum NextStrapAlarm {

    /// Whether an alarm set in NOOP reaches the strap at all. A WHOOP 5/MG only takes one with the Puffin
    /// experiments on; without them nothing buzzes, so nothing may promise that it will.
    static func willArm(whoop5Detected: Bool) -> Bool {
        !(whoop5Detected && !PuffinExperiment.isEnabled)
    }

    /// The next fire, or nil when the alarm is off or will not be armed. Resolved through the same
    /// `nextSmartAlarmDate` the strap is armed from, so a day with its own time resolves to that time.
    static func date(enabled: Bool, willArm: Bool, minutes: Int, weekdays: Set<Int>,
                     overrides: [Int: Int], from now: Date) -> Date? {
        guard enabled, willArm else { return nil }
        return AppModel.nextSmartAlarmDate(minutes: minutes, weekdays: weekdays, overrides: overrides, from: now)
    }

    /// How a time of day reads under the Clock setting.
    struct Style {
        var locale: Locale
        var uses24Hour: Bool

        static var app: Style { Style(locale: AppClock.activeLocale, uses24Hour: AppClock.uses24Hour) }

        /// `skeleton` plus the hour and minute, the H-versus-h choice being the setting's.
        func format(_ date: Date, skeleton: String = "", calendar: Calendar = .current) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(skeleton + ClockFormat.hourMinuteTemplate(uses24Hour: uses24Hour))
            return f.string(from: date)
        }
    }

    /// The fire as a short phrase: "today 15:00", "tomorrow 06:00", or the weekday ("Wed 06:00") further out.
    static func shortLabel(for fire: Date, now: Date, calendar: Calendar = .current,
                           style: Style = .app) -> String {
        let time = style.format(fire, calendar: calendar)
        if calendar.isDate(fire, inSameDayAs: now) { return String(localized: "today \(time)") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(fire, inSameDayAs: tomorrow) {
            return String(localized: "tomorrow \(time)")
        }
        return style.format(fire, skeleton: "EEE", calendar: calendar)
    }

    /// A wake minute of the day (0..<1440) as a time, for schedule figures that are not a dated fire.
    static func timeOfDay(minutes: Int, style: Style = .app, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: Date())
        let date = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
        return style.format(date, calendar: calendar)
    }
}
