import Foundation
import XCTest
import StrandCore
import WhoopStore
@testable import NoopCore

/// The Android goal operations (parity plan 1.2): a goal added through the core is measured from the store by the
/// shared loader and engine, and the detail page's actions change it in the persisted image.
@MainActor
final class CoreGoalsTests: XCTestCase {
    private let settings = CoreGoals.Settings(profileSex: "male", lastSync: nil, agelessEnabled: false,
                                              dismissedWorkoutSpans: [])

    func testAddedWeeklyGoalCountsTheStoredWorkoutsOfThisWeek() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let now = Date()
        let start = Int(now.timeIntervalSince1970) - 60
        _ = try await store.upsertWorkouts([WorkoutRow(startTs: start - 3_600, endTs: start, sport: "Running",
            source: "my-whoop", durationS: 3_600, energyKcal: nil, avgHr: 140, maxHr: 170, strain: 10,
            distanceM: 8_000, zonesJSON: nil, notes: nil, steps: nil)], deviceId: "my-whoop")

        let added = await CoreGoals.addPeriodGoal(store: store, metric: "workouts", period: "week", target: 3,
                                                  threshold: nil, now: now)
        XCTAssertTrue(added.ok)
        let duplicate = await CoreGoals.addPeriodGoal(store: store, metric: "workouts", period: "week", target: 4,
                                                      threshold: nil, now: now)
        XCTAssertEqual(duplicate.error, "duplicate")

        let output = try await CoreGoals.snapshot(reader: reader, settings: settings, now: now)
        let goal = try XCTUnwrap(output.period.first)
        XCTAssertEqual(output.period.count, 1)
        XCTAssertEqual(goal.metric, "workouts")
        XCTAssertEqual(goal.periodTarget, 3, accuracy: 3)
        XCTAssertEqual(goal.current, 1)
        XCTAssertEqual(goal.counted.count, 1)

        // The answer Kotlin parses (`CoreGoalsTest`): the dates and ids change per run, so the pin compares the
        // shape, every key at every level; NOOP_UPDATE_TRAINING_FIXTURES=1 rewrites the file.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let file = root.appendingPathComponent("android/app/src/test/resources/goals/snapshot.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(output)
        if ProcessInfo.processInfo.environment["NOOP_UPDATE_TRAINING_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        func shape(_ value: Any) -> Any {
            if let object = value as? [String: Any] { return object.mapValues(shape) as NSDictionary }
            if let array = value as? [Any] { return (array.first.map { [shape($0)] } ?? []) as NSArray }
            return "value"
        }
        let pinned = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        XCTAssertEqual(shape(try JSONSerialization.jsonObject(with: data)) as? NSDictionary, shape(pinned) as? NSDictionary)
    }

    func testDetailActionsChangeThePersistedGoal() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        _ = await CoreGoals.addPeriodGoal(store: store, metric: "trainingMinutes", period: "month", target: 600,
                                          threshold: nil)
        var output = try await CoreGoals.snapshot(reader: reader, settings: settings)
        let id = try XCTUnwrap(output.period.first?.id)

        let retarget = await CoreGoals.changePeriodGoal(store: store, id: id, action: "setTarget", target: 720,
                                                        reason: nil)
        let pause = await CoreGoals.changePeriodGoal(store: store, id: id, action: "pause", target: nil,
                                                     reason: "travel")
        XCTAssertTrue(retarget.ok)
        XCTAssertTrue(pause.ok)
        output = try await CoreGoals.snapshot(reader: reader, settings: settings)
        XCTAssertEqual(output.period.first?.target, 720)
        XCTAssertEqual(output.period.first?.status, "paused")

        let removal = await CoreGoals.changePeriodGoal(store: store, id: id, action: "remove", target: nil,
                                                       reason: nil)
        XCTAssertTrue(removal.ok)
        output = try await CoreGoals.snapshot(reader: reader, settings: settings)
        XCTAssertTrue(output.period.isEmpty)
        let resumeRemoved = await CoreGoals.changePeriodGoal(store: store, id: id, action: "resume", target: nil,
                                                             reason: nil)
        XCTAssertFalse(resumeRemoved.ok)
    }

    func testSetupOffersEveryMetricWithItsRanges() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let setup = try await CoreGoals.setup(reader: reader, settings: settings)
        XCTAssertEqual(setup.metrics.count, PeriodMetric.allCases.count)
        let workouts = try XCTUnwrap(setup.metrics.first { $0.metric == "workouts" })
        XCTAssertLessThanOrEqual(workouts.weekLow, workouts.weekDefault)
        XCTAssertGreaterThanOrEqual(workouts.weekHigh, workouts.weekDefault)
        XCTAssertEqual(setup.openCount, 0)
    }
}
