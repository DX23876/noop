import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

// WeightTrackerPreparation.swift — the weight page's inputs, gathered once for the Apple app and the Android core
// (owner decisions 2026-11-26). The derivation is `WeightTracker` (StrandAnalytics); this file only reads the
// weigh-ins, the weight goal, the diet plan's pace and the wearer's settings and events, so a page, a widget and
// the coach cannot each assemble a different picture of the same body.

@MainActor
enum WeightTrackerPreparation {
    /// How far back the page reads: every weigh-in the yearly reports need, which is a few hundred rows a year.
    nonisolated static let historyDays = 4_000

    /// NOOP's weigh-ins (with ids and notes) over the phone's health store, newest first.
    static func entries(store: WhoopStore, reader: StoreReader, days: Int = historyDays, now: Date = Date()) async -> [WeightEntry] {
        let from = StoreReader.localDayKey(now.addingTimeInterval(-Double(days) * 86_400))
        let to = StoreReader.localDayKey(now.addingTimeInterval(86_400))
        let manual = (try? await store.bodyWeights(deviceId: WhoopStore.noopWeightSourceId, from: from, to: to)) ?? []
        // A phone has Apple Health or Health Connect; both stand in the same tier under a manual weigh-in.
        async let apple = reader.series(key: WhoopStore.bodyWeightMetricKey, source: MetricResolver.appleHealthSource,
                                        from: from, to: to, suppressedSleepWakeDays: [])
        async let connect = reader.series(key: WhoopStore.bodyWeightMetricKey, source: MetricResolver.healthConnectSource,
                                          from: from, to: to, suppressedSleepWakeDays: [])
        let imported = (await apple + connect).map { (day: $0.day, value: $0.value) }
        return WeightSeries.mergeEntries(manual: manual, appleHealth: imported)
    }

    /// The entries as dated readings. An imported day has no instant; it stands at local noon of its day.
    static func readings(_ entries: [WeightEntry]) -> [WeightTracker.Reading] {
        entries.compactMap { e in
            guard let date = e.takenAt ?? WeightSeries.date(forDay: e.day)?.addingTimeInterval(12 * 3_600) else { return nil }
            return WeightTracker.Reading(date: date, kg: e.value, note: e.note, id: e.isEditable ? e.id : nil,
                                         source: e.source == .manual ? "noop" : "health")
        }
    }

    /// The active weight goal, else the diet plan's goal weight: one goal weight for both (F26). The plan's own
    /// value stands in only while no weight goal exists.
    static func goal(goals: CoachGoalStore, plan: DietPlan?) -> WeightTracker.Goal? {
        if let g = goals.activeGoals.first(where: { $0.kind == .weight }), let target = g.target {
            let baseline = g.baseline ?? target
            return WeightTracker.Goal(baseline: baseline, target: target, createdAt: g.createdAt, targetDate: g.targetDate,
                                      band: g.measure?.band, storedMilestones: g.milestones.map(\.value))
        }
        guard let plan, plan.goal == .lose || plan.goal == .gain, let target = plan.goalWeightKg,
              let start = WeightSeries.date(forDay: plan.startDay) else { return nil }
        return WeightTracker.Goal(baseline: plan.startWeightKg, target: target, createdAt: start)
    }

    /// The diet plan's pace in kg a week, signed: its percent of body weight in the plan's direction. Nil without a
    /// plan that moves the weight.
    static func planKgPerWeek(_ plan: DietPlan?, currentKg: Double) -> Double? {
        guard let plan, currentKg > 0 else { return nil }
        switch plan.goal {
        case .lose: return -plan.pacePercent / 100 * currentKg
        case .gain: return plan.pacePercent / 100 * currentKg
        case .maintain, .recomp: return nil
        }
    }

    // MARK: One goal weight (F26)

    /// The plan as the screens read it: a plan that moves the weight takes the weight goal's target as its goal
    /// weight, so the plan and the goal cannot name two different weights. Only a goal pointing the plan's way
    /// counts; a maintain goal and a goal on the wrong side of the plan's start leave the plan's own value.
    static func planWithGoalWeight(_ plan: DietPlan?, goals: CoachGoalStore) -> DietPlan? {
        guard var plan, plan.goal == .lose || plan.goal == .gain,
              let goal = goals.activeGoals.first(where: { $0.kind == .weight }), goal.measure?.band == nil,
              let target = goal.target else { return plan }
        guard plan.goal == .lose ? target < plan.startWeightKg : target > plan.startWeightKg else { return plan }
        plan.goalWeightKg = target
        return plan
    }

    /// A plan saved with a goal weight sets the weight goal: it moves the target of the active one, or creates one
    /// when there is none and a goal slot is free.
    static func adoptPlanGoal(_ plan: DietPlan?, goals: CoachGoalStore, now: Date = Date()) {
        guard let plan, plan.goal == .lose || plan.goal == .gain, let target = plan.goalWeightKg else { return }
        if var goal = goals.activeGoals.first(where: { $0.kind == .weight }) {
            guard goal.measure?.band == nil, goal.target.map({ abs($0 - target) > 0.05 }) ?? true else { return }
            goal.target = target
            goals.commit(goal, editingId: goal.id)
        } else {
            guard goals.canAdd(kind: .weight) == nil else { return }
            let template = GoalCatalog.template(plan.goal == .lose ? .weightLose : .weightGain)
            goals.commit(CoachGoal(kind: .weight, title: template?.title.localizedCatalogValue ?? "Weight",
                                   baseline: plan.startWeightKg, target: target, createdAt: now,
                                   templateId: template?.id.rawValue))
        }
    }

    /// A local day key, yyyy-MM-dd, for an event's date.
    nonisolated static func dayKey(_ date: Date) -> String { StoreReader.localDayKey(date) }

    static func stored(_ prefs: any GoalPreferenceStorage) -> WeightTracker.Stored {
        WeightTracker.Stored.decode(prefs.string(forKey: WeightTracker.storageKey))
    }

    static func save(_ stored: WeightTracker.Stored, to prefs: any GoalPreferenceStorage) {
        prefs.set(stored.encoded(), forKey: WeightTracker.storageKey)
    }

    /// Everything the page shows, from the store, the goals, the plan and the stored settings.
    static func snapshot(store: WhoopStore, reader: StoreReader, goals: CoachGoalStore, prefs: any GoalPreferenceStorage,
                         plan: DietPlan?, now: Date = Date(), calendar: Calendar = .current) async -> WeightTracker.Snapshot? {
        let entries = await entries(store: store, reader: reader, now: now)
        return snapshot(entries: entries, goals: goals, prefs: prefs, plan: plan, now: now, calendar: calendar)
    }

    static func snapshot(entries: [WeightEntry], goals: CoachGoalStore, prefs: any GoalPreferenceStorage, plan: DietPlan?,
                         now: Date = Date(), calendar: Calendar = .current) -> WeightTracker.Snapshot? {
        let readings = readings(entries)
        let stored = stored(prefs)
        let latest = readings.max(by: { $0.date < $1.date })?.kg ?? 0
        return WeightTracker.snapshot(.init(readings: readings, goal: goal(goals: goals, plan: plan),
                                            planKgPerWeek: planKgPerWeek(plan, currentKg: latest), settings: stored.settings,
                                            events: stored.events, now: now, calendar: calendar))
    }

    // MARK: Coach

    /// What the coach is told about the scale (only when the coach is on, like every other block): the trend and
    /// its rates, the forecast as arithmetic on the chosen rate, the milestones and the wearer's dates. It is told
    /// never to turn these into a diet or a calorie target of its own.
    static func coachLines(_ s: WeightTracker.Snapshot, now: Date = Date()) -> String {
        func kg(_ v: Double) -> String { String(format: "%.1f kg", v) }
        func signed(_ v: Double) -> String { String(format: "%+.1f", v) }
        let age = max(0, Int(now.timeIntervalSince(s.latest.date) / 86_400))
        var lines = ["Weight trend \(kg(s.trendKg))\(s.trendSettled ? "" : " (still settling)"); latest weigh-in \(kg(s.latest.kg)), \(age)d ago."]
        let changes = s.changes.map { "\($0.days.map { "\($0)d" } ?? "since start") \(signed($0.kg))" }
        if !changes.isEmpty { lines.append("Trend change: " + changes.joined(separator: ", ") + " kg.") }
        var rates: [String] = []
        if let r = s.rates.currentKgPerWeek { rates.append("current \(signed(r)) kg/week") }
        if let r = s.rates.overallKgPerWeek { rates.append("overall \(signed(r)) kg/week") }
        if let r = s.rates.wishKgPerWeek {
            rates.append("planned \(signed(r)) kg/week (\(s.rates.wishSource?.rawValue ?? "plan")\(s.rates.wishIsSteep ? ", steep" : ""))")
        }
        if !rates.isEmpty { lines.append("Rates: " + rates.joined(separator: "; ") + ".") }
        if let goal = s.goal {
            let date = s.forecast.targetDate.map { StoreReader.localDayKey($0) }
            let state: String = switch s.forecast.state {
            case .arriving: "reaches it around \(date ?? "?") at the \(s.forecast.rateMode.rawValue) rate"
            case .reached: "reached on the trend"
            case .movingAway: "the \(s.forecast.rateMode.rawValue) rate points away from it, so no date"
            case .tooSlow: "the rate is too slow for a useful date"
            case .notEnoughData: "too few weigh-ins for a rate"
            case .withinBand: "inside the band"
            case .outsideBand: "outside the band"
            case .noGoal: ""
            }
            lines.append("Weight goal \(kg(goal.target)): \(state).")
        }
        if let m = s.milestones {
            lines.append("Milestones: \(m.reachedCount) of \(m.route.count) reached\(m.next.map { ", next \(kg($0))" } ?? "").")
        }
        let upcoming = s.events.filter { $0.phase == .upcoming }.prefix(3).map { e in
            "\(e.event.name) on \(e.event.day) (in \(e.daysAway) days)\(e.predictedKg.map { ": expected \(kg($0))" } ?? "")"
        }
        if !upcoming.isEmpty { lines.append("Dates the wearer set: " + upcoming.joined(separator: "; ") + ".") }
        lines.append("Forecasts are arithmetic on one rate, not promises. Never derive a diet or a calorie target from them.")
        return lines.joined(separator: "\n")
    }
}
