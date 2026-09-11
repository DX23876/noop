import Foundation

// MARK: - Training load, kept in the units each kind of training is actually measured in
//
// The question this answers: how much did this week ask of you, and is that unusual for you. The
// question it refuses: how much did lifting and cardio ask of you TOGETHER, as one number. There is no
// exchange rate between a heart-rate minute and a hard set, and inventing one is how a training-load
// score stops being a measurement.
//
// So there are three figures, deliberately separate — the same split Polar arrived at:
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

public enum TrainingLoad {

    /// Recent window, in days.
    public static let recentWindow = 7
    /// Baseline window, in days. Long enough that one big week does not become "usual".
    public static let baselineWindow = 28
    /// Baseline days needed before a comparison is honest.
    public static let minimumBaselineDays = 14
    /// Below this share of rated sets, the effort weighting is mostly assumption.
    public static let trustedRatedShare = 0.5

    /// Effort-weighted working sets.
    ///
    /// The weight per set is `MuscleStimulus.proximityFactor` — the SAME curve the muscle map already
    /// prices sets with. A second RPE weighting living beside it would let two screens disagree about
    /// how hard the same set was, which is the divergence this project spends most of its rules
    /// preventing. An unrated set takes that function's documented default rather than counting as
    /// full effort, because assuming every unlogged set went to failure inflates exactly the people
    /// who log least.
    public static func strengthLoad(setRpes: [Double?]) -> StrengthLoad {
        let weighted = setRpes.reduce(0.0) { $0 + MuscleStimulus.proximityFactor(rpe: $1) }
        let rated = setRpes.filter { $0 != nil }.count
        return StrengthLoad(
            weightedSets: weighted,
            workingSets: setRpes.count,
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

    /// Compares a daily load series with its own recent baseline.
    ///
    /// `daily` must be DENSE and zero-filled: a rest day is a real zero. Averaging only the days that
    /// happened to contain training would make someone who trained twice look identical to someone who
    /// trained six times, which is the whole difference between load and session intensity.
    public static func trend(daily: [Double], recent: Int = recentWindow,
                             baseline: Int = baselineWindow,
                             minimumBaseline: Int = minimumBaselineDays) -> LoadTrend? {
        guard daily.count >= minimumBaseline else { return nil }
        let recentSlice = Array(daily.suffix(recent))
        let baselineSlice = Array(daily.suffix(baseline))
        guard !recentSlice.isEmpty, !baselineSlice.isEmpty else { return nil }
        let r = recentSlice.reduce(0, +) / Double(recentSlice.count)
        let b = baselineSlice.reduce(0, +) / Double(baselineSlice.count)
        // No baseline means no comparison. Someone's first fortnight is not "infinitely above usual".
        guard b > 0 else { return nil }
        return LoadTrend(recentPerDay: r, baselinePerDay: b, percentChange: (r - b) / b * 100)
    }

    /// Builds the dense, zero-filled day series required by `trend(daily:)` from sparse dated loads.
    ///
    /// Keeping this here gives Strength, Cardio and Session load one definition of the comparison
    /// window. Callers may sum several sessions into one day before passing the dictionary; missing
    /// dictionary keys are rest days and therefore become real zeros.
    public static func trend(dailyByDay: [String: Double], through day: String,
                             recent: Int = recentWindow, baseline: Int = baselineWindow,
                             minimumBaseline: Int = minimumBaselineDays) -> LoadTrend? {
        guard let firstDay = dailyByDay.keys.min() else { return nil }
        let availableDays = StrengthSession.daysBetween(firstDay, and: day) + 1
        guard availableDays >= minimumBaseline else { return nil }
        let dayCount = min(baseline, availableDays)
        var dense: [Double] = []
        var cursor = WeeklyDigestEngine.addDays(day, -(dayCount - 1))
        for _ in 0..<dayCount {
            dense.append(dailyByDay[cursor] ?? 0)
            cursor = WeeklyDigestEngine.addDays(cursor, 1)
        }
        return trend(daily: dense, recent: recent, baseline: baseline,
                     minimumBaseline: minimumBaseline)
    }
}
