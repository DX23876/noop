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
        case "weight.deleteEvent":
            let id = args["id"] as? String ?? ""
            return await change(store: store) { $0.events.removeAll { $0.id == id } }
        default:
            return nil
        }
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
