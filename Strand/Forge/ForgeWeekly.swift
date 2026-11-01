import Foundation

/// The redesign's weekly report (2026-11): this week against last week, from values other screens already
/// show (daily Charge, Effort, Rest, time asleep, steps). Only means and sums of those stored daily values;
/// nothing is scored again and nothing is stored.
///
/// Analysis migration required: no. Presentation only.
enum ForgeWeekly {

    struct DayValues: Equatable {
        var charge: Double?
        var effort: Double?
        var rest: Double?
        var asleepMin: Double?
        var steps: Double?
    }

    struct Week: Equatable {
        /// The seven day keys of the week, first day first.
        let days: [String]
        let values: [DayValues]

        func mean(_ pick: (DayValues) -> Double?) -> Double? {
            let xs = values.compactMap(pick)
            return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        }

        func sum(_ pick: (DayValues) -> Double?) -> Double? {
            let xs = values.compactMap(pick)
            return xs.isEmpty ? nil : xs.reduce(0, +)
        }

        /// The day with the highest value, as its index in `days`.
        func bestIndex(_ pick: (DayValues) -> Double?) -> Int? {
            values.indices.compactMap { i in pick(values[i]).map { (i, $0) } }.max(by: { $0.1 < $1.1 })?.0
        }
    }

    /// The week containing `date` (first day per `calendar.firstWeekday`) and the one before it.
    static func weeks(containing date: Date, calendar: Calendar, dayKey: (Date) -> String,
                      lookup: (String) -> DayValues) -> (this: Week, last: Week) {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        func week(from first: Date) -> Week {
            let keys = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }.map(dayKey)
            return Week(days: keys, values: keys.map(lookup))
        }
        let previous = calendar.date(byAdding: .day, value: -7, to: start) ?? start
        return (week(from: start), week(from: previous))
    }
}
