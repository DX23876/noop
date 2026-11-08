import Foundation
import WhoopStore

/// "As usual": when the wearer ate the same meal on several of the last days, the Food page offers it again at its
/// time of day, one tap away. Only a real habit qualifies, so the offer is rare and right rather than a guess.
public enum FoodRepeat {
    public struct Suggestion: Equatable, Sendable {
        public var kind: FoodLog.MealKind
        /// The most recent time it was eaten; logging copies these to today at the same time of day.
        public var entries: [FoodLogEntry]
        /// On how many of the last `window` days it was eaten.
        public var days: Int
    }

    /// Days looked back over, and how many of them must share the meal.
    public static let window = 7
    public static let minimumDays = 3

    /// The meal for the time of day `now`, if it is a habit and today has none of that kind yet. Snacks are never
    /// offered: they are too varied to call a habit. `history` holds the entries of the days before `today`.
    public static func suggestion(history: [FoodLogEntry], todayEntries: [FoodLogEntry], today: String, now: Date,
                                  calendar: Calendar = .current) -> Suggestion? {
        let kind = FoodLog.MealKind.around(now, calendar: calendar)
        guard kind != .snack,
              !FoodLog.meals(todayEntries, calendar: calendar).contains(where: { $0.kind == kind }),
              let todayDate = WeightSeries.date(forDay: today),
              let start = calendar.date(byAdding: .day, value: -window, to: todayDate) else { return nil }
        let first = StoreReader.localDayKey(start)
        var seen: [[String]: (days: Set<String>, latest: (day: String, entries: [FoodLogEntry]))] = [:]
        for (day, entries) in Dictionary(grouping: history.filter { $0.day >= first && $0.day < today }, by: \.day) {
            for meal in FoodLog.meals(entries, calendar: calendar) where meal.kind == kind {
                // A meal with a quick calorie entry has nothing to repeat exactly.
                let ids = meal.entries.compactMap(\.foodId)
                guard ids.count == meal.entries.count, !ids.isEmpty else { continue }
                let key = Array(Set(ids)).sorted()
                var record = seen[key] ?? (days: [], latest: (day: day, entries: meal.entries))
                record.days.insert(day)
                if day >= record.latest.day { record.latest = (day, meal.entries) }
                seen[key] = record
            }
        }
        // The habit eaten on most days; ties to the one eaten most recently, then by its foods, so it is stable.
        let best = seen.filter { $0.value.days.count >= minimumDays }.max { a, b in
            (a.value.days.count, a.value.latest.day, b.key.joined()) < (b.value.days.count, b.value.latest.day, a.key.joined())
        }
        guard let best else { return nil }
        return Suggestion(kind: kind, entries: best.value.latest.entries, days: best.value.days.count)
    }
}
