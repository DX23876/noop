import Foundation
import StrandCore
import WhoopStore

/// The logical day: the calendar date of `now` minus the rollover hour, so the small hours after midnight still
/// read as the day before (#144). Shared by the Apple `Repository` and the Android core.
enum LogicalDay {
    /// The hour the LOGICAL day rolls (04:00 local). Between midnight and this hour, "Today" stays put.
    static let rolloverHour = 4

    static func date(_ now: Date, rolloverHour: Int = rolloverHour) -> Date {
        now.addingTimeInterval(-Double(rolloverHour) * 3_600)
    }

    /// `yyyy-MM-dd` key for the logical day of `now`.
    static func key(_ now: Date, rolloverHour: Int = rolloverHour) -> String {
        StoreReader.localDayKey(date(now, rolloverHour: rolloverHour))
    }
}

/// The last scored night Today carries over while today has no Charge yet (#543), and its caption. Moved out of
/// `TodayView` so Momentum on Android carries the same day with the same words.
enum CarriedRecovery {
    /// How many days a carried score stays "last night" before it reads as "latest sleep" (#779).
    static let freshnessDays = 2

    static func lastScored(days: [DailyMetric], selectedDayKey: String,
                           isToday: Bool, todayScored: Bool, isCalibrating: Bool) -> DailyMetric? {
        guard isToday, !todayScored, !isCalibrating else { return nil }
        // Defensive future-day guard (#547): never a day after today's key.
        return days.last(where: { $0.recovery != nil && $0.day < selectedDayKey })
    }

    /// True when the carried scored day is older than the freshness cap (#779). An unparseable key reads as fresh.
    static func isStale(priorDayKey: String, todayKey: String) -> Bool {
        guard let prior = dayKeyParser.date(from: priorDayKey),
              let today = dayKeyParser.date(from: todayKey) else { return false }
        let days = Calendar.current.dateComponents([.day], from: prior, to: today).day ?? 0
        return days > freshnessDays
    }

    static func caption(priorDayKey: String, todayKey: String) -> String {
        let date = shortDate(priorDayKey)
        return isStale(priorDayKey: priorDayKey, todayKey: todayKey)
            ? String(localized: "Latest sleep · \(date)")
            : String(localized: "Last night · \(date)")
    }

    static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "d MMM" for a stored day key, in the app's language.
    static func shortDate(_ dayKey: String) -> String {
        guard let date = dayKeyParser.date(from: dayKey) else { return dayKey }
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: date)
    }
}
