import Foundation

/// Readings for the five long-term goal shapes: a total collected toward a target (sum), a value moving
/// between a start and a target (target value, with a "maintain" band variant), a best effort (best
/// value), a weekly rhythm kept over many weeks (consistency) and a rolling mean (average).
///
/// Each reading answers what the goal page shows: the big number, three figures, the band and a state.
/// The states reuse `PeriodGoalState` so a long-term goal says "on track" by the same words and colours
/// as a weekly one. A `nil` state means the shape has nothing honest to judge, which is shown as such.
///
/// The rules that keep this honest:
/// - no forecast without enough measured history, and none further out than a year;
/// - a missing value is missing, never zero;
/// - a week the wearer protected (paused, ill) neither counts for nor against them.
///
/// Pure: no store, no clock of its own, no formatting.
public enum LongTermGoalMath {

    static let secondsPerDay: TimeInterval = 86_400
    static let daysPerWeek = 7.0
    /// Average month length, for trends stated "per month".
    static let daysPerMonth = 30.44

    /// The furthest ahead any date is projected. A date two years out from a four-week trend is
    /// arithmetic, not a forecast.
    public static let maxProjectionDays = 365

    // MARK: - Sum

    /// Lead over the planned share that reads as "ahead", as a fraction of that share.
    public static let sumAheadMargin = 0.15
    /// Shortfall against the planned share that still reads as "on track".
    public static let sumOnTrackTolerance = 0.05
    /// Shortfall that reads as "close" rather than "behind".
    public static let sumCloseTolerance = 0.15
    /// Complete weeks of history the recent pace needs before it may project a finish.
    public static let paceWeeks = 4
    /// Days after the start during which a sum goal is "starting" rather than judged.
    public static let sumStartingDays = 7

    public struct SumReading: Equatable, Sendable {
        public let total: Double
        public let target: Double
        /// `total / target`, unclamped: above 1 once the target is passed.
        public let fraction: Double
        /// The target's linear share at `now`: where an even pace from start to end would stand.
        public let plannedByNow: Double
        /// Still to collect, never below zero.
        public let remaining: Double
        /// Whole weeks left until the end, at least one while the goal runs; 0 once it ended.
        public let weeksLeft: Double
        /// What each remaining week needs for the target, or nil once reached or ended.
        public let neededPerWeek: Double?
        /// Mean of the last `paceWeeks` complete weeks, or nil with fewer weeks of history.
        public let recentWeeklyAverage: Double?
        /// The weekly target to suggest: what is needed, but never more than the cap above the recent
        /// average. Nil when nothing is needed any more.
        public let suggestedWeeklyTarget: Double?
        /// True when the needed weekly amount is above the cap, so the page says it is getting tight.
        public let catchUpExceedsCap: Bool
        /// When the recent pace would reach the target, nil without a pace or beyond a year.
        public let projectedFinish: Date?
        public let state: PeriodGoalState
    }

    /// - Parameters:
    ///   - recentWeeklyTotals: the amounts of the last complete weeks, oldest first. Weeks without any
    ///     activity are a real 0 and must be passed; only the most recent `paceWeeks` are used.
    ///   - capFraction: how far above the recent average a suggested week may go (0.10 for running).
    public static func sum(total: Double, target: Double, start: Date, end: Date, now: Date,
                           recentWeeklyTotals: [Double], capFraction: Double) -> SumReading? {
        guard target > 0, total.isFinite, end > start else { return nil }
        let span = end.timeIntervalSince(start)
        let elapsed = min(max(0, now.timeIntervalSince(start)), span)
        let plannedByNow = target * elapsed / span
        let remaining = max(0, target - total)
        let secondsLeft = max(0, end.timeIntervalSince(now))
        let ended = secondsLeft <= 0
        let weeksLeft = ended ? 0 : max(1, (secondsLeft / (daysPerWeek * secondsPerDay)).rounded(.up))

        let recent = Array(recentWeeklyTotals.suffix(paceWeeks))
        let recentAverage: Double? = recent.count >= paceWeeks ? recent.reduce(0, +) / Double(recent.count) : nil

        let needed: Double? = (remaining > 0 && !ended) ? remaining / weeksLeft : nil
        var suggested = needed
        var exceedsCap = false
        if let needed, let recentAverage, recentAverage > 0 {
            let cap = recentAverage * (1 + capFraction)
            if needed > cap + 1e-9 {
                suggested = cap
                exceedsCap = true
            }
        }

        var projected: Date?
        if remaining > 0, let recentAverage, recentAverage > 0 {
            let days = remaining / recentAverage * daysPerWeek
            if days <= Double(maxProjectionDays) { projected = now.addingTimeInterval(days * secondsPerDay) }
        }

        let state: PeriodGoalState
        if remaining <= 0 {
            state = .achieved
        } else if ended {
            state = .outOfReach
        } else if now.timeIntervalSince(start) < Double(sumStartingDays) * secondsPerDay {
            state = .starting
        } else if plannedByNow > 0, total >= plannedByNow * (1 + sumAheadMargin) {
            state = .ahead
        } else if total >= plannedByNow * (1 - sumOnTrackTolerance) || (projected.map { $0 <= end } ?? false) {
            state = .onTrack
        } else if total >= plannedByNow * (1 - sumCloseTolerance) {
            state = .close
        } else {
            state = .behind
        }

        return SumReading(total: total, target: target, fraction: total / target,
                          plannedByNow: plannedByNow, remaining: remaining, weeksLeft: weeksLeft,
                          neededPerWeek: needed, recentWeeklyAverage: recentAverage,
                          suggestedWeeklyTarget: suggested, catchUpExceedsCap: exceedsCap,
                          projectedFinish: projected, state: state)
    }

    // MARK: - Target value without a target date

    /// Waypoints for a goal without a date are finer than a dated route's: the band shows five at a
    /// time, so a long way (217 → 100 kg) can carry ten-kilo steps without crowding.
    public static let undatedPreferredCount = 12
    /// The fine route skips the 2.5 rung. With twice the waypoints it would otherwise cut a short goal
    /// into quarter steps (3 kg in 0.25 kg); without it a short goal keeps the dated route's steps.
    public static let undatedLadder: [Double] = [1, 2, 5, 10]

    public struct MilestoneWindow: Equatable, Sendable {
        /// Every waypoint, ordered from start to target.
        public let values: [Double]
        /// How many of them are already reached (always a prefix along the direction of travel).
        public let reachedCount: Int
        /// The indices the band shows: two reached, the next one, two to come, shifted at the ends.
        public let visible: Range<Int>
        /// The first waypoint not yet reached, nil once all are.
        public var next: Double? { reachedCount < values.count ? values[reachedCount] : nil }
    }

    /// The route between `baseline` and `target` and the five waypoints the band shows around `current`.
    ///
    /// `step` fixes the spacing instead of fitting about a dozen marks to the span: weight passes 0.5 or
    /// 1 kg, so a 40 kg goal is a long route of small marks rather than nine 5 kg ones months apart.
    public static func milestoneWindow(baseline: Double, target: Double, current: Double,
                                       preferredCount: Int = undatedPreferredCount,
                                       step: Double? = nil,
                                       size: Int = 5) -> MilestoneWindow? {
        let values = step.map { GoalMilestones.values(baseline: baseline, target: target, step: $0) }
            ?? GoalMilestones.values(baseline: baseline, target: target, preferredCount: preferredCount,
                                     ladder: undatedLadder)
        guard !values.isEmpty, current.isFinite, size > 0 else { return nil }
        let ascending = target > baseline
        let reached = values.prefix { ascending ? current >= $0 - 1e-9 : current <= $0 + 1e-9 }.count
        return MilestoneWindow(values: values, reachedCount: reached,
                               visible: window(count: values.count, focus: reached, size: size))
    }

    /// A run of `size` indices with `focus` in the middle where possible, kept inside `0..<count`.
    static func window(count: Int, focus: Int, size: Int) -> Range<Int> {
        guard count > size else { return 0..<count }
        let lower = min(max(0, focus - size / 2), count - size)
        return lower..<(lower + size)
    }

    /// The spacing of weight marks: half a kilo up to a 10 kg change, a whole kilo beyond, so the next
    /// mark is always a week or two away at a sustainable pace.
    public static func weightMilestoneStep(baseline: Double, target: Double) -> Double {
        abs(target - baseline) > 10 ? 1 : 0.5
    }

    /// When the measured trend reaches `mark`, or nil: no trend, a trend that points away, or a date
    /// further out than `maxDays`. Used for the next waypoint and, within a year, for the target.
    public static func projectedDate(current: Double, mark: Double, ratePerDay: Double?, now: Date,
                                     maxDays: Int = maxProjectionDays) -> Date? {
        guard let ratePerDay, ratePerDay.isFinite, abs(ratePerDay) > 1e-12, current.isFinite else { return nil }
        let days = (mark - current) / ratePerDay
        guard days >= 0, days <= Double(maxDays) else { return nil }
        return now.addingTimeInterval(days * secondsPerDay)
    }

    /// The state of a target-value goal with no date to plan against: it can only say whether the
    /// trend is heading the right way. Nil without a trend.
    public static func undatedState(baseline: Double, target: Double, current: Double,
                                    ratePerDay: Double?) -> PeriodGoalState? {
        let ascending = target > baseline
        if ascending ? current >= target : current <= target { return .achieved }
        guard let ratePerDay, ratePerDay.isFinite else { return nil }
        let toward = ascending ? ratePerDay > 0 : ratePerDay < 0
        return toward ? .onTrack : .behind
    }

    // MARK: - Maintain

    /// Share of readings inside the band that reads as "on track", and as "close".
    public static let maintainOnTrackShare = 0.8
    public static let maintainCloseShare = 0.6
    /// Readings a maintain goal needs inside its window before it is judged. Weigh-ins are sparse.
    public static let maintainMinReadings = 4

    public struct MaintainReading: Equatable, Sendable {
        public let readings: Int
        /// Share of readings within `center ± band`, nil without readings.
        public let inBandShare: Double?
        public let latest: Double?
        /// `latest - center`.
        public let deviation: Double?
        /// Highest minus lowest reading in the window.
        public let spread: Double?
        public let state: PeriodGoalState
    }

    /// - Parameter samples: the smoothed series, so a day of water weight does not leave the band.
    public static func maintain(samples: [GoalMilestones.Sample], center: Double, band: Double,
                                now: Date, windowDays: Int = 28) -> MaintainReading {
        let window = recent(samples, now: now, days: windowDays)
        let values = window.map(\.value)
        guard !values.isEmpty, band >= 0 else {
            return MaintainReading(readings: 0, inBandShare: nil, latest: nil, deviation: nil, spread: nil,
                                   state: .noData)
        }
        let inside = values.filter { abs($0 - center) <= band + 1e-9 }.count
        let share = Double(inside) / Double(values.count)
        let latest = window.last?.value
        let state: PeriodGoalState
        if values.count < maintainMinReadings {
            state = .starting
        } else if share >= maintainOnTrackShare - 1e-9 {
            state = .onTrack
        } else if share >= maintainCloseShare - 1e-9 {
            state = .close
        } else {
            state = .behind
        }
        return MaintainReading(readings: values.count, inBandShare: share, latest: latest,
                               deviation: latest.map { $0 - center },
                               spread: (values.max() ?? 0) - (values.min() ?? 0), state: state)
    }

    // MARK: - Best value

    public struct BestReading: Equatable, Sendable {
        /// The best value since the goal started, nil before the first one.
        public let best: Double?
        public let bestDate: Date?
        public let daysSinceBest: Int?
        /// The best value inside the recent window, for "longest run of the last four weeks". It reads
        /// the whole window, before the start too: a goal set today still has a last four weeks.
        public let recentBest: Double?
        /// The best value before the goal started, shown beside it for context.
        public let earlierBest: Double?
        /// `best / target` for a higher-is-better goal, `target / best` otherwise; unclamped.
        public let fraction: Double?
        /// Nil when the goal has no date to plan against and is not reached yet: a best effort comes
        /// when it comes, and there is nothing honest to call late.
        public let state: PeriodGoalState?
    }

    /// A planned route for a dated best-value goal: the start value at `start`, the target at `end`.
    public struct BestPlan: Equatable, Sendable {
        public let baseline: Double
        public let start: Date
        public let end: Date
        public init(baseline: Double, start: Date, end: Date) {
            self.baseline = baseline
            self.start = start
            self.end = end
        }
    }

    public static func best(samples: [GoalMilestones.Sample], since: Date, target: Double,
                            higherIsBetter: Bool = true, plan: BestPlan? = nil, now: Date,
                            recentDays: Int = 28) -> BestReading {
        func better(_ a: GoalMilestones.Sample, _ b: GoalMilestones.Sample) -> Bool {
            higherIsBetter ? a.value > b.value : a.value < b.value
        }
        let valid = samples.filter { $0.value.isFinite && $0.date <= now }
        let during = valid.filter { $0.date >= since }
        let before = valid.filter { $0.date < since }
        let bestSample = during.reduce(nil as GoalMilestones.Sample?) { current, s in
            guard let current else { return s }
            return better(s, current) ? s : current
        }
        let recentCutoff = now.addingTimeInterval(-Double(recentDays) * secondsPerDay)
        let recentBest = valid.filter { $0.date >= recentCutoff }.map(\.value)
            .reduce(nil as Double?) { current, v in
                guard let current else { return v }
                return higherIsBetter ? max(current, v) : min(current, v)
            }
        let earlierBest = before.map(\.value).reduce(nil as Double?) { current, v in
            guard let current else { return v }
            return higherIsBetter ? max(current, v) : min(current, v)
        }
        let fraction: Double? = bestSample.flatMap { s in
            guard target > 0, s.value > 0 else { return nil }
            return higherIsBetter ? s.value / target : target / s.value
        }
        let reached = bestSample.map { higherIsBetter ? $0.value >= target - 1e-9 : $0.value <= target + 1e-9 } ?? false

        let state: PeriodGoalState?
        if reached {
            state = .achieved
        } else if let plan, plan.end > plan.start {
            let elapsed = min(max(0, now.timeIntervalSince(plan.start)), plan.end.timeIntervalSince(plan.start))
            let plannedNow = plan.baseline + (target - plan.baseline) * elapsed / plan.end.timeIntervalSince(plan.start)
            if during.isEmpty {
                state = .starting
            } else if let recentBest {
                let keepingUp = higherIsBetter ? recentBest >= plannedNow - 1e-9 : recentBest <= plannedNow + 1e-9
                state = keepingUp ? .onTrack : .behind
            } else {
                state = .behind
            }
        } else {
            state = nil
        }

        let daysSince = bestSample.map { Int((now.timeIntervalSince($0.date) / secondsPerDay).rounded(.down)) }
        return BestReading(best: bestSample?.value, bestDate: bestSample?.date, daysSinceBest: daysSince,
                           recentBest: recentBest, earlierBest: earlierBest, fraction: fraction, state: state)
    }

    // MARK: - Consistency

    /// Share of evaluated weeks hit that reads as "on track" by default, and as "close".
    public static let adherenceTarget = 0.8
    public static let adherenceCloseShare = 0.6
    /// Weeks of rhythm that must be evaluated before the share is judged.
    public static let adherenceMinWeeks = 4
    /// The rolling window of an open-ended consistency goal.
    public static let adherenceWindowWeeks = 12

    public struct AdherenceReading: Equatable, Sendable {
        /// Weeks that reached the weekly target inside the window.
        public let hit: Int
        /// Weeks that count: reached, almost or missed. Protected weeks and weeks without data do not.
        public let evaluated: Int
        /// `hit / evaluated`, nil with nothing evaluated.
        public let share: Double?
        public let currentStreak: Int
        public let bestStreak: Int
        public let state: PeriodGoalState
    }

    /// - Parameters:
    ///   - weeks: finished weeks, oldest first, without the running one.
    ///   - window: how many recent weeks count; pass `weeks.count` for a goal with a fixed end.
    public static func adherence(weeks: [PeriodOutcome], target: Double = adherenceTarget,
                                 window: Int = adherenceWindowWeeks) -> AdherenceReading {
        let inWindow = Array(weeks.suffix(max(0, window)))
        let hit = inWindow.filter { $0 == .achieved }.count
        let evaluated = inWindow.filter { $0 == .achieved || $0 == .almost || $0 == .missed }.count
        let share: Double? = evaluated > 0 ? Double(hit) / Double(evaluated) : nil
        let streak = PeriodGoalPace.streak(weeks)
        let state: PeriodGoalState
        if evaluated < adherenceMinWeeks {
            state = .starting
        } else if let share, share >= target - 1e-9 {
            state = .onTrack
        } else if let share, share >= adherenceCloseShare - 1e-9 {
            state = .close
        } else {
            state = .behind
        }
        return AdherenceReading(hit: hit, evaluated: evaluated, share: share,
                                currentStreak: streak.current, bestStreak: streak.best, state: state)
    }

    /// The weekday most events fall on and its share, from one day key per event. Nil with fewer than
    /// `minEvents` events or a tie for first place, where naming one day would be a coin toss.
    public static func strongestWeekday(eventDays: [String], minEvents: Int = 4) -> (weekday: Int, share: Double)? {
        let weekdays = eventDays.compactMap(PeriodCalendar.weekday)
        guard weekdays.count >= minEvents else { return nil }
        var counts: [Int: Int] = [:]
        for day in weekdays { counts[day, default: 0] += 1 }
        let sorted = counts.sorted { $0.value > $1.value }
        guard let top = sorted.first else { return nil }
        if sorted.count > 1, sorted[1].value == top.value { return nil }
        return (top.key, Double(top.value) / Double(weekdays.count))
    }

    // MARK: - Average

    /// Values the rolling mean needs before it is shown at all.
    public static let averageMinValues = 14
    /// The trend is fitted over this many days and needs this many values.
    public static let trendWindowDays = 56
    public static let trendMinValues = 28
    /// A monthly trend smaller than this share of the target counts as flat.
    public static let flatTrendShare = 0.01
    /// A flat trend this close to the target reads as "close" rather than "behind".
    public static let averageCloseShare = 0.05

    public struct AverageReading: Equatable, Sendable {
        public let mean: Double?
        /// Values inside the window.
        public let values: Int
        /// Values inside the window that met the target.
        public let atTarget: Int
        /// Still to go toward the target in the goal's direction, never below zero; nil without a mean.
        public let gap: Double?
        /// Fitted change per month, signed in the goal's unit; nil without enough values.
        public let trendPerMonth: Double?
        public let state: PeriodGoalState
    }

    public static func average(samples: [GoalMilestones.Sample], target: Double, higherIsBetter: Bool = true,
                               now: Date, windowDays: Int = 28) -> AverageReading {
        let window = recent(samples, now: now, days: windowDays).map(\.value)
        let mean = window.count >= averageMinValues ? window.reduce(0, +) / Double(window.count) : nil
        let atTarget = window.filter { higherIsBetter ? $0 >= target - 1e-9 : $0 <= target + 1e-9 }.count

        let trendSamples = recent(samples, now: now, days: trendWindowDays)
        let rate = trendSamples.count >= trendMinValues
            ? GoalMilestones.observedRatePerDay(series: trendSamples, now: now, windowDays: trendWindowDays)
            : nil
        let perMonth = rate.map { $0 * daysPerMonth }
        let gap = mean.map { max(0, higherIsBetter ? target - $0 : $0 - target) }

        let state: PeriodGoalState
        if let mean {
            let reached = higherIsBetter ? mean >= target - 1e-9 : mean <= target + 1e-9
            if reached {
                state = .achieved
            } else if let perMonth {
                let toward = higherIsBetter ? perMonth : -perMonth
                if abs(perMonth) < abs(target) * flatTrendShare {
                    state = (gap ?? 0) <= abs(target) * averageCloseShare ? .close : .behind
                } else {
                    state = toward > 0 ? .onTrack : .behind
                }
            } else {
                state = .starting
            }
        } else {
            state = .noData
        }
        return AverageReading(mean: mean, values: window.count, atTarget: atTarget, gap: gap,
                              trendPerMonth: perMonth, state: state)
    }

    // MARK: - Running pace

    public struct RunSample: Equatable, Sendable {
        public let date: Date
        public let distanceM: Double
        public let durationS: Double
        public init(date: Date, distanceM: Double, durationS: Double) {
            self.date = date
            self.distanceM = distanceM
            self.durationS = durationS
        }
    }

    /// Seconds per kilometre over every qualifying run in the window: total time over total distance,
    /// so a long run weighs as much as its kilometres. Nil without a qualifying run.
    public static func pace(runs: [RunSample], minDistanceM: Double = 3_000, now: Date,
                            windowDays: Int = 28) -> (secondsPerKm: Double, runs: Int)? {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * secondsPerDay)
        let counted = runs.filter {
            $0.date >= cutoff && $0.date <= now && $0.distanceM >= minDistanceM && $0.durationS > 0
                && $0.distanceM.isFinite && $0.durationS.isFinite
        }
        let distance = counted.reduce(0) { $0 + $1.distanceM }
        guard distance > 0 else { return nil }
        let duration = counted.reduce(0) { $0 + $1.durationS }
        return (duration / (distance / 1000), counted.count)
    }

    /// Pace as an average-shaped reading for a "run faster" goal (lower is better): the weighted pace of
    /// the window's qualifying runs, the runs at or under the target pace, and a monthly trend fitted on
    /// each run's own pace. Runs are sparse, so the minimums count runs, not days.
    public static let paceMinRuns = 2
    public static let paceTrendMinRuns = 4

    public static func paceAverage(runs: [RunSample], targetSecondsPerKm: Double, minDistanceM: Double = 3_000,
                                   now: Date, windowDays: Int = 28) -> AverageReading {
        let qualifying = runs.filter {
            $0.distanceM >= minDistanceM && $0.durationS > 0 && $0.distanceM.isFinite && $0.durationS.isFinite
        }
        let windowed = pace(runs: qualifying, minDistanceM: minDistanceM, now: now, windowDays: windowDays)
        let mean = windowed.flatMap { $0.runs >= paceMinRuns ? $0.secondsPerKm : nil }
        let samples = qualifying.map { GoalMilestones.Sample(date: $0.date, value: $0.durationS / ($0.distanceM / 1000)) }
        let inWindow = recent(samples, now: now, days: windowDays)
        let atTarget = inWindow.filter { $0.value <= targetSecondsPerKm + 1e-9 }.count

        let trendSamples = recent(samples, now: now, days: trendWindowDays)
        let rate = trendSamples.count >= paceTrendMinRuns
            ? GoalMilestones.observedRatePerDay(series: trendSamples, now: now, windowDays: trendWindowDays,
                                                minimumPoints: paceTrendMinRuns)
            : nil
        let perMonth = rate.map { $0 * daysPerMonth }
        let gap = mean.map { max(0, $0 - targetSecondsPerKm) }

        let state: PeriodGoalState
        if let mean {
            if mean <= targetSecondsPerKm + 1e-9 {
                state = .achieved
            } else if let perMonth {
                if abs(perMonth) < targetSecondsPerKm * flatTrendShare {
                    state = (gap ?? 0) <= targetSecondsPerKm * averageCloseShare ? .close : .behind
                } else {
                    state = perMonth < 0 ? .onTrack : .behind
                }
            } else {
                state = .starting
            }
        } else {
            // One run is a start, not an absence: the mean waits for the second.
            state = inWindow.isEmpty ? .noData : .starting
        }
        return AverageReading(mean: mean, values: inWindow.count, atTarget: atTarget, gap: gap,
                              trendPerMonth: perMonth, state: state)
    }

    // MARK: - Level of a sparse series

    /// Where a measured series stands now, for target-value goals that are not weight: the mean of the
    /// readings inside the window, so one reading cannot swing the verdict. Fewer than `minValues`
    /// readings still give a value, marked provisional: it is shown, never judged.
    public struct Level: Equatable, Sendable {
        public let value: Double
        public let readings: Int
        public let isProvisional: Bool
    }

    public static func level(samples: [GoalMilestones.Sample], now: Date, windowDays: Int,
                             minValues: Int) -> Level? {
        let window = recent(samples, now: now, days: windowDays)
        if window.isEmpty {
            // Nothing recent: the latest reading still says where the wearer stood, provisionally.
            guard let last = samples.filter({ $0.date <= now && $0.value.isFinite }).max(by: { $0.date < $1.date })
            else { return nil }
            return Level(value: last.value, readings: 1, isProvisional: true)
        }
        let mean = window.map(\.value).reduce(0, +) / Double(window.count)
        return Level(value: mean, readings: window.count, isProvisional: window.count < minValues)
    }

    // MARK: - Helpers

    static func recent(_ samples: [GoalMilestones.Sample], now: Date, days: Int) -> [GoalMilestones.Sample] {
        let cutoff = now.addingTimeInterval(-Double(days) * secondsPerDay)
        return samples.filter { $0.date > cutoff && $0.date <= now && $0.value.isFinite }
            .sorted { $0.date < $1.date }
    }
}
