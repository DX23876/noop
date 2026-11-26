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
}
