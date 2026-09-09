import Foundation
import WhoopStore

// MARK: - Is a lift actually moving? — measured bests and a robust line
//
// `StrengthSession` says what a session held. This says whether the numbers are going anywhere, and it
// is deliberately built out of two different KINDS of statement:
//
//   • RECORDS are measured. The heaviest set ever logged, the best single-session volume, the best set
//     inside a rep band — every one of them is a thing that was actually performed on a nameable day.
//     They need no caveat, which is why they carry the screen.
//   • The TREND is modelled, and modestly. A median of pairwise slopes (Theil–Sen) through the e1RM
//     points, with the middle half of those slopes reported beside it as the spread.
//
// ## Why not "first point vs last point, in per cent"
//
// That is what the exercise card used to show, and it is one bad session away from a lie in either
// direction: train through a cold on the last logged day and a good block reads as a decline. A single
// outlier moves Theil–Sen's median by nothing.
//
// ## Why the spread is reported, and what it is allowed to say
//
// The slope alone invites "you are gaining 0.4 kg a week" from four points over a fortnight. So the
// p25…p75 band of the pairwise slopes travels with it, and when that band CONTAINS ZERO the answer is
// "no direction the data agrees on" rather than a number. That is a statement about the evidence, not
// a diagnosis: it is not "you have plateaued", and nothing here is allowed to phrase it that way.
//
// No claim is made that a slope in kilograms per week is physiologically meaningful. It is the line
// through the points the log actually holds.

/// One measured best, with the day it happened on.
public struct StrengthRecordPoint: Equatable, Sendable {
    /// Kilograms for a load record, kilogram-reps for a volume record.
    public let value: Double
    public let day: String
    public let startTs: Int
    public let workoutId: String
    /// Reps of the set that set the record, when the record is about a single set. Nil for a
    /// session-level record, where "reps" would mean nothing.
    public let reps: Int?

    public init(value: Double, day: String, startTs: Int, workoutId: String, reps: Int?) {
        self.value = value
        self.day = day
        self.startTs = startTs
        self.workoutId = workoutId
        self.reps = reps
    }
}

/// The rep bands records are kept in.
///
/// Bands rather than a single "best set", because 100 kg × 3 and 70 kg × 12 are both bests and neither
/// is comparable to the other. The cut points are the conventional strength / hypertrophy / endurance
/// split; they decide only how records are GROUPED, never how anything is scored.
public enum StrengthRepBand: String, CaseIterable, Sendable, Codable {
    case oneToThree, fourToSix, sevenToTwelve, thirteenPlus

    public static func of(reps: Int) -> StrengthRepBand? {
        switch reps {
        case ..<1:   return nil
        case 1...3:  return .oneToThree
        case 4...6:  return .fourToSix
        case 7...12: return .sevenToTwelve
        default:     return .thirteenPlus
        }
    }

    /// A locale-stable label. The display layer localizes; this is a key.
    public var label: String {
        switch self {
        case .oneToThree:    return "1–3"
        case .fourToSix:     return "4–6"
        case .sevenToTwelve: return "7–12"
        case .thirteenPlus:  return "13+"
        }
    }
}

/// Everything measured about one exercise's history, plus the one estimate, clearly separated.
public struct ExerciseRecords: Equatable, Sendable {
    public let templateId: String
    /// The heaviest working set ever logged. Measured.
    public let heaviestSet: StrengthRecordPoint?
    /// The best single session's volume load for this exercise. Measured.
    public let bestSessionVolume: StrengthRecordPoint?
    /// The heaviest working set inside each rep band. Measured.
    public let bestByRepBand: [StrengthRepBand: StrengthRecordPoint]
    /// The best ESTIMATED one-rep max. The only modelled entry here, and the UI must label it as such.
    public let bestE1RM: StrengthRecordPoint?

    public init(templateId: String, heaviestSet: StrengthRecordPoint?,
                bestSessionVolume: StrengthRecordPoint?,
                bestByRepBand: [StrengthRepBand: StrengthRecordPoint],
                bestE1RM: StrengthRecordPoint?) {
        self.templateId = templateId
        self.heaviestSet = heaviestSet
        self.bestSessionVolume = bestSessionVolume
        self.bestByRepBand = bestByRepBand
        self.bestE1RM = bestE1RM
    }

    /// Whether anything at all was recorded — an exercise with no weighted set has no records to show,
    /// and a card of four dashes is worse than no card.
    public var isEmpty: Bool {
        heaviestSet == nil && bestSessionVolume == nil && bestByRepBand.isEmpty && bestE1RM == nil
    }
}

/// A robust line through a series, in units per week.
public struct StrengthTrendLine: Equatable, Sendable {
    /// Theil–Sen: the MEDIAN of every pairwise slope. Units per week (kg/week for an e1RM series).
    public let slopePerWeek: Double
    /// The middle half of those pairwise slopes, p25…p75 — how much they agree with each other.
    public let slopeSpread: ClosedRange<Double>
    public let pointCount: Int
    public let spanDays: Int
    /// The fitted value at the first and last point, for drawing the line itself.
    public let firstValue: Double
    public let lastValue: Double

    public init(slopePerWeek: Double, slopeSpread: ClosedRange<Double>, pointCount: Int,
                spanDays: Int, firstValue: Double, lastValue: Double) {
        self.slopePerWeek = slopePerWeek
        self.slopeSpread = slopeSpread
        self.pointCount = pointCount
        self.spanDays = spanDays
        self.firstValue = firstValue
        self.lastValue = lastValue
    }

    /// True when the middle half of the pairwise slopes straddles zero: the points do not agree on a
    /// direction. A statement about the EVIDENCE — never render it as "plateau" or as a verdict on the
    /// training.
    public var directionIsUnclear: Bool {
        slopeSpread.lowerBound <= 0 && slopeSpread.upperBound >= 0
    }

    /// The change the line implies over its own span, in the series' units. Reported instead of a
    /// per-cent change because a per cent of an ESTIMATED 1RM compounds one estimate into another.
    public var changeOverSpan: Double {
        slopePerWeek * Double(spanDays) / 7.0
    }
}

public enum StrengthProgress {

    // MARK: - Records

    /// Below this many points a trend line is not offered at all. Four sessions is the least that can
    /// disagree with itself; three points make a "trend" out of a good day and a bad one.
    public static let minimumTrendPoints = 4

    /// Every measured best for one exercise, over the sessions given.
    ///
    /// Warmups are excluded throughout — `workingSets` is the only set list read — so a heavy single
    /// taken as a warmup ramp never becomes a "record".
    public static func records(templateId: String,
                               workouts: [HevyWorkout],
                               templates: [String: HevyExerciseTemplate],
                               tzOffsetSeconds: Int = 0) -> ExerciseRecords {
        let template = templates[templateId]
        var heaviest: StrengthRecordPoint?
        var bestVolume: StrengthRecordPoint?
        var bestE1RM: StrengthRecordPoint?
        var byBand: [StrengthRepBand: StrengthRecordPoint] = [:]

        // Ascending, so ties keep the EARLIEST day: the record was set the first time it was reached,
        // and re-dating it to the most recent repeat would quietly erase how long it has stood.
        for workout in workouts.sorted(by: { $0.startTs < $1.startTs }) {
            let sets = workout.exercises
                .filter { $0.templateId == templateId }
                .flatMap(\.workingSets)
            guard !sets.isEmpty else { continue }
            let day = AnalyticsEngine.dayString(workout.startTs, offsetSec: tzOffsetSeconds)

            func point(_ value: Double, reps: Int?) -> StrengthRecordPoint {
                StrengthRecordPoint(value: value, day: day, startTs: workout.startTs,
                                    workoutId: workout.id, reps: reps)
            }

            var sessionVolume = 0.0
            for set in sets {
                if let volume = set.volumeLoadKg { sessionVolume += volume }
                if let weight = set.weightKg, weight > 0 {
                    if weight > (heaviest?.value ?? 0) { heaviest = point(weight, reps: set.reps) }
                    if let reps = set.reps, let band = StrengthRepBand.of(reps: reps),
                       weight > (byBand[band]?.value ?? 0) {
                        byBand[band] = point(weight, reps: reps)
                    }
                }
                if let estimate = OneRepMax.forSet(set, template: template),
                   estimate > (bestE1RM?.value ?? 0) {
                    bestE1RM = point(estimate, reps: set.reps)
                }
            }
            if sessionVolume > (bestVolume?.value ?? 0) {
                bestVolume = point(sessionVolume, reps: nil)
            }
        }

        return ExerciseRecords(templateId: templateId, heaviestSet: heaviest,
                               bestSessionVolume: bestVolume, bestByRepBand: byBand,
                               bestE1RM: bestE1RM)
    }

    /// Days since the heaviest set was lifted, or nil when there is no record to age.
    ///
    /// Deliberately NOT named "days stagnant". How long a best has stood is a fact; whether that is a
    /// problem depends on the block someone is running, and this file has no way to know that.
    public static func daysSinceHeaviestSet(_ records: ExerciseRecords, today: String) -> Int? {
        guard let record = records.heaviestSet else { return nil }
        return StrengthSession.daysBetween(record.day, and: today)
    }

    // MARK: - The line

    /// A robust line through a performance series.
    ///
    /// `value` picks the series — `\.bestE1RMKg` for the strength trend, `\.volumeLoadKg` for a volume
    /// one. Points where it is nil are skipped rather than zero-filled: a session with no estimable set
    /// is missing evidence, not evidence of zero.
    ///
    /// Returns nil below `minimumTrendPoints` usable points, or when every point shares one day (no
    /// span to take a slope over).
    public static func trend(_ points: [ExercisePerformancePoint],
                             value: (ExercisePerformancePoint) -> Double?,
                             minimumPoints: Int = minimumTrendPoints) -> StrengthTrendLine? {
        let series: [(ts: Int, value: Double)] = points
            .compactMap { point in value(point).map { (point.startTs, $0) } }
            .sorted { $0.ts < $1.ts }
        guard series.count >= max(minimumPoints, 2) else { return nil }

        // Every pairwise slope, in units per week. O(n²) and that is fine: a single exercise's history
        // is hundreds of points at the very most, and the alternative — a least-squares fit — is the
        // thing being avoided, not a cheaper version of it.
        var slopes: [Double] = []
        slopes.reserveCapacity(series.count * (series.count - 1) / 2)
        for i in 0..<series.count {
            for j in (i + 1)..<series.count {
                let weeks = Double(series[j].ts - series[i].ts) / (7 * 86_400)
                guard weeks > 0 else { continue }   // two sessions the same second carry no slope
                slopes.append((series[j].value - series[i].value) / weeks)
            }
        }
        guard !slopes.isEmpty else { return nil }
        let sorted = slopes.sorted()
        let slope = StrengthSession.percentile(sorted, 0.5)
        let low = StrengthSession.percentile(sorted, 0.25)
        let high = StrengthSession.percentile(sorted, 0.75)

        let spanDays = (series[series.count - 1].ts - series[0].ts) / 86_400
        return StrengthTrendLine(slopePerWeek: slope,
                                 slopeSpread: min(low, high)...max(low, high),
                                 pointCount: series.count,
                                 spanDays: spanDays,
                                 firstValue: series[0].value,
                                 lastValue: series[series.count - 1].value)
    }

    /// The e1RM trend, the series the exercise card draws.
    public static func e1rmTrend(_ points: [ExercisePerformancePoint]) -> StrengthTrendLine? {
        trend(points, value: { $0.bestE1RMKg })
    }

    /// The volume trend — the honest fallback for a movement no e1RM is defined for (a plank, a
    /// bodyweight row), where "am I doing more of it" is the only progression question the log can
    /// answer.
    public static func volumeTrend(_ points: [ExercisePerformancePoint]) -> StrengthTrendLine? {
        trend(points, value: { $0.volumeLoadKg > 0 ? $0.volumeLoadKg : nil })
    }
}
