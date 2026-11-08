import Foundation
import WhoopStore

extension FoodLog {
    /// The seven days of the Food page's week strip, oldest first. The strip ends today while the shown day lies
    /// within the last seven days, else on the shown day, so tapping a day of the strip never moves the strip.
    public static func weekDays(shown: String, today: String, calendar: Calendar = .current) -> [String] {
        guard let shownDate = WeightSeries.date(forDay: shown), let todayDate = WeightSeries.date(forDay: today) else { return [] }
        let span = FoodScore.window - 1
        let weekStart = calendar.date(byAdding: .day, value: -span, to: todayDate) ?? todayDate
        let last = shownDate >= weekStart && shownDate <= todayDate ? todayDate : shownDate
        return (0...span).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: last) }
            .map(StoreReader.localDayKey)
    }
}
