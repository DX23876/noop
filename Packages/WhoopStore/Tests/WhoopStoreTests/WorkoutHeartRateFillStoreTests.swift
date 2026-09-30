import XCTest
@testable import WhoopStore

/// v73: the heart rate NOOP fills into a workout lives beside the row, survives the source rewriting the
/// row, and is replaced per key; Health steps ride on the source metadata; and a trace that arrives later
/// frees exactly the cardio-load rows that were priced without one.
final class WorkoutHeartRateFillStoreTests: XCTestCase {

    private func fill(_ key: WorkoutKey, avg: Int = 120, source: String = "watch") -> WorkoutHeartRateFillRow {
        WorkoutHeartRateFillRow(key: key, avgHr: avg, maxHr: avg + 20, strain: 30, hrSource: source,
                                restingHrUsed: 62, coveredMinutes: 40, possibleMinutes: 45, updatedAtTs: 1)
    }

    func testFillsSurviveTheSourceRewritingTheRowAndAreReplacedPerKey() async throws {
        let store = try await WhoopStore.inMemory()
        let row = WorkoutRow(startTs: 1_000, endTs: 3_700, sport: "Walking", source: "apple-health",
                             durationS: 2_700, energyKcal: 300, avgHr: nil, maxHr: nil, strain: nil,
                             distanceM: 3_000, zonesJSON: nil, notes: nil, steps: nil)
        try await store.upsertWorkouts([row], deviceId: "apple-health")
        let a = WorkoutKey(deviceId: "apple-health", startTs: 1_000, sport: "Walking")
        let b = WorkoutKey(deviceId: "apple-health", startTs: 9_000, sport: "Walking")
        try await store.replaceWorkoutHeartRateFills([fill(a), fill(b, avg: 110)], keys: [a, b])
        // The next sync writes the row again, still without heart rate.
        try await store.upsertWorkouts([row], deviceId: "apple-health")

        var fills = try await store.workoutHeartRateFills(deviceId: "apple-health", from: 0, to: 10_000)
        XCTAssertEqual(fills[a]?.avgHr, 120)
        XCTAssertEqual(fills[a]?.hrSource, "watch")
        XCTAssertEqual(fills[b]?.avgHr, 110)

        // Re-filling `a` alone, now without a covering trace, removes its fill and leaves `b` alone.
        try await store.replaceWorkoutHeartRateFills([], keys: [a])
        fills = try await store.workoutHeartRateFills(deviceId: "apple-health", from: 0, to: 10_000)
        XCTAssertNil(fills[a])
        XCTAssertEqual(fills[b]?.avgHr, 110)
    }

    func testMetadataCarriesHealthSteps() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertWorkoutSourceMetadata([
            WorkoutSourceMetadataRow(componentKey: "apple-health|x", source: "apple-health", startTs: 1_000,
                                     sport: "Walking", externalId: "x", sourceBundleId: "com.apple.Fitness",
                                     rawActivityType: 52, activitiesJSON: nil, updatedAtTs: 1, steps: 4_321),
        ])
        let rows = try await store.workoutSourceMetadata(from: 0, to: 2_000)
        XCTAssertEqual(rows.first?.steps, 4_321)
    }

    func testOnlyUntracedLedgerRowsAreDropped() async throws {
        let store = try await WhoopStore.inMemory()
        func load(_ id: String, start: Int, source: String) -> TrainingSessionLoadRow {
            TrainingSessionLoadRow(sessionId: id, method: "banister-hrr", methodVersion: 1, startTs: start,
                                   endTs: start + 1_800, trimp: source == "none" ? nil : 40, effort: nil,
                                   hrSource: source, coveredMinutes: 0, possibleMinutes: 30, hrmaxUsed: 190,
                                   restingHrUsed: 60, inputFingerprint: id, computedAtTs: 1)
        }
        try await store.upsertTrainingSessionLoads([
            load("none", start: 1_000, source: "none"),
            load("avg", start: 2_000, source: "avg_hr"),
            load("band", start: 3_000, source: "noop_band"),
            load("later", start: 90_000, source: "none"),
        ])
        let dropped = try await store.dropUntracedTrainingSessionLoads(from: 0, to: 10_000)
        XCTAssertEqual(dropped, 2)
        let left = try await store.trainingSessionLoads(from: 0, to: Int.max, method: "banister-hrr",
                                                        methodVersion: 1)
        XCTAssertEqual(Set(left.map(\.sessionId)), ["band", "later"])
    }
}
