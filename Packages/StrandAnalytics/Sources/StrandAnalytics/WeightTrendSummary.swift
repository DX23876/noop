import Foundation

// WeightTrendSummary.swift — the numbers a weight screen shows, derived once so every surface agrees.
//
// Pure, DB-free, clock-injected. It composes what already exists rather than adding new maths:
// `GoalMeasure.weightTrend` (the 10-day-half-life EWMA that goal tracking already judges a weight goal
// on) and `GoalMilestones.observedRatePerDay` (its least-squares rate fit). A second smoothing here
// would give the app two different answers to "what do I weigh?", which is exactly what
// `GoalMeasure.smoothedSeries`' doc comment warns about.
//
// Every derived figure is read off the SMOOTHED series, never off raw scale readings. A person weighs
// 1–2 kg more after a salty dinner; "you gained 1.4 kg this week" computed from two raw mornings is
// noise presented as a fact. The latest RAW reading is still reported — it is what the scale said, and
// hiding it would be its own dishonesty — but it is labelled separately from the trend.

/// What a weight screen needs to render: the last reading, the smoothed trend, and how that trend has
/// moved. Any figure that cannot be honestly derived is `nil`, never zero.
public struct WeightTrendSummary: Equatable, Sendable {

    /// The most recent plausible reading, exactly as measured.
    public let latestKg: Double
    /// When that reading was taken.
    public let latestAt: Date
    /// The smoothed centre — the number a goal, a rate or a comparison should be computed from.
    public let trendKg: Double
    /// False while the EWMA is still cold-starting (fewer than `GoalMeasure.trendReliableAfter`
    /// readings). Show the number, but do not turn it into a verdict yet.
    public let isTrendReliable: Bool
    /// Change in the TREND over the last 7 days. Nil when no reading is old enough to compare against.
    public let change7dKg: Double?
    /// Change in the TREND over the last 30 days. Nil when nothing that old exists.
    public let change30dKg: Double?
    /// Least-squares rate through the smoothed series, in kg per week. Nil until the fit has enough
    /// span and enough points to mean anything (`GoalMilestones.minimumRateDays` / `minimumRatePoints`).
    public let ratePerWeekKg: Double?
    /// How many readings the summary rests on.
    public let readingCount: Int

    public init(latestKg: Double, latestAt: Date, trendKg: Double, isTrendReliable: Bool,
                change7dKg: Double?, change30dKg: Double?, ratePerWeekKg: Double?, readingCount: Int) {
        self.latestKg = latestKg
        self.latestAt = latestAt
        self.trendKg = trendKg
        self.isTrendReliable = isTrendReliable
        self.change7dKg = change7dKg
        self.change30dKg = change30dKg
        self.ratePerWeekKg = ratePerWeekKg
        self.readingCount = readingCount
    }
}
extension WeightTrendSummary {

    /// The smoothed series itself, dated — for a caller that wants to DRAW the trend rather than read
    /// its endpoint. Same filter and same fold as `summarize`, so the line a chart plots and the number
    /// beside it can never come from two different smoothings.
    ///
    /// Returns one centre per KEPT reading (implausible ones are dropped by the shared rule), paired
    /// with that reading's own date — which is why the filtering happens here and not at the call site.
    public static func smoothedSeries(_ samples: [(date: Date, value: Double)]) -> [(date: Date, value: Double)] {
        let usable = samples
            .filter { GoalMeasure.isPlausible($0.value, cfg: GoalMeasure.weightTrend) }
            .sorted { $0.date < $1.date }
        let centres = GoalMeasure.smoothedSeries(usable.map(\.value), cfg: GoalMeasure.weightTrend)
        return zip(usable.map(\.date), centres).map { (date: $0, value: $1) }
    }

    /// Derive the summary from dated weigh-ins, in any order. Returns nil when nothing plausible
    /// remains — an empty scale history has no summary, and a fabricated one would be worse.
    ///
    /// Implausible readings (a 0 kg sample, a pounds figure mistaken for kg) are dropped with the SAME
    /// rule the fold applies (`GoalMeasure.isPlausible`), because `smoothedSeries` returns one centre
    /// per kept value: filtering here and not there would shift every centre onto the wrong date.
    public static func summarize(_ samples: [(date: Date, value: Double)],
                                 now: Date = Date()) -> WeightTrendSummary? {
        let usable = samples
            .filter { GoalMeasure.isPlausible($0.value, cfg: GoalMeasure.weightTrend) }
            .sorted { $0.date < $1.date }
        guard let newest = usable.last else { return nil }

        let centres = GoalMeasure.smoothedSeries(usable.map(\.value), cfg: GoalMeasure.weightTrend)
        guard let trend = centres.last else { return nil }
        let dated = zip(usable.map(\.date), centres).map { (date: $0, centre: $1) }

        /// The smoothed centre as it stood at or before `days` ago — the honest "what did the trend
        /// read back then?". Nil when the history does not reach that far: a 4-day history has no
        /// 30-day change, and answering 0 would claim stability nobody measured.
        func centre(daysAgo days: Int) -> Double? {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            return dated.last(where: { $0.date <= cutoff })?.centre
        }

        let rate = GoalMilestones.observedRatePerDay(
            series: dated.map { GoalMilestones.Sample(date: $0.date, value: $0.centre) },
            now: now)

        return WeightTrendSummary(
            latestKg: newest.value,
            latestAt: newest.date,
            trendKg: trend,
            isTrendReliable: centres.count >= GoalMeasure.trendReliableAfter,
            change7dKg: centre(daysAgo: 7).map { trend - $0 },
            change30dKg: centre(daysAgo: 30).map { trend - $0 },
            ratePerWeekKg: rate.map { $0 * 7.0 },
            readingCount: usable.count
        )
    }
}
