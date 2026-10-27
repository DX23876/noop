import Foundation
import StrandAnalytics
import StrandCore
import StrandTraining
import WhoopStore

/// Goals for the Android app (Android parity plan 1.2 and 2.3): the shared `GoalInputLoader` reads the store through
/// the host below, the shared `GoalTrackingModel` evaluates, and the goal stores change only inside a
/// `CoreGoalState` transaction, as the Apple screens change them through `PeriodGoalStore` and `GoalActionStore`.
public enum CoreGoals {
    /// What the Android device knows besides the store, as the Apple host reads it from UserDefaults.
    public struct Settings {
        public var profileSex: String
        public var lastSync: Date?
        public var agelessEnabled: Bool
        public var dismissedWorkoutSpans: [String]
        public init(profileSex: String, lastSync: Date?, agelessEnabled: Bool, dismissedWorkoutSpans: [String]) {
            self.profileSex = profileSex; self.lastSync = lastSync
            self.agelessEnabled = agelessEnabled; self.dismissedWorkoutSpans = dismissedWorkoutSpans
        }
    }

    public struct Contribution: Encodable {
        public var id: String, day: String, title: String, value: Double, isManual: Bool, reason: String?
    }

    public struct HistoryEntry: Encodable {
        public var periodStart: String, target: Double, value: Double, outcome: String
    }

    /// A weekly or monthly goal as `PeriodGoalSnapshot` reads it.
    public struct Period: Encodable {
        public var id: String, metric: String, period: String, status: String
        public var target: Double, threshold: Double?, sportFilter: [String], parentGoalId: String?
        public var periodStart: String, periodDays: [String], todayIndex: Int, daysLeft: Int
        public var current: Double, periodTarget: Double, fraction: Double, paceFraction: Double?
        public var remaining: Double, requiredPerDay: Double?, state: String, isProtected: Bool
        public var dayValues: [Double?], restDays: [String]
        public var history: [HistoryEntry], currentStreak: Int, bestStreak: Int
        public var counted: [Contribution], notCounted: [Contribution], suggestedDays: [String]
        public var aggregation: String, step: Double, rangeLow: Double, rangeHigh: Double
    }

    /// A long-term goal as `GoalTrackingSnapshot` reads it.
    public struct LongTerm: Encodable {
        public var id: String, title: String, status: String, targetDate: String?
        public var health: String, progress: Double?, reason: String, nextAction: String
        public var currentStreak: Int, bestStreak: Int, periodGoalIds: [String]
    }

    /// One daily goal on one day (`GoalActionOccurrence`).
    public struct Action: Encodable {
        public var id: String, actionId: String, title: String, kind: String, day: String
        public var isCompleted: Bool, isAutomatic: Bool, measured: Double?, measuredTarget: Double?
    }

    /// A metric the setup can offer: available once its source has delivered data, with its own target range.
    public struct MetricChoice: Encodable {
        public var metric: String, aggregation: String, reason: String?, available: Bool
        public var weekDefault: Double, weekStep: Double, weekLow: Double, weekHigh: Double
        public var monthDefault: Double, monthStep: Double, monthLow: Double, monthHigh: Double
        public var threshold: Double?
    }

    public struct Output: Encodable {
        public var period: [Period], longTerm: [LongTerm]
        public var today: [Action], week: [Action]
        public var periodLimit: Int
        public var updatedAt: Double
    }

    public struct Setup: Encodable {
        public var metrics: [MetricChoice], openCount: Int, periodLimit: Int
    }

    public struct Change: Encodable {
        public var ok: Bool, error: String?
    }

    // MARK: Read

    /// Refreshes every goal as `GoalTrackingStore.refresh(repo:)` does on Apple (its migrations, the shared
    /// inputs, the shared evaluation, the weekly targets that follow a long-term goal) and returns what the screens
    /// show. The goal stores change in the refresh (frozen periods, followed targets), so it commits.
    @MainActor
    public static func snapshot(reader: StoreReader, settings: Settings, now: Date = Date()) async throws -> Output {
        let today = StoreReader.localDayKey(now)
        let state = try await CoreGoalState.change(store: reader.store) { context -> Inputs in
            context.actions.migrateMomentumStepGoalIfNeeded()
            context.actions.syncStepGoal()
            context.goals.assignTemplatesToLegacyGoals(today: today, now: now)
            return Inputs(goals: context.goals.goals, actions: context.actions.actions,
                          periodGoals: context.periods.goals, motivationEnabled: GoalPrefs.motivationEnabled)
        }
        let host = Host(reader: reader, settings: settings, motivationEnabled: state.motivationEnabled)
        let source = await GoalInputLoader.source(reader: host, now: now, goals: state.goals,
                                                  actions: state.actions, periodGoals: state.periodGoals)
        return try await CoreGoalState.change(store: reader.store) { context in
            let model = GoalTrackingModel()
            // Coach plans are not on Android yet: no proposals and no open reconciliation questions.
            model.refresh(source: source, now: now, goals: context.goals.goals, proposals: [], unresolved: [],
                          actions: context.actions.actions, checkoffs: context.actions.checkoffs,
                          contributions: context.contributions.contributions,
                          dismissedWorkoutKeys: context.contributions.dismissedWorkoutKeys)
            model.applyFollowingWeeklyTargets(now: now, calendar: source.calendar)
            return Output(period: model.periodSnapshots.map(period), longTerm: model.snapshots.map(longTerm),
                          today: model.todayActions.map(action), week: model.weekActions.map(action),
                          periodLimit: GoalPrefs.periodLimit, updatedAt: now.timeIntervalSince1970)
        }
    }

    /// The metrics the period-goal setup offers, read with every source as the Apple setup reads them.
    @MainActor
    public static func setup(reader: StoreReader, settings: Settings, now: Date = Date()) async throws -> Setup {
        let state = try await CoreGoalState.read(store: reader.store) { context in
            (context.periods.goals, GoalPrefs.motivationEnabled)
        }
        let host = Host(reader: reader, settings: settings, motivationEnabled: state.1)
        let inputs = await GoalInputLoader.fullPeriodInputs(reader: host, goals: state.0, now: now)
        let calendar = TrainingPreferences.weekCalendar
        let choices = PeriodMetric.allCases.map { metric -> MetricChoice in
            let week = metric.range(for: .week), month = metric.range(for: .month)
            var reason: String?
            if case .unavailable(let why) = PeriodGoalTracker.availability(metric, inputs: inputs, now: now,
                                                                           calendar: calendar) { reason = why }
            return MetricChoice(metric: metric.rawValue, aggregation: "\(metric.aggregation)", reason: reason,
                available: PeriodGoalTracker.availability(metric, inputs: inputs, now: now, calendar: calendar) == .available,
                weekDefault: metric.defaultTarget(for: .week), weekStep: metric.step(for: .week),
                weekLow: week.lowerBound, weekHigh: week.upperBound,
                monthDefault: metric.defaultTarget(for: .month), monthStep: metric.step(for: .month),
                monthLow: month.lowerBound, monthHigh: month.upperBound, threshold: metric.defaultThreshold)
        }
        return Setup(metrics: choices, openCount: state.0.filter(\.isOpen).count, periodLimit: GoalPrefs.periodLimit)
    }

    // MARK: Change

    /// Adds a weekly or monthly goal as the Apple setup's Create button does (`canAdd`, then `commit`).
    @MainActor
    public static func addPeriodGoal(store: WhoopStore, metric: String, period: String, target: Double,
                                     threshold: Double?, now: Date = Date()) async -> Change {
        guard let metric = PeriodMetric(rawValue: metric), let period = PeriodGoal.Period(rawValue: period) else {
            return Change(ok: false, error: "invalid")
        }
        do {
            return try await CoreGoalState.change(store: store) { context in
                let goal = PeriodGoal(metric: metric, period: period, target: target,
                                      threshold: metric.hasThreshold ? (threshold ?? metric.defaultThreshold) : nil,
                                      createdAt: now)
                switch context.periods.canAdd(goal) {
                case .limitReached?: return Change(ok: false, error: "limitReached")
                case .duplicate?: return Change(ok: false, error: "duplicate")
                case nil:
                    context.periods.commit(goal, today: StoreReader.localDayKey(now))
                    return Change(ok: true, error: nil)
                }
            }
        } catch {
            return Change(ok: false, error: "conflict")
        }
    }

    /// The detail page's actions on a weekly or monthly goal.
    @MainActor
    public static func changePeriodGoal(store: WhoopStore, id: String, action: String, target: Double?,
                                        reason: String?, now: Date = Date()) async -> Change {
        guard let uuid = UUID(uuidString: id) else { return Change(ok: false, error: "invalid") }
        do {
            return try await CoreGoalState.change(store: store) { context in
                guard context.periods.goal(id: uuid) != nil else { return Change(ok: false, error: "missing") }
                switch action {
                case "setTarget":
                    guard let target else { return Change(ok: false, error: "invalid") }
                    context.periods.setTarget(uuid, target, today: StoreReader.localDayKey(now))
                case "pause":
                    context.periods.pause(uuid, reason: CoachGoal.PauseReason(rawValue: reason ?? "") ?? .other, on: now)
                case "resume": context.periods.resume(uuid, on: now)
                case "end": context.periods.end(uuid, on: now)
                case "remove": context.periods.remove(uuid)
                default: return Change(ok: false, error: "invalid")
                }
                return Change(ok: true, error: nil)
            }
        } catch {
            return Change(ok: false, error: "conflict")
        }
    }

    /// Checks a manual daily goal off for a day, or undoes it (`GoalActionStore.toggleManual`).
    @MainActor
    public static func toggleAction(store: WhoopStore, actionId: String, day: String, now: Date = Date()) async -> Change {
        guard let uuid = UUID(uuidString: actionId) else { return Change(ok: false, error: "invalid") }
        do {
            return try await CoreGoalState.change(store: store) { context in
                context.actions.toggleManual(uuid, day: day, now: now)
                return Change(ok: true, error: nil)
            }
        } catch {
            return Change(ok: false, error: "conflict")
        }
    }

    // MARK: Encoding

    private struct Inputs {
        var goals: [CoachGoal], actions: [GoalAction], periodGoals: [PeriodGoal], motivationEnabled: Bool
    }

    @MainActor
    private static func period(_ s: PeriodGoalSnapshot) -> Period {
        let goal = s.goal
        let range = goal.metric.range(for: goal.period, days: s.periodDays.count)
        func contribution(_ c: PeriodGoalSnapshot.Contribution) -> Contribution {
            Contribution(id: c.id, day: c.day, title: c.title, value: c.value, isManual: c.isManual, reason: c.reason)
        }
        return Period(id: goal.id.uuidString, metric: goal.metric.rawValue, period: goal.period.rawValue,
            status: goal.status.rawValue, target: goal.target, threshold: goal.threshold,
            sportFilter: goal.sportFilter, parentGoalId: goal.parentGoalId?.uuidString,
            periodStart: s.periodStart, periodDays: s.periodDays, todayIndex: s.todayIndex, daysLeft: s.daysLeft,
            current: s.result.current, periodTarget: s.result.target, fraction: s.result.fraction,
            paceFraction: s.result.paceFraction, remaining: s.result.remaining,
            requiredPerDay: s.result.requiredPerDay, state: s.result.state.rawValue, isProtected: s.isProtected,
            dayValues: s.dayValues, restDays: s.restDays.sorted(),
            history: s.history.map { HistoryEntry(periodStart: $0.periodStart, target: $0.target, value: $0.value,
                                                  outcome: $0.outcome.rawValue) },
            currentStreak: s.currentStreak, bestStreak: s.bestStreak,
            counted: s.counted.map(contribution), notCounted: s.notCounted.map(contribution),
            suggestedDays: s.suggestedDays, aggregation: "\(goal.metric.aggregation)",
            step: goal.metric.step(for: goal.period), rangeLow: range.lowerBound, rangeHigh: range.upperBound)
    }

    @MainActor
    private static func longTerm(_ s: GoalTrackingSnapshot) -> LongTerm {
        let health: String
        switch s.health {
        case .decisionNeeded: health = "decisionNeeded"
        case .atRisk: health = "atRisk"
        case .attention: health = "attention"
        case .onTrack: health = "onTrack"
        case .building: health = "building"
        case .paused: health = "paused"
        }
        let children = PeriodGoalStore.shared.goals.filter { $0.parentGoalId == s.id && $0.isOpen }
        return LongTerm(id: s.id.uuidString, title: s.goal.title, status: s.goal.status.rawValue,
                        targetDate: s.goal.targetDate.map(StoreReader.localDayKey), health: health,
                        progress: s.displayProgress, reason: s.reason, nextAction: s.nextAction,
                        currentStreak: s.currentStreak, bestStreak: s.bestStreak,
                        periodGoalIds: children.map(\.id.uuidString))
    }

    @MainActor
    private static func action(_ o: GoalActionOccurrence) -> Action {
        let kind: String
        switch o.action.requirement {
        case .steps: kind = "steps"
        case .workout: kind = "workout"
        case .sleep: kind = "sleep"
        case .activeCalories: kind = "activeCalories"
        case .manual: kind = "manual"
        case .journal: kind = "journal"
        }
        return Action(id: o.id, actionId: o.action.id.uuidString, title: o.action.title, kind: kind, day: o.day,
                      isCompleted: o.isCompleted, isAutomatic: o.isAutomatic, measured: o.measured,
                      measuredTarget: o.measuredTarget)
    }

    // MARK: Host

    /// The Android host of `GoalInputLoader`, over the core's store reader: the same reads the Apple
    /// `Repository` makes where the core has them. Lanes the core cannot read yet (active energy, the journal,
    /// hydration, VO2max and sleep-timing levels) return nothing, which leaves the goals on them unmeasured.
    @MainActor
    final class Host: GoalInputReading {
        let reader: StoreReader
        let settings: Settings
        let motivationEnabled: Bool
        private var days: [DailyMetric]?

        init(reader: StoreReader, settings: Settings, motivationEnabled: Bool) {
            self.reader = reader; self.settings = settings; self.motivationEnabled = motivationEnabled
        }

        private func range(days: Int, now: Date = Date()) -> (from: String, to: String) {
            (StoreReader.localDayKey(now.addingTimeInterval(-Double(days) * 86_400)),
             StoreReader.localDayKey(now.addingTimeInterval(86_400)))
        }

        func goalDays() async -> [DailyMetric] {
            if let days { return days }
            let r = range(days: 400)
            let merged = StoreReader.mergeDaily(imported: await reader.unionDailyMetrics(from: r.from, to: r.to),
                                                computed: await reader.unionComputedDailyMetrics(from: r.from, to: r.to))
            days = merged
            return merged
        }

        func goalStore() async -> WhoopStore? { reader.store }

        func goalWorkoutRows(days: Int) async -> [WorkoutRow] {
            let now = Int(Date().timeIntervalSince1970)
            let raw = await reader.rawWorkoutRows(from: now - days * 86_400, to: now + 86_400,
                                                  dismissedDetectedSpans: settings.dismissedWorkoutSpans)
            let deduped = WorkoutSource.dedupCrossSource(raw)
            return await WorkoutHeartRateFills.overlay(deduped.sorted { $0.startTs > $1.startTs }, store: reader.store)
        }

        func goalWeightDailyValues(days: Int) async -> [(day: String, value: Double)] {
            let r = range(days: days)
            return await WeightSeries.series(reader: reader, from: r.from, to: r.to).map { ($0.day, $0.value) }
        }

        func goalSeries(key: String, source: String, days: Int) async -> [(day: String, value: Double)] {
            let r = range(days: days)
            return await reader.series(key: key, source: source, from: r.from, to: r.to, suppressedSleepWakeDays: [])
        }

        func goalActiveEnergyByDay(days: Int) async -> [String: Double] { [:] }

        func goalAppleDailyRows(days: Int) async -> [AppleDaily] {
            let r = range(days: days)
            return (try? await reader.store.appleDaily(deviceId: MetricResolver.appleHealthSource,
                                                       from: r.from, to: r.to)) ?? []
        }

        func goalJournalEntries(days: Int) async -> [JournalEntry] { [] }

        func goalHydrationHistory(days: Int, now: Date) async -> [(day: String, value: Double)] { [] }

        func goalStrengthHistory(days: Int) async -> ResolvedStrengthHistory {
            let now = Int(Date().timeIntervalSince1970)
            let fusion = await TrainingSessionResolver.read(reader: reader, from: now - days * 86_400, to: now + 86_400,
                                                            dismissedDetectedSpans: settings.dismissedWorkoutSpans)
            return await StrengthHistoryReader.read(store: reader.store, days: days, now: now) { fusion }
        }

        func goalAgeLessMinutes(key: String, days: Int) async -> [(day: String, value: Double)] {
            await goalSeries(key: key, source: MetricResolver.whoopSource, days: days)
        }

        func goalLevelSeries(metrics: Set<LongTermMetric>) async -> [LongTermMetric: [GoalMilestones.Sample]] {
            var out: [LongTermMetric: [GoalMilestones.Sample]] = [:]
            func samples(_ rows: [(day: String, value: Double)]) -> [GoalMilestones.Sample] {
                rows.compactMap { row in
                    GoalMeasurements.parseDay(row.day).map { GoalMilestones.Sample(date: $0, value: row.value) }
                }
            }
            if metrics.contains(.restingHr) {
                out[.restingHr] = samples(await goalDays().compactMap { day in
                    day.restingHr.flatMap { $0 > 0 ? (day.day, Double($0)) : nil }
                })
            }
            if metrics.contains(.sleepHeartRate) {
                out[.sleepHeartRate] = samples(await goalSeries(key: "rhr_primary_session",
                                                                source: MetricResolver.whoopSource, days: 400))
            }
            let bodyKeys: [(LongTermMetric, String)] = [(.bodyFat, "body_fat"), (.leanMass, "lean_mass"), (.waist, "waist")]
            if bodyKeys.contains(where: { metrics.contains($0.0) }) {
                let body = await BodyMetricsReader.read(reader: reader, activeDeviceId: reader.activeDeviceId, days: 400)
                for (metric, key) in bodyKeys where metrics.contains(metric) {
                    out[metric] = samples(body.series(key).map { ($0.day, $0.value) })
                }
            }
            return out
        }

        func goalHostState() -> GoalHostState {
            GoalHostState(hydrationEnabled: false, profileSex: settings.profileSex, lastSync: settings.lastSync,
                          agelessEnabled: settings.agelessEnabled, motivationEnabled: motivationEnabled)
        }
    }
}
