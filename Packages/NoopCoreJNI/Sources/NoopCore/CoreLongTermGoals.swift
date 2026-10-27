import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// Long-term goals for the Android app (parity plan 2.3): the catalog with each template's availability, the setup's
/// draft with the suggestions the Apple setup makes (`LongTermGoalDraft`, shared), creating the goal with its weekly
/// goal, and the page's pause, resume, set-aside and delete. Texts cross as the catalog's English keys, which the
/// Android screens translate from their own resources.
public enum CoreLongTermGoals {
    public struct Template: Encodable {
        public var id: String, area: String, title: String, blurb: String, available: Bool, reason: String?
        public var sportChoices: [String]
    }

    public struct Catalog: Encodable {
        public var areas: [String], templates: [Template]
    }

    /// The setup's state, as the Kotlin screen holds it and sends it back. Dates are seconds since 1970.
    public struct State: Codable {
        public var template: String?
        public var sportIndex = 0
        public var target: Double = 0, baseline: Double = 0
        public var countFromYearStart = true
        public var endDate: Double = 0
        public var hasDate = false
        public var targetDate: Double = 0
        public var openEnded = true
        public var fixedWeeks = 12
        public var weeklyOn = true
        public var weeklyTarget: Double = 3
        public var weeklyChoice = "workouts"
        public var title = "", motivation = ""
        public var threshold: Double = 0, band: Double = 1
        public var habitKey: String?
        public var habitWantsYes = true
    }

    /// The draft after an action, with what the value and weekly steps show beside the state.
    public struct Draft: Encodable {
        public var state: State
        public var shape: String?, metric: String?, weeklyMetric: String?
        public var currentLevel: Double?, collectedSoFar: Double, hasMeasuredStart: Bool
        public var levelStep: Double, levelLow: Double, levelHigh: Double
        public var perWeekStep: Double, perWeekLow: Double, perWeekHigh: Double
        public var sumStep: Double, weeklyMetricOfGoal: String?
        public var risky: Bool, requiresReason: Bool, rate: String?
    }

    public struct Created: Encodable {
        public var ok: Bool, error: String? = nil, goalId: String? = nil
        /// For `sameMeasure`: the goal already measuring this, which the wearer may replace or keep beside it.
        public var existingId: String? = nil, existingTitle: String? = nil
    }

    /// What every draft action reads: all period-goal inputs, the level series and the last weigh-in.
    @MainActor
    private static func context(reader: StoreReader, settings: CoreGoals.Settings,
                                now: Date) async throws -> (PeriodGoalInputs, [LongTermMetric: [GoalMilestones.Sample]], Double?) {
        let periods = try await CoreGoalState.read(store: reader.store) { $0.periods.goals }
        let host = CoreGoals.Host(reader: reader, settings: settings, motivationEnabled: false, now: now)
        let inputs = await GoalInputLoader.fullPeriodInputs(reader: host, goals: periods, now: now)
        let series = await host.goalLevelSeries(metrics: [.restingHr, .sleepHeartRate, .vo2max, .bodyFat, .leanMass,
                                                          .waist, .sleepConsistency])
        let weights = await host.goalWeightDailyValues(days: GoalMeasure.weightWindowDays)
        let weight = weights.last { GoalMeasure.isPlausible($0.value, cfg: GoalMeasure.weightTrend) }?.value
        return (inputs, series, weight)
    }

    @MainActor
    public static func catalog(reader: StoreReader, settings: CoreGoals.Settings, profileWeightKg: Double,
                               now: Date = Date()) async throws -> Catalog {
        let (inputs, series, weight) = try await context(reader: reader, settings: settings, now: now)
        let offered = GoalCatalog.offered
        let areas = GoalCatalogArea.allCases.filter { a in offered.contains { $0.area == a } }.map(\.rawValue)
        let templates = offered.map { item -> Template in
            let availability = GoalCatalog.availability(item.id, inputs: inputs, series: series,
                                                        hasWeight: weight != nil || profileWeightKg > 0)
            var reason: String?
            if case .unavailable(let why) = availability { reason = why }
            return Template(id: item.id.rawValue, area: item.area.rawValue, title: item.title, blurb: item.blurb,
                            available: availability == .available, reason: reason,
                            sportChoices: item.sportChoices.map(\.label))
        }
        return Catalog(areas: areas, templates: templates)
    }

    /// Applies one setup action to the state: "suggest" (a template was picked or its sport changed), "sum" (the end
    /// date of a sum goal moved), "weekly" (the weekly goal is suggested again) or "none" (only read).
    @MainActor
    public static func draft(reader: StoreReader, settings: CoreGoals.Settings, profileWeightKg: Double,
                             state: State, action: String, now: Date = Date()) async throws -> Draft {
        let (inputs, series, weight) = try await context(reader: reader, settings: settings, now: now)
        var d = draft(state, inputs: inputs, series: series, weight: weight, profileWeightKg: profileWeightKg, now: now)
        switch action {
        case "suggest": d.suggest()
        case "sum": d.resuggestSum(); d.suggestWeekly()
        case "weekly": d.suggestWeekly()
        default: break
        }
        return output(d)
    }

    /// Creates the goal as the Apple setup's Create does: a goal measuring the same thing asks first
    /// (`sameMeasure`, answered with `replacing` or `keepBoth`), a full list says `limitReached`, and a pace the
    /// safety gate calls very aggressive needs a reason (`riskReason`).
    @MainActor
    public static func create(reader: StoreReader, settings: CoreGoals.Settings, profileWeightKg: Double,
                              state: State, replacing: String?, keepBoth: Bool, riskReason: String?,
                              now: Date = Date()) async -> Created {
        do {
            let (inputs, series, weight) = try await context(reader: reader, settings: settings, now: now)
            let d = draft(state, inputs: inputs, series: series, weight: weight, profileWeightKg: profileWeightKg, now: now)
            guard let template = d.template else { return Created(ok: false, error: "invalid") }
            let reason = riskReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            if d.safety?.requiresReason == true, reason?.isEmpty != false {
                return Created(ok: false, error: "riskReason")
            }
            let replace = replacing.flatMap(UUID.init(uuidString:))
            return try await CoreGoalState.change(store: reader.store) { context in
                if replace == nil, !keepBoth,
                   let existing = d.sameMeasureGoal(template, goals: context.goals, periods: context.periods) {
                    return Created(ok: false, error: "sameMeasure", existingId: existing.id.uuidString,
                                   existingTitle: existing.title)
                }
                if replace == nil, !context.goals.hasRoom() { return Created(ok: false, error: "limitReached") }
                let ack: CoachGoal.RiskAcknowledgement? = d.safety?.requiresReason == true
                    ? CoachGoalRisk.acknowledgement(verdict: d.safety?.verdict.rawValue ?? "veryAggressive",
                                                    reason: reason ?? "")
                    : nil
                guard let id = d.commit(goals: context.goals, periods: context.periods, replacing: replace,
                                        acknowledgedRisk: ack) else { return Created(ok: false, error: "invalid") }
                return Created(ok: true, goalId: id.uuidString)
            }
        } catch {
            return Created(ok: false, error: "conflict")
        }
    }

    /// The long-term page's lifecycle actions: "pause" (with a `CoachGoal.PauseReason`), "resume", "setAside" and
    /// "remove"; the weekly and monthly goals that serve it follow, as on Apple.
    @MainActor
    public static func change(store: WhoopStore, id: String, action: String, reason: String?,
                              now: Date = Date()) async -> CoreGoals.Change {
        guard let uuid = UUID(uuidString: id) else { return CoreGoals.Change(ok: false, error: "invalid") }
        do {
            return try await CoreGoalState.change(store: store) { context in
                guard context.goals.goal(id: uuid) != nil else { return CoreGoals.Change(ok: false, error: "missing") }
                switch action {
                case "pause":
                    context.goals.pause(uuid, reason: CoachGoal.PauseReason(rawValue: reason ?? "") ?? .other, on: now)
                case "resume": context.goals.resume(uuid, on: now)
                case "setAside": context.goals.setAside(uuid, reason: reason ?? "", on: now)
                case "remove": context.goals.remove(uuid)
                default: return CoreGoals.Change(ok: false, error: "invalid")
                }
                return CoreGoals.Change(ok: true, error: nil)
            }
        } catch {
            return CoreGoals.Change(ok: false, error: "conflict")
        }
    }

    // MARK: State

    private static func draft(_ s: State, inputs: PeriodGoalInputs, series: [LongTermMetric: [GoalMilestones.Sample]],
                              weight: Double?, profileWeightKg: Double, now: Date) -> LongTermGoalDraft {
        LongTermGoalDraft(
            template: s.template.flatMap(GoalTemplateID.init(rawValue:)).flatMap(GoalCatalog.template),
            sportIndex: s.sportIndex, target: s.target, baseline: s.baseline,
            countFromYearStart: s.countFromYearStart,
            endDate: s.endDate > 0 ? Date(timeIntervalSince1970: s.endDate) : now, hasDate: s.hasDate,
            targetDate: s.targetDate > 0 ? Date(timeIntervalSince1970: s.targetDate) : now,
            openEnded: s.openEnded, fixedWeeks: s.fixedWeeks, weeklyOn: s.weeklyOn, weeklyTarget: s.weeklyTarget,
            weeklyChoice: LongTermGoalDraft.WeeklyChoice(rawValue: s.weeklyChoice) ?? .workouts,
            title: s.title, motivation: s.motivation, threshold: s.threshold, band: s.band,
            habitKey: s.habitKey, habitWantsYes: s.habitWantsYes, inputs: inputs, series: series,
            currentWeight: weight, profileWeightKg: profileWeightKg, now: now,
            calendar: TrainingPreferences.weekCalendar)
    }

    private static func output(_ d: LongTermGoalDraft) -> Draft {
        let state = State(template: d.template?.id.rawValue, sportIndex: d.sportIndex, target: d.target,
            baseline: d.baseline, countFromYearStart: d.countFromYearStart,
            endDate: d.endDate.timeIntervalSince1970, hasDate: d.hasDate,
            targetDate: d.targetDate.timeIntervalSince1970, openEnded: d.openEnded, fixedWeeks: d.fixedWeeks,
            weeklyOn: d.weeklyOn, weeklyTarget: d.weeklyTarget, weeklyChoice: d.weeklyChoice.rawValue,
            title: d.title, motivation: d.motivation, threshold: d.threshold, band: d.band, habitKey: d.habitKey,
            habitWantsYes: d.habitWantsYes)
        let weekly = d.weeklyDraft(parentId: UUID())
        return Draft(state: state, shape: d.shape?.rawValue, metric: d.metric.map { "\($0)" },
                     weeklyMetric: d.weeklyMetric?.rawValue, currentLevel: d.currentLevel,
                     collectedSoFar: d.collectedSoFar, hasMeasuredStart: d.hasMeasuredStart,
                     levelStep: d.levelStep.step, levelLow: d.levelStep.range.lowerBound,
                     levelHigh: d.levelStep.range.upperBound, perWeekStep: d.perWeekStep.step,
                     perWeekLow: d.perWeekStep.range.lowerBound, perWeekHigh: d.perWeekStep.range.upperBound,
                     sumStep: d.sumStep(d.target), weeklyMetricOfGoal: weekly?.metric.rawValue,
                     risky: d.safety?.warning != nil, requiresReason: d.safety?.requiresReason == true,
                     rate: d.safety?.rateDescription)
    }
}
