import Foundation

// PeriodGoalPace.swift — the pure arithmetic behind weekly and monthly goals.
//
// A period goal ("4 runs a week", "60 km in October", "5 nights of 7 h", "7.5 h average sleep") is read
// against a PACE: where the wearer should stand today if the target were spread over the period's
// planned days. The app turns stored rows into one value per day; everything from there to a state word
// ("on track", "close", "behind") lives here, database-free and unit-tested.
//
// Honesty rules carried over from the long-term goals:
// - a day with no data is NOT a zero for an average (a night the strap was off is missing, not 0 h);
// - "out of reach" is only said when the arithmetic proves it, never as a guess;
// - a week that has barely started is not judged ("starting"), and a protected week (paused, ill) is not
//   judged at all.

/// How a period goal adds up its days.
public enum PeriodAggregation: String, Codable, Sendable, CaseIterable {
    /// Events per period, e.g. workouts. Each day carries how many happened.
    case count
    /// An amount per period, e.g. minutes or kilometres. Each day carries its amount.
    case sum
    /// Days meeting a condition, e.g. nights of at least 7 h. Each day carries 1 (met) or 0 (missed).
    case hitDays
    /// The mean of the days that have a value, e.g. average nightly sleep.
    case average
}

/// The state of a period that is still running.
public enum PeriodGoalState: String, Sendable, CaseIterable {
    case achieved, ahead, onTrack, close, behind, outOfReach, protected, starting, noData
}

/// How a finished period ended. `almost` (at least 80 %) keeps a series alive without being called
/// achieved — two thresholds the wearer can see, rather than one hidden one.
public enum PeriodOutcome: String, Codable, Sendable, CaseIterable {
    case achieved, almost, missed, protected, noData
}

/// One calendar day of a period.
public struct PeriodDay: Equatable, Sendable {
    /// "yyyy-MM-dd".
    public let key: String
    /// The day's contribution: a count, an amount, 1/0 for a hit day, or a reading for an average.
    /// nil = no data for that day. For `count`/`sum` the caller passes 0 for a day with nothing logged,
    /// because "no workout" is a real zero; nil there means the day could not be read at all.
    public let value: Double?
    /// A planned rest day: it carries no share of the pace. Only training goals mark rest days.
    public let isRest: Bool

    public init(key: String, value: Double?, isRest: Bool = false) {
        self.key = key
        self.value = value
        self.isRest = isRest
    }
}

public struct PeriodPaceInput: Sendable {
    public var aggregation: PeriodAggregation
    /// The full-period target in the goal's unit.
    public var target: Double
    /// Every day of the period, in order.
    public var days: [PeriodDay]
    /// Index of today within `days`. `days.count` or more = the period is over; negative = not begun.
    public var todayIndex: Int
    /// First day the goal existed in this period. A goal set up on a Thursday is judged on Thursday to
    /// Sunday with a pro-rated target, instead of being "behind" for days nobody was pursuing it.
    public var activeFromIndex: Int
    /// How much of today counts as elapsed for the pace (0...1). The default half-day keeps a morning
    /// from reading as "behind" for a workout that is planned for the evening.
    public var todayElapsed: Double
    /// What the wearer typically manages on an active day (upper quartile). With it, "close" and
    /// "behind" are measured against the wearer's own capacity rather than a fixed rule.
    public var typicalDailyUpper: Double?
    /// The most a single day can contribute (1 for hit days). Enables a proven "out of reach".
    public var maxPerDay: Double?
    /// Paused, ill, travelling: the period is not judged.
    public var isProtected: Bool

    public init(aggregation: PeriodAggregation, target: Double, days: [PeriodDay], todayIndex: Int,
                activeFromIndex: Int = 0, todayElapsed: Double = 0.5, typicalDailyUpper: Double? = nil,
                maxPerDay: Double? = nil, isProtected: Bool = false) {
        self.aggregation = aggregation
        self.target = target
        self.days = days
        self.todayIndex = todayIndex
        self.activeFromIndex = activeFromIndex
        self.todayElapsed = todayElapsed
        self.typicalDailyUpper = typicalDailyUpper
        self.maxPerDay = maxPerDay
        self.isProtected = isProtected
    }
}

public struct PeriodPaceResult: Equatable, Sendable {
    /// What has been done so far (the mean, for an average goal).
    public let current: Double
    /// The target that applies to this period, pro-rated when the goal started part-way through it.
    public let target: Double
    /// `current / target`, unclamped: 1.6 means 60 % over.
    public let fraction: Double
    /// Where the pace says the wearer should stand now, as a fraction of `target`. nil for an average
    /// goal (its pace line is the target itself) and once the period is over.
    public let paceFraction: Double?
    /// What is still missing, never negative. For an average goal: the mean the remaining days need.
    public let remaining: Double
    /// Planned days left, today included.
    public let remainingDays: Int
    /// What each remaining planned day needs to deliver. nil when nothing is missing.
    public let requiredPerDay: Double?
    /// Where the current rate lands at the end of the period. nil until there is a rate to extend.
    public let projected: Double?
    /// The verdict for a running period.
    public let state: PeriodGoalState
    /// Days in the judged window (from `activeFromIndex`) and how many of the elapsed ones had no data.
    public let judgedDays: Int
    public let missingDays: Int
    /// True when the target was cut because the goal began part-way through the period.
    public let isProrated: Bool
}

public enum PeriodGoalPace {

    /// Share of the target a count/sum goal may trail the pace by and still be "on track".
    public static let sumTolerance = 0.10
    /// Share of the target a goal must lead the pace by to be "ahead".
    public static let aheadMargin = 0.15
    /// An average goal within this share below its target is still "on track".
    public static let averageTolerance = 0.02
    /// The share of the target that keeps a finished period's series alive as "almost".
    public static let almostFraction = 0.8
    /// Planned days that must have elapsed before a period without a lead is judged.
    public static let startingDays = 2

    // MARK: - Running period

    public static func evaluate(_ input: PeriodPaceInput) -> PeriodPaceResult {
        let days = input.days
        let n = days.count
        let from = min(max(0, input.activeFromIndex), max(0, n - 1))
        let judged = n > 0 ? Array(days[from...]) : []
        let todayRel = input.todayIndex - from          // today's index inside `judged`
        let isOver = input.todayIndex >= n

        // Planned days: non-rest days of the judged window. A week marked entirely as rest would have
        // no pace at all, so it falls back to every day.
        var planned = judged.map { !$0.isRest }
        if !planned.contains(true) { planned = judged.map { _ in true } }
        let totalPlanned = planned.filter { $0 }.count
        let fullPlanned: Int = {
            let all = days.map { !$0.isRest }
            let count = all.filter { $0 }.count
            return count == 0 ? n : count
        }()

        // Pro-rating: a goal that began part-way through the period answers for its share of it.
        let isProrated = from > 0 && fullPlanned > 0
        let target: Double = {
            guard isProrated else { return input.target }
            let share = input.target * Double(totalPlanned) / Double(fullPlanned)
            switch input.aggregation {
            case .count, .hitDays: return max(1, share.rounded())
            case .sum:             return max(share, 0)
            case .average:         return input.target
            }
        }()

        // Days whose value is already known: everything before today, plus today itself.
        let knownCount = isOver ? judged.count : max(0, min(judged.count, todayRel + 1))
        let known = Array(judged.prefix(knownCount))
        let elapsedBeforeToday = isOver ? judged.count : max(0, min(judged.count, todayRel))
        let missing = judged.prefix(elapsedBeforeToday).filter { $0.value == nil }.count

        if input.aggregation == .average {
            return evaluateAverage(input: input, target: target, judged: judged, known: known,
                                   todayRel: todayRel, isOver: isOver, missing: missing,
                                   elapsedBeforeToday: elapsedBeforeToday, isProrated: isProrated)
        }

        let current = known.reduce(0) { $0 + ($1.value ?? 0) }
        let fraction = target > 0 ? current / target : 0
        let remaining = max(0, target - current)

        // Planned days left, today included.
        let remainingPlanned: Int = isOver ? 0
            : planned.indices.filter { $0 >= max(0, todayRel) && planned[$0] }.count
        // Calendar days still able to contribute (a hit day already counted today has no room left).
        let todayValue = (!isOver && todayRel >= 0 && todayRel < judged.count) ? judged[todayRel].value : nil
        var openDays = isOver ? 0 : max(0, judged.count - max(0, todayRel))
        if input.aggregation == .hitDays, (todayValue ?? 0) >= 1 { openDays = max(0, openDays - 1) }

        // The pace: the target spread over planned days, with today counted as part-elapsed.
        let plannedBefore = planned.indices.filter { $0 < max(0, todayRel) && planned[$0] }.count
        let todayPlanned = (todayRel >= 0 && todayRel < planned.count) ? planned[todayRel] : false
        let elapsedPlanned = Double(plannedBefore) + (todayPlanned ? min(1, max(0, input.todayElapsed)) : 0)
        let expected = totalPlanned > 0 ? target * elapsedPlanned / Double(totalPlanned) : 0

        let requiredPerDay: Double? = remaining > 0 && remainingPlanned > 0
            ? remaining / Double(remainingPlanned) : nil
        let projected: Double? = {
            guard !isOver, plannedBefore >= 1 else { return nil }
            let rate = current / max(1, elapsedPlanned)
            return current + rate * Double(max(0, remainingPlanned - (todayPlanned ? 1 : 0)))
                + (todayPlanned ? rate * (1 - min(1, max(0, input.todayElapsed))) : 0)
        }()

        let state: PeriodGoalState
        if input.isProtected {
            state = .protected
        } else if target > 0, current >= target - 1e-9 {
            state = .achieved
        } else if input.todayIndex < 0 {
            state = .starting
        } else if let cap = input.maxPerDay, remaining > cap * Double(openDays) + 1e-9 {
            state = .outOfReach
        } else {
            let wholeUnits = input.aggregation != .sum
            let lead = current - expected
            let aheadBy = max(aheadMargin * target, wholeUnits ? 1 : 0)
            let tolerance = wholeUnits ? 0.5 : sumTolerance * target
            if lead >= aheadBy && current > 0 {
                state = .ahead
            } else if plannedBefore < startingDays {
                state = .starting
            } else if lead >= -tolerance {
                state = .onTrack
            } else if let needed = requiredPerDay {
                let capacity = input.typicalDailyUpper
                    ?? (totalPlanned > 0 ? 1.5 * target / Double(totalPlanned) : needed)
                state = needed <= capacity + 1e-9 ? .close : .behind
            } else {
                state = .onTrack
            }
        }

        return PeriodPaceResult(current: current, target: target, fraction: fraction,
                                paceFraction: isOver || target <= 0 ? nil : min(1, expected / target),
                                remaining: remaining, remainingDays: remainingPlanned,
                                requiredPerDay: requiredPerDay, projected: projected, state: state,
                                judgedDays: judged.count, missingDays: missing, isProrated: isProrated)
    }

    private static func evaluateAverage(input: PeriodPaceInput, target: Double, judged: [PeriodDay],
                                        known: [PeriodDay], todayRel: Int, isOver: Bool, missing: Int,
                                        elapsedBeforeToday: Int, isProrated: Bool) -> PeriodPaceResult {
        let values = known.compactMap(\.value)
        let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let fraction = target > 0 ? mean / target : 0
        // Days after today that can still bring the mean up.
        let futureDays = isOver ? 0 : max(0, judged.count - max(0, todayRel) - 1)
        let needed: Double? = {
            guard futureDays > 0, !values.isEmpty else { return nil }
            let total = target * Double(values.count + futureDays) - values.reduce(0, +)
            return max(0, total / Double(futureDays))
        }()

        let state: PeriodGoalState
        if input.isProtected {
            state = .protected
        } else if elapsedBeforeToday >= 2, missing * 2 > elapsedBeforeToday {
            state = .noData
        } else if values.isEmpty || input.todayIndex < 0 {
            state = .starting
        } else if mean >= target * (1 + aheadMargin / 3) {
            state = .ahead
        } else if mean >= target * (1 - averageTolerance) {
            state = isOver ? .achieved : .onTrack
        } else if let needed {
            if let cap = input.maxPerDay, needed > cap + 1e-9 {
                state = .outOfReach
            } else {
                let capacity = input.typicalDailyUpper ?? target * 1.1
                state = needed <= capacity + 1e-9 ? .close : .behind
            }
        } else {
            state = .behind
        }

        return PeriodPaceResult(current: mean, target: target, fraction: fraction, paceFraction: nil,
                                remaining: needed ?? 0, remainingDays: futureDays, requiredPerDay: needed,
                                projected: nil, state: state, judgedDays: judged.count,
                                missingDays: missing, isProrated: isProrated)
    }

    // MARK: - Finished period

    /// How a finished period ended. Takes the same input as `evaluate`; `todayIndex` is ignored.
    public static func outcome(_ input: PeriodPaceInput) -> PeriodOutcome {
        if input.isProtected { return .protected }
        var finished = input
        finished.todayIndex = input.days.count
        let result = evaluate(finished)
        if input.aggregation == .average {
            let known = result.judgedDays - result.missingDays
            if known * 2 < result.judgedDays { return .noData }
        }
        guard result.target > 0 else { return .noData }
        if result.fraction >= 1 - 1e-9 { return .achieved }
        if result.fraction >= almostFraction - 1e-9 { return .almost }
        return .missed
    }

    // MARK: - Series

    /// The current and best run of achieved-or-almost periods, oldest → newest. A protected period or
    /// one without data neither extends nor breaks a run; a missed one ends it.
    public static func streak(_ outcomes: [PeriodOutcome]) -> (current: Int, best: Int) {
        var run = 0, best = 0
        for outcome in outcomes {
            switch outcome {
            case .achieved, .almost:
                run += 1
                best = max(best, run)
            case .missed:
                run = 0
            case .protected, .noData:
                continue
            }
        }
        return (run, best)
    }

    // MARK: - Capacity

    /// The upper quartile of the days that contributed anything — what this person typically manages
    /// on an active day. nil with fewer than three such days.
    public static func typicalDailyUpper(_ dailyValues: [Double]) -> Double? {
        let active = dailyValues.filter { $0 > 0 }.sorted()
        guard active.count >= 3 else { return nil }
        return quantile(active, 0.75)
    }

    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}

// MARK: - Calendar helpers (day keys, timezone-free)

public enum PeriodCalendar {

    /// The seven day keys of the week containing `day`, for a week starting on `firstWeekday`
    /// (1 = Sunday, 2 = Monday). Empty for an unparseable day.
    public static func weekDays(containing day: String, firstWeekday: Int) -> [String] {
        guard let start = WeeklyDigestEngine.weekStart(containing: day, firstWeekday: firstWeekday) else {
            return []
        }
        return (0..<7).map { WeeklyDigestEngine.addDays(start, $0) }
    }

    /// Every day key of the calendar month containing `day`.
    public static func monthDays(containing day: String) -> [String] {
        guard let (y, m, _) = WeeklyDigestEngine.parseYMD(day) else { return [] }
        let count = WeeklyDigestEngine.daysInMonth(y, m)
        return (1...count).map { WeeklyDigestEngine.formatYMD(y, m, $0) }
    }

    /// The first day key of the period before the one starting at `start`.
    public static func previousWeekStart(_ start: String) -> String { WeeklyDigestEngine.addDays(start, -7) }

    public static func previousMonthAnyDay(_ start: String) -> String { WeeklyDigestEngine.addDays(start, -1) }

    /// Calendar weekday (1 = Sunday … 7 = Saturday) of a day key, or nil.
    public static func weekday(_ day: String) -> Int? {
        guard let (y, m, d) = WeeklyDigestEngine.parseYMD(day),
              let w = WeeklyDigestEngine.weekday(y, m, d) else { return nil }
        return w + 1
    }
}

// MARK: - Recommendations

/// Three target levels for a new period goal, read from the wearer's own recent periods.
///
/// The research behind the shape: realistic goals are reached far more often than hard ones, so the
/// pre-selected level sits a little above the wearer's usual rather than at their best. Each level says
/// how many of the recent periods would have met it, which explains the choice without a lecture.
public struct PeriodRecommendation: Equatable, Sendable {
    public struct Level: Equatable, Sendable {
        public let value: Double
        /// Recent periods that reached `value`, out of `periods`.
        public let hits: Int
        public let periods: Int
    }
    public let easy: Level
    public let recommended: Level
    public let ambitious: Level
    /// The wearer's usual per period (the median).
    public let usual: Double
}

public enum PeriodGoalRecommender {

    /// Periods needed before a recommendation is offered.
    public static let minimumPeriods = 2

    /// `history`: totals (or means, for an average goal) of recent finished periods, any order.
    /// `step`: the smallest sensible change (1 workout, 5 km, 0.25 h). `minimum`: the lowest target
    /// worth offering.
    public static func levels(history: [Double], aggregation: PeriodAggregation, step: Double,
                              minimum: Double, maximum: Double? = nil) -> PeriodRecommendation? {
        guard history.count >= minimumPeriods, step > 0 else { return nil }
        let sorted = history.sorted()
        let median = PeriodGoalPace.quantile(sorted, 0.5)
        let upper = PeriodGoalPace.quantile(sorted, 0.75)
        func clamp(_ v: Double) -> Double {
            let low = max(minimum, v)
            return maximum.map { min($0, low) } ?? low
        }
        func round(_ v: Double, up: Bool = false) -> Double {
            let units = v / step
            return (up ? units.rounded(.up) : units.rounded()) * step
        }
        let easy = clamp(round(median))
        let grown = aggregation == .average ? median + step : median * 1.1
        let recommended = clamp(max(round(grown, up: true), easy + step))
        let ambitious = clamp(max(round(upper), recommended + step))
        func level(_ v: Double) -> PeriodRecommendation.Level {
            .init(value: v, hits: history.filter { $0 >= v - 1e-9 }.count, periods: history.count)
        }
        return PeriodRecommendation(easy: level(easy), recommended: level(recommended),
                                    ambitious: level(ambitious), usual: median)
    }
}

// MARK: - Step plan under a long-term rate goal

/// The weekly target a long-term "get to N per week by a date" goal suggests for a given week.
///
/// The plan is computed once from the start and goal rates: equal steps of `step`, each held for at
/// least `minWeeksPerStep` weeks, reaching the goal by the last week when the runway allows and more
/// slowly when it does not. The app only ever SUGGESTS the result; the wearer confirms each step.
public enum PeriodRampPlan {
    public static func target(start: Double, goal: Double, totalWeeks: Int, weekIndex: Int,
                              step: Double, minWeeksPerStep: Int = 3) -> Double {
        guard step > 0, totalWeeks > 0, goal != start else { return goal }
        let direction: Double = goal > start ? 1 : -1
        let steps = Int((abs(goal - start) / step).rounded(.up))
        guard steps > 0 else { return goal }
        let weeksPerStep = max(minWeeksPerStep, totalWeeks / steps)
        let taken = min(steps, max(0, weekIndex) / weeksPerStep)
        let value = start + direction * step * Double(taken)
        return direction > 0 ? min(goal, value) : max(goal, value)
    }
}
