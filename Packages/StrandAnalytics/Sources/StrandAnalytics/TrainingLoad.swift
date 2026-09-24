import Foundation

// MARK: - Training load, kept in the units each kind of training is actually measured in
//
// The question this answers: how much did this week ask of you, and is that unusual for you. The
// question it refuses: how much did lifting and cardio ask of you TOGETHER, as one number. There is no
// exchange rate between a heart-rate minute and a hard set, and inventing one is how a training-load
// score stops being a measurement.
//
// So there are three figures, deliberately separate:
//
//   • CARDIOVASCULAR LOAD — classic Edwards TRIMP, kept separate from Effort.
//   • STRENGTH LOAD — working sets, weighted by how close each went to failure.
//   • SESSION LOAD — session RPE × duration (Foster 1998), the athlete's own verdict on the whole
//     session. Not a fallback for the other two: a different question, answerable on days the set
//     data cannot describe.
//
// WHY NOT TONNAGE. Sets × reps × kilos looks like the obvious strength load and gets the ordering
// wrong. Four sets of ten at 100 kg is 4 000 kg; five triples at 180 kg is 2 700 kg — and the second
// session is the harder one, neuromuscularly and in what it costs to recover from. Tonnage rewards
// high-rep, sub-maximal work and reads a heavy top-end session as light. It offers a precision it does
// not have, so it stays a statistic on the Strength screen and is never the load.
//
// WHY SETS ARE BETTER THAN THEY SOUND. A plain count of WORKING sets — warmups excluded — tracks
// weekly fatigue surprisingly well, which is why hypertrophy research reports weekly set volume rather
// than tonnage. Its one real weakness is that it treats an easy set and a set to failure alike, and
// that is exactly what the effort weighting below fixes.

/// Working-set load for a period, weighted by proximity to failure.
public struct StrengthLoad: Equatable, Sendable {
    /// Effort-weighted working sets. The headline figure.
    public let weightedSets: Double
    /// Working sets before weighting, so the screen can show what it rests on.
    public let workingSets: Int
    /// Working sets that carried an RPE. Kept as a count beside the share, because "31 of 40 sets" is
    /// what a screen should say; a percentage alone hides how few sets it may rest on.
    public let ratedSets: Int
    /// Share of those sets that carried an RPE. Below `TrainingLoad.trustedRatedShare` the weighting is
    /// mostly the unrated default, which the caller should say out loud rather than imply precision.
    public let ratedShare: Double

    /// True when unrated sets used the athlete's recent ratings instead of the neutral start value.
    public let usedPersonalUnratedEstimate: Bool
    /// Weight assigned to each unrated set. Exposed so the UI can explain the estimate.
    public let unratedWeight: Double

    public var isMostlyUnrated: Bool { ratedShare < TrainingLoad.trustedRatedShare }
}

/// Session RPE × duration, in the arbitrary units Foster's method reports.
public struct SessionLoad: Equatable, Sendable {
    /// Sum of (session RPE × minutes) over the period.
    public let arbitraryUnits: Double
    /// Sessions that carried enough RPE to be priced at all.
    public let ratedSessions: Int
    public let totalSessions: Int
}

/// How a load compares with the wearer's own recent level.
///
/// Reported as a SIGNED PERCENTAGE, not as a ratio. "18 % above your usual" is a sentence someone can
/// act on; "ACWR 1.18" is a number that has to be looked up, and whose 0.8–1.3 bands come from team-
/// sport distance research that was never validated on set counts. The ratio is still computed —
/// `ReadinessEngine` reads one of its own — but it is not what the screen leads with.
public struct LoadTrend: Equatable, Sendable {
    /// Mean per day over the recent window.
    public let recentPerDay: Double
    /// Mean per day over the longer baseline window.
    public let baselinePerDay: Double
    /// Signed change from baseline, as a percentage. +18 means 18 % above usual.
    public let percentChange: Double

    /// The ratio the sports-science literature calls acute:chronic. Kept for callers that need it,
    /// never the headline.
    public var ratio: Double { baselinePerDay > 0 ? recentPerDay / baselinePerDay : 0 }
}

/// How evenly a week's load was spread, in Foster's terms.
///
/// Two weeks can carry the same total and feel nothing alike: 600 units in one session and six rest
/// days is not 100 units on six days. Monotony is the week's mean daily load over its standard
/// deviation, and strain is the week's total multiplied by that monotony (Foster 1998). Neither is a
/// verdict — they describe the SHAPE of a week, which the seven-day mean deliberately throws away.
public struct LoadDistribution: Equatable, Sendable {
    /// Mean daily load ÷ its standard deviation. Higher means flatter, more repetitive.
    public let monotony: Double
    /// The week's summed load × monotony.
    public let strain: Double
    /// The week's summed load, for the reader who wants the plain figure beside the derived ones.
    public let total: Double
    /// Days the window actually knew about — the divisor everything above rests on.
    public let knownDays: Int
}

/// How much personal history is available for interpreting a load.
public enum TrainingLoadMaturity: String, Equatable, Sendable, Codable {
    case immediate
    case earlyEstimate
    case baselineGrowing
    case personalBaseline
}

/// A neutral description of the current week relative to the athlete's own history.
public enum RelativeLoadBand: String, Equatable, Sendable, Codable {
    case below
    case usual
    case higher
    case muchHigher
}

/// The robust weekly range used once a personal baseline is established.
public struct PersonalLoadRange: Equatable, Sendable {
    public let median: Double
    public let medianAbsoluteDeviation: Double
    public let usualLowerBound: Double
    public let usualUpperBound: Double
    public let muchHigherBound: Double
}

/// Relative load, its precision state and the personal evidence behind it.
public struct RelativeLoadReading: Equatable, Sendable {
    public let maturity: TrainingLoadMaturity
    public let trend: LoadTrend?
    public let band: RelativeLoadBand?
    public let completeDays: Int
    public let completeWeeks: Int
    public let personalRange: PersonalLoadRange?
}

/// The four deliberately broad bands used only while a personal strength baseline is unavailable.
/// They describe the amount logged in the last seven days, not adaptation, safety or injury risk.
public enum ProvisionalStrengthLoadBand: String, Equatable, Sendable, Codable {
    case low
    case moderate
    case high
    case veryHigh
}

/// What placed the strength marker on the Training Load ring.
public enum LoadRingSource: String, Equatable, Sendable, Codable {
    case personalRelativeLoad
    case provisionalSessionLoad
    case provisionalWeightedSets
}

/// A pre-baseline strength-ring position. This type intentionally cannot become a `LaneReading`:
/// callers therefore cannot accidentally feed a population convention into personal comparisons,
/// adaptation or sustained-overload logic.
public struct ProvisionalStrengthRingReading: Equatable, Sendable {
    public let band: ProvisionalStrengthLoadBand
    /// Position on the visual ring, from empty to full.
    public let fraction: Double
    public let source: LoadRingSource
    /// The seven-day amount in the source's own unit (AU or weighted muscle sets).
    public let value: Double
    /// True when some working sets had no reliable detailed muscle assignment.
    public let isLowerBound: Bool

    public init(band: ProvisionalStrengthLoadBand, fraction: Double, source: LoadRingSource,
                value: Double, isLowerBound: Bool = false) {
        self.band = band
        self.fraction = min(1, max(0, fraction))
        self.source = source
        self.value = max(0, value)
        self.isLowerBound = isLowerBound
    }
}

public enum TrainingLoad {

    /// Recent window, in days.
    public static let recentWindow = 7
    /// Baseline window, in days, immediately BEFORE the recent window. Keeping the windows disjoint
    /// avoids putting the value being judged into its own comparator.
    public static let baselineWindow = 28
    /// Total history needed for a full comparison: 28 baseline days followed by 7 recent days.
    public static let comparisonWindow = baselineWindow + recentWindow
    /// Baseline days needed before a comparison is honest.
    public static let minimumBaselineDays = 14
    /// Below this share of rated sets, the effort weighting is mostly assumption.
    public static let trustedRatedShare = 0.5
    /// Known days a distribution needs before monotony is reported. A standard deviation over three
    /// days describes the three days, not the week.
    public static let minimumDistributionDays = recentWindow
    /// Complete calendar days required for a provisional 7-versus-14-day comparison.
    public static let earlyComparisonDays = 21
    /// Complete calendar days required for the standard disjoint 7-versus-28-day comparison.
    public static let growingBaselineDays = comparisonWindow
    /// Complete weeks required before personal variability is interpreted.
    public static let personalBaselineWeeks = 8
    /// Enough recent ratings to describe an unrated set as the athlete's own typical set.
    public static let minimumPersonalRPERatings = 3
    /// Neutral start value for an unrated set before the athlete has a usable 28-day rating history.
    /// This is the continuous RPE curve at 7.5 (0.6), rather than the muscle-map fallback of 0.75,
    /// which would assume an unreported set was close to RPE 8.5.
    public static let neutralUnratedWeight = 0.6

    /// Fills only the strength ring before personal comparison is available.
    ///
    /// Session Load is preferred only when EVERY canonical strength session in the seven-day window
    /// has a rating. If one is missing, the whole window switches to the maximum reliably mapped
    /// muscle stimulus. The two units are never added or averaged.
    public static func provisionalStrengthRing(sessionLoads: [Double?],
                                               weightedMuscleSets: [String: Double],
                                               hasUnmappedSets: Bool = false)
    -> ProvisionalStrengthRingReading? {
        guard !sessionLoads.isEmpty else { return nil }
        if sessionLoads.allSatisfy({ $0 != nil }) {
            let total = sessionLoads.compactMap { $0 }.reduce(0, +)
            guard total > 0 else { return nil }
            return provisionalReading(value: total, thresholds: [300, 900, 1_500], cap: 2_400,
                                      source: .provisionalSessionLoad, isLowerBound: false)
        }
        guard let maximum = weightedMuscleSets.values.max(), maximum > 0 else { return nil }
        return provisionalReading(value: maximum, thresholds: [5, 10, 20], cap: 30,
                                  source: .provisionalWeightedSets,
                                  isLowerBound: hasUnmappedSets)
    }

    private static func provisionalReading(value: Double, thresholds: [Double], cap: Double,
                                           source: LoadRingSource, isLowerBound: Bool)
    -> ProvisionalStrengthRingReading {
        let band: ProvisionalStrengthLoadBand
        if value < thresholds[0] { band = .low }
        else if value < thresholds[1] { band = .moderate }
        else if value < thresholds[2] { band = .high }
        else { band = .veryHigh }
        return ProvisionalStrengthRingReading(band: band, fraction: min(1, value / cap),
                                              source: source, value: value,
                                              isLowerBound: isLowerBound)
    }

    /// Effort-weighted working sets.
    ///
    /// The weight per set is `MuscleStimulus.proximityFactor` — the SAME curve the muscle map already
    /// prices sets with. A second RPE weighting living beside it would let two screens disagree about
    /// how hard the same set was, which is the divergence this project spends most of its rules
    /// preventing.
    ///
    /// An unrated set takes the MEDIAN weight of the sets this athlete DID rate, and only falls back to
    /// the fixed default when nothing in the pool carries a rating. The fixed default sat at 0.75 —
    /// close to a hard set — so someone who rated nothing was priced near their own hardest work, and,
    /// worse, a change in rating habit moved the weekly figure on its own: start rating your easy sets
    /// and the load appears to fall. Borrowing the athlete's own median keeps an unrated set looking
    /// like their typical rated one, which is the honest guess when the set itself says nothing.
    public static func strengthLoad(setRpes: [Double?], historicalRpes: [Double] = []) -> StrengthLoad {
        let ratedWeights = setRpes.compactMap { $0 }.map { MuscleStimulus.proximityFactor(rpe: $0) }
        let historyWeights = historicalRpes.filter { $0.isFinite && (1...10).contains($0) }
            .map { MuscleStimulus.proximityFactor(rpe: $0) }
        let usesPersonal = historyWeights.count >= minimumPersonalRPERatings
        let unratedWeight = usesPersonal ? (median(historyWeights) ?? neutralUnratedWeight)
                                         : neutralUnratedWeight
        let weighted = setRpes.reduce(0.0) { total, rpe in
            total + (rpe == nil ? unratedWeight : MuscleStimulus.proximityFactor(rpe: rpe))
        }
        let rated = ratedWeights.count
        return StrengthLoad(
            weightedSets: weighted,
            workingSets: setRpes.count,
            ratedSets: rated,
            ratedShare: setRpes.isEmpty ? 0 : Double(rated) / Double(setRpes.count),
            usedPersonalUnratedEstimate: usesPersonal,
            unratedWeight: unratedWeight)
    }

    /// Builds the staged personal comparison without hiding the first eight weeks of data.
    ///
    /// A comparison window is all-or-nothing. Nil means an observed training day was incomplete; it is
    /// never averaged away and never turned into a rest-day zero. Personal ranges use the preceding
    /// seven complete weekly totals, leaving the current week out of its own comparator.
    public static func relativeLoad(daily: [Double?]) -> RelativeLoadReading {
        let completeDays = daily.compactMap { $0 }.count
        let completeWeeks = stride(from: 0, to: daily.count, by: recentWindow).reduce(0) { count, start in
            let end = min(start + recentWindow, daily.count)
            return count + (end - start == recentWindow && daily[start..<end].allSatisfy { $0 != nil } ? 1 : 0)
        }

        var maturity: TrainingLoadMaturity
        if daily.count >= personalBaselineWeeks * recentWindow,
           daily.suffix(personalBaselineWeeks * recentWindow).allSatisfy({ $0 != nil }) {
            maturity = .personalBaseline
        } else if completeDays >= growingBaselineDays {
            maturity = .baselineGrowing
        } else if completeDays >= earlyComparisonDays {
            maturity = .earlyEstimate
        } else {
            maturity = .immediate
        }

        let comparison: LoadTrend?
        if maturity == .earlyEstimate {
            comparison = strictTrend(daily: daily, recent: recentWindow, baseline: 14)
        } else if maturity == .baselineGrowing || maturity == .personalBaseline {
            comparison = strictTrend(daily: daily, recent: recentWindow, baseline: baselineWindow)
        } else {
            comparison = nil
        }

        var range: PersonalLoadRange?
        var relativeBand: RelativeLoadBand?
        if maturity == .personalBaseline {
            let window = Array(daily.suffix(personalBaselineWeeks * recentWindow)).compactMap { $0 }
            let totals = stride(from: 0, to: window.count, by: recentWindow).map {
                window[$0..<($0 + recentWindow)].reduce(0, +)
            }
            if let current = totals.last, totals.count == personalBaselineWeeks,
               let centre = median(Array(totals.dropLast())), centre > 0 {
                let deviations = totals.dropLast().map { abs($0 - centre) }
                if let mad = median(deviations), mad > 0 {
                    let robustSpread = 1.4826 * mad
                    let lower = max(0, centre - robustSpread)
                    let upper = centre + robustSpread
                    let high = centre + 2 * robustSpread
                    range = PersonalLoadRange(median: centre, medianAbsoluteDeviation: mad,
                                              usualLowerBound: lower, usualUpperBound: upper,
                                              muchHigherBound: high)
                    if current < lower { relativeBand = .below }
                    else if current <= upper { relativeBand = .usual }
                    else if current <= high { relativeBand = .higher }
                    else { relativeBand = .muchHigher }
                } else {
                    // Eight flat weeks do not define personal variation bands. Keep the comparison,
                    // but do not present arbitrary decimal boundaries as a mature baseline.
                    maturity = .baselineGrowing
                }
            } else {
                maturity = .baselineGrowing
            }
        }

        return RelativeLoadReading(maturity: maturity, trend: comparison, band: relativeBand,
                                   completeDays: completeDays, completeWeeks: completeWeeks,
                                   personalRange: range)
    }

    /// Dated convenience form. Missing keys are known rest days; `unknownDays` are incomplete training
    /// days. History starts with the first load or explicitly unknown training day, whichever came first.
    public static func relativeLoad(dailyByDay: [String: Double], through day: String,
                                    unknownDays: Set<String> = []) -> RelativeLoadReading {
        guard let firstDay = (Set(dailyByDay.keys).union(unknownDays)).min() else {
            return relativeLoad(daily: [])
        }
        let available = max(0, StrengthSession.daysBetween(firstDay, and: day)) + 1
        let count = min(personalBaselineWeeks * recentWindow, available)
        var cursor = WeeklyDigestEngine.addDays(day, -(count - 1))
        var daily: [Double?] = []
        daily.reserveCapacity(count)
        for _ in 0..<count {
            daily.append(unknownDays.contains(cursor) ? nil : (dailyByDay[cursor] ?? 0))
            cursor = WeeklyDigestEngine.addDays(cursor, 1)
        }
        return relativeLoad(daily: daily)
    }

    /// Foster's session-RPE load: the session's own RPE times its duration in minutes.
    ///
    /// Sessions with no RPE are counted but not priced — a session whose effort nobody recorded is
    /// missing data, and giving it an average would put invented work into a figure whose whole point
    /// is that the athlete supplied it.
    public static func sessionLoad(_ sessions: [(rpe: Double?, minutes: Double)]) -> SessionLoad {
        var au = 0.0
        var rated = 0
        for session in sessions {
            guard let rpe = session.rpe, rpe > 0, session.minutes > 0,
                  rpe.isFinite, session.minutes.isFinite else { continue }
            au += rpe * session.minutes
            rated += 1
        }
        return SessionLoad(arbitraryUnits: au, ratedSessions: rated, totalSessions: sessions.count)
    }

    /// Compares a daily load series with its own preceding baseline.
    ///
    /// `daily` must be DENSE and zero-filled: a rest day is a real zero. Averaging only the days that
    /// happened to contain training would make someone who trained twice look identical to someone who
    /// trained six times, which is the whole difference between load and session intensity.
    public static func trend(daily: [Double], recent: Int = recentWindow,
                             baseline: Int = baselineWindow,
                             minimumBaseline: Int = minimumBaselineDays) -> LoadTrend? {
        trend(daily: daily.map { Optional($0) }, recent: recent, baseline: baseline,
              minimumBaseline: minimumBaseline)
    }

    /// The same comparison over a series where some days are NOT KNOWN.
    ///
    /// A nil day is one the data cannot speak for — a cardio session whose heart-rate trace was too
    /// sparse to price, say. It is dropped from BOTH windows rather than counted as a rest day: scoring
    /// an unmeasured session as zero pulls the recent mean down and reports real training as a decline,
    /// which is the one failure mode this series must not have. A rest day is still a real zero, and
    /// callers are the ones who know which is which.
    public static func trend(daily: [Double?], recent: Int = recentWindow,
                             baseline: Int = baselineWindow,
                             minimumBaseline: Int = minimumBaselineDays) -> LoadTrend? {
        let recentKnown = daily.suffix(recent).compactMap { $0 }
        let baselineKnown = daily.dropLast(min(recent, daily.count)).suffix(baseline).compactMap { $0 }
        guard baselineKnown.count >= minimumBaseline, !recentKnown.isEmpty else { return nil }
        let r = recentKnown.reduce(0, +) / Double(recentKnown.count)
        let b = baselineKnown.reduce(0, +) / Double(baselineKnown.count)
        // No baseline means no comparison. Someone's first fortnight is not "infinitely above usual".
        guard b > 0 else { return nil }
        return LoadTrend(recentPerDay: r, baselinePerDay: b, percentChange: (r - b) / b * 100)
    }

    /// Builds the dense day series required by `trend(daily:)` from sparse dated loads.
    ///
    /// Keeping this here gives Strength, Cardio and Session load one definition of the comparison
    /// window. Callers may sum several sessions into one day before passing the dictionary; missing
    /// dictionary keys are rest days and therefore become real zeros — EXCEPT the days named in
    /// `unknownDays`, which the caller has marked as unmeasured and which drop out of both windows.
    public static func trend(dailyByDay: [String: Double], through day: String,
                             unknownDays: Set<String> = [],
                             recent: Int = recentWindow, baseline: Int = baselineWindow,
                             minimumBaseline: Int = minimumBaselineDays) -> LoadTrend? {
        guard let series = denseSeries(dailyByDay: dailyByDay, through: day,
                                       unknownDays: unknownDays, span: baseline + recent,
                                       minimumSpan: minimumBaseline + recent) else { return nil }
        return trend(daily: series, recent: recent, baseline: baseline, minimumBaseline: minimumBaseline)
    }

    /// How evenly the last `window` days were loaded (Foster 1998).
    ///
    /// Returns nil when too few days are known, and when every known day carries the same load: a
    /// standard deviation of zero makes monotony infinite, and "infinitely repetitive" is a division
    /// artefact rather than a description of a week.
    public static func distribution(daily: [Double?], window: Int = recentWindow,
                                    minimumDays: Int = minimumDistributionDays) -> LoadDistribution? {
        let known = daily.suffix(window).compactMap { $0 }
        guard known.count >= minimumDays else { return nil }
        let total = known.reduce(0, +)
        let mean = total / Double(known.count)
        let variance = known.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(known.count)
        let deviation = variance.squareRoot()
        guard deviation > 0 else { return nil }
        let monotony = mean / deviation
        return LoadDistribution(monotony: monotony, strain: total * monotony,
                                total: total, knownDays: known.count)
    }

    /// The same distribution from dated loads.
    public static func distribution(dailyByDay: [String: Double], through day: String,
                                    unknownDays: Set<String> = [],
                                    window: Int = recentWindow,
                                    minimumDays: Int = minimumDistributionDays) -> LoadDistribution? {
        guard let series = denseSeries(dailyByDay: dailyByDay, through: day,
                                       unknownDays: unknownDays, span: window,
                                       minimumSpan: minimumDays) else { return nil }
        return distribution(daily: series, window: window, minimumDays: minimumDays)
    }

    /// This week's total against the week before it, as a signed percentage.
    ///
    /// The plainer companion to the ratio: week over week is what a training plan is actually written
    /// in, it needs no threshold to interpret, and it does not share the ratio's coupling problem —
    /// the two weeks it compares do not overlap. Nil when either week has no known day, or when the
    /// earlier week was empty (there is no percentage change from nothing).
    public static func weekOverWeek(daily: [Double?], week: Int = recentWindow) -> Double? {
        guard daily.count >= week * 2 else { return nil }
        let thisSlice = daily.suffix(week)
        let lastSlice = daily.suffix(week * 2).prefix(week)
        guard thisSlice.allSatisfy({ $0 != nil }), lastSlice.allSatisfy({ $0 != nil }) else { return nil }
        let thisWeek = thisSlice.compactMap { $0 }
        let lastWeek = lastSlice.compactMap { $0 }
        let previous = lastWeek.reduce(0, +)
        guard previous > 0 else { return nil }
        return (thisWeek.reduce(0, +) - previous) / previous * 100
    }

    /// The same week-over-week change from dated loads.
    public static func weekOverWeek(dailyByDay: [String: Double], through day: String,
                                    unknownDays: Set<String> = [],
                                    week: Int = recentWindow) -> Double? {
        guard let series = denseSeries(dailyByDay: dailyByDay, through: day,
                                       unknownDays: unknownDays, span: week * 2,
                                       minimumSpan: week * 2) else { return nil }
        return weekOverWeek(daily: series, week: week)
    }

    // MARK: - Shared series building

    /// The dense day series behind every comparison above: `span` days ending on `day`, rest days as
    /// zeros, unmeasured days as nil. Nil when the history is shorter than `minimumSpan`, so a first
    /// fortnight is never padded with invented rest days.
    private static func denseSeries(dailyByDay: [String: Double], through day: String,
                                    unknownDays: Set<String>, span: Int,
                                    minimumSpan: Int) -> [Double?]? {
        guard let firstDay = dailyByDay.keys.min() else { return nil }
        let availableDays = StrengthSession.daysBetween(firstDay, and: day) + 1
        guard availableDays >= minimumSpan else { return nil }
        let dayCount = min(span, availableDays)
        var dense: [Double?] = []
        dense.reserveCapacity(dayCount)
        var cursor = WeeklyDigestEngine.addDays(day, -(dayCount - 1))
        for _ in 0..<dayCount {
            dense.append(unknownDays.contains(cursor) ? nil : (dailyByDay[cursor] ?? 0))
            cursor = WeeklyDigestEngine.addDays(cursor, 1)
        }
        return dense
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func strictTrend(daily: [Double?], recent: Int, baseline: Int) -> LoadTrend? {
        guard daily.count >= recent + baseline else { return nil }
        let recentSlice = daily.suffix(recent)
        let baselineSlice = daily.dropLast(recent).suffix(baseline)
        guard recentSlice.allSatisfy({ $0 != nil }), baselineSlice.allSatisfy({ $0 != nil }) else { return nil }
        let recentValues = recentSlice.compactMap { $0 }
        let baselineValues = baselineSlice.compactMap { $0 }
        let recentMean = recentValues.reduce(0, +) / Double(recent)
        let baselineMean = baselineValues.reduce(0, +) / Double(baseline)
        guard baselineMean > 0 else { return nil }
        return LoadTrend(recentPerDay: recentMean, baselinePerDay: baselineMean,
                         percentChange: (recentMean - baselineMean) / baselineMean * 100)
    }
}
