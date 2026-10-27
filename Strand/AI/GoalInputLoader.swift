import Foundation
import StrandAnalytics
import StrandCore
import StrandTraining
import WhoopStore

/// What the wearer's device knows about itself that a goal refresh reads besides the store: settings Apple keeps
/// in UserDefaults and Android in its preferences.
struct GoalHostState {
    var hydrationEnabled = false
    var profileSex = ""
    var lastSync: Date?
    var agelessEnabled = false
    /// `GoalPrefs.motivationEnabled`, read where the goal preferences are bound.
    var motivationEnabled = true
}

/// The reads a goal refresh makes (Android parity plan 1.2). Apple's `Repository` answers them, and so does the
/// Android core over its `StoreReader`, so both run one loader with the same windows and the same choice of what is
/// read. A host that cannot read a lane yet returns nothing for it: the goals on it then stay unmeasured instead of
/// showing a number the other platform would not.
@MainActor
protocol GoalInputReading: AnyObject {
    /// The merged daily metrics the host has loaded (`Repository.days`).
    func goalDays() async -> [DailyMetric]
    func goalStore() async -> WhoopStore?
    func goalWorkoutRows(days: Int) async -> [WorkoutRow]
    func goalWeightDailyValues(days: Int) async -> [(day: String, value: Double)]
    func goalSeries(key: String, source: String, days: Int) async -> [(day: String, value: Double)]
    func goalActiveEnergyByDay(days: Int) async -> [String: Double]
    func goalAppleDailyRows(days: Int) async -> [AppleDaily]
    func goalJournalEntries(days: Int) async -> [JournalEntry]
    func goalHydrationHistory(days: Int, now: Date) async -> [(day: String, value: Double)]
    func goalStrengthHistory(days: Int) async -> ResolvedStrengthHistory
    /// AgeLess's banked minutes by day for a series key (`DailyAnalysis.healthspanZone13Key`, `…Zone45Key`).
    func goalAgeLessMinutes(key: String, days: Int) async -> [(day: String, value: Double)]
    /// The target-value series long-term goals read besides weight (`LongTermReaderInputs.series`).
    func goalLevelSeries(metrics: Set<LongTermMetric>) async -> [LongTermMetric: [GoalMilestones.Sample]]
    func goalHostState() -> GoalHostState
}

/// Assembles a goal refresh's inputs from a `GoalInputReading` host, the adapter `GoalTrackingStore` used to own.
@MainActor
enum GoalInputLoader {
    /// Everything `GoalTrackingModel.refresh` reads, for the goals and daily actions given.
    static func source(reader: GoalInputReading, now: Date, goals: [CoachGoal], actions: [GoalAction],
                       periodGoals: [PeriodGoal]) async -> GoalTrackingModel.Source {
        let host = reader.goalHostState()
        let days = await reader.goalDays()
        let earliestCount = goals.compactMap { goal -> Date? in
            guard goal.measure?.shape == .sum else { return nil }
            return goal.measure?.countFrom ?? goal.createdAt
        }.min()
        let workoutDays = max(365, earliestCount.map { Int(now.timeIntervalSince($0) / 86_400) + 14 } ?? 0)
        let workouts = await reader.goalWorkoutRows(days: workoutDays)
        let weights = await reader.goalWeightDailyValues(days: 365)
        let stress = await reader.goalSeries(key: "stress", source: "my-whoop", days: 365)
        let hardSets = await hardSetsPerWeek(reader: reader, now: now)
        let activeKcal = await reader.goalActiveEnergyByDay(days: 400)
        let steps = GoalMotivationBuilder.stepsByDay(days: days, apple: await reader.goalAppleDailyRows(days: 4000))
        let journal: [JournalEntry]
        if actions.contains(where: { if case .journal = $0.requirement { return $0.isActive } else { return false } }) {
            journal = await reader.goalJournalEntries(days: 400)
        } else { journal = [] }
        let periodInputs = await periodInputs(reader: reader, days: days, workouts: workouts,
                                              activeKcalByDay: activeKcal, goals: periodGoals, now: now)
        let allWorkouts = host.motivationEnabled ? await reader.goalWorkoutRows(days: 4000) : []
        let metrics = Set(goals.compactMap { $0.measure?.metric })
        let levels = await reader.goalLevelSeries(metrics: metrics)
        return GoalTrackingModel.Source(workouts: workouts, allWorkouts: allWorkouts, weights: weights, stress: stress,
            days: days, hardSetsPerWeek: hardSets, activeKcalByDay: activeKcal, stepsByDay: steps,
            journalByDay: Dictionary(grouping: journal, by: \.day), periodInputs: periodInputs,
            levelSeries: levels, calendar: TrainingPreferences.weekCalendar)
    }

    /// The inputs period goals need. Sources only some goals use (lifting log per day, hydration, the journal) are
    /// read only when such a goal exists or the setup flow asks (`full`).
    static func periodInputs(reader: GoalInputReading, days: [DailyMetric], workouts: [WorkoutRow],
                             activeKcalByDay: [String: Double], goals: [PeriodGoal], now: Date,
                             full: Bool = false) async -> PeriodGoalInputs {
        let host = reader.goalHostState()
        let open = goals.filter(\.isOpen)
        var inputs = PeriodGoalInputs()
        inputs.workouts = workouts
        inputs.days = days
        inputs.activeKcalByDay = activeKcalByDay
        inputs.stepsByDay = GoalMotivationBuilder.stepsByDay(days: days, apple: await reader.goalAppleDailyRows(days: 400))
        inputs.hydrationEnabled = host.hydrationEnabled
        inputs.profileSex = host.profileSex
        inputs.lastSync = host.lastSync
        inputs.hasStrap = inputs.lastSync != nil
        if full || open.contains(where: { $0.metric == .workingSets }) {
            inputs.setsByDay = await workingSetsByDay(reader: reader, days: 400, now: now)
        } else if await hasLiftingLog(reader: reader, now: now) {
            // Connected but not needed yet: an empty map still marks the metric as available.
            inputs.setsByDay = [:]
        }
        if inputs.hydrationEnabled && (full || open.contains(where: { $0.metric == .hydrationDays })) {
            inputs.hydrationByDay = Dictionary(await reader.goalHydrationHistory(days: 400, now: now)
                .map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        if full || open.contains(where: { $0.metric == .habitDays }) {
            inputs.journal = await reader.goalJournalEntries(days: 400)
        }
        // AgeLess's banked activity minutes, while AgeLess is on and something reads them: an open goal on them,
        // or the setup flow (`full`), where their presence makes the two metrics available. Nil leaves an open
        // goal on them resting (`PeriodGoalTracker.restsWithoutAgeLess`).
        if host.agelessEnabled, full || open.contains(where: { $0.metric.needsAgeLess }) {
            func byDay(_ key: String) async -> [String: Double] {
                Dictionary(await reader.goalAgeLessMinutes(key: key, days: 400).map { ($0.day, $0.value) },
                           uniquingKeysWith: { _, b in b })
            }
            inputs.agelessModerateByDay = await byDay(DailyAnalysis.healthspanZone13Key)
            inputs.agelessVigorousByDay = await byDay(DailyAnalysis.healthspanZone45Key)
        }
        return inputs
    }

    /// Everything, for recommendations in the setup flow.
    static func fullPeriodInputs(reader: GoalInputReading, goals: [PeriodGoal], now: Date) async -> PeriodGoalInputs {
        await periodInputs(reader: reader, days: await reader.goalDays(),
                           workouts: await reader.goalWorkoutRows(days: 400),
                           activeKcalByDay: await reader.goalActiveEnergyByDay(days: 400),
                           goals: goals, now: now, full: true)
    }

    static func hasLiftingLog(reader: GoalInputReading, now: Date) async -> Bool {
        guard let store = await reader.goalStore() else { return false }
        let end = Int(now.timeIntervalSince1970)
        let imported = !(((try? await store.strengthWorkouts(from: 0, to: end + 86_400, limit: 1)) ?? []).isEmpty)
        if imported { return true }
        return !(((try? await store.nativeWorkouts(from: 0, to: end + 86_400, limit: 1)) ?? []).isEmpty)
    }

    /// Working sets per local day, from the canonical strength read model (a session logged natively and
    /// imported counts once). nil without a lifting log.
    static func workingSetsByDay(reader: GoalInputReading, days: Int, now: Date) async -> [String: Double]? {
        guard await hasLiftingLog(reader: reader, now: now) else { return nil }
        let history = await reader.goalStrengthHistory(days: days)
        var byDay: [String: Double] = [:]
        for workout in history.workouts {
            let day = StoreReader.localDayKey(Date(timeIntervalSince1970: Double(workout.startTs)))
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
    static func hardSetsPerWeek(reader: GoalInputReading, now: Date) async -> Double? {
        // "Is a lifting log connected at all" has to include NOOP's own log and every file import, or a
        // wearer who never connected Hevy reads as unmeasured instead of as the sets they performed.
        // Both probes are LIMIT 1 existence checks, not a history read.
        guard await hasLiftingLog(reader: reader, now: now) else { return nil }
        // The window itself comes from the canonical read model, so a session logged natively and
        // imported is counted once.
        let history = await reader.goalStrengthHistory(days: GoalMeasure.hardSetWindowDays)
        let sets = history.workouts
            .map { StrengthSession.summarize($0, templates: history.templates).workingSetCount }
            .reduce(0, +)
        return GoalMeasure.perWeek(count: sets, overDays: GoalMeasure.hardSetWindowDays)
    }
}
