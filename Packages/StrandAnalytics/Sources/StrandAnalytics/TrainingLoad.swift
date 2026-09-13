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
//   • CARDIO LOAD — heart-rate derived. NOOP already has it as Effort.
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
    public static let minimumDistributionDays = 5

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
    public static func strengthLoad(setRpes: [Double?]) -> StrengthLoad {
        let ratedWeights = setRpes.compactMap { $0 }.map { MuscleStimulus.proximityFactor(rpe: $0) }
        let unratedWeight = median(ratedWeights) ?? MuscleStimulus.unratedProximity
        let weighted = setRpes.reduce(0.0) { total, rpe in
            total + (rpe == nil ? unratedWeight : MuscleStimulus.proximityFactor(rpe: rpe))
        }
        let rated = ratedWeights.count
        return StrengthLoad(
            weightedSets: weighted,
            workingSets: setRpes.count,
            ratedSets: rated,
            ratedShare: setRpes.isEmpty ? 0 : Double(rated) / Double(setRpes.count))
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
        let thisWeek = daily.suffix(week).compactMap { $0 }
        let lastWeek = daily.suffix(week * 2).prefix(week).compactMap { $0 }
        guard !thisWeek.isEmpty, !lastWeek.isEmpty else { return nil }
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
}
