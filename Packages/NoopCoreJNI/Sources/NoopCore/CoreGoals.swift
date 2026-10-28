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
        public var energyProfile: UserProfile?
        public var energyCalibrationEnabled = false
        public var energyManualVO2: PeakMETResolver.ManualEntry?
        public var energyActivityLevel: JurcaFitness.ActivityLevel?
        public var hydrationEnabled = false
        public var journalAliases: [String: String] = [:]
        public var journalAliasOrder: [String: Int] = [:]
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
        /// The journal question a habit goal counts; the host names it with the wearer's own label.
        public var habitKey: String? = nil, habitWantsYes = true
        /// The screens this goal shows on (`GoalContext`): "training", "sleep" or none.
        public var contexts: [String] = []
        /// The period's target is scaled to the days left when the goal began mid-period (`PeriodPaceResult`).
        public var isProrated = false
    }

    /// A long-term goal as `GoalTrackingSnapshot` reads it.
    public struct LongTerm: Encodable {
        public var id: String, title: String, status: String, targetDate: String?
        public var health: String, progress: Double?, reason: String, nextAction: String
        public var currentStreak: Int, bestStreak: Int, periodGoalIds: [String]
        /// A catalog goal's state as its page and Apple's overview word it (`LongTermGoalContent.style`), with its
        /// `GoalTone`; nil for a goal without a catalog reading, which keeps its health.
        public var statusText: String? = nil, statusTone: String? = nil
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

    /// What Today's goals card shows (`GoalSpotlight`): the rings and checks among today's daily goals, the weekly,
    /// monthly or long-term goals that need a look, and how many weekly and monthly goals are on course.
    public struct Spotlight: Encodable {
        public struct Row: Encodable { public var kind: String, id: String, reason: String }
        public var rings: [String], checks: [String], rows: [Row]
        public var dailyTotal: Int, dailyDone: Int
        public var weekOnCourse: Int, weekTotal: Int, monthOnCourse: Int, monthTotal: Int
    }

    /// A measured daily goal's slot as the editor opens it (`DailyGoalSlot`).
    public struct DailySlot: Encodable {
        public var slot: String, values: [Double], defaultValue: Double
        public var value: Double?, runs: String?, endsOn: String?, weekdays: [Int], showsAsRing: Bool
    }

    public struct Output: Encodable {
        public var period: [Period], longTerm: [LongTerm]
        public var today: [Action], week: [Action]
        public var spotlight: Spotlight, daily: [DailySlot]
        public var periodLimit: Int
        public var updatedAt: Double
        /// Badges, streaks and records (`GoalMotivationSnapshot`); nil while motivation is switched off.
        public var motivation: Motivation? = nil
        public var motivationEnabled = true
        /// Goals that were reached, set aside or archived, newest first, as the iOS journey's "Past goals" lists them.
        public var past: [Past] = []
    }

    public struct Past: Encodable {
        public var id: String, title: String, status: String, closedOn: String?, reason: String?
    }

    /// The motivation the goals page shows, worded by the shared badge texts (`GoalEventPlan`).
    public struct Motivation: Encodable {
        public struct Badge: Encodable {
            public var id: String, family: String, familyTitle: String, title: String, shortValue: String
            public var earned: Bool, earnedOn: String?
        }
        public struct Next: Encodable { public var id: String, fraction: Double }
        public var badges: [Badge], earnedIds: [String], unseenIds: [String], next: Next?
        public var bestStepDay: Int?, bestStepDayOn: String?, bestStepWeek: Int?, bestStepWeekStart: String?
        public var mostWorkoutsWeek: Int?, mostWorkoutsWeekStart: String?, longestStepStreak: Int
        /// Days in a row per measured daily goal, keyed by the goal action's id.
        public var streaks: [String: Int]
    }

    static func motivation(_ m: GoalMotivationSnapshot) -> Motivation {
        let next = GoalMotivation.BadgeFamily.allCases
            .compactMap { GoalMotivation.nextBadge(in: $0, badges: m.badges, progressValue: m.progressValue(for: $0)) }
            .max { $0.fraction < $1.fraction }
        let r = m.records
        return Motivation(
            badges: m.badges.map {
                Motivation.Badge(id: $0.id, family: "\($0.family)", familyTitle: $0.family.title, title: $0.title,
                                 shortValue: $0.shortValue, earned: $0.isEarned, earnedOn: $0.earnedOn)
            },
            earnedIds: m.earned.map(\.id), unseenIds: m.unseen.map(\.id),
            next: next.map { Motivation.Next(id: $0.badge.id, fraction: $0.fraction) },
            bestStepDay: r.bestStepDay?.steps, bestStepDayOn: r.bestStepDay?.day,
            bestStepWeek: r.bestStepWeek?.steps, bestStepWeekStart: r.bestStepWeek?.start,
            mostWorkoutsWeek: r.mostWorkoutsWeek?.count, mostWorkoutsWeekStart: r.mostWorkoutsWeek?.start,
            longestStepStreak: r.longestStepStreak,
            streaks: Dictionary(uniqueKeysWithValues: m.streaks.map { ($0.key.uuidString, $0.value.current) }))
    }

    /// Marks badges as seen (the banner's cross, the achievements page), or switches motivation on or off.
    @MainActor
    public static func changeMotivation(store: WhoopStore, seen: [String], enabled: Bool?) async -> Change {
        do {
            return try await CoreGoalState.change(store: store) { _ in
                if !seen.isEmpty { GoalPrefs.markBadgesSeen(seen) }
                if let enabled { GoalPreferences.standard.set(enabled, forKey: GoalPrefs.motivationEnabledKey) }
                return Change(ok: true, error: nil)
            }
        } catch {
            return Change(ok: false, error: "conflict")
        }
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
        let host = Host(reader: reader, settings: settings, motivationEnabled: state.motivationEnabled, now: now)
        let source = await GoalInputLoader.source(reader: host, now: now, goals: state.goals,
                                                  actions: state.actions, periodGoals: state.periodGoals)
        return try await CoreGoalState.change(store: reader.store) { context in
            let model = evaluate(source: source, context: context, now: now)
            model.applyFollowingWeeklyTargets(now: now, calendar: source.calendar)
            let spot = GoalSpotlight.make(todayActions: model.todayActions, periodSnapshots: model.periodSnapshots,
                                          longTerm: model.snapshots, pinnedLongTerm: GoalPrefs.pinnedLongTermIds,
                                          maxRows: 3, fillsWithLongTerm: true)
            return Output(period: model.periodSnapshots.map(period), longTerm: model.snapshots.map(longTerm),
                          today: model.todayActions.map(action), week: model.weekActions.map(action),
                          spotlight: spotlight(spot, periods: model.periodSnapshots),
                          daily: DailyGoalSlot.allCases.map { daily($0, actions: context.actions.actions, today: today) },
                          periodLimit: GoalPrefs.periodLimit, updatedAt: now.timeIntervalSince1970,
                          motivation: model.motivation.map(motivation), motivationEnabled: GoalPrefs.motivationEnabled,
                          past: context.goals.goals
                              .filter { $0.status == .achieved || $0.status == .abandoned || $0.status == .archived }
                              .sorted { ($0.closure?.date ?? $0.createdAt) > ($1.closure?.date ?? $1.createdAt) }
                              .map { g in Past(id: g.id.uuidString, title: g.title, status: g.status.rawValue,
                                               closedOn: g.closure.map { StoreReader.localDayKey($0.date) },
                                               reason: g.closure?.reason?.isEmpty == false ? g.closure?.reason : nil) })
        }
    }

    /// The goal notes beside one workout and one night (`GoalContextLines`): what the workout counted toward and where
    /// the night stands in the week's sleep goals. Reads the goals without changing them.
    public struct Lines: Encodable {
        public var workout: [String], night: [String]
        /// With `draft`: what saving the open logger session adds, and whether it reaches the goal.
        public var preview: [PreviewLine] = []
    }

    public struct PreviewLine: Encodable {
        public var text: String, reaches: Bool
    }

    @MainActor
    public static func lines(reader: StoreReader, settings: Settings, workoutId: String?, day: String?,
                             draft: Bool = false, now: Date = Date()) async throws -> Lines {
        var row: WorkoutRow?
        if let workoutId, !workoutId.isEmpty {
            row = await CoreTrainingSession.select(reader: reader, id: workoutId, dismissed: settings.dismissedWorkoutSpans,
                                                   now: Int(now.timeIntervalSince1970))?.row
        }
        let source = try await source(reader: reader, settings: settings, now: now)
        let snapshots = try await CoreGoalState.read(store: reader.store) { context in
            evaluate(source: source, context: context, now: now).periodSnapshots
        }
        var preview: [PreviewLine] = []
        if draft, let open = (try? await reader.store.workoutDraft()) ?? nil {
            // The session as the Apple logger previews it: a manual strength workout from its start until now,
            // with the completed work sets it would keep.
            let end = Int(now.timeIntervalSince1970)
            let session = WorkoutRow(startTs: open.startedAt, endTs: end, sport: "Strength Training", source: "manual",
                                     durationS: Double(end - open.startedAt), energyKcal: nil, avgHr: nil, maxHr: nil,
                                     strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
            let sets = open.exercises.flatMap(\.sets).filter { $0.isCompleted && $0.phase == .work }.count
            preview = GoalContextLines.sessionPreview(snapshots, row: session, workingSets: sets)
                .map { PreviewLine(text: $0.text, reaches: $0.reaches) }
        }
        return Lines(workout: row.map { GoalContextLines.contributions(snapshots, row: $0) } ?? [],
                     night: day.map { GoalContextLines.night(snapshots, day: $0) } ?? [], preview: preview)
    }

    /// The shared refresh over loaded inputs, inside a goal-state transaction.
    @MainActor
    static func evaluate(source: GoalTrackingModel.Source, context: CoreGoalState.Context, now: Date) -> GoalTrackingModel {
        let model = GoalTrackingModel()
        // Coach plans are not on Android yet: no proposals and no open reconciliation questions.
        model.refresh(source: source, now: now, goals: context.goals.goals, proposals: [], unresolved: [],
                      actions: context.actions.actions, checkoffs: context.actions.checkoffs,
                      contributions: context.contributions.contributions,
                      dismissedWorkoutKeys: context.contributions.dismissedWorkoutKeys)
        return model
    }

    /// The goal inputs for a read that does not change the goals (Momentum).
    @MainActor
    static func source(reader: StoreReader, settings: Settings, now: Date) async throws -> GoalTrackingModel.Source {
        let state = try await CoreGoalState.read(store: reader.store) { context in
            Inputs(goals: context.goals.goals, actions: context.actions.actions,
                   periodGoals: context.periods.goals, motivationEnabled: GoalPrefs.motivationEnabled)
        }
        let host = Host(reader: reader, settings: settings, motivationEnabled: state.motivationEnabled, now: now)
        return await GoalInputLoader.source(reader: host, now: now, goals: state.goals, actions: state.actions,
                                            periodGoals: state.periodGoals)
    }

    /// The metrics the period-goal setup offers, read with every source as the Apple setup reads them.
    @MainActor
    public static func setup(reader: StoreReader, settings: Settings, now: Date = Date()) async throws -> Setup {
        let state = try await CoreGoalState.read(store: reader.store) { context in
            (context.periods.goals, GoalPrefs.motivationEnabled)
        }
        let host = Host(reader: reader, settings: settings, motivationEnabled: state.1, now: now)
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
                                     threshold: Double?, habitKey: String? = nil, habitWantsYes: Bool = true,
                                     now: Date = Date()) async -> Change {
        guard let metric = PeriodMetric(rawValue: metric), let period = PeriodGoal.Period(rawValue: period) else {
            return Change(ok: false, error: "invalid")
        }
        // A habit goal counts one journal question, as the Apple setup's habit picker requires.
        let habit = habitKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if metric == .habitDays && (habit ?? "").isEmpty { return Change(ok: false, error: "invalid") }
        do {
            return try await CoreGoalState.change(store: store) { context in
                let goal = PeriodGoal(metric: metric, period: period, target: target,
                                      threshold: metric.hasThreshold ? (threshold ?? metric.defaultThreshold) : nil,
                                      habitKey: metric == .habitDays ? habit : nil, habitWantsYes: habitWantsYes,
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

    /// Saves a measured daily goal as the editor's Done does (`DailyGoalSlot.save`).
    @MainActor
    public static func saveDaily(store: WhoopStore, slot: String, value: Double, runs: String, endsOn: String?,
                                 weekdays: [Int], showsAsRing: Bool, now: Date = Date()) async -> Change {
        guard let slot = DailyGoalSlot(rawValue: slot), let runs = DailyGoalSlot.Runs(rawValue: runs) else {
            return Change(ok: false, error: "invalid")
        }
        do {
            return try await CoreGoalState.change(store: store) { context in
                slot.save(in: context.actions, value: slot.nearest(value), runs: runs, endsOn: endsOn,
                          weekdays: Set(weekdays.filter { (1...7).contains($0) }), showsAsRing: showsAsRing,
                          today: StoreReader.localDayKey(now), now: now)
                return Change(ok: true, error: nil)
            }
        } catch {
            return Change(ok: false, error: "conflict")
        }
    }

    /// Turns a measured daily goal off, keeping its history (`DailyGoalSlot.turnOff`).
    @MainActor
    public static func turnOffDaily(store: WhoopStore, slot: String, now: Date = Date()) async -> Change {
        guard let slot = DailyGoalSlot(rawValue: slot) else { return Change(ok: false, error: "invalid") }
        do {
            return try await CoreGoalState.change(store: store) { context in
                slot.turnOff(in: context.actions, today: StoreReader.localDayKey(now),
                             yesterday: StoreReader.localDayKey(now.addingTimeInterval(-86_400)))
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
            step: goal.metric.step(for: goal.period), rangeLow: range.lowerBound, rangeHigh: range.upperBound,
            habitKey: goal.habitKey, habitWantsYes: goal.habitWantsYes,
            contexts: GoalContext.contexts(of: goal).map(\.rawValue), isProrated: s.result.isProrated)
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
        let word = s.reading == nil ? nil : LongTermGoalContent.style(s)
        return LongTerm(id: s.id.uuidString, title: s.goal.title, status: s.goal.status.rawValue,
                        targetDate: s.goal.targetDate.map(StoreReader.localDayKey), health: health,
                        progress: s.displayProgress, reason: s.reason, nextAction: s.nextAction,
                        currentStreak: s.currentStreak, bestStreak: s.bestStreak,
                        periodGoalIds: children.map(\.id.uuidString),
                        statusText: word?.text, statusTone: word?.tone.rawValue)
    }

    @MainActor
    private static func spotlight(_ spot: GoalSpotlight, periods: [PeriodGoalSnapshot]) -> Spotlight {
        let open = periods.filter { $0.goal.status == .active }
        func onCourse(_ items: [PeriodGoalSnapshot]) -> Int {
            items.filter { [.onTrack, .ahead, .achieved].contains($0.state) }.count
        }
        let week = open.filter { $0.goal.period == .week }, month = open.filter { $0.goal.period == .month }
        let rows = spot.rows.map { row -> Spotlight.Row in
            switch row {
            case .period(let s, let reason): return .init(kind: "period", id: s.id.uuidString, reason: "\(reason)")
            case .longTerm(let s, let reason): return .init(kind: "longTerm", id: s.id.uuidString, reason: "\(reason)")
            }
        }
        return Spotlight(rings: spot.rings.map(\.id), checks: spot.checks.map(\.id), rows: rows,
                         dailyTotal: spot.dailyTotal, dailyDone: spot.dailyDone,
                         weekOnCourse: onCourse(week), weekTotal: week.count,
                         monthOnCourse: onCourse(month), monthTotal: month.count)
    }

    @MainActor
    private static func daily(_ slot: DailyGoalSlot, actions: [GoalAction], today: String) -> DailySlot {
        let current = slot.current(in: actions, today: today)
        var runs: String?, weekdays = Array(1...7)
        if let current {
            runs = current.endsOn == nil ? "ongoing" : (current.endsOn == today ? "todayOnly" : "untilDate")
            if case .weekdays(let days) = current.schedule { weekdays = days }
        }
        return DailySlot(slot: slot.rawValue, values: slot.values, defaultValue: slot.defaultValue,
                         value: current.flatMap { slot.value(of: $0.requirement) }, runs: runs,
                         endsOn: current?.endsOn, weekdays: weekdays, showsAsRing: current?.showsAsRing != false)
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
    /// `Repository` makes over the shared store. Host opt-ins and catalog aliases are explicit inputs;
    /// target-value assembly uses the same GoalLevelReader as Apple.
    @MainActor
    final class Host: GoalInputReading, GoalLevelReading {
        let reader: StoreReader
        let settings: Settings
        let motivationEnabled: Bool
        private var days: [DailyMetric]?
        private let now: Date

        init(reader: StoreReader, settings: Settings, motivationEnabled: Bool, now: Date = Date()) {
            self.reader = reader; self.settings = settings; self.motivationEnabled = motivationEnabled; self.now = now
        }

        private func range(days: Int) -> (from: String, to: String) {
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
            let now = Int(self.now.timeIntervalSince1970)
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

        func goalActiveEnergyByDay(days: Int) async -> [String: Double] {
            guard let profile = settings.energyProfile else { return [:] }
            let now = self.now
            let daily = await goalDays()
            return await EnergySummaryStoreReads.activeEnergyByDay(reader: reader, days: days, dailyRows: daily,
                workouts: await goalWorkoutRows(days: max(1, days) + 1), profile: profile, hrMax: profile.maxHR,
                calibrationEnabled: settings.energyCalibrationEnabled, now: now) {
                await CoreGoalEnergy.repairToday(reader: reader, settings: settings, dailyRows: daily,
                                                profile: profile, now: now)
            }
        }

        func goalAppleDailyRows(days: Int) async -> [AppleDaily] {
            let r = range(days: days)
            return (try? await reader.store.appleDaily(deviceId: MetricResolver.appleHealthSource,
                                                       from: r.from, to: r.to)) ?? []
        }

        func goalJournalEntries(days: Int) async -> [JournalEntry] {
            let r = range(days: days)
            return await JournalRead.entries(reader: reader, from: r.from, to: r.to,
                aliases: settings.journalAliases, aliasOrder: settings.journalAliasOrder)
        }

        func goalHydrationHistory(days: Int, now: Date) async -> [(day: String, value: Double)] {
            await HydrationRead.history(store: reader.store, days: days, now: now)
        }

        func goalStrengthHistory(days: Int) async -> ResolvedStrengthHistory {
            let now = Int(self.now.timeIntervalSince1970)
            let fusion = await TrainingSessionResolver.read(reader: reader, from: now - days * 86_400, to: now + 86_400,
                                                            dismissedDetectedSpans: settings.dismissedWorkoutSpans)
            return await StrengthHistoryReader.read(store: reader.store, days: days, now: now) { fusion }
        }

        func goalAgeLessMinutes(key: String, days: Int) async -> [(day: String, value: Double)] {
            await goalLevelValues(key: key, source: MetricResolver.whoopSource, days: days)
        }

        func goalLevelSeries(metrics: Set<LongTermMetric>) async -> [LongTermMetric: [GoalMilestones.Sample]] {
            await GoalLevelReader.read(reader: self, metrics: metrics, now: now)
        }

        func goalLevelValues(key: String, source: String, days: Int) async -> [(day: String, value: Double)] {
            let r = range(days: days)
            return await reader.exploreSeries(key: key, source: source, from: r.from, to: r.to,
                dailyRows: await goalDays(), suppressedSleepWakeDays: [])
        }

        func goalComputedSleepSessions(from: Int, to: Int, limit: Int) async -> [CachedSleepSession] {
            await reader.unionComputedSleepSessions(from: from, to: to, limit: limit).sorted { $0.startTs < $1.startTs }
        }

        func goalVO2Inputs(days: Int) async -> (manual: (day: String, value: Double)?, appleHealth: [(day: String, value: Double)]) {
            (settings.energyManualVO2.map { ($0.day, $0.vo2max) },
             await goalLevelValues(key: "vo2max", source: MetricResolver.appleHealthSource, days: days))
        }

        func goalBodyMetrics(days: Int) async -> BodyMetrics {
            await BodyMetricsReader.read(reader: reader, activeDeviceId: reader.activeDeviceId, days: days, now: now)
        }

        func goalHostState() -> GoalHostState {
            GoalHostState(hydrationEnabled: settings.hydrationEnabled, profileSex: settings.profileSex, lastSync: settings.lastSync,
                          agelessEnabled: settings.agelessEnabled, motivationEnabled: motivationEnabled)
        }
    }
}
