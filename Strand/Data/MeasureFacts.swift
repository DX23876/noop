import Foundation

/// What a measure tile knows about itself beyond today's figure, shared by the iPhone and the Android core.
///
/// The owner's correction of 2026-11-18: a tile that is given more room should say MORE FACTS, not the same
/// figure over a longer span. Steps at two columns adds the week and the daily average; weight adds when it
/// was last weighed and which way it has gone. So one read produces one bundle, and each size of each tile
/// picks what it needs from it.
///
/// One bundle, computed once, is the point. The same week must not be averaged in Swift for the iPhone and
/// again in Kotlin for Android: that is exactly where two numbers for one fact start to disagree, which the
/// fork rules forbid above almost everything else. The platforms keep their own WORDS (each writes
/// "diese Woche" or "this week" in its own catalogue), as they already do for `MeasureTileReading.summary`.
///
/// Pure: dates in, numbers out, no store and no clock of its own. Analysis migration required: no.
enum MeasureFacts {

    /// A day and its value, oldest first, as every series on both platforms is already ordered.
    struct Point: Equatable, Sendable {
        let day: String
        let value: Double
        init(day: String, value: Double) { self.day = day; self.value = value }
    }

    /// Everything a tile can ask about one measure. A field is nil when the data cannot answer it, never a
    /// stand-in: a measure with no reading today has no `today`, and a tile must say so rather than show
    /// the last one as if it were current.
    struct Facts: Equatable, Sendable {
        /// Today's reading, nil when nothing was recorded today.
        let today: Double?
        /// The mean of the days that HAVE a reading in the last seven, nil when none do. Missing days are
        /// skipped rather than counted as zero: a day without a weigh-in is not a weight of nothing.
        let weekAverage: Double?
        /// The sum over the last seven days. Only meaningful for day totals (steps, minutes, calories), and
        /// the tile decides whether to show it.
        let weekTotal: Double?
        /// The newest reading there is, however old. This is what "last weighed" reads.
        let lastValue: Double?
        let lastDay: String?
        /// Whole days between `lastDay` and today. 0 means today, 1 yesterday.
        let daysSinceLast: Int?
        /// The newest reading minus the newest one at least seven days older, nil without both. The honest
        /// way to say "which way it has gone this week" for a measure that is not recorded daily.
        let weekChange: Double?
        /// The day's goal, when the caller has one (calories, protein, water, steps).
        let target: Double?
        /// `target` minus today's reading, floored at zero, nil without both.
        let targetLeft: Double?
        /// The last thirty readings in order, for the row-wide form's curve.
        let last30: [Double]
    }

    /// Read one measure's facts from its series.
    ///
    /// - Parameters:
    ///   - points: the series, oldest first, one point per day that HAS a reading. Days without one are
    ///     simply absent; nothing is interpolated.
    ///   - today: the logical day key the caller counts from, passed in rather than read, so a test can
    ///     place "today" where it wants it and the two platforms cannot disagree about when today is.
    ///   - target: the day's goal, where the caller has one.
    static func read(points: [Point], today: String, target: Double? = nil) -> Facts {
        let ordered = points.sorted { $0.day < $1.day }
        let todayValue = ordered.last(where: { $0.day == today })?.value
        let last = ordered.last

        // The seven days ending today, by day key rather than by position: a gappy series would otherwise
        // reach weeks back and call it a week.
        let weekStart = dayKey(today, minusDays: 6)
        let week = ordered.filter { $0.day >= weekStart && $0.day <= today }
        let weekValues = week.map(\.value)

        let daysSince = last.flatMap { days(from: $0.day, to: today) }
        let change = last.flatMap { newest -> Double? in
            guard let cutoff = dayKey(newest.day, minusDays: 7) as String?,
                  let before = ordered.last(where: { $0.day <= cutoff }) else { return nil }
            return newest.value - before.value
        }
        let left = target.flatMap { t in todayValue.map { max(0, t - $0) } }

        return Facts(today: todayValue,
                     weekAverage: weekValues.isEmpty ? nil : weekValues.reduce(0, +) / Double(weekValues.count),
                     weekTotal: weekValues.isEmpty ? nil : weekValues.reduce(0, +),
                     lastValue: last?.value, lastDay: last?.day, daysSinceLast: daysSince,
                     weekChange: change, target: target, targetLeft: left,
                     last30: Array(ordered.suffix(30).map(\.value)))
    }

    // MARK: - Day keys

    /// Day keys are "yyyy-MM-dd" on both platforms, so they are compared as text and shifted as dates. A key
    /// that does not parse yields the key itself, which keeps a malformed series harmless rather than fatal.
    static func dayKey(_ day: String, minusDays: Int) -> String {
        guard let date = formatter.date(from: day) else { return day }
        return formatter.string(from: date.addingTimeInterval(-Double(minusDays) * 86_400))
    }

    static func days(from: String, to: String) -> Int? {
        guard let a = formatter.date(from: from), let b = formatter.date(from: to) else { return nil }
        return Int(((b.timeIntervalSince1970 - a.timeIntervalSince1970) / 86_400).rounded())
    }

    /// UTC, because a day key is a label and not a moment: shifting it must not depend on where the phone is
    /// or on whether the clocks changed last night.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
