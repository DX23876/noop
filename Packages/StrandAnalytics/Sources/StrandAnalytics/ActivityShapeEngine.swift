import Foundation

// ActivityShapeEngine.swift — "by 15:00 this person has normally burned 57% of the day's activity."
//
// The day projection used to extrapolate linearly: `active / elapsedFraction`. That assumes activity
// arrives at a constant rate, which nobody's day does. An 08:00 workout made the forecast shoot far
// too high (a whole day extrapolated from the one hour that contained all of it); a quiet morning
// before an evening session made it read far too low.
//
// What replaces it is not a smarter constant — it is the user's OWN shape. This file learns, from
// their recent history, what fraction of a typical day's active energy has accrued by each hour, and
// the projection asks that curve how much of the day is still ahead.
//
// Two deliberate properties:
//
//   • Each day is normalized to its OWN total BEFORE the days are combined. The curve is a SHAPE, so
//     one enormous day must not count for more than an ordinary one — otherwise a single marathon
//     Sunday would redefine what "a normal afternoon" looks like.
//   • The per-hour combination is a MEDIAN, not a mean. Same reason, applied to the other axis: one
//     unusual hour cannot drag the curve, and a person with a genuinely bimodal routine still gets
//     the middle of their own distribution rather than an average of two shapes they never live.
//
// Deliberately NOT split by weekday/weekend here. It is a real effect, but splitting doubles the
// history each arm needs before it can say anything, and the fallback (below) is the honest linear
// behaviour rather than a worse curve. Worth revisiting once the pooled curve is proven.

/// A personal time-of-day activity profile.
public struct ActivityShape: Equatable, Sendable {
    /// Cumulative fraction of a typical day's active energy burned by the END of each hour.
    /// 24 entries, non-decreasing, last entry 1.0.
    public let cumulativeByHour: [Double]
    /// How many usable days the shape was fitted from — surfaced so callers can say how well-known it is.
    public let sampleDays: Int
    /// Typical active kcal in each local hour. Unlike `cumulativeByHour`, this retains magnitude and
    /// therefore lets a quiet morning use the person's historical remainder instead of dividing by a
    /// near-zero fraction.
    public let expectedActiveByHour: [Double]

    public init(cumulativeByHour: [Double], sampleDays: Int,
                expectedActiveByHour: [Double] = []) {
        self.cumulativeByHour = cumulativeByHour
        self.sampleDays = sampleDays
        self.expectedActiveByHour = expectedActiveByHour
    }

    /// Expected fraction of the day's active energy burned by `elapsedSeconds` into a local day of
    /// `dayDurationSeconds`. Interpolates linearly WITHIN an hour: the curve is hourly, but the
    /// question is asked at an arbitrary instant, and a step function would make the projection jump
    /// every hour on the hour for no physiological reason.
    ///
    /// Real local-day seconds rather than a fixed 86,400, matching `EnergyEngine.DayContext`, so a
    /// 23- or 25-hour DST day maps onto the curve correctly.
    public func expectedFraction(elapsedSeconds: Double, dayDurationSeconds: Double) -> Double {
        guard cumulativeByHour.count == 24, dayDurationSeconds > 0 else { return 0 }
        let progress = min(1, max(0, elapsedSeconds / dayDurationSeconds))
        let position = progress * 24
        if position <= 0 { return 0 }
        if position >= 24 { return 1 }
        let index = Int(position)               // 0...23
        let withinHour = position - Double(index)
        let start = index == 0 ? 0 : cumulativeByHour[index - 1]
        let end = cumulativeByHour[index]
        return min(1, max(0, start + (end - start) * withinHour))
    }

    public func expectedActivity(elapsedSeconds: Double, dayDurationSeconds: Double)
        -> (toNow: Double, remaining: Double)? {
        guard expectedActiveByHour.count == 24, dayDurationSeconds > 0 else { return nil }
        let position = min(24, max(0, elapsedSeconds / dayDurationSeconds * 24))
        let wholeHours = min(24, Int(position))
        let partial = position - Double(wholeHours)
        var toNow = expectedActiveByHour.prefix(wholeHours).reduce(0, +)
        if wholeHours < 24 { toNow += expectedActiveByHour[wholeHours] * partial }
        let total = expectedActiveByHour.reduce(0, +)
        return (toNow, max(0, total - toNow))
    }
}

public enum ActivityShapeEngine {
    /// Below this the curve is not offered at all and the caller keeps the linear fallback. A shape
    /// fitted from a handful of days is a description of those days, not of the person.
    public static let minimumDays = 7
    public static let maximumWindowDays = 28
    /// A day must carry at least this much active energy to describe a shape. A near-zero day has no
    /// meaningful distribution to normalize — dividing by it manufactures a shape out of rounding.
    public static let minimumDailyActiveKcal = 50.0

    /// One day's active energy split into 24 local hours.
    public struct DayProfile: Equatable, Sendable {
        public let day: String
        /// 24 entries, hour 0...23, active kcal only (basal excluded — basal is flat and would
        /// flatten the very shape this measures).
        public let activeByHour: [Double]

        public init(day: String, activeByHour: [Double]) {
            self.day = day
            self.activeByHour = activeByHour
        }
    }

    /// Fit a shape, or nil when there is not enough usable history to claim one.
    public static func fit(days: [DayProfile]) -> ActivityShape? {
        let usable = days
            .filter { $0.activeByHour.count == 24 }
            .compactMap { day -> [Double]? in
                let clean = day.activeByHour.map { $0.isFinite && $0 > 0 ? $0 : 0 }
                let total = clean.reduce(0, +)
                guard total >= minimumDailyActiveKcal else { return nil }
                return clean
            }
            .suffix(maximumWindowDays)
        guard usable.count >= minimumDays else { return nil }

        let normalizedDays = usable.map { day -> [Double] in
            let total = day.reduce(0, +)
            return day.map { $0 / total }
        }

        // Median share per hour, then integrate. Medians do not sum to 1 (they are taken
        // independently per hour), so the cumulative curve is renormalized by its own final value.
        var shares: [Double] = []
        shares.reserveCapacity(24)
        for hour in 0..<24 {
            shares.append(median(normalizedDays.map { $0[hour] }))
        }
        var running = 0.0
        var cumulative: [Double] = []
        cumulative.reserveCapacity(24)
        for share in shares {
            running += share
            cumulative.append(running)
        }
        guard let last = cumulative.last, last > 0 else { return nil }
        // Enforce the invariant the type promises rather than trusting the arithmetic: non-decreasing,
        // bounded, ending at exactly 1.0.
        var normalized = cumulative.map { min(1, max(0, $0 / last)) }
        for index in 1..<normalized.count {
            normalized[index] = max(normalized[index], normalized[index - 1])
        }
        normalized[23] = 1.0
        let expected = (0..<24).map { hour in median(usable.map { $0[hour] }) }
        return ActivityShape(cumulativeByHour: normalized, sampleDays: usable.count,
                             expectedActiveByHour: expected)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
