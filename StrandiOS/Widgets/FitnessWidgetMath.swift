#if os(iOS)
import Foundation

/// The pure arithmetic behind the fitness widgets, kept apart from the publisher so it can be tested
/// without the app, the database or a calendar that moves.
enum FitnessWidgetMath {

    /// The middle of a wearer's recent values: mean ± one standard deviation of the non-nil values.
    /// Nil below `minimum` values, where a band would only describe a handful of nights.
    static func usual(_ values: [Double?], minimum: Int = 7) -> FitnessWidgetSnapshot.Usual? {
        let xs = values.compactMap { $0 }
        guard xs.count >= minimum else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
        let sd = variance.squareRoot()
        return .init(low: mean - sd, high: mean + sd)
    }

    /// The day keys of the `count` days ending at `today`, oldest first.
    static func dayKeys(endingAt today: Date, count: Int, calendar: Calendar) -> [String] {
        let start = calendar.startOfDay(for: today)
        return (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: start).map { key($0, calendar: calendar) }
        }
    }

    /// yyyy-MM-dd in the calendar's time zone, the key every stored day uses.
    static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The training week containing `today` (first weekday first) as day keys, and today's index in it.
    static func week(containing today: Date, calendar: Calendar) -> (keys: [String], todayIndex: Int) {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: today) else { return ([], 0) }
        let keys = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
            .map { key($0, calendar: calendar) }
        let todayKey = key(today, calendar: calendar)
        return (keys, keys.firstIndex(of: todayKey) ?? 0)
    }

    /// Latest minus earliest of a window of readings; nil with fewer than two.
    static func change(_ readings: [Double]) -> Double? {
        guard readings.count >= 2, let first = readings.first, let last = readings.last else { return nil }
        return last - first
    }
}
#endif
