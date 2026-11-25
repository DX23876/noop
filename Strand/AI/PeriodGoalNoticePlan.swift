import Foundation

/// Which optional notices a wearer's weekly goals call for, and when, decided once for both platforms.
///
/// Off by default per kind (`GoalPrefs.NotificationKind`). The Apple app turns the result into one-shot
/// calendar notifications (`GoalNotifier.reschedule`); the Android app turns the same result into alarms
/// (`goals.notices` in the shared core). Nothing here touches a notification centre.
enum PeriodGoalNoticePlan {
    static let weekStartId = "goals.notify.weekStart"
    static let midWeekId = "goals.notify.midWeek"
    static let reviewId = "goals.notify.review"

    struct Notice: Equatable {
        let id: String
        let title: String
        let body: String
        let at: Date
    }

    /// The notices for the current week, in the order they fire. `calendar` carries the wearer's week start;
    /// `isQuiet` is the quiet-hours test for the moment a notice would fire.
    static func plan(_ snapshots: [PeriodGoalSnapshot], kinds: Set<GoalPrefs.NotificationKind>, now: Date,
                     calendar: Calendar, isQuiet: (Date) -> Bool) -> [Notice] {
        let week = snapshots.filter { $0.goal.status == .active && $0.goal.period == .week }
        guard !week.isEmpty, let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        func at(_ day: Date, hour: Int) -> Date? { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) }
        var out: [Notice] = []
        func add(_ id: String, title: String, body: String, at date: Date) {
            guard !isQuiet(date), !body.isEmpty else { return }
            out.append(Notice(id: id, title: title, body: body, at: date))
        }

        if kinds.contains(.weekStart),
           let next = calendar.date(byAdding: .day, value: 7, to: interval.start).flatMap({ at($0, hour: 8) }) {
            add(weekStartId, title: String(localized: "A new week"),
                body: week.map { GoalFormat.title($0.goal) }.prefix(3).joined(separator: " · "), at: next)
        }
        if kinds.contains(.midWeek),
           let slipping = PeriodGoalMaintenance.slipping(week),
           let thursday = calendar.date(byAdding: .day, value: 3, to: interval.start).flatMap({ at($0, hour: 18) }),
           thursday > now {
            add(midWeekId, title: GoalFormat.shortName(slipping.goal), body: GoalFormat.remainingLine(slipping),
                at: thursday)
        }
        if kinds.contains(.review),
           let lastDay = calendar.date(byAdding: .day, value: 6, to: interval.start).flatMap({ at($0, hour: 19) }),
           lastDay > now {
            add(reviewId, title: String(localized: "Your week"),
                body: String(localized: "See how your goals went and set up the next week."), at: lastDay)
        }
        return out
    }
}
