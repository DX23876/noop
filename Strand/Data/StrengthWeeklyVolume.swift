import Foundation

/// The Strength page's volume card, shared by iOS (`ForgeStrengthView`) and the Android core: tonnes lifted in each
/// of the last eight finished weeks, oldest first, and how the latest four weeks compare with the four before.
/// The week that is still running is left out, so a Monday does not read as a collapse.
enum StrengthWeeklyVolume {
    /// One strength session's start and its volume load (Σ weight × reps over working sets), in kilograms.
    struct Session: Equatable {
        let startTs: Int
        let volumeKg: Double
    }

    static let weeks = 8

    /// Tonnes per finished week, oldest first; index 7 is last week. Sessions in the running week or more than eight
    /// weeks back count nowhere.
    static func tonnes(_ sessions: [Session], now: Date, firstWeekday: Int, calendar base: Calendar = .current) -> [Double] {
        var cal = base
        cal.firstWeekday = firstWeekday
        guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var totals = Array(repeating: 0.0, count: weeks)
        for s in sessions {
            let start = Date(timeIntervalSince1970: TimeInterval(s.startTs))
            guard let week = cal.dateInterval(of: .weekOfYear, for: start)?.start,
                  let back = cal.dateComponents([.weekOfYear], from: week, to: thisWeek).weekOfYear,
                  (1...weeks).contains(back) else { continue }
            totals[weeks - back] += s.volumeKg / 1000
        }
        return totals
    }

    /// The latest four weeks against the four before, in whole percent (truncated toward zero); nil when either half
    /// has no volume. A change under 3 % in either direction reads as "about the same" on the page.
    static func fourWeekChange(_ tonnes: [Double]) -> Int? {
        guard tonnes.count == weeks else { return nil }
        let before = tonnes.prefix(4).reduce(0, +), after = tonnes.suffix(4).reduce(0, +)
        guard before > 0, after > 0 else { return nil }
        return Int(((after / before) - 1) * 100)
    }
}
