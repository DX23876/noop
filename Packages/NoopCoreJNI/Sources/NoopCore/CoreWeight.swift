import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// The weight page on Android (owner decisions 2026-11-26): the same `WeightTracker` snapshot the Apple app
/// shows, read over the goals' transaction image so the goal, the settings and the events are the stored ones.
/// Settings and events are written through `CoreGoalState.change`, so they land in the goal preferences and the
/// goals backup carries them.
@MainActor
enum CoreWeight {
    struct Output: Encodable {
        var snapshot: WeightTracker.Snapshot?
        var settings: WeightTracker.Settings
        var events: [WeightTracker.Event]
        /// Where the goal came from: "goal", "dietPlan" or nil without one.
        var goalSource: String?
    }

    static func run(_ op: String, _ args: [String: Any], store: WhoopStore, reader: StoreReader) async -> String? {
        switch op {
        case "weight.snapshot":
            let plan = DietPlan.decode(args["plan"] as? String)
            let entries = await WeightTrackerPreparation.entries(store: store, reader: reader)
            do {
                let output = try await CoreGoalState.read(store: store) { ctx -> Output in
                    let stored = WeightTrackerPreparation.stored(ctx.preferences)
                    let hasGoal = ctx.goals.activeGoals.contains { $0.kind == .weight && $0.target != nil }
                    let goal = WeightTrackerPreparation.goal(goals: ctx.goals, plan: plan)
                    return Output(snapshot: WeightTrackerPreparation.snapshot(entries: entries, goals: ctx.goals,
                                                                              prefs: ctx.preferences, plan: plan),
                                  settings: stored.settings, events: stored.events,
                                  goalSource: goal == nil ? nil : (hasGoal ? "goal" : "dietPlan"))
                }
                return encode(output)
            } catch {
                return #"{"error":"goalState"}"#
            }
        case "weight.saveSettings":
            guard let raw = args["settings"] as? String, let data = raw.data(using: .utf8),
                  let settings = try? JSONDecoder().decode(WeightTracker.Settings.self, from: data) else {
                return #"{"error":"invalid"}"#
            }
            return await change(store: store) { $0.settings = settings }
        case "weight.saveEvent":
            let name = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let day = args["day"] as? String ?? ""
            guard !name.isEmpty, day.count == 10 else { return #"{"error":"invalid"}"# }
            let id = (args["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return await change(store: store) { stored in
                if let id, let i = stored.events.firstIndex(where: { $0.id == id }) {
                    stored.events[i].name = name
                    stored.events[i].day = day
                } else {
                    stored.events.append(.init(name: name, day: day))
                }
            }
        case "weight.adoptPlanGoal":
            // A plan saved with a goal weight moves the weight goal, or creates one (one goal weight, F26).
            let plan = DietPlan.decode(args["plan"] as? String)
            do {
                try await CoreGoalState.change(store: store) { ctx in WeightTrackerPreparation.adoptPlanGoal(plan, goals: ctx.goals) }
                return #"{"ok":true}"#
            } catch {
                return #"{"ok":false}"#
            }
        case "weight.nextReminder":
            // The daily weigh-in reminder's next moment (shared rule `WeightTracker.reminderTimes`): the chosen
            // weekdays, and a day that already has a NOOP weigh-in stays quiet.
            let now = Date(timeIntervalSince1970: (args["now"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970)
            let weekdays = Set(((args["weekdays"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue })
            let weighed = await weighedDays(store: store, now: now)
            let next = WeightTracker.reminderTimes(after: now, minutes: (args["minutes"] as? NSNumber)?.intValue ?? 7 * 60,
                                                   weekdays: weekdays, weighedInDays: weighed).first
            return next.map { #"{"at":\#(Int($0.timeIntervalSince1970))}"# } ?? #"{"at":null}"#
        case "weight.weighedToday":
            let today = StoreReader.localDayKey(Date())
            return await weighedDays(store: store, now: Date()).contains(today) ? #"{"weighed":true}"# : #"{"weighed":false}"#
        case "weight.linkedPlan":
            guard let plan = DietPlan.decode(args["plan"] as? String) else { return "null" }
            return await linkedPlan(plan, store: store).encoded() ?? "null"
        case "weight.updateWeight":
            // An edit keeps the row's id, as Apple's `updateWeight`: the same weigh-in with a new value, instant or
            // note, re-projected onto its (possibly new) day.
            guard let id = args["id"] as? String, !id.isEmpty, let kg = (args["kg"] as? NSNumber)?.doubleValue,
                  GoalMeasure.isPlausible(kg, cfg: GoalMeasure.weightTrend) else { return #"{"ok":false}"# }
            let at = Date(timeIntervalSince1970: (args["takenAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970)
            let note = (args["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // As Apple's `updateWeight`: the row keeps its source (a coach weigh-in stays the coach's), and it is
            // deleted then written again, because the natural key carries the instant and the delete re-projects
            // the day being left behind.
            guard let existing = (try? await store.bodyWeights(deviceId: WhoopStore.noopWeightSourceId))?
                .first(where: { $0.id == id }) else { return #"{"ok":false}"# }
            _ = try? await store.deleteBodyWeight(id: id)
            let row = BodyWeightRow(id: id, deviceId: WhoopStore.noopWeightSourceId, day: StoreReader.localDayKey(at),
                                    takenAt: Int(at.timeIntervalSince1970), weightKg: kg, source: existing.source, note: note)
            return (try? await store.upsertBodyWeights([row])) != nil ? #"{"ok":true}"# : #"{"ok":false}"#
        case "weight.deleteEvent":
            let id = args["id"] as? String ?? ""
            return await change(store: store) { $0.events.removeAll { $0.id == id } }
        default:
            return nil
        }
    }

    /// Days of the last and the next day with a weigh-in logged in NOOP.
    private static func weighedDays(store: WhoopStore, now: Date) async -> Set<String> {
        let from = StoreReader.localDayKey(now.addingTimeInterval(-86_400))
        let to = StoreReader.localDayKey(now.addingTimeInterval(86_400))
        let rows = (try? await store.bodyWeights(deviceId: WhoopStore.noopWeightSourceId, from: from, to: to)) ?? []
        return Set(rows.map(\.day))
    }

    /// The plan with the weight goal's target as its goal weight; the plan unchanged when the goals cannot be read.
    static func linkedPlan(_ plan: DietPlan, store: WhoopStore) async -> DietPlan {
        let linked = try? await CoreGoalState.read(store: store) { ctx in
            WeightTrackerPreparation.planWithGoalWeight(plan, goals: ctx.goals)
        }
        return (linked ?? plan) ?? plan
    }

    private static func change(store: WhoopStore, _ body: @escaping (inout WeightTracker.Stored) -> Void) async -> String {
        do {
            try await CoreGoalState.change(store: store) { ctx in
                var stored = WeightTrackerPreparation.stored(ctx.preferences)
                body(&stored)
                WeightTrackerPreparation.save(stored, to: ctx.preferences)
            }
            return #"{"ok":true}"#
        } catch {
            return #"{"ok":false}"#
        }
    }

    /// Dates as unix seconds, keys sorted, as the Kotlin side reads them.
    nonisolated static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}
