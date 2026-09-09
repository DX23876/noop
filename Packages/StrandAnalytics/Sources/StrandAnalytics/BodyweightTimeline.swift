import Foundation

// MARK: - What did this person weigh, around then?
//
// The bodyweight volume in `StrengthDetail` needs the wearer's mass AT THE TIME of a session, not
// today's. Weigh-ins are irregular — a few in one week, then nothing for a month — so the timeline has
// to answer for days nobody stepped on a scale.
//
// The rule is deliberately dull: THE NEAREST MEASUREMENT IN TIME, and nothing at all when the nearest
// one is further away than `maximumGapDays`. Two alternatives were rejected:
//
//   • Interpolating between weigh-ins would manufacture a daily weight series out of two points and
//     make a chart of it look like data.
//   • Carrying the last value forward indefinitely would price a session from 2024 at a weight first
//     recorded in 2026 — with no upper bound on how wrong that can be.
//
// Nearest-within-a-window is the smallest rule that answers the question honestly and says nothing when
// it cannot. Ties go to the EARLIER measurement, so the answer never depends on iteration order.

/// The wearer's measured weight over time, queryable at an instant.
public struct BodyweightTimeline: Sendable {

    /// How far a weigh-in may be from a session and still be used for it. Two months: body weight moves
    /// slowly enough that a measurement inside that window is worth more than no figure at all, and far
    /// enough that a stale one cannot follow a training history around forever.
    public static let maximumGapDays = 60

    /// Ascending by day.
    private let points: [(day: String, kg: Double)]

    public init(points: [(day: String, kg: Double)]) {
        self.points = points.filter { $0.kg > 0 }.sorted { $0.day < $1.day }
    }

    public var isEmpty: Bool { points.isEmpty }

    /// The measured weight to use for `day`, or nil when nothing was recorded near enough.
    public func kg(onDay day: String) -> Double? {
        guard !points.isEmpty else { return nil }

        // Binary search for the first point not before `day`; the answer is that point or its
        // predecessor, whichever is closer.
        var low = 0
        var high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].day < day { low = mid + 1 } else { high = mid }
        }

        var best: (gap: Int, kg: Double)?
        func consider(_ index: Int) {
            guard index >= 0, index < points.count else { return }
            let point = points[index]
            let gap = point.day <= day
                ? StrengthSession.daysBetween(point.day, and: day)
                : StrengthSession.daysBetween(day, and: point.day)
            guard gap <= Self.maximumGapDays else { return }
            // Strictly-closer wins, so an earlier point already considered keeps a tie.
            if best == nil || gap < best!.gap { best = (gap, point.kg) }
        }
        consider(low - 1)   // the earlier neighbour first, so it wins ties
        consider(low)
        return best?.kg
    }

    /// The measured weight to use for a session starting at `ts`, in the given local offset.
    public func kg(at ts: Int, tzOffsetSeconds: Int = 0) -> Double? {
        kg(onDay: AnalyticsEngine.dayString(ts, offsetSec: tzOffsetSeconds))
    }
}
