import Foundation

/// A long goal turned into a route: round-number waypoints with expected dates, and an honest read of
/// whether the actual trend is keeping up with the planned one.
///
/// Distinct from `JourneyMilestones` in the app target, which records what has ALREADY happened
/// ("first week in", "first run done"). These are forward-looking: where the plan says you should be,
/// and when.
///
/// Waypoints, not rewards. No streak, no score, no celebration — the project's stated line is that a
/// record is not a game to keep up, and a milestone here is a fact about the plan, nothing else.
///
/// Pure: no store, no clock of its own, no formatting. Callers pass what they hold.
public enum GoalMilestones {

    // MARK: - Waypoints

    public struct Milestone: Equatable, Sendable {
        /// The value this waypoint sits on (kg, km, hours — whatever the goal measures).
        public let value: Double
        /// When the PLANNED rate would reach it. Not a prediction — see `course(...)` for that.
        public let expectedDate: Date
        public init(value: Double, expectedDate: Date) {
            self.value = value
            self.expectedDate = expectedDate
        }
    }

    /// How many waypoints to aim for. Not a hard bound — the rounded step decides the real count, and
    /// a round number people recognise is worth more than hitting an exact quota.
    public static let preferredCount = 6

    /// The "nice number" ladder. People think in fives and tens, not in 4.7 kg increments.
    static let ladder: [Double] = [1, 2, 2.5, 5, 10]

    /// Step size for a span: the smallest ladder value that keeps the count at or under
    /// `preferredCount`. Rounding UP rather than to the nearest rung is deliberate — it can only ever
    /// produce FEWER, coarser waypoints, and a route with too many stops reads as noise.
    public static func step(forSpan span: Double, preferredCount: Int = preferredCount) -> Double? {
        let magnitudeInput = abs(span)
        guard magnitudeInput > 0, magnitudeInput.isFinite, preferredCount > 0 else { return nil }
        let raw = magnitudeInput / Double(preferredCount)
        let magnitude = pow(10, floor(log10(raw)))
        let normalized = raw / magnitude
        let rung = ladder.first { $0 >= normalized - 1e-9 } ?? 10
        return rung * magnitude
    }

    /// Round-number waypoints between `baseline` and `target`, ordered along the direction of travel,
    /// with the target itself always last.
    ///
    /// Direction-neutral: a weight goal counting DOWN and a distance goal counting UP produce the same
    /// shape, because the anchors are multiples of the step lying strictly between the two ends and
    /// are then ordered from the baseline outwards.
    public static func suggest(baseline: Double, target: Double,
                               createdAt: Date, targetDate: Date,
                               preferredCount: Int = preferredCount) -> [Milestone] {
        guard baseline.isFinite, target.isFinite, baseline != target,
              targetDate > createdAt,
              let step = step(forSpan: target - baseline, preferredCount: preferredCount)
        else { return [] }

        let low = min(baseline, target)
        let high = max(baseline, target)
        // Multiples of `step` strictly inside the span. The epsilon keeps a value that IS an endpoint
        // (100 with step 5) from sneaking in through floating-point noise.
        var anchors: [Double] = []
        var k = (low / step).rounded(.down) + 1
        while k * step < high - 1e-9 {
            let value = k * step
            if value > low + 1e-9 { anchors.append(value) }
            k += 1
        }
        // Along the direction of travel, then the target as the final waypoint.
        anchors.sort { baseline < target ? $0 < $1 : $0 > $1 }
        anchors.append(target)

        let totalSpan = target - baseline
        let totalTime = targetDate.timeIntervalSince(createdAt)
        return anchors.map { value in
            let fraction = (value - baseline) / totalSpan
            return Milestone(value: value,
                             expectedDate: createdAt.addingTimeInterval(fraction * totalTime))
        }
    }

    // MARK: - Course

    public enum Verdict: Equatable, Sendable {
        /// Close enough to the planned line to call it even.
        case onCourse
        /// Further along than the plan asks.
        case ahead
        /// Behind the planned line, but still moving the right way.
        case behind
        /// The recent trend points AWAY from the target. No arrival date exists; saying one would be
        /// arithmetic dressed up as a forecast.
        case movingAway
        /// Moving the right way, but so slowly that the arrival date is beyond any useful horizon.
        case unforeseeable
        /// Not enough measured history to say anything. The honest default, not a failure.
        case notEnoughData
    }

    public struct Course: Equatable, Sendable {
        /// Where the PLANNED rate says you should be today.
        public let plannedNow: Double
        /// `current - plannedNow`, in the goal's own unit and sign. For a weight-loss goal a POSITIVE
        /// value means heavier than planned, i.e. behind — the phrasing is the caller's job.
        public let deviation: Double
        /// Units per day from the recent measured trend, nil when there isn't enough to fit one.
        public let observedRatePerDay: Double?
        /// When the CURRENT trend would reach the target. Nil unless it actually would.
        public let projectedDate: Date?
        /// Days between `projectedDate` and the target date. Negative = early.
        public let daysLate: Int?
        public let verdict: Verdict
    }

    /// Days of history the rate fit needs before it says anything.
    public static let minimumRateDays = 14
    /// Distinct measurements the rate fit needs. Two points through noise is a line, not a trend.
    public static let minimumRatePoints = 8
    /// Window the observed rate is fitted over.
    public static let rateWindowDays = 28
    /// How far past the target date a projection may land before it is called unforeseeable, as a
    /// multiple of the goal's own total runway.
    public static let horizonMultiple: Double = 2.0
    /// Deviation under this fraction of the total span counts as "on course" — a plan is a line, not a
    /// tightrope.
    public static let onCourseTolerance: Double = 0.02

    /// One dated measurement. Callers pass the SMOOTHED series where one exists (`GoalMeasure`), so a
    /// day of water weight cannot tilt the fitted rate.
    public struct Sample: Equatable, Sendable {
        public let date: Date
        public let value: Double
        public init(date: Date, value: Double) {
            self.date = date
            self.value = value
        }
    }

    public static func course(baseline: Double, target: Double,
                              createdAt: Date, targetDate: Date,
                              current: Double,
                              series: [Sample],
                              now: Date) -> Course? {
        guard baseline.isFinite, target.isFinite, baseline != target,
              targetDate > createdAt, current.isFinite else { return nil }

        let totalTime = targetDate.timeIntervalSince(createdAt)
        let elapsed = max(0, now.timeIntervalSince(createdAt))
        let plannedRatePerSecond = (target - baseline) / totalTime
        let plannedNow = baseline + plannedRatePerSecond * min(elapsed, totalTime)
        let deviation = current - plannedNow
        let span = abs(target - baseline)

        // Toward the goal is positive, whichever way the goal counts.
        let towardGoal = (target > baseline) ? 1.0 : -1.0
        let progressDeviation = deviation * towardGoal

        guard let rate = observedRatePerDay(series: series, now: now) else {
            return Course(plannedNow: plannedNow, deviation: deviation, observedRatePerDay: nil,
                          projectedDate: nil, daysLate: nil, verdict: .notEnoughData)
        }

        let movingTowardGoal = rate * towardGoal > 0
        let remaining = target - current
        guard movingTowardGoal, abs(remaining) > 1e-9 else {
            // Either drifting away, or already at/past the target — in both cases an arrival date is
            // either meaningless or already behind us.
            let verdict: Verdict = movingTowardGoal ? .ahead : .movingAway
            return Course(plannedNow: plannedNow, deviation: deviation, observedRatePerDay: rate,
                          projectedDate: nil, daysLate: nil, verdict: verdict)
        }

        let daysToTarget = remaining / rate
        let projected = now.addingTimeInterval(daysToTarget * 86_400)
        let horizon = targetDate.addingTimeInterval(totalTime * horizonMultiple)
        guard projected <= horizon else {
            return Course(plannedNow: plannedNow, deviation: deviation, observedRatePerDay: rate,
                          projectedDate: nil, daysLate: nil, verdict: .unforeseeable)
        }

        let daysLate = Int((projected.timeIntervalSince(targetDate) / 86_400).rounded())
        let verdict: Verdict
        if abs(progressDeviation) <= span * onCourseTolerance {
            verdict = .onCourse
        } else {
            verdict = progressDeviation > 0 ? .ahead : .behind
        }
        return Course(plannedNow: plannedNow, deviation: deviation, observedRatePerDay: rate,
                      projectedDate: projected, daysLate: daysLate, verdict: verdict)
    }

    /// Least-squares slope in units per day over the recent window. Nil when the window is too short
    /// or too sparse to fit a line worth trusting.
    public static func observedRatePerDay(series: [Sample], now: Date,
                                          windowDays: Int = rateWindowDays) -> Double? {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let window = series.filter { $0.date >= cutoff && $0.date <= now && $0.value.isFinite }
            .sorted { $0.date < $1.date }
        guard window.count >= minimumRatePoints,
              let first = window.first, let last = window.last else { return nil }
        let spanDays = last.date.timeIntervalSince(first.date) / 86_400
        guard spanDays >= Double(minimumRateDays) else { return nil }

        let xs = window.map { $0.date.timeIntervalSince(first.date) / 86_400 }
        let ys = window.map(\.value)
        let n = Double(window.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var numerator = 0.0
        var denominator = 0.0
        for (x, y) in zip(xs, ys) {
            numerator += (x - meanX) * (y - meanY)
            denominator += (x - meanX) * (x - meanX)
        }
        guard denominator > 1e-9 else { return nil }
        return numerator / denominator
    }
}
