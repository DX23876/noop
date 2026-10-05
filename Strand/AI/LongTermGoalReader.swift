import Foundation
import WhoopStore
import StrandAnalytics

/// What a catalog goal's page shows, one case per shape: the reading from `LongTermGoalMath` plus the
/// few series the page draws (weeks, days, milestones). Built by `LongTermGoalReader` on each tracking
/// refresh and carried on `GoalTrackingSnapshot.reading`.
enum GoalShapeReading: Equatable {
    case sum(SumData)
    case target(TargetData)
    case best(BestData)
    case consistency(ConsistencyData)
    case average(AverageData)
    case maintain(MaintainData)

    struct MaintainData: Equatable {
        let metric: LongTermMetric
        let reading: LongTermGoalMath.MaintainReading
        let center: Double
        let band: Double
    }

    struct SumData: Equatable {
        let metric: LongTermMetric
        let reading: LongTermGoalMath.SumReading
        let milestones: LongTermGoalMath.MilestoneWindow?
        /// The last complete weeks' amounts, oldest first.
        let recentWeeks: [Double]
        /// The running week so far.
        let thisWeek: Double
    }

    struct TargetData: Equatable {
        let metric: LongTermMetric
        let current: Double
        /// When `current` was measured, where it is one reading rather than an average (body weight).
        var currentDate: Date? = nil
        let baseline: Double
        let target: Double
        /// 0…1 along the way from baseline to target.
        let progress: Double
        /// Measured change per week, signed in the goal's unit; nil without enough readings.
        let ratePerWeek: Double?
        let milestones: LongTermGoalMath.MilestoneWindow?
        /// When the trend reaches the next waypoint, within a year.
        let nextMarkDate: Date?
        /// When the trend reaches the target: the course projection for a dated goal, a date within a
        /// year for an undated one.
        let arrivalDate: Date?
        let isProvisional: Bool
        let state: PeriodGoalState?
    }

    struct BestData: Equatable {
        let reading: LongTermGoalMath.BestReading
        let milestones: LongTermGoalMath.MilestoneWindow?
        /// Kilometres per week over the last four complete weeks, in the goal's sports.
        let recentWeeklyDistance: Double?
    }

    struct ConsistencyData: Equatable {
        let reading: LongTermGoalMath.AdherenceReading
        let weeklyGoalId: UUID
        let weeklyTarget: Double
        /// What the weekly goal counts, and its per-day bar (steps, hours of sleep) where it has one.
        let weeklyMetric: PeriodMetric
        let weeklyThreshold: Double?
        let thisWeek: Double
        /// The last eight finished weeks, oldest first, with the day key each one starts on.
        let lastWeeks: [PeriodOutcome]
        let lastWeekStarts: [String]
        /// Mean weekly amount over `lastWeeks`, and over the weeks before them.
        let averagePerWeek: Double?
        let previousAveragePerWeek: Double?
        let strongestWeekday: Int?
        let strongestWeekdayShare: Double?
        let adherenceTarget: Double
        /// A goal with a fixed end that has passed it: judged once, as reached or not.
        let fixedEndReached: Bool
    }

    struct AverageData: Equatable {
        let metric: LongTermMetric
        let reading: LongTermGoalMath.AverageReading
        /// The last 28 days, oldest first; nil = no reading that day.
        let days: [Double?]
        let target: Double
        let higherIsBetter: Bool
        /// The best of the four seven-day blocks in the window, by mean.
        let bestWeekMean: Double?
    }

    /// The state the page and the status pill show. Nil when the shape has nothing honest to judge.
    var state: PeriodGoalState? {
        switch self {
        case .sum(let d): return d.reading.state
        case .target(let d): return d.state
        case .best(let d): return d.reading.state
        case .consistency(let d):
            if d.fixedEndReached {
                return (d.reading.share ?? 0) >= d.adherenceTarget - 1e-9 ? .achieved : .outOfReach
            }
            return d.reading.state
        case .average(let d): return d.reading.state
        case .maintain(let d): return d.reading.state
        }
    }

    /// Progress toward the target, 0…1, where the shape has one (the bar in lists and on Today).
    var progress: Double? {
        switch self {
        case .sum(let d): return min(1, max(0, d.reading.fraction))
        case .target(let d): return d.progress
        case .best(let d): return d.reading.fraction.map { min(1, max(0, $0)) }
        case .consistency(let d): return d.reading.share
        case .average(let d):
            guard let mean = d.reading.mean, d.target > 0 else { return nil }
            return min(1, max(0, d.higherIsBetter ? mean / d.target : d.target / mean))
        case .maintain(let d): return d.reading.inBandShare
        }
    }
}

/// What the reader needs beyond the goals themselves, gathered once per tracking refresh.
struct LongTermReaderInputs {
    var workouts: [WorkoutRow] = []
    var days: [DailyMetric] = []
    var stepsByDay: [String: Int] = [:]
    /// The smoothed body-weight reading the tracking store already derives for weight goals.
    var weight: GoalMeasurement?
    /// The smoothed weight series the course fit reads.
    var weightSamples: [GoalMilestones.Sample] = []
    /// The scale's own readings, unsmoothed, oldest → newest: what a weight goal's headline and
    /// milestones count.
    var weightReadings: [GoalMilestones.Sample] = []
    /// The other target-value series, one reading per day where the source has one: resting heart rate,
    /// VO2max, body fat, lean mass, waist. Raw readings; `LongTermGoalReader` averages them itself.
    var series: [LongTermMetric: [GoalMilestones.Sample]] = [:]
}

/// Turns a catalog goal (`CoachGoal.measure`) into its `GoalShapeReading`. Pure apart from the inputs it
/// is handed. Metrics a later catalog step adds return nil here until their reading exists, and the
/// page says so instead of drawing a number it does not have.
enum LongTermGoalReader {

    static func reading(goal: CoachGoal, course: GoalMilestones.Course?, inputs: LongTermReaderInputs,
                        periodSnapshots: [PeriodGoalSnapshot], now: Date,
                        calendar: Calendar) -> GoalShapeReading? {
        guard let spec = goal.measure else { return nil }
        switch spec.metric {
        case .distanceTotal, .minutesTotal, .workoutsTotal, .stepsTotal:
            return sum(goal: goal, spec: spec, inputs: inputs, now: now, calendar: calendar)
        case .weight:
            if let band = spec.band {
                guard let center = goal.target else { return nil }
                return .maintain(.init(metric: .weight,
                                       reading: LongTermGoalMath.maintain(samples: inputs.weightSamples, center: center,
                                                                          band: band, now: now),
                                       center: center, band: band))
            }
            return weight(goal: goal, course: course, inputs: inputs, now: now, calendar: calendar)
        case .longestDistance:
            return best(goal: goal, spec: spec, inputs: inputs, now: now, calendar: calendar)
        case .weeklyAdherence:
            guard let id = spec.weeklyGoalId,
                  let weekly = periodSnapshots.first(where: { $0.id == id }) else { return nil }
            return consistency(goal: goal, spec: spec, weeklyGoalId: id, history: weekly.history,
                               thisWeek: weekly.result.current, weeklyTarget: weekly.goal.target,
                               weeklyMetric: weekly.goal.metric, weeklyThreshold: weekly.goal.threshold,
                               workouts: weekly.goal.isWorkoutBasedWeekly ? matching(inputs.workouts, weekly.goal.sportFilter) : [],
                               now: now, calendar: calendar)
        case .sleepAverage, .hrvAverage, .recoveryAverage:
            return average(goal: goal, metric: spec.metric, days: inputs.days, now: now, calendar: calendar)
        case .paceAverage:
            return pace(goal: goal, workouts: inputs.workouts, now: now)
        case .bodyFat, .leanMass, .waist, .vo2max, .restingHr:
            return level(goal: goal, metric: spec.metric, samples: inputs.series[spec.metric] ?? [], now: now,
                         calendar: calendar)
        }
    }

    // MARK: - Sum

    static func sum(goal: CoachGoal, spec: GoalMeasureSpec, inputs: LongTermReaderInputs, now: Date,
                    calendar: Calendar) -> GoalShapeReading? {
        guard let target = goal.target, target > 0, let targetDate = goal.targetDate else { return nil }
        let start = calendar.startOfDay(for: spec.countFrom ?? goal.createdAt)
        // The target day counts in full.
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: targetDate)) ?? targetDate

        var byDay: [String: Double] = [:]
        if spec.metric == .stepsTotal {
            for (day, steps) in inputs.stepsByDay { byDay[day] = Double(steps) }
        } else {
            for row in matching(inputs.workouts, spec.sportFilter) {
                guard let amount = amount(spec.metric, row) else { continue }
                byDay[dayKey(Date(timeIntervalSince1970: Double(row.startTs)), calendar), default: 0] += amount
            }
        }
        func total(from: Date, to: Date) -> Double {
            let fromKey = dayKey(from, calendar), toKey = dayKey(to, calendar)
            return byDay.reduce(0) { $0 + ($1.key >= fromKey && $1.key <= toKey ? $1.value : 0) }
        }

        // Nothing after the target day counts: a goal missed on 31 December is not reached by January's runs.
        let collected = total(from: start, to: min(now, end.addingTimeInterval(-1)))
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let recent: [Double] = (1...LongTermGoalMath.paceWeeks).reversed().compactMap { back in
            guard let from = calendar.date(byAdding: .weekOfYear, value: -back, to: weekStart),
                  let to = calendar.date(byAdding: .day, value: 6, to: from) else { return nil }
            return total(from: from, to: to)
        }
        let cap = isRunning(spec.sportFilter) ? 0.10 : 0.20
        guard let reading = LongTermGoalMath.sum(total: collected, target: target, start: start, end: end, now: now,
                                                 recentWeeklyTotals: recent, capFraction: cap) else { return nil }
        return .sum(.init(metric: spec.metric, reading: reading,
                          milestones: LongTermGoalMath.milestoneWindow(baseline: 0, target: target, current: collected),
                          recentWeeks: recent, thisWeek: total(from: weekStart, to: now)))
    }

    // MARK: - Target value

    static func weight(goal: CoachGoal, course: GoalMilestones.Course?, inputs: LongTermReaderInputs,
                       now: Date, calendar: Calendar) -> GoalShapeReading? {
        guard let measurement = inputs.weight, let baseline = goal.baseline, let target = goal.target,
              baseline != target else { return nil }
        let ascending = target > baseline
        // Two numbers on purpose. What the scale said (the latest reading for the headline, the best
        // since the goal began for milestones and arrival) is a fact: weighed 207.3 kg once, the 208 kg
        // mark is reached and stays reached. The smoothed trend only judges the course and projects
        // dates, where one day of water must not flip the verdict.
        let latest = inputs.weightReadings.last
        let current = latest?.value ?? measurement.value
        let start = calendar.startOfDay(for: goal.createdAt)
        let sinceStart = inputs.weightReadings.filter { $0.date >= start }.map(\.value) + [current]
        let best = (ascending ? sinceStart.max() : sinceStart.min()) ?? current
        let trend = measurement.value
        let rate = GoalMilestones.observedRatePerDay(series: inputs.weightSamples, now: now)
        let window = LongTermGoalMath.milestoneWindow(
            baseline: baseline, target: target, current: best,
            step: LongTermGoalMath.weightMilestoneStep(baseline: baseline, target: target))
        let nextDate = window?.next.flatMap {
            LongTermGoalMath.projectedDate(current: trend, mark: $0, ratePerDay: rate, now: now)
        }
        let arrival: Date?
        var state: PeriodGoalState?
        if goal.targetDate != nil {
            arrival = course?.projectedDate
            state = course.map { courseState($0.verdict) }
        } else {
            arrival = LongTermGoalMath.projectedDate(current: trend, mark: target, ratePerDay: rate, now: now)
            state = LongTermGoalMath.undatedState(baseline: baseline, target: target, current: trend, ratePerDay: rate)
        }
        if ascending ? best >= target : best <= target { state = .achieved }
        // A trend still settling is shown, never judged.
        if measurement.isProvisional, state != .achieved { state = .starting }
        let progress = min(1, max(0, (current - baseline) / (target - baseline)))
        return .target(.init(metric: .weight, current: current, currentDate: latest?.date,
                             baseline: baseline, target: target,
                             progress: progress, ratePerWeek: rate.map { $0 * 7 }, milestones: window,
                             nextMarkDate: nextDate, arrivalDate: arrival,
                             isProvisional: measurement.isProvisional, state: state))
    }

    static func courseState(_ verdict: GoalMilestones.Verdict) -> PeriodGoalState {
        switch verdict {
        case .onCourse: return .onTrack
        case .ahead: return .ahead
        case .behind, .movingAway, .unforeseeable: return .behind
        case .notEnoughData: return .starting
        }
    }

    /// How a series other than weight is read: the window its level is averaged over, how many readings
    /// that level needs before it is judged, and the window and minimum its trend is fitted with. Resting
    /// heart rate arrives nightly; VO2max about weekly; body measurements whenever the wearer takes them.
    struct LevelRule {
        let windowDays: Int
        let minValues: Int
        let rateWindowDays: Int
        let rateMinPoints: Int
        /// The finest step the value is shown in: waypoints are never finer, and a change below half of
        /// it in a month reads as flat rather than as a direction.
        let resolution: Double
        /// Each reading is a measurement the wearer took (tape, scale), so like body weight the headline
        /// is the latest and milestones count the best since the start; the average only judges the
        /// course. False for nightly or estimated series, where one good reading proves nothing.
        var countsReadings = false
    }

    static func levelRule(_ metric: LongTermMetric) -> LevelRule {
        switch metric {
        // A lower resting heart rate only means something once it holds: the level is four weeks of
        // nights, not a good week, so "reached" says it was kept.
        case .restingHr:
            return LevelRule(windowDays: 28, minValues: 14, rateWindowDays: 56, rateMinPoints: 14, resolution: 1)
        case .vo2max:
            return LevelRule(windowDays: 21, minValues: 2, rateWindowDays: 84, rateMinPoints: 4, resolution: 0.5)
        case .waist:
            return LevelRule(windowDays: 30, minValues: 2, rateWindowDays: 90, rateMinPoints: 3, resolution: 1,
                             countsReadings: true)
        default:
            return LevelRule(windowDays: 30, minValues: 2, rateWindowDays: 90, rateMinPoints: 3, resolution: 0.5,
                             countsReadings: true)
        }
    }

    /// A target value read from a series other than weight. The same reading as weight (milestones, next
    /// mark, arrival), with the level averaged over the series' own window instead of the weight trend.
    static func level(goal: CoachGoal, metric: LongTermMetric, samples: [GoalMilestones.Sample],
                      now: Date, calendar: Calendar) -> GoalShapeReading? {
        guard let baseline = goal.baseline, let target = goal.target, baseline != target else { return nil }
        let rule = levelRule(metric)
        guard let level = LongTermGoalMath.level(samples: samples, now: now, windowDays: rule.windowDays,
                                                 minValues: rule.minValues) else { return nil }
        let ascending = target > baseline
        let trend = level.value
        // A measured series reads like body weight: the latest measurement as the headline, the best since
        // the start for milestones and "reached". The average below only judges the course.
        let latest = rule.countsReadings
            ? samples.filter { $0.date <= now && $0.value.isFinite }.max(by: { $0.date < $1.date }) : nil
        let current = latest?.value ?? trend
        let best: Double
        if rule.countsReadings {
            let start = calendar.startOfDay(for: goal.createdAt)
            let since = samples.filter { $0.date >= start && $0.date <= now && $0.value.isFinite }.map(\.value) + [current]
            best = (ascending ? since.max() : since.min()) ?? current
        } else {
            best = trend
        }
        let fitted = GoalMilestones.observedRatePerDay(series: samples, now: now, windowDays: rule.rateWindowDays,
                                                       minimumPoints: rule.rateMinPoints)
        // A drift too small to show in the value's own step within a month is no direction yet.
        let isFlat = fitted.map { abs($0 * 30.44) < rule.resolution / 2 } ?? false
        let rate = isFlat ? nil : fitted
        let steps = Int((abs(target - baseline) / rule.resolution).rounded(.down))
        let window = LongTermGoalMath.milestoneWindow(
            baseline: baseline, target: target, current: best,
            preferredCount: min(LongTermGoalMath.undatedPreferredCount, max(1, steps)))
        let nextDate = window?.next.flatMap {
            LongTermGoalMath.projectedDate(current: trend, mark: $0, ratePerDay: rate, now: now)
        }
        let arrival: Date?
        var state: PeriodGoalState?
        if let targetDate = goal.targetDate {
            let course = GoalMilestones.course(baseline: baseline, target: target, createdAt: goal.createdAt,
                                               targetDate: targetDate, current: trend, series: samples, now: now,
                                               rateWindowDays: rule.rateWindowDays,
                                               minimumRatePoints: rule.rateMinPoints)
            arrival = course?.projectedDate
            state = course.map { courseState($0.verdict) }
        } else {
            arrival = LongTermGoalMath.projectedDate(current: trend, mark: target, ratePerDay: rate, now: now)
            state = LongTermGoalMath.undatedState(baseline: baseline, target: target, current: trend, ratePerDay: rate)
        }
        if ascending ? best >= target : best <= target { state = .achieved }
        if level.isProvisional, state != .achieved { state = .starting }
        // Flat and not reached: shown as running, neither on track nor behind.
        if isFlat, state != .achieved, !level.isProvisional, goal.targetDate == nil { state = nil }
        let progress = min(1, max(0, (current - baseline) / (target - baseline)))
        return .target(.init(metric: metric, current: current, currentDate: latest?.date,
                             baseline: baseline, target: target,
                             progress: progress, ratePerWeek: isFlat ? 0 : rate.map { $0 * 7 }, milestones: window,
                             nextMarkDate: nextDate, arrivalDate: arrival,
                             isProvisional: level.isProvisional, state: state))
    }

    /// "Run faster": the 28-day pace of runs from 3 km, lower is better. The band is each run's pace
    /// over the last 28 days, oldest first, so the columns read like the other averages.
    static func pace(goal: CoachGoal, workouts: [WorkoutRow], now: Date) -> GoalShapeReading? {
        guard let target = goal.target, target > 0 else { return nil }
        let runs = matching(workouts, ["Running"]).compactMap { row -> LongTermGoalMath.RunSample? in
            guard let meters = row.distanceM, meters > 0 else { return nil }
            let seconds = row.durationS ?? Double(max(0, row.endTs - row.startTs))
            return LongTermGoalMath.RunSample(date: Date(timeIntervalSince1970: Double(row.startTs)),
                                              distanceM: meters, durationS: seconds)
        }
        let reading = LongTermGoalMath.paceAverage(runs: runs, targetSecondsPerKm: target, now: now)
        let cutoff = now.addingTimeInterval(-28 * 86_400)
        let recent = runs.filter { $0.date > cutoff && $0.distanceM >= 3_000 && $0.durationS > 0 }
            .sorted { $0.date < $1.date }
            .map { Optional($0.durationS / ($0.distanceM / 1_000)) }
        let best = recent.compactMap { $0 }.min()
        return .average(.init(metric: .paceAverage, reading: reading, days: recent, target: target,
                              higherIsBetter: false, bestWeekMean: best))
    }

    // MARK: - Best value

    static func best(goal: CoachGoal, spec: GoalMeasureSpec, inputs: LongTermReaderInputs, now: Date,
                     calendar: Calendar) -> GoalShapeReading? {
        guard let target = goal.target, target > 0 else { return nil }
        let rows = matching(inputs.workouts, spec.sportFilter).filter { ($0.distanceM ?? 0) > 0 }
        let samples = rows.map {
            GoalMilestones.Sample(date: Date(timeIntervalSince1970: Double($0.startTs)), value: ($0.distanceM ?? 0) / 1_000)
        }
        let plan = goal.targetDate.flatMap { end in
            goal.baseline.map { LongTermGoalMath.BestPlan(baseline: $0, start: goal.createdAt, end: end) }
        }
        let reading = LongTermGoalMath.best(samples: samples, since: goal.createdAt, target: target,
                                            plan: plan, now: now)
        let baseline = goal.baseline ?? 0
        let window = baseline < target
            ? LongTermGoalMath.milestoneWindow(baseline: baseline, target: target, current: reading.best ?? baseline)
            : nil
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let fourWeeksAgo = calendar.date(byAdding: .weekOfYear, value: -LongTermGoalMath.paceWeeks, to: weekStart) ?? weekStart
        let recentKm = samples.filter { $0.date >= fourWeeksAgo && $0.date < weekStart }.reduce(0) { $0 + $1.value }
        let hasHistory = samples.contains { $0.date < fourWeeksAgo }
        return .best(.init(reading: reading, milestones: window,
                           recentWeeklyDistance: hasHistory || recentKm > 0
                               ? recentKm / Double(LongTermGoalMath.paceWeeks) : nil))
    }

    // MARK: - Consistency

    static func consistency(goal: CoachGoal, spec: GoalMeasureSpec, weeklyGoalId: UUID,
                            history: [PeriodGoalSnapshot.HistoryEntry], thisWeek: Double, weeklyTarget: Double,
                            weeklyMetric: PeriodMetric = .workouts, weeklyThreshold: Double? = nil,
                            workouts: [WorkoutRow], now: Date, calendar: Calendar) -> GoalShapeReading {
        // A goal with a fixed end judges only its own weeks; an open one the rolling window, which may
        // reach back before the goal was set because the weekly goal's history does.
        var entries = history
        if spec.fixedEnd != nil {
            let createdWeek = calendar.dateInterval(of: .weekOfYear, for: goal.createdAt)?.start ?? goal.createdAt
            let createdKey = dayKey(createdWeek, calendar)
            entries = entries.filter { $0.periodStart >= createdKey }
        }
        let outcomes = entries.map(\.outcome)
        let target = spec.adherenceTarget ?? LongTermGoalMath.adherenceTarget
        let window = spec.fixedEnd != nil ? outcomes.count : (spec.adherenceWeeks ?? LongTermGoalMath.adherenceWindowWeeks)
        let reading = LongTermGoalMath.adherence(weeks: outcomes, target: target, window: window)

        let last = Array(entries.suffix(8))
        let earlier = Array(entries.dropLast(last.count))
        func mean(_ list: [PeriodGoalSnapshot.HistoryEntry]) -> Double? {
            list.isEmpty ? nil : list.map(\.value).reduce(0, +) / Double(list.count)
        }
        let cutoff = calendar.date(byAdding: .weekOfYear, value: -12, to: now) ?? now
        let eventDays = workouts.filter { Double($0.startTs) >= cutoff.timeIntervalSince1970 }
            .map { dayKey(Date(timeIntervalSince1970: Double($0.startTs)), calendar) }
        let weekday = LongTermGoalMath.strongestWeekday(eventDays: eventDays)
        return .consistency(.init(reading: reading, weeklyGoalId: weeklyGoalId, weeklyTarget: weeklyTarget,
                                  weeklyMetric: weeklyMetric, weeklyThreshold: weeklyThreshold,
                                  thisWeek: thisWeek, lastWeeks: last.map(\.outcome),
                                  lastWeekStarts: last.map(\.periodStart),
                                  averagePerWeek: mean(last), previousAveragePerWeek: mean(earlier),
                                  strongestWeekday: weekday?.weekday, strongestWeekdayShare: weekday?.share,
                                  adherenceTarget: target,
                                  fixedEndReached: spec.fixedEnd.map { now >= $0 } ?? false))
    }

    // MARK: - Average

    static func average(goal: CoachGoal, metric: LongTermMetric, days: [DailyMetric], now: Date,
                        calendar: Calendar) -> GoalShapeReading? {
        guard let target = goal.target, target > 0 else { return nil }
        func value(_ row: DailyMetric) -> Double? {
            switch metric {
            case .sleepAverage: return row.totalSleepMin.map { $0 / 60 }
            case .hrvAverage: return row.avgHrv
            case .recoveryAverage: return row.recovery
            default: return nil
            }
        }
        var byDay: [String: Double] = [:]
        for row in days { if let v = value(row) { byDay[row.day] = v } }
        let samples = byDay.compactMap { day, v -> GoalMilestones.Sample? in
            noon(of: day, calendar).map { GoalMilestones.Sample(date: $0, value: v) }
        }
        let higherIsBetter = goal.baseline.map { target >= $0 } ?? true
        let reading = LongTermGoalMath.average(samples: samples, target: target, higherIsBetter: higherIsBetter, now: now)
        let today = calendar.startOfDay(for: now)
        let window: [Double?] = (0..<28).reversed().map { back in
            calendar.date(byAdding: .day, value: -back, to: today).flatMap { byDay[dayKey($0, calendar)] }
        }
        let blocks = stride(from: 0, to: 28, by: 7).compactMap { start -> Double? in
            let values = window[start..<(start + 7)].compactMap { $0 }
            return values.count >= 3 ? values.reduce(0, +) / Double(values.count) : nil
        }
        let best = higherIsBetter ? blocks.max() : blocks.min()
        return .average(.init(metric: metric, reading: reading, days: window, target: target,
                              higherIsBetter: higherIsBetter, bestWeekMean: best))
    }

    // MARK: - Helpers

    static func matching(_ workouts: [WorkoutRow], _ sportFilter: [String]) -> [WorkoutRow] {
        workouts.filter { GoalActionEvaluator.matches($0, any: sportFilter) }
    }

    static func amount(_ metric: LongTermMetric, _ row: WorkoutRow) -> Double? {
        switch metric {
        case .distanceTotal:
            guard let meters = row.distanceM, meters > 0 else { return nil }
            return meters / 1_000
        case .minutesTotal:
            return (row.durationS ?? Double(max(0, row.endTs - row.startTs))) / 60
        case .workoutsTotal:
            return 1
        default:
            return nil
        }
    }

    /// Running gets the tighter weekly cap (Q21): a sport filter that names running.
    static func isRunning(_ sportFilter: [String]) -> Bool {
        sportFilter.contains { $0.lowercased().contains("run") || $0.lowercased().contains("lauf") }
    }

    static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        PeriodGoalTracker.dayKey(date, calendar: calendar)
    }

    static func noon(of day: String, _ calendar: Calendar) -> Date? {
        PeriodGoalTracker.date(day, calendar: calendar).flatMap {
            calendar.date(bySettingHour: 12, minute: 0, second: 0, of: $0)
        }
    }
}

private extension PeriodGoal {
    /// Weekly goals whose events are workouts, so the strongest weekday can be read from them.
    var isWorkoutBasedWeekly: Bool { metric.isWorkoutBased || metric == .workingSets }
}
