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
        // The shared loader resolves each data lane (`GoalInputLoader`, the same one the Android core runs);
        // GoalTrackingModel owns all evaluation and mutations.
        let source = await GoalInputLoader.source(reader: repo, now: now, goals: goals, actions: actions,
                                                  periodGoals: PeriodGoalStore.shared.goals)
        let steps = source.stepsByDay
        let calendar = source.calendar
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

    /// The target-value series catalog goals read besides weight (`LongTermReaderInputs.series`):
    /// resting heart rate from the nightly metrics, the sleeping heart rate AgeLess reads, VO2max by
    /// AgeLess's rule (`HealthspanVO2.goalReadings`: an entered value for a year, else Apple Health's
    /// readings), body fat, lean mass and waist from the
    /// body-measurement resolver. Read only for the metrics asked for, so a refresh without such goals
    /// reads nothing extra.
    func loadLevelSeries(repo: Repository, metrics: Set<LongTermMetric>) async -> [LongTermMetric: [GoalMilestones.Sample]] {
        await GoalLevelReader.read(reader: repo, metrics: metrics, now: Date())
    }

    /// Everything, for recommendations in the setup flow.
    func loadFullPeriodInputs(repo: Repository, now: Date = Date()) async -> PeriodGoalInputs {
        await GoalInputLoader.fullPeriodInputs(reader: repo, goals: PeriodGoalStore.shared.goals, now: now)
    }
}

/// The Apple host of the shared goal loader: the Repository's own reads, unchanged.
extension Repository: GoalInputReading {
    func goalDays() async -> [DailyMetric] { days }
    func goalStore() async -> WhoopStore? { await storeHandle() }
    func goalWorkoutRows(days: Int) async -> [WorkoutRow] { await workoutRows(days: days, reconcileHrCap: 0) }
    func goalWeightDailyValues(days: Int) async -> [(day: String, value: Double)] { await weightDailyValues(days: days) }
    func goalSeries(key: String, source: String, days: Int) async -> [(day: String, value: Double)] {
        await series(key: key, source: source, days: days)
    }
    func goalActiveEnergyByDay(days: Int) async -> [String: Double] { await activeEnergyByDay(days: days) }
    func goalAppleDailyRows(days: Int) async -> [AppleDaily] { await appleDailyRows(days: days) }
    func goalJournalEntries(days: Int) async -> [JournalEntry] { await journalEntries(days: days) }
    func goalHydrationHistory(days: Int, now: Date) async -> [(day: String, value: Double)] {
        await hydrationHistory(days: days, now: now)
    }
    func goalStrengthHistory(days: Int) async -> ResolvedStrengthHistory { await resolvedStrengthHistory(days: days) }
    func goalAgeLessMinutes(key: String, days: Int) async -> [(day: String, value: Double)] {
        await exploreSeries(key: key, source: Self.whoopSource, days: days)
    }
    func goalLevelSeries(metrics: Set<LongTermMetric>) async -> [LongTermMetric: [GoalMilestones.Sample]] {
        await GoalTrackingStore.shared.loadLevelSeries(repo: self, metrics: metrics)
    }
    func goalHostState() -> GoalHostState {
        let syncedAt = UserDefaults.standard.double(forKey: "lastSyncedAt")
        return GoalHostState(hydrationEnabled: UserDefaults.standard.bool(forKey: HydrationStore.enabledKey),
                             profileSex: UserDefaults.standard.string(forKey: "profile.sex") ?? "",
                             lastSync: syncedAt > 0 ? Date(timeIntervalSince1970: syncedAt) : nil,
                             agelessEnabled: HealthspanFeature.isEnabled,
                             motivationEnabled: GoalPrefs.motivationEnabled)
    }
}

/// Store access stays in Repository; target-value assembly and its clock stay in GoalLevelReader.
extension Repository: GoalLevelReading {
    func goalLevelValues(key: String, source: String, days: Int) async -> [(day: String, value: Double)] {
        await exploreSeries(key: key, source: source, days: days)
    }
    func goalComputedSleepSessions(from: Int, to: Int, limit: Int) async -> [CachedSleepSession] {
        await computedSleepSessions(from: from, to: to, limit: limit)
    }
    func goalVO2Inputs(days: Int) async -> (manual: (day: String, value: Double)?, appleHealth: [(day: String, value: Double)]) {
        await agelessVO2Inputs(days: days)
    }
    func goalBodyMetrics(days: Int) async -> BodyMetrics { await bodyMetrics(days: days) }
}
