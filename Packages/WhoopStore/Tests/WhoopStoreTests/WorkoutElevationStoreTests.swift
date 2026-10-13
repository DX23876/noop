import XCTest
@testable import WhoopStore

/// v78: a workout's elevation lives beside the row, survives the source rewriting the row, is upserted per
/// key, and goes when the workout is deleted.
final class WorkoutElevationStoreTests: XCTestCase {

    private let row = WorkoutRow(startTs: 1_000, endTs: 3_700, sport: "Walking", source: "apple-health",
                                 durationS: 2_700, energyKcal: 300, avgHr: nil, maxHr: nil, strain: nil,
                                 distanceM: 3_000, zonesJSON: nil, notes: nil, steps: nil)

    func testElevationSurvivesTheSourceRewritingTheRowAndIsUpsertedPerKey() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertWorkouts([row], deviceId: "apple-health")
        let a = WorkoutKey(deviceId: "apple-health", startTs: 1_000, sport: "Walking")
        let b = WorkoutKey(deviceId: "manual", startTs: 9_000, sport: "Running")
        try await store.upsertWorkoutElevations([
            WorkoutElevationRow(key: a, ascentM: 42, descentM: nil, source: "apple-health", updatedAtTs: 1),
            WorkoutElevationRow(key: b, ascentM: 12, descentM: 9, source: "barometer", updatedAtTs: 1),
        ])
        try await store.upsertWorkouts([row], deviceId: "apple-health")

        var rows = try await store.workoutElevations(from: 0, to: 10_000)
        XCTAssertEqual(rows[a]?.ascentM, 42)
        XCTAssertNil(rows[a]?.descentM)
        XCTAssertEqual(rows[b]?.descentM, 9)
        XCTAssertEqual(rows[b]?.source, "barometer")

        try await store.upsertWorkoutElevations([
            WorkoutElevationRow(key: a, ascentM: 45, descentM: 44, source: "apple-health", updatedAtTs: 2),
        ])
        rows = try await store.workoutElevations(from: 0, to: 10_000)
        XCTAssertEqual(rows[a]?.ascentM, 45)
        XCTAssertEqual(rows[a]?.descentM, 44)
        XCTAssertEqual(rows[b]?.ascentM, 12)
        let later = try await store.workoutElevations(from: 2_000, to: 10_000)
        XCTAssertEqual(later.count, 1)
    }

    func testInvalidHeightsAreNotStored() async throws {
        let store = try await WhoopStore.inMemory()
        let key = WorkoutKey(deviceId: "manual", startTs: 1, sport: "Walking")
        try await store.upsertWorkoutElevations([
            WorkoutElevationRow(key: key, ascentM: .nan, descentM: nil, source: "barometer", updatedAtTs: 1),
            WorkoutElevationRow(key: key, ascentM: 3, descentM: -1, source: "barometer", updatedAtTs: 1),
        ])
        let stored = try await store.workoutElevations(from: 0, to: 10)
        XCTAssertTrue(stored.isEmpty)
    }

    func testDeletingTheWorkoutDeletesItsElevation() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertWorkouts([row], deviceId: "apple-health")
        let key = WorkoutKey(deviceId: "apple-health", startTs: 1_000, sport: "Walking")
        try await store.upsertWorkoutElevations([
            WorkoutElevationRow(key: key, ascentM: 42, descentM: 40, source: "apple-health", updatedAtTs: 1),
        ])
        try await store.deleteWorkouts(deviceId: "apple-health", sport: "Walking", from: 0, to: 2_000)
        var stored = try await store.workoutElevations(from: 0, to: 10_000)
        XCTAssertTrue(stored.isEmpty)

        try await store.upsertWorkoutElevations([
            WorkoutElevationRow(key: key, ascentM: 42, descentM: 40, source: "apple-health", updatedAtTs: 1),
        ])
        try await store.deleteWorkoutElevation(key)
        stored = try await store.workoutElevations(from: 0, to: 10_000)
        XCTAssertTrue(stored.isEmpty)
    }

    func testResolverPrefersTheRowsOwnSourceThenBarometer() {
        func entry(_ device: String, _ source: String, _ ascent: Double, start: Int = 100) -> WorkoutElevationRow {
            WorkoutElevationRow(key: WorkoutKey(deviceId: device, startTs: start, sport: "Walking"),
                                ascentM: ascent, descentM: nil, source: source, updatedAtTs: 1)
        }
        let rows = Dictionary(uniqueKeysWithValues: [
            entry("strap", WorkoutElevationSource.barometer, 30),
            entry("apple-health", WorkoutElevationSource.appleHealth, 42),
            entry("activity-file", WorkoutElevationSource.file, 50),
            entry("strap", WorkoutElevationSource.barometer, 99, start: 200),
        ].map { ($0.key, $0) })
        XCTAssertEqual(WorkoutElevationRow.resolve(startTs: 100, sport: "Walking", rowSource: "apple-health",
                                                   in: rows)?.ascentM, 42)
        XCTAssertEqual(WorkoutElevationRow.resolve(startTs: 100, sport: "Walking", rowSource: "activity-file",
                                                   in: rows)?.ascentM, 50)
        XCTAssertEqual(WorkoutElevationRow.resolve(startTs: 100, sport: "Walking", rowSource: "manual",
                                                   in: rows)?.ascentM, 30)
        XCTAssertNil(WorkoutElevationRow.resolve(startTs: 100, sport: "Running", rowSource: "manual", in: rows))
        let onlyHealth = rows.filter { $0.value.source == WorkoutElevationSource.appleHealth }
        XCTAssertEqual(WorkoutElevationRow.resolve(startTs: 100, sport: "Walking", rowSource: "manual",
                                                   in: onlyHealth)?.ascentM, 42)
    }
}
