import Foundation
import WhoopStore
import StrandAnalytics

/// Everything period goals read, loaded once per tracking refresh. A value type so the arithmetic can
/// run off the main actor and the setup flow can ask for recommendations without another database trip.
struct PeriodGoalInputs {
    var workouts: [WorkoutRow] = []
    var days: [DailyMetric] = []
    var activeKcalByDay: [String: Double] = [:]
    /// Working sets per day from the lifting log; nil when no lifting log is connected.
    var setsByDay: [String: Double]?
    var hydrationByDay: [String: Double] = [:]
    var hydrationEnabled = false
    var profileSex = ""
    var journal: [JournalEntry] = []
    /// When the strap last finished a sync, if a strap is set up. A period is frozen and notified only
    /// once data newer than its end has arrived.
    var lastSync: Date?
    var hasStrap = false
}

/// A weekly or monthly goal as of now: the running period, its history, what counted and what to do.
struct PeriodGoalSnapshot: Identifiable, Equatable {

    struct Contribution: Identifiable, Equatable {
        /// The workout key, or the day key for a day-based goal.
        let id: String
        let day: String
        let title: String
        let value: Double
        let source: String?
        /// Set when the wearer corrected the automatic decision.
        let isManual: Bool
        /// Why it did not count, for the "not counted" list.
        let reason: String?
        let startTs: Int?
    }

    struct HistoryEntry: Identifiable, Equatable {
        var id: String { periodStart }
        let periodStart: String
        let target: Double
        let value: Double
        let outcome: PeriodOutcome
        var fraction: Double { target > 0 ? value / target : 0 }
    }

    let id: UUID
    let goal: PeriodGoal
    let periodStart: String
    let periodDays: [String]
    let todayIndex: Int
    let result: PeriodPaceResult
    /// One value per period day (count, amount, 1/0, or a reading; nil = no data).
    let dayValues: [Double?]
    let restDays: Set<String>
    /// Earlier periods, oldest → newest, at most twelve.
    let history: [HistoryEntry]
    let currentStreak: Int
    let bestStreak: Int
    let counted: [Contribution]
    let notCounted: [Contribution]
    /// Days the pace suggests for what is still missing.
    let suggestedDays: [String]
    /// A step-up the parent's plan suggests for this week, not answered yet (Q19).
    let rampSuggestion: Double?
    let isProtected: Bool

    var state: PeriodGoalState { result.state }
    var daysLeft: Int { max(0, periodDays.count - max(0, todayIndex)) }
}

enum PeriodGoalTracker {

    /// Periods of history computed per goal.
    static let historyCount = 12

    // MARK: - Snapshots

    static func snapshots(goals: [PeriodGoal], inputs: PeriodGoalInputs, parents: [CoachGoal],
                          frozen: [PeriodGoalResult], corrections: [GoalCountingCorrections.Correction],
                          now: Date, calendar: Calendar) -> [PeriodGoalSnapshot] {
        let today = dayKey(now, calendar: calendar)
        let index = DataIndex(inputs: inputs, calendar: calendar)
        let frozenByGoal = Dictionary(grouping: frozen, by: \.goalId)
        return goals.map { goal in
            snapshot(goal: goal, today: today, now: now, index: index, inputs: inputs,
                     parent: goal.parentGoalId.flatMap { id in parents.first { $0.id == id } },
                     frozen: frozenByGoal[goal.id] ?? [],
                     corrections: corrections.filter { $0.goalId == goal.id }, calendar: calendar)
        }
    }

    static func periodDays(_ period: PeriodGoal.Period, containing day: String, calendar: Calendar) -> [String] {
        switch period {
        case .week:  return PeriodCalendar.weekDays(containing: day, firstWeekday: calendar.firstWeekday)
        case .month: return PeriodCalendar.monthDays(containing: day)
        }
    }

    private static func snapshot(goal: PeriodGoal, today: String, now: Date, index: DataIndex,
                                 inputs: PeriodGoalInputs, parent: CoachGoal?, frozen: [PeriodGoalResult],
                                 corrections: [GoalCountingCorrections.Correction],
                                 calendar: Calendar) -> PeriodGoalSnapshot {
        // A one-off goal lives in its own period; a recurring one in the period containing today.
        let currentDays = periodDays(goal.period, containing: goal.oneOffPeriodStart ?? today, calendar: calendar)
        let start = currentDays.first ?? today
        let todayIndex = currentDays.firstIndex(of: today) ?? (today > (currentDays.last ?? today)
                                                               ? currentDays.count : -1)
        let overrides = Dictionary(corrections.map { ($0.workoutKey, $0.counts) }, uniquingKeysWith: { _, b in b })

        let (values, counted, notCounted) = dailyValues(goal: goal, days: currentDays, today: today,
                                                        index: index, inputs: inputs, overrides: overrides)
        let rest = Set(currentDays.filter { day in
            PeriodCalendar.weekday(day).map(goal.effectiveRestWeekdays.contains) ?? false
        })
        let createdDay = dayKey(goal.createdAt, calendar: calendar)
        let activeFrom = currentDays.firstIndex(where: { $0 >= createdDay }) ?? 0
        let protected = goal.status == .paused || isProtected(goal, days: currentDays, calendar: calendar)

        let capacity = typicalUpper(goal: goal, today: today, index: index, inputs: inputs,
                                    overrides: overrides, calendar: calendar)
        let input = PeriodPaceInput(
            aggregation: goal.metric.aggregation,
            target: goal.target(forPeriodStarting: start),
            days: zip(currentDays, values).map { PeriodDay(key: $0, value: $1, isRest: rest.contains($0)) },
            todayIndex: todayIndex, activeFromIndex: createdDay > start ? activeFrom : 0,
            todayElapsed: elapsedShareOfDay(now, calendar: calendar),
            typicalDailyUpper: capacity, maxPerDay: goal.metric.maxPerDay, isProtected: protected)
        let result = PeriodGoalPace.evaluate(input)

        // History: the periods before this one, from the goal's first period on.
        var history: [PeriodGoalSnapshot.HistoryEntry] = []
        if goal.oneOffPeriodStart == nil {
            let frozenByStart = Dictionary(frozen.map { ($0.periodStart, $0) }, uniquingKeysWith: { a, _ in a })
            var cursorDay = previousPeriodAnyDay(goal.period, start: start)
            for _ in 0..<historyCount {
                let days = periodDays(goal.period, containing: cursorDay, calendar: calendar)
                guard let first = days.first, let last = days.last, last >= createdDay else { break }
                if let stored = frozenByStart[first] {
                    history.append(.init(periodStart: first, target: stored.target, value: stored.value,
                                         outcome: stored.outcome))
                } else {
                    let (pastValues, _, _) = dailyValues(goal: goal, days: days, today: today, index: index,
                                                         inputs: inputs, overrides: overrides)
                    let pastRest = Set(days.filter { PeriodCalendar.weekday($0).map(goal.effectiveRestWeekdays.contains) ?? false })
                    let pastInput = PeriodPaceInput(
                        aggregation: goal.metric.aggregation, target: goal.target(forPeriodStarting: first),
                        days: zip(days, pastValues).map { PeriodDay(key: $0, value: $1, isRest: pastRest.contains($0)) },
                        todayIndex: days.count,
                        activeFromIndex: createdDay > first ? (days.firstIndex(where: { $0 >= createdDay }) ?? 0) : 0,
                        isProtected: isProtected(goal, days: days, calendar: calendar))
                    let evaluated = PeriodGoalPace.evaluate(pastInput)
                    history.append(.init(periodStart: first, target: evaluated.target, value: evaluated.current,
                                         outcome: PeriodGoalPace.outcome(pastInput)))
                }
                cursorDay = previousPeriodAnyDay(goal.period, start: first)
            }
            history.reverse()
        }
        var outcomes = history.map(\.outcome)
        if result.state == .achieved { outcomes.append(.achieved) }
        let streak = PeriodGoalPace.streak(outcomes)

        return PeriodGoalSnapshot(
            id: goal.id, goal: goal, periodStart: start, periodDays: currentDays, todayIndex: todayIndex,
            result: result, dayValues: values, restDays: rest, history: history,
            currentStreak: streak.current, bestStreak: streak.best,
            counted: counted, notCounted: notCounted,
            suggestedDays: suggestedDays(goal: goal, result: result, days: currentDays, values: values,
                                         todayIndex: todayIndex, rest: rest),
            rampSuggestion: rampSuggestion(goal: goal, parent: parent, periodStart: start, now: now),
            isProtected: protected)
    }

    // MARK: - Day values

    /// Indexes the inputs by day once per refresh.
    struct DataIndex {
        let workoutsByDay: [String: [WorkoutRow]]
        let dailyByDay: [String: DailyMetric]
        let journalByDay: [String: [JournalEntry]]

        init(inputs: PeriodGoalInputs, calendar: Calendar) {
            workoutsByDay = Dictionary(grouping: inputs.workouts) {
                PeriodGoalTracker.dayKey(Date(timeIntervalSince1970: Double($0.startTs)), calendar: calendar)
            }
            dailyByDay = Dictionary(inputs.days.map { ($0.day, $0) }, uniquingKeysWith: { _, latest in latest })
            journalByDay = Dictionary(grouping: inputs.journal, by: \.day)
        }
    }

    static func dailyValues(goal: PeriodGoal, days: [String], today: String, index: DataIndex,
                            inputs: PeriodGoalInputs, overrides: [String: Bool])
        -> ([Double?], [PeriodGoalSnapshot.Contribution], [PeriodGoalSnapshot.Contribution]) {
        var counted: [PeriodGoalSnapshot.Contribution] = []
        var notCounted: [PeriodGoalSnapshot.Contribution] = []
        let values: [Double?] = days.map { day in
            let isFuture = day > today
            switch goal.metric {
            case .workouts, .trainingMinutes, .distance, .zoneMinutes:
                guard !isFuture else { return 0 }
                var total = 0.0
                for row in index.workoutsByDay[day] ?? [] {
                    let key = PlanWorkoutReference(row).workoutKey
                    let amount = workoutAmount(goal.metric, row)
                    let matches = workoutMatches(goal, row)
                    let override = overrides[key]
                    let counts = override ?? matches
                    let item = PeriodGoalSnapshot.Contribution(
                        id: key, day: day, title: row.sport, value: amount ?? 0, source: row.source,
                        isManual: override != nil,
                        reason: counts ? nil : notCountedReason(goal, row, matches: matches, amount: amount),
                        startTs: row.startTs)
                    if counts, goal.metric == .workouts || (amount ?? 0) > 0 {
                        total += goal.metric == .workouts ? 1 : (amount ?? 0)
                        counted.append(item)
                    } else {
                        notCounted.append(item)
                    }
                }
                return total
            case .stepDays:
                guard !isFuture else { return 0 }
                guard let steps = index.dailyByDay[day]?.steps else { return nil }
                let hit = Double(steps) >= (goal.threshold ?? 8_000)
                if hit { counted.append(dayItem(day, Double(steps))) }
                return hit ? 1 : 0
            case .sleepNights:
                guard !isFuture else { return 0 }
                guard let minutes = index.dailyByDay[day]?.totalSleepMin else { return nil }
                let hit = minutes >= (goal.threshold ?? 7) * 60
                if hit { counted.append(dayItem(day, minutes / 60)) }
                return hit ? 1 : 0
            case .sleepAverage:
                guard !isFuture, let minutes = index.dailyByDay[day]?.totalSleepMin else { return nil }
                counted.append(dayItem(day, minutes / 60))
                return minutes / 60
            case .workingSets:
                guard !isFuture else { return 0 }
                guard let byDay = inputs.setsByDay else { return nil }
                let sets = byDay[day] ?? 0
                if sets > 0 { counted.append(dayItem(day, sets)) }
                return sets
            case .activeEnergy:
                guard !isFuture else { return 0 }
                guard let kcal = inputs.activeKcalByDay[day] else { return nil }
                if kcal > 0 { counted.append(dayItem(day, kcal)) }
                return kcal
            case .restDays:
                guard !isFuture, day < today || index.dailyByDay[day] != nil else { return 0 }
                let rest = (index.workoutsByDay[day] ?? []).isEmpty
                if rest { counted.append(dayItem(day, 1)) }
                return rest ? 1 : 0
            case .hydrationDays:
                guard !isFuture else { return 0 }
                let ml = inputs.hydrationByDay[day] ?? 0
                let goalML = Double(HydrationGoal.dailyGoalML(sex: inputs.profileSex,
                                                              effort: index.dailyByDay[day]?.strain))
                let hit = goalML > 0 && ml >= goalML
                if hit { counted.append(dayItem(day, ml)) }
                return hit ? 1 : 0
            case .habitDays:
                guard !isFuture else { return 0 }
                guard let key = goal.habitKey,
                      let entry = (index.journalByDay[day] ?? []).first(where: { $0.question == key })
                else { return nil }
                let hit = entry.answeredYes == goal.habitWantsYes
                if hit { counted.append(dayItem(day, 1)) }
                return hit ? 1 : 0
            }
        }
        return (values, counted, notCounted)
    }

    private static func dayItem(_ day: String, _ value: Double) -> PeriodGoalSnapshot.Contribution {
        .init(id: day, day: day, title: day, value: value, source: nil, isManual: false, reason: nil, startTs: nil)
    }

    static func workoutAmount(_ metric: PeriodMetric, _ row: WorkoutRow) -> Double? {
        switch metric {
        case .workouts:
            return 1
        case .trainingMinutes:
            let seconds = row.durationS ?? Double(max(0, row.endTs - row.startTs))
            return seconds / 60
        case .distance:
            return row.distanceM.map { $0 / 1000 }
        case .zoneMinutes:
            guard let percents = WorkoutZones.percents(row.zonesJSON) else { return nil }
            let minutes = (row.durationS ?? Double(max(0, row.endTs - row.startTs))) / 60
            return minutes * percents.dropFirst().reduce(0, +) / 100
        default:
            return nil
        }
    }

    static func workoutMatches(_ goal: PeriodGoal, _ row: WorkoutRow) -> Bool {
        guard GoalActionEvaluator.matches(row.sport, any: goal.sportFilter) else { return false }
        switch goal.metric {
        case .distance:    return (row.distanceM ?? 0) > 0
        case .zoneMinutes: return WorkoutZones.percents(row.zonesJSON) != nil
        default:           return true
        }
    }

    private static func notCountedReason(_ goal: PeriodGoal, _ row: WorkoutRow, matches: Bool,
                                         amount: Double?) -> String {
        if !GoalActionEvaluator.matches(row.sport, any: goal.sportFilter) {
            return String(localized: "\(row.sport) is not one of the sports this goal counts")
        }
        if matches { return String(localized: "You excluded it") }
        switch goal.metric {
        case .distance:    return String(localized: "No distance recorded")
        case .zoneMinutes: return String(localized: "No heart-rate zones recorded")
        default:           return String(localized: "Not counted")
        }
    }

    // MARK: - Capacity, protection, suggestions

    /// The wearer's typical active day for this goal over the last eight weeks (upper quartile).
    private static func typicalUpper(goal: PeriodGoal, today: String, index: DataIndex, inputs: PeriodGoalInputs,
                                     overrides: [String: Bool], calendar: Calendar) -> Double? {
        let days = (1...56).map { WeeklyDigestEngine.addDays(today, -$0) }.reversed()
        let (values, _, _) = dailyValues(goal: goal, days: Array(days), today: today, index: index,
                                         inputs: inputs, overrides: overrides)
        return PeriodGoalPace.typicalDailyUpper(values.compactMap { $0 })
    }

    static func isProtected(_ goal: PeriodGoal, days: [String], calendar: Calendar) -> Bool {
        guard let first = days.first, let last = days.last,
              let start = date(first, calendar: calendar),
              let endDay = date(last, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDay)) else { return false }
        let interval = DateInterval(start: calendar.startOfDay(for: start), end: end)
        return goal.pauseIntervals.contains { $0.intersects(interval) }
    }

    /// Evenly spaced planned days for what is still missing, ending on the period's last planned day.
    static func suggestedDays(goal: PeriodGoal, result: PeriodPaceResult, days: [String], values: [Double?],
                              todayIndex: Int, rest: Set<String>) -> [String] {
        guard result.remaining > 0, todayIndex >= 0, todayIndex < days.count,
              goal.metric.aggregation == .count || goal.metric.aggregation == .hitDays else { return [] }
        let todayDone = (values[todayIndex] ?? 0) > 0
        let candidates = days.indices
            .filter { $0 > todayIndex || ($0 == todayIndex && !todayDone) }
            .map { days[$0] }
            .filter { !rest.contains($0) }
        let wanted = min(candidates.count, Int(result.remaining.rounded(.up)))
        guard wanted > 0 else { return [] }
        let picks = (1...wanted).map { Int((Double($0) * Double(candidates.count) / Double(wanted)).rounded()) - 1 }
        return Array(Set(picks.map { candidates[max(0, min(candidates.count - 1, $0))] })).sorted()
    }

    /// The suggested weekly step under a long-term rate goal, when it is above the current target and
    /// not answered for this week.
    static func rampSuggestion(goal: PeriodGoal, parent: CoachGoal?, periodStart: String, now: Date) -> Double? {
        guard goal.period == .week, goal.status == .active, let parent,
              parent.status == .active,
              let baseline = parent.baseline, let target = parent.target, let targetDate = parent.targetDate,
              rampMetric(for: parent.kind) == goal.metric,
              !goal.rampAnsweredPeriods.contains(periodStart) else { return nil }
        let week = 7.0 * 86_400
        let totalWeeks = max(1, Int((targetDate.timeIntervalSince(parent.createdAt) / week).rounded()))
        let weekIndex = max(0, Int(now.timeIntervalSince(parent.createdAt) / week))
        let suggested = PeriodRampPlan.target(start: baseline, goal: target, totalWeeks: totalWeeks,
                                              weekIndex: weekIndex, step: goal.metric.step(for: .week))
        let ascending = target > baseline
        return (ascending ? suggested > goal.target : suggested < goal.target) ? suggested : nil
    }

    /// The period metric a long-term rate goal steps up, if it has one.
    static func rampMetric(for kind: CoachGoal.Kind) -> PeriodMetric? {
        switch kind {
        case .consistency: return .workouts
        case .hardSets:    return .workingSets
        case .strength:    return .trainingMinutes
        default:           return nil
        }
    }

    // MARK: - Recommendations and availability

    /// Three levels for a new goal from the wearer's recent finished periods (Q14 and the setup flow).
    static func recommendation(for draft: PeriodGoal, inputs: PeriodGoalInputs, now: Date,
                               calendar: Calendar) -> PeriodRecommendation? {
        let today = dayKey(now, calendar: calendar)
        let index = DataIndex(inputs: inputs, calendar: calendar)
        let count = draft.period == .week ? 8 : 6
        var totals: [Double] = []
        var cursor = previousPeriodAnyDay(draft.period, start: periodDays(draft.period, containing: today,
                                                                          calendar: calendar).first ?? today)
        for _ in 0..<count {
            let days = periodDays(draft.period, containing: cursor, calendar: calendar)
            guard let first = days.first else { break }
            let (values, _, _) = dailyValues(goal: draft, days: days, today: today, index: index, inputs: inputs,
                                             overrides: [:])
            let known = values.compactMap { $0 }
            // A period with no readable day at all is not evidence about the wearer's usual.
            if known.isEmpty || (draft.metric.aggregation != .count && draft.metric.aggregation != .sum
                                 && known.count * 2 < days.count) {
                cursor = previousPeriodAnyDay(draft.period, start: first)
                continue
            }
            switch draft.metric.aggregation {
            case .average: totals.append(known.reduce(0, +) / Double(known.count))
            default:       totals.append(known.reduce(0, +))
            }
            cursor = previousPeriodAnyDay(draft.period, start: first)
        }
        let range = draft.metric.range(for: draft.period)
        return PeriodGoalRecommender.levels(history: totals, aggregation: draft.metric.aggregation,
                                            step: draft.metric.step(for: draft.period),
                                            minimum: range.lowerBound, maximum: range.upperBound)
    }

    enum Availability: Equatable {
        case available
        /// Not offered yet, with the reason to show (catalog key).
        case unavailable(String)
    }

    static func availability(_ metric: PeriodMetric, inputs: PeriodGoalInputs, now: Date,
                             calendar: Calendar) -> Availability {
        let cutoff = dayKey(now.addingTimeInterval(-60 * 86_400), calendar: calendar)
        let recentDays = inputs.days.filter { $0.day >= cutoff }
        let recentWorkouts = inputs.workouts.filter {
            dayKey(Date(timeIntervalSince1970: Double($0.startTs)), calendar: calendar) >= cutoff
        }
        switch metric {
        case .workouts, .trainingMinutes, .restDays:
            return .available
        case .distance:
            return recentWorkouts.contains { ($0.distanceM ?? 0) > 0 }
                ? .available : .unavailable("Needs workouts with a recorded distance")
        case .zoneMinutes:
            return recentWorkouts.contains { WorkoutZones.percents($0.zonesJSON) != nil }
                ? .available : .unavailable("Needs workouts with heart-rate zones")
        case .stepDays:
            return recentDays.contains { $0.steps != nil } ? .available : .unavailable("Needs step data")
        case .sleepNights, .sleepAverage:
            return recentDays.contains { $0.totalSleepMin != nil } ? .available : .unavailable("Needs sleep data")
        case .workingSets:
            return inputs.setsByDay != nil ? .available : .unavailable("Connect a lifting log first")
        case .activeEnergy:
            return inputs.activeKcalByDay.isEmpty ? .unavailable("Needs energy data") : .available
        case .hydrationDays:
            return inputs.hydrationEnabled ? .available : .unavailable("Turn on hydration tracking first")
        case .habitDays:
            return .available
        }
    }

    // MARK: - Helpers

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        GoalActionEvaluator.dayKey(date, calendar: calendar)
    }

    static func date(_ day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    static func previousPeriodAnyDay(_ period: PeriodGoal.Period, start: String) -> String {
        period == .week ? PeriodCalendar.previousWeekStart(start) : PeriodCalendar.previousMonthAnyDay(start)
    }

    /// Share of the waking day gone by (06:00 to 22:00), for the pace's half-counted today.
    static func elapsedShareOfDay(_ now: Date, calendar: Calendar) -> Double {
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let hours = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
        return min(1, max(0, (hours - 6) / 16))
    }
}
