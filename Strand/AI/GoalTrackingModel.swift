import Foundation
#if canImport(Combine)
import Combine
#endif
import WhoopStore
import StrandAnalytics
import StrandCore

/// One synchronous refresh over resolved on-device data. Hosts load the inputs and deliver their own
/// notifications; goal progress, attribution, history settlement and milestone decisions stay shared.
@MainActor
class GoalTrackingModel: ObservableObject {
    struct Source {
        var workouts: [WorkoutRow]
        var allWorkouts: [WorkoutRow]
        var weights: [(day: String, value: Double)]
        var stress: [(day: String, value: Double)]
        var days: [DailyMetric]
        var hardSetsPerWeek: Double?
        var activeKcalByDay: [String: Double]
        var stepsByDay: [String: Int]
        var journalByDay: [String: [JournalEntry]]
        var periodInputs: PeriodGoalInputs
        var levelSeries: [LongTermMetric: [GoalMilestones.Sample]]
        var calendar: Calendar
    }

    @Published private(set) var snapshots: [GoalTrackingSnapshot] = []
    @Published private(set) var todayActions: [GoalActionOccurrence] = []
    /// The current week's action occurrences. Same computation as `todayActions`, wider filter — the
    /// occurrences were already being calculated for a whole year and then discarded, and the Today
    /// tile needs the week to draw a day row.
    @Published private(set) var weekActions: [GoalActionOccurrence] = []
    /// The daily-goal occurrences of the days before today that the next-day question may still ask
    /// about (`GoalMissedQuestions`). Which are open is decided where they are shown, against the
    /// answers given so far.
    @Published private(set) var recentActions: [GoalActionOccurrence] = []
    @Published private(set) var pendingWorkoutAttributions: [GoalWorkoutAttributionSuggestion] = []
    @Published private(set) var lastUpdated: Date?
    /// Weekly and monthly goals as of the last refresh, in the wearer's order.
    @Published private(set) var periodSnapshots: [PeriodGoalSnapshot] = []
    /// Streaks, badges and records (plan §17e); nil while motivation is switched off.
    @Published private(set) var motivation: GoalMotivationSnapshot?
    /// What the period goals were computed from, kept for recommendations in the setup flow.
    private(set) var periodInputs = PeriodGoalInputs()

    func periodSnapshot(for goalId: UUID) -> PeriodGoalSnapshot? {
        periodSnapshots.first { $0.id == goalId }
    }

    func snapshot(for goalId: UUID) -> GoalTrackingSnapshot? {
        snapshots.first { $0.id == goalId }
    }

    func refresh(source: Source, now: Date, goals: [CoachGoal], proposals: [PlanProposal],
                 unresolved: Set<UUID>, actions: [GoalAction], checkoffs: [GoalActionCheckoff],
                 contributions: [GoalWorkoutContribution], dismissedWorkoutKeys: Set<String>) {
        let workouts = source.workouts
        let weights = source.weights
        let stress = source.stress
        let weightsInWindow = GoalMeasurements.weightsWithin(GoalMeasure.weightWindowDays, weights: weights, now: now)
        // Working sets for a `.hardSets` goal. Read here rather than derived from `workouts` above: a
        // mirrored strength row carries a duration, not a set count — the sets only exist in the
        // strength lane's own tables.
        let measurementByKind = GoalMeasurements.values(workouts: workouts, weights: weightsInWindow, stress: stress,
                                             days: source.days, hardSetsPerWeek: source.hardSetsPerWeek, now: now)
        let calendar = source.calendar
        let start = calendar.date(byAdding: .day, value: -365, to: now) ?? now
        let end = calendar.dateInterval(of: .weekOfYear, for: now)?.end ?? now
        let activeGoalIds = Set(goals.filter { $0.status == .active }.map(\.id))
        let activeKcalByDay = source.activeKcalByDay
        let stepsByDay = source.stepsByDay
        let journalByDay = source.journalByDay
        let actionOccurrences = GoalActionEvaluator.occurrences(
            actions: actions, checkoffs: checkoffs, activeGoalIds: activeGoalIds,
            days: source.days, workouts: workouts, from: start, through: end,
            activeKcalByDay: activeKcalByDay, stepsByDay: stepsByDay, journalByDay: journalByDay,
            calendar: calendar)
        let today = GoalActionEvaluator.dayKey(now, calendar: calendar)
        todayActions = actionOccurrences.filter { $0.day == today }
        recentActions = GoalMissedQuestions.open(actionOccurrences, answered: [], today: today,
                                                 journalByDay: journalByDay, calendar: calendar)
        if let week = calendar.dateInterval(of: .weekOfYear, for: now) {
            let from = GoalActionEvaluator.dayKey(week.start, calendar: calendar)
            let to = GoalActionEvaluator.dayKey(week.end.addingTimeInterval(-1), calendar: calendar)
            weekActions = actionOccurrences.filter { $0.day >= from && $0.day <= to }
        } else {
            weekActions = todayActions
        }
        // Weekly and monthly goals. Loaded and computed here so every surface reads one result.
        let periodGoals = PeriodGoalStore.shared.goals
        let inputs = source.periodInputs
        periodInputs = inputs
        let computed = PeriodGoalTracker.snapshots(
            goals: periodGoals.filter { $0.isOpen }, inputs: inputs, parents: goals,
            frozen: PeriodGoalStore.shared.results, corrections: GoalCountingCorrections.shared.corrections,
            now: now, calendar: calendar)
        periodSnapshots = computed
        if GoalPrefs.motivationEnabled {
            // Badges count every recorded workout, not just the last year the goals need.
            motivation = GoalMotivationBuilder.build(
                actions: actions, stepsByDay: stepsByDay, days: source.days, activeKcalByDay: activeKcalByDay,
                workouts: source.allWorkouts, periodSnapshots: computed, frozen: PeriodGoalStore.shared.results,
                periodGoals: periodGoals, now: now, calendar: calendar)
        } else {
            motivation = nil
        }
        settlePeriods(computed, inputs: inputs, now: now, calendar: calendar)
        // A workout an open weekly or monthly goal already counts on its own needs no "which goal did this
        // support?" question (Q20): the question is kept for workouts nothing claims.
        let periodClaimed: Set<String> = Set(computed.flatMap { snapshot in
            snapshot.goal.metric.isWorkoutBased && snapshot.goal.status == .active
                ? snapshot.counted.map(\.id) : []
        })
        let consumedWorkoutKeys = Set(proposals.compactMap { $0.completionEvidence?.workoutKey })
            .union(contributions.map(\.id)).union(dismissedWorkoutKeys).union(periodClaimed)
        let workoutRowsByKey = Dictionary(workouts.map { (PlanWorkoutReference($0).workoutKey, $0) },
                                          uniquingKeysWith: { first, _ in first })
        let attributionCutoff = now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        pendingWorkoutAttributions = workouts
            .filter { Double($0.startTs) >= attributionCutoff && Double($0.startTs) <= now.timeIntervalSince1970 }
            .map(PlanWorkoutReference.init)
            .filter { !consumedWorkoutKeys.contains($0.workoutKey) }
            .filter { workout in
                guard let row = workoutRowsByKey[workout.workoutKey] else { return true }
                let workoutDate = Date(timeIntervalSince1970: Double(row.startTs))
                return !actions.contains { action in
                    guard action.isActive,
                          case .workout = action.requirement else { return false }
                    return GoalActionEvaluator.isDue(action, on: workoutDate,
                                                     activeGoalIds: activeGoalIds, calendar: calendar)
                        && GoalActionEvaluator.automaticCompletion(action.requirement,
                                                                   metric: nil, workouts: [row])
                }
            }
            .compactMap { workout in
                let suggested = GoalAttributionSuggester.suggestedGoalIds(for: workout.sport,
                                                                          goals: goals)
                return suggested.isEmpty ? nil : .init(workout: workout, suggestedGoalIds: suggested)
            }
            .sorted { $0.workout.startTs > $1.workout.startTs }
        // The route is suggested ONCE per goal and then belongs to the user (see `ensureMilestones`),
        // and any waypoint the measured value has passed is stamped with the date it was first reached.
        CoachGoalStore.shared.ensureMilestones(now: now)
        for goal in CoachGoalStore.shared.goals {
            // A provisional value must not stamp a waypoint. `achievedAt` is written once and never
            // cleared, so this is the one place where a still-cold-starting trend would leave a
            // PERMANENT record — the same reading `evaluate` refuses to draw a verdict from.
            guard let measurement = measurementByKind[goal.kind], !measurement.isProvisional else { continue }
            CoachGoalStore.shared.markMilestonesReached(goalId: goal.id, current: measurement.value, on: now)
        }

        // Only the weight goal has a dated measurement series to fit a rate against; the others get a
        // planned-vs-actual reading without an arrival date, which `course` reports honestly as
        // "not enough data" rather than inventing a slope.
        //
        // SMOOTHED, not raw. `GoalMilestones.Sample` asks for the smoothed series in as many words —
        // "so a day of water weight cannot tilt the fitted rate" — and this used to hand it the raw
        // scale readings, so the least-squares slope was fitted straight through 28 days of daily
        // water swing. `isPlausible` filters the pairs with the SAME rule the fold uses, because
        // `smoothedSeries` returns one centre per kept value: zipping it against unfiltered dates
        // would shift every sample onto the wrong day.
        let datedWeights = weightsInWindow.compactMap { row -> (date: Date, value: Double)? in
            guard GoalMeasure.isPlausible(row.value, cfg: GoalMeasure.weightTrend),
                  let date = GoalMeasurements.parseDay(row.day) else { return nil }
            return (date, row.value)
        }
        let weightSamples = zip(datedWeights,
                                GoalMeasure.smoothedSeries(dated: datedWeights, cfg: GoalMeasure.weightTrend))
            .map { GoalMilestones.Sample(date: $0.date, value: $1) }
        // The scale's own readings for the whole loaded year, unsmoothed: a weight goal's milestones and
        // its headline count what was actually weighed, not the trend (which only judges the course).
        let weightReadings = weights.compactMap { row -> GoalMilestones.Sample? in
            guard GoalMeasure.isPlausible(row.value, cfg: GoalMeasure.weightTrend),
                  let date = GoalMeasurements.parseDay(row.day) else { return nil }
            return GoalMilestones.Sample(date: date, value: row.value)
        }.sorted { $0.date < $1.date }
        let levelSeries = source.levelSeries
        // Always called, so the one-time listing happens on the first refresh after the update even with no VO₂max
        // goal yet; a goal set later is then never listed.
        CoachGoalStore.shared.rebaselineVO2maxGoals(readings: levelSeries[.vo2max] ?? [], now: now)
        let readerInputs = LongTermReaderInputs(workouts: workouts, days: source.days, stepsByDay: stepsByDay,
                                                weight: measurementByKind[.weight], weightSamples: weightSamples,
                                                weightReadings: weightReadings, series: levelSeries)
        snapshots = CoachGoalStore.shared.goals.map { goal in
            let snapshot = GoalTrackingEngine.evaluate(goal: goal, proposals: proposals,
                                        actionOccurrences: actionOccurrences,
                                        measurement: measurementByKind[goal.kind],
                                        hasReconciliationQuestion: proposals.contains {
                                            $0.serves(goal.id) && unresolved.contains($0.id)
                                        },
                                        courseSeries: goal.kind == .weight ? weightSamples : [],
                                        now: now, calendar: calendar)
            guard goal.measure != nil else { return snapshot }
            return snapshot.applying(LongTermGoalReader.reading(goal: goal, course: snapshot.course,
                                                                inputs: readerInputs, periodSnapshots: computed,
                                                                now: now, calendar: calendar))
        }
        lastUpdated = now
    }

    /// Weekly goals that follow a catalog sum goal (plan Q9) get what the week needs, once at the start
    /// of each week and from its first day, never mid-week. The cap above the recent pace is already in
    /// the reading's suggestion.
    func applyFollowingWeeklyTargets(now: Date, calendar: Calendar) {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let weekKey = PeriodGoalTracker.dayKey(weekStart, calendar: calendar)
        for snapshot in snapshots {
            guard case .sum(let data)? = snapshot.reading, let suggested = data.reading.suggestedWeeklyTarget
            else { continue }
            for child in PeriodGoalStore.shared.goals where child.parentGoalId == snapshot.id && child.followsParent
                && child.isOpen && child.period == .week {
                let lastChange = child.targetHistory.map(\.fromDay).max() ?? ""
                guard lastChange < weekKey else { continue }
                let step = child.metric.step(for: .week)
                let target = max(step, (suggested / step).rounded(.up) * step)
                PeriodGoalStore.shared.setTarget(child.id, target, today: weekKey, followed: true)
            }
        }
    }

    /// Freezes finished periods once data newer than their end has arrived, and retires one-off goals
    /// whose period is over (Q16: they move to the archive by themselves).
    private func settlePeriods(_ snapshots: [PeriodGoalSnapshot], inputs: PeriodGoalInputs, now: Date,
                               calendar: Calendar) {
        var frozen: [PeriodGoalResult] = []
        for snapshot in snapshots {
            for entry in snapshot.history {
                let days = PeriodGoalTracker.periodDays(snapshot.goal.period, containing: entry.periodStart,
                                                        calendar: calendar)
                guard let last = days.last, let lastDate = PeriodGoalTracker.date(last, calendar: calendar),
                      let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDate))
                else { continue }
                // With a strap, wait for a sync that ended after the period did; otherwise a late
                // offload could still change the result.
                if inputs.hasStrap, let synced = inputs.lastSync, synced < end { continue }
                frozen.append(.init(goalId: snapshot.id, periodStart: entry.periodStart, target: entry.target,
                                    value: entry.value, outcome: entry.outcome, frozenAt: now))
            }
            if snapshot.goal.oneOffPeriodStart != nil, snapshot.todayIndex >= snapshot.periodDays.count {
                frozen.append(.init(goalId: snapshot.id, periodStart: snapshot.periodStart,
                                    target: snapshot.result.target, value: snapshot.result.current,
                                    outcome: PeriodGoalPace.outcome(.init(
                                        aggregation: snapshot.goal.metric.aggregation,
                                        target: snapshot.result.target,
                                        days: zip(snapshot.periodDays, snapshot.dayValues).map {
                                            PeriodDay(key: $0, value: $1)
                                        }, todayIndex: snapshot.periodDays.count)),
                                    frozenAt: now))
                PeriodGoalStore.shared.end(snapshot.id, on: now)
            }
        }
        PeriodGoalStore.shared.freeze(frozen)
    }

}
