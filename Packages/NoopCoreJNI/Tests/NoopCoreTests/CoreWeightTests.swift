import Foundation
import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

/// Android's weight page reads the same snapshot the Apple app shows, with the stored goal, settings and events;
/// settings and events land in the goal preferences, which the goals backup carries.
@MainActor
final class CoreWeightTests: XCTestCase {
    private func seeded() async throws -> (WhoopStore, StoreReader) {
        let store = try await WhoopStore.inMemory()
        let now = Int(Date().timeIntervalSince1970)
        let rows = (0..<40).map { i -> BodyWeightRow in
            let at = now - (39 - i) * 86_400
            return BodyWeightRow(id: "w\(i)", deviceId: WhoopStore.noopWeightSourceId,
                                 day: StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(at))),
                                 takenAt: at, weightKg: 100 - 0.1 * Double(i), source: "manual", note: i == 39 ? "after run" : nil)
        }
        _ = try await store.upsertBodyWeights(rows)
        return (store, StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: []))
    }

    private struct Out: Decodable {
        struct Snap: Decodable {
            struct Forecast: Decodable { var state: String; var rateKgPerWeek: Double? }
            struct Log: Decodable { struct R: Decodable { var note: String?; var id: String? }; var reading: R }
            struct Event: Decodable { struct E: Decodable { var name: String }; var event: E; var predictedKg: Double? }
            var trendKg: Double
            var forecast: Forecast
            var log: [Log]
            var events: [Event]
        }
        var snapshot: Snap?
        var goalSource: String?
        var events: [WeightTracker.Event]
    }

    private func read(_ store: WhoopStore, _ reader: StoreReader, plan: String? = nil) async throws -> Out {
        var args: [String: Any] = [:]
        if let plan { args["plan"] = plan }
        let answer = await CoreWeight.run("weight.snapshot", args, store: store, reader: reader)
        let json = try XCTUnwrap(answer)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(Out.self, from: Data(json.utf8))
    }

    func testTheSnapshotCarriesTheWeighInsTheGoalAndTheEvents() async throws {
        let (store, reader) = try await seeded()
        try await CoreGoalState.change(store: store) { ctx in
            ctx.goals.commit(CoachGoal(kind: .weight, title: "Weight", baseline: 100, target: 90,
                                           createdAt: Date().addingTimeInterval(-40 * 86_400)))
        }
        _ = await CoreWeight.run("weight.saveEvent", ["name": "Wedding", "day": StoreReader.localDayKey(Date().addingTimeInterval(30 * 86_400))],
                                 store: store, reader: reader)
        let out = try await read(store, reader)
        let snap = try XCTUnwrap(out.snapshot)
        XCTAssertEqual(out.goalSource, "goal")
        XCTAssertEqual(snap.forecast.state, "arriving")
        XCTAssertEqual(snap.log.first?.reading.note, "after run", "the newest weigh-in, with its note")
        XCTAssertEqual(snap.log.first?.reading.id, "w39", "NOOP's own weigh-in keeps its id for editing")
        XCTAssertEqual(snap.events.first?.event.name, "Wedding")
        XCTAssertNotNil(snap.events.first?.predictedKg)
    }

    func testTheDietPlanStandsInForAMissingWeightGoalAndGivesThePlannedRate() async throws {
        let (store, reader) = try await seeded()
        let start = StoreReader.localDayKey(Date().addingTimeInterval(-40 * 86_400))
        let plan = DietPlan(goal: .lose, pacePercent: 0.5, form: .balanced, goalWeightKg: 92, startDay: start, startWeightKg: 100)
        var settings = WeightTracker.Settings.standard
        settings.rateMode = .wish
        let encoded = String(data: try JSONEncoder().encode(settings), encoding: .utf8)!
        _ = await CoreWeight.run("weight.saveSettings", ["settings": encoded], store: store, reader: reader)
        let out = try await read(store, reader, plan: plan.encoded())
        XCTAssertEqual(out.goalSource, "dietPlan")
        let rate = try XCTUnwrap(out.snapshot?.forecast.rateKgPerWeek)
        XCTAssertEqual(rate, -0.5 / 100 * 96.1, accuracy: 0.05, "half a percent of the latest weigh-in a week")
    }

    func testEventsAreEditedAndDeletedInTheGoalPreferences() async throws {
        let (store, reader) = try await seeded()
        _ = await CoreWeight.run("weight.saveEvent", ["name": "Trip", "day": "2027-03-01"], store: store, reader: reader)
        var out = try await read(store, reader)
        let id = try XCTUnwrap(out.events.first?.id)
        _ = await CoreWeight.run("weight.saveEvent", ["id": id, "name": "Holiday", "day": "2027-03-02"], store: store, reader: reader)
        out = try await read(store, reader)
        XCTAssertEqual(out.events.map(\.name), ["Holiday"])
        XCTAssertEqual(out.events.first?.day, "2027-03-02")
        let raw = try await CoreGoalState.read(store: store) { $0.preferences.string(forKey: WeightTracker.storageKey) }
        XCTAssertNotNil(raw, "stored under goals., where the goals backup carries it")
        _ = await CoreWeight.run("weight.deleteEvent", ["id": id], store: store, reader: reader)
        out = try await read(store, reader)
        XCTAssertTrue(out.events.isEmpty)
        let invalid = await CoreWeight.run("weight.saveEvent", ["name": " ", "day": "2027-03-02"], store: store, reader: reader)
        XCTAssertEqual(invalid, #"{"error":"invalid"}"#)
    }

    /// One goal weight (F26): the plan reads the weight goal's target, and a plan saved with a goal weight sets it.
    func testThePlanAndTheWeightGoalShareOneGoalWeight() async throws {
        let (store, reader) = try await seeded()
        let plan = DietPlan(goal: .lose, pacePercent: 0.5, form: .balanced, goalWeightKg: 92, startDay: "2026-10-01",
                            startWeightKg: 100)
        _ = await CoreWeight.run("weight.adoptPlanGoal", ["plan": plan.encoded()!], store: store, reader: reader)
        var targets = try await CoreGoalState.read(store: store) { ctx in
            ctx.goals.activeGoals.filter { $0.kind == .weight }.map(\.target) }
        XCTAssertEqual(targets, [92], "a plan without a weight goal creates it")

        try await CoreGoalState.change(store: store) { ctx in
            var goal = ctx.goals.activeGoals.first { $0.kind == .weight }!
            goal.target = 88
            ctx.goals.commit(goal, editingId: goal.id)
        }
        let linked = await CoreWeight.linkedPlan(plan, store: store)
        XCTAssertEqual(linked.goalWeightKg, 88, "the plan reads the goal's target")

        var moved = plan
        moved.goalWeightKg = 90
        _ = await CoreWeight.run("weight.adoptPlanGoal", ["plan": moved.encoded()!], store: store, reader: reader)
        targets = try await CoreGoalState.read(store: store) { ctx in
            ctx.goals.activeGoals.filter { $0.kind == .weight }.map(\.target) }
        XCTAssertEqual(targets, [90], "the planner moves the one goal, it does not add a second")

        let gain = DietPlan(goal: .gain, pacePercent: 0.3, form: .balanced, goalWeightKg: 105, startDay: "2026-10-01",
                            startWeightKg: 100)
        let gainLinked = await CoreWeight.linkedPlan(gain, store: store)
        XCTAssertEqual(gainLinked.goalWeightKg, 105,
                       "a goal on the other side of the plan's start leaves the plan's own value")
    }
}
