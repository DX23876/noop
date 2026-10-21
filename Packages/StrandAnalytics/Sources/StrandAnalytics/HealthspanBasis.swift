import Foundation

// HealthspanBasis.swift — fork feature "AgeLess" (backlog plan HEALTHSPAN_AGE_PLAN, stage "Datenbasis",
// 2026-10-13): what each measure of a week stands on, and when that is too little to lean on.
//
// The counts are taken from the same window days the week's inputs are averaged over (`HealthspanWindow.weekly`),
// so a measure and its basis come out of one pass and cannot disagree. The thresholds are reasoned starting
// values, not validated ones; they sit together here so they can be re-tuned in one place.

public enum HealthspanBasis {

    /// A daily measure is thin when fewer than this share of the window's days have it.
    public static let minimumDayShare = 0.6
    /// Banked days of zone minutes before a weekly rate is more than a glimpse: four weeks.
    public static let minimumZoneDays = 28
    /// A body-fat reading older than this no longer describes the body the week measured.
    public static let bodyFatFreshDays = 90

    /// Per measure, how many of the window's days stand behind it; for strength, how many sessions. VO₂max and
    /// lean mass come from readings outside the daily values and are not counted here.
    public static func counts(_ days: [HealthspanDay]) -> [HealthspanEngine.Component: Int] {
        func n(_ f: (HealthspanDay) -> Double?) -> Int { days.filter { f($0) != nil }.count }
        return [.sleepDuration: n(\.sleepHours), .sleepConsistency: n(\.sleepConsistencyPct),
                .dailySteps: n(\.steps), .restingHR: n(\.sleepMeanHR), .zone13: n(\.zone13Min),
                .zone45: n(\.zone45Min), .strength: days.compactMap(\.strengthSessions).reduce(0, +)]
    }

    /// What one measure's line says.
    public enum Kind: Equatable, Sendable {
        /// Days with a value out of the days the window covers (sleep, consistency, steps, sleeping HR).
        case days(count: Int, of: Int)
        /// Banked days of zone minutes.
        case zoneDays(count: Int)
        /// Strength sessions in the window.
        case sessions(count: Int)
        /// The VO₂max source, its readings in the window and the newest one's day.
        case vo2max(source: HealthspanVO2.Source, readings: Int, latestDay: String)
        /// The day of the body-fat reading lean mass is taken from.
        case bodyFat(day: String)
    }

    public struct Line: Equatable, Sendable {
        public let kind: Kind
        public let isThin: Bool
    }

    /// The line for one measure; nil when nothing is known about its basis. `count` is the stored count (VO₂max:
    /// its readings), `coveredDays` the week's span of data, `latestDay` the newest VO₂max or body-fat reading
    /// and `weekEnd` the last day of the week's window.
    public static func line(_ c: HealthspanEngine.Component, count: Int?, coveredDays: Int,
                            vo2Source: HealthspanVO2.Source?, latestDay: String?, weekEnd: String) -> Line? {
        switch c {
        case .sleepDuration, .sleepConsistency, .dailySteps, .restingHR:
            guard let count, coveredDays > 0 else { return nil }
            let of = min(coveredDays, HealthspanWindow.ageWindowDays)
            return Line(kind: .days(count: count, of: of), isThin: Double(count) < minimumDayShare * Double(of))
        case .zone13, .zone45:
            guard let count else { return nil }
            return Line(kind: .zoneDays(count: count), isThin: count < minimumZoneDays)
        case .strength:
            // No sessions is a true statement about the window, not a gap in it.
            guard let count else { return nil }
            return Line(kind: .sessions(count: count), isThin: false)
        case .vo2max:
            guard let vo2Source, let count, let latestDay else { return nil }
            // A measurement is a measurement: an entered lab value or Apple Watch's readings are never thin.
            return Line(kind: .vo2max(source: vo2Source, readings: count, latestDay: latestDay), isThin: false)
        case .leanMass:
            guard let latestDay else { return nil }
            return Line(kind: .bodyFat(day: latestDay),
                        isThin: latestDay < HealthspanWindow.dayKey(weekEnd, plus: -bodyFatFreshDays))
        }
    }

    // MARK: - Stored days

    /// A day key as a number for the metric store, which holds only numbers: "2026-10-03" → 20261003.
    public static func dayNumber(_ key: String) -> Double? {
        guard HealthspanWindow.date(key) != nil, let n = Int(key.replacingOccurrences(of: "-", with: "")) else { return nil }
        return Double(n)
    }

    /// The day key back from `dayNumber`; nil for anything that is not a calendar day.
    public static func dayKey(number: Double) -> String? {
        let n = Int(number)
        guard Double(n) == number else { return nil }
        let key = String(format: "%04d-%02d-%02d", n / 10_000, n / 100 % 100, n % 100)
        return HealthspanWindow.date(key).map { _ in key }
    }
}
