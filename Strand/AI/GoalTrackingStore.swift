import Foundation
import Combine
import WhoopStore
import StrandAnalytics
import StrandCore

@MainActor
final class GoalTrackingStore: GoalTrackingModel {
    static let shared = GoalTrackingStore()

    func refresh(repo: Repository, now: Date = Date()) async {
        // One step goal in the app (Q8): Momentum's own value becomes a daily goal once, then follows it.
        GoalActionStore.shared.migrateMomentumStepGoalIfNeeded()
        GoalActionStore.shared.syncStepGoal()
        // Goals made before the catalog get their template once (plan Q5), before anything reads them.
        CoachGoalStore.shared.assignTemplatesToLegacyGoals(today: Repository.localDayKey(now), now: now)
        await refresh(repo: repo, now: now, goals: CoachGoalStore.shared.goals,
                      proposals: CoachPlanStore.shared.proposals,
                      resolutions: CoachPlanStore.shared.reconciliationResolutions,
                      actions: GoalActionStore.shared.actions,
                      checkoffs: GoalActionStore.shared.checkoffs,
                      contributions: GoalContributionStore.shared.contributions,
                      dismissedWorkoutKeys: GoalContributionStore.shared.dismissedWorkoutKeys)
    }

    func refresh(repo: Repository, now: Date,
                 goals: [CoachGoal], proposals: [PlanProposal],
                 resolutions: [PlanReconciliationResolution],
                 actions: [GoalAction] = [], checkoffs: [GoalActionCheckoff] = [],
                 contributions: [GoalWorkoutContribution] = [],
                 dismissedWorkoutKeys: Set<String> = []) async {
        // The adapter resolves each data lane; GoalTrackingModel owns all evaluation and mutations.
        let earliestCount = goals.compactMap { goal -> Date? in
            guard goal.measure?.shape == .sum else { return nil }
            return goal.measure?.countFrom ?? goal.createdAt
        }.min()
        let workoutDays = max(365, earliestCount.map { Int(now.timeIntervalSince($0) / 86_400) + 14 } ?? 0)
        let workouts = await repo.workoutRows(days: workoutDays, reconcileHrCap: 0)
        let weights = await repo.weightDailyValues(days: 365)
        let stress = await repo.series(key: "stress", source: "my-whoop", days: 365)
        let hardSets = await hardSetsPerWeek(repo: repo, now: now)
        let activeKcal = await repo.activeEnergyByDay(days: 400)
        let steps = GoalMotivationBuilder.stepsByDay(days: repo.days, apple: await repo.appleDailyRows(days: 4000))
        let journal: [JournalEntry]
        if actions.contains(where: { if case .journal = $0.requirement { return $0.isActive } else { return false } }) {
            journal = await repo.journalEntries(days: 400)
        } else { journal = [] }
        let periodInputs = await periodGoalInputs(repo: repo, workouts: workouts, activeKcalByDay: activeKcal,
                                                  goals: PeriodGoalStore.shared.goals, now: now)
        let allWorkouts = GoalPrefs.motivationEnabled ? await repo.workoutRows(days: 4000, reconcileHrCap: 0) : []
        let metrics = Set(CoachGoalStore.shared.goals.compactMap { $0.measure?.metric })
        let levels = await loadLevelSeries(repo: repo, metrics: metrics)
        let calendar = TrainingPreferences.weekCalendar
        let source = Source(workouts: workouts, allWorkouts: allWorkouts, weights: weights, stress: stress,
            days: repo.days, hardSetsPerWeek: hardSets, activeKcalByDay: activeKcal, stepsByDay: steps,
            journalByDay: Dictionary(grouping: journal, by: \.day), periodInputs: periodInputs,
            levelSeries: levels, calendar: calendar)
        refresh(source: source, now: now, goals: goals, proposals: proposals,
            unresolved: Set(resolutions.map(\.proposalId)), actions: actions, checkoffs: checkoffs,
            contributions: contributions, dismissedWorkoutKeys: dismissedWorkoutKeys)
        GoalNotifier.reschedule(periodSnapshots, now: now)
        GoalEvents.announce(periodSnapshots)
        GoalReminderLines.update(periodSnapshots: periodSnapshots, todaySteps: steps[Repository.localDayKey(now)])
        GoalEventNotifier.evaluate(todayActions: todayActions, motivation: motivation, now: now)
        #if os(iOS)
        GoalWidgetPublisher.publish(periodSnapshots, daily: todayActions, longTerm: snapshots, now: now)
        #endif
        CoachNotifier.syncGoalMonitoring(snapshots)
        applyFollowingWeeklyTargets(now: now, calendar: calendar)
        GoalEventNotifier.evaluateLongTerm(snapshots, now: now)
    }

    /// The inputs period goals need. Sources only some goals use (lifting log per day, hydration, the
    /// journal) are read only when such a goal exists or the setup flow asks (`loadFullPeriodInputs`).
    private func periodGoalInputs(repo: Repository, workouts: [WorkoutRow], activeKcalByDay: [String: Double],
                                  goals: [PeriodGoal], now: Date, full: Bool = false) async -> PeriodGoalInputs {
        let open = goals.filter(\.isOpen)
        var inputs = PeriodGoalInputs()
        inputs.workouts = workouts
        inputs.days = repo.days
        inputs.activeKcalByDay = activeKcalByDay
        inputs.stepsByDay = GoalMotivationBuilder.stepsByDay(days: repo.days, apple: await repo.appleDailyRows(days: 400))
        inputs.hydrationEnabled = UserDefaults.standard.bool(forKey: HydrationStore.enabledKey)
        inputs.profileSex = UserDefaults.standard.string(forKey: "profile.sex") ?? ""
        let syncedAt = UserDefaults.standard.double(forKey: "lastSyncedAt")
        inputs.lastSync = syncedAt > 0 ? Date(timeIntervalSince1970: syncedAt) : nil
        inputs.hasStrap = inputs.lastSync != nil
        if full || open.contains(where: { $0.metric == .workingSets }) {
            inputs.setsByDay = await workingSetsByDay(repo: repo, days: 400)
        } else if await hasLiftingLog(repo: repo, now: now) {
            // Connected but not needed yet: an empty map still marks the metric as available.
            inputs.setsByDay = [:]
        }
        if inputs.hydrationEnabled && (full || open.contains(where: { $0.metric == .hydrationDays })) {
            inputs.hydrationByDay = Dictionary(await repo.hydrationHistory(days: 400, now: now)
                .map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        if full || open.contains(where: { $0.metric == .habitDays }) {
            inputs.journal = await repo.journalEntries(days: 400)
        }
        // AgeLess's banked activity minutes, while AgeLess is on and something reads them: an open goal on them,
        // or the setup flow (`full`), where their presence makes the two metrics available. Nil leaves an open
        // goal on them resting (`PeriodGoalTracker.restsWithoutAgeLess`).
        if HealthspanFeature.isEnabled, full || open.contains(where: { $0.metric.needsAgeLess }) {
            func byDay(_ key: String) async -> [String: Double] {
                Dictionary(await repo.exploreSeries(key: key, source: Repository.whoopSource, days: 400)
                    .map { ($0.day, $0.value) }, uniquingKeysWith: { _, b in b })
            }
            inputs.agelessModerateByDay = await byDay(IntelligenceEngine.healthspanZone13Key)
            inputs.agelessVigorousByDay = await byDay(IntelligenceEngine.healthspanZone45Key)
        }
        return inputs
    }

    /// Everything, for recommendations in the setup flow.
    /// The target-value series catalog goals read besides weight (`LongTermReaderInputs.series`):
    /// resting heart rate from the nightly metrics, the sleeping heart rate AgeLess reads, VO2max by
    /// AgeLess's rule (`HealthspanVO2.goalReadings`: an entered value for a year, else Apple Health's
    /// readings), body fat, lean mass and waist from the
    /// body-measurement resolver. Read only for the metrics asked for, so a refresh without such goals
    /// reads nothing extra.
    func loadLevelSeries(repo: Repository, metrics: Set<LongTermMetric>) async -> [LongTermMetric: [GoalMilestones.Sample]] {
        var out: [LongTermMetric: [GoalMilestones.Sample]] = [:]
        func samples(_ rows: [(day: String, value: Double)]) -> [GoalMilestones.Sample] {
            rows.compactMap { row in GoalMeasurements.parseDay(row.day).map { GoalMilestones.Sample(date: $0, value: row.value) } }
        }
        if metrics.contains(.restingHr) {
            out[.restingHr] = samples(repo.days.compactMap { day in
                day.restingHr.flatMap { $0 > 0 ? (day.day, Double($0)) : nil }
            })
        }
        if metrics.contains(.sleepHeartRate) {
            out[.sleepHeartRate] = samples(await repo.exploreSeries(key: "rhr_primary_session",
                                                                     source: Repository.whoopSource, days: 400))
        }
        if metrics.contains(.sleepConsistency) {
            // The nightly score AgeLess averages, from the same computed sleep sessions and the same function.
            let now = Date()
            let to = Int(now.timeIntervalSince1970) + 86_400, from = to - 70 * 86_400
            let offset = TimeZone.current.secondsFromGMT()
            let sessions = await repo.computedSleepSessions(from: from - 5 * 86_400, to: to, limit: 1_000)
                .map { SleepTimingConsistency.Interval(start: $0.effectiveStartTs, end: $0.endTs) }
            let scores = SleepTimingConsistency.scoresByDay(sessions: sessions, from: from, to: to) {
                AnalyticsEngine.dayString($0, offsetSec: offset)
            }
            out[.sleepConsistency] = samples(scores.map { (day: $0.key, value: $0.value) }.sorted { $0.day < $1.day })
        }
        if metrics.contains(.vo2max) {
            let vo2 = await repo.agelessVO2Inputs(days: 400)
            out[.vo2max] = samples(HealthspanVO2.goalReadings(manual: vo2.manual, appleHealth: vo2.appleHealth,
                                                              today: Repository.localDayKey(Date())))
        }
        let bodyKeys: [(LongTermMetric, String)] = [(.bodyFat, "body_fat"), (.leanMass, "lean_mass"), (.waist, "waist")]
        if bodyKeys.contains(where: { metrics.contains($0.0) }) {
            let body = await repo.bodyMetrics(days: 400)
            for (metric, key) in bodyKeys where metrics.contains(metric) {
                out[metric] = samples(body.series(key).map { ($0.day, $0.value) })
            }
        }
        return out
    }

    func loadFullPeriodInputs(repo: Repository, now: Date = Date()) async -> PeriodGoalInputs {
        await periodGoalInputs(repo: repo, workouts: await repo.workoutRows(days: 400, reconcileHrCap: 0),
                               activeKcalByDay: await repo.activeEnergyByDay(days: 400),
                               goals: PeriodGoalStore.shared.goals, now: now, full: true)
    }

    private func hasLiftingLog(repo: Repository, now: Date) async -> Bool {
        guard let store = await repo.storeHandle() else { return false }
        let end = Int(now.timeIntervalSince1970)
        let imported = !(((try? await store.strengthWorkouts(from: 0, to: end + 86_400, limit: 1)) ?? []).isEmpty)
        if imported { return true }
        return !(((try? await store.nativeWorkouts(from: 0, to: end + 86_400, limit: 1)) ?? []).isEmpty)
    }

    /// Working sets per local day, from the canonical strength read model (a session logged natively and
    /// imported counts once). nil without a lifting log.
    private func workingSetsByDay(repo: Repository, days: Int) async -> [String: Double]? {
        guard await hasLiftingLog(repo: repo, now: Date()) else { return nil }
        let history = await repo.resolvedStrengthHistory(days: days)
        var byDay: [String: Double] = [:]
        for workout in history.workouts {
            let day = Repository.localDayKey(Date(timeIntervalSince1970: Double(workout.startTs)))
            byDay[day, default: 0] += Double(StrengthSession.summarize(workout, templates: history.templates)
                .workingSetCount)
        }
        return byDay
    }

    /// Working sets per week over `GoalMeasure.hardSetWindowDays`, or nil when there is no lifting log.
    ///
    /// Nil, not zero, when nothing is connected — the goal is then UNMEASURED rather than unmet, and the
    /// tile says "connect a lifting log" instead of showing a 0 that reads as a failure. An empty window
    /// WITH a log is a real zero and returns one, exactly as the consistency measure does.
    private func hardSetsPerWeek(repo: Repository, now: Date) async -> Double? {
        guard let store = await repo.storeHandle() else { return nil }
        let end = Int(now.timeIntervalSince1970)
        // "Is a lifting log connected at all" has to include NOOP's own log and every file import, or a
        // wearer who never connected Hevy reads as unmeasured instead of as the sets they performed.
        // Both probes are LIMIT 1 existence checks, not a history read.
        let hasImportedLog = !(((try? await store.strengthWorkouts(from: 0, to: end + 86_400,
                                                                   limit: 1)) ?? []).isEmpty)
        let hasNativeLog = !(((try? await store.nativeWorkouts(from: 0, to: end + 86_400,
                                                               limit: 1)) ?? []).isEmpty)
        guard hasImportedLog || hasNativeLog else { return nil }
        // The window itself comes from the canonical read model, so a session logged natively and
        // imported is counted once.
        let history = await repo.resolvedStrengthHistory(days: GoalMeasure.hardSetWindowDays)
        let sets = history.workouts
            .map { StrengthSession.summarize($0, templates: history.templates).workingSetCount }
            .reduce(0, +)
        return GoalMeasure.perWeek(count: sets, overDays: GoalMeasure.hardSetWindowDays)
    }

}
