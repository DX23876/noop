import XCTest
import GRDB
@testable import WhoopStore

final class WorkoutRecordingStoreTests: XCTestCase {
    func testRecordingFoldIncludesAllEarlierDevicesButNotFutureOrOtherSports() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveWorkoutRecording(row(start: 10), deviceId: "A", payloadJSON: "A")
        try await store.saveWorkoutRecording(row(start: 20), deviceId: "B", payloadJSON: "B")
        try await store.saveWorkoutRecording(row(start: 30), deviceId: "A", payloadJSON: "current")
        try await store.saveWorkoutRecording(row(start: 5, sport: "Cycling"), deviceId: "A", payloadJSON: "other")
        let earlier = try await store.reduceWorkoutRecordingPayloads(sport: "Running", before: 30, initial: Set<String>()) { values, payload in
            values.union([payload])
        }
        XCTAssertEqual(earlier, ["A", "B"])
    }
    func testDatabaseBackupKeepsRecordingEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await WhoopStore.inMemory()
        try await store.saveWorkoutRecording(row(), deviceId: "A", payloadJSON: "original route, zones, pauses, laps")
        let backupPath = directory.appendingPathComponent("backup.sqlite").path
        let writer = try DatabaseQueue(path: backupPath)
        try store.registryWriter.backup(to: writer)
        let restored = try await WhoopStore(path: backupPath)
        let payload = try await restored.workoutRecording(for: WorkoutKey(deviceId: "A", startTs: 100, sport: "Running"))
        XCTAssertEqual(payload, "original route, zones, pauses, laps")
    }
    private func row(start: Int = 100, sport: String = "Running") -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 600, sport: sport, source: "manual",
                   durationS: 550, energyKcal: 100, avgHr: 130, maxHr: 150, strain: nil,
                   distanceM: 1000, zonesJSON: nil, notes: nil, steps: nil)
    }

    func testSaveIsIdempotentAndSourceScoped() async throws {
        let store = try await WhoopStore.inMemory()
        let row = row()
        try await store.saveWorkoutRecording(row, deviceId: "A", payloadJSON: "original")
        try await store.saveWorkoutRecording(row, deviceId: "A", payloadJSON: "original")
        let saved = try await store.workouts(deviceId: "A", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(saved, [row])
        let evidence = try await store.workoutRecording(for: WorkoutKey(deviceId: "A", startTs: 100, sport: "Running"))
        let other = try await store.workoutRecording(for: WorkoutKey(deviceId: "B", startTs: 100, sport: "Running"))
        XCTAssertEqual(evidence, "original")
        XCTAssertNil(other)
    }

    func testEvidenceFailureRollsBackWorkoutAndEnergy() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER rejectRecording BEFORE INSERT ON workoutRecording
                BEGIN SELECT RAISE(ABORT, 'forced failure'); END
                """)
        }
        do {
            try await store.saveWorkoutRecording(row(), deviceId: "A", payloadJSON: "payload")
            XCTFail("Transaction must fail")
        } catch { }
        let rows = try await store.workouts(deviceId: "A", from: 0, to: 1000, limit: 100)
        let energyCount = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workoutEnergySource")
        }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(energyCount, 0)
    }

    func testCorrectionCopiesOriginalEvidenceAndDeleteCascades() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveWorkoutRecording(row(), deviceId: "A", payloadJSON: "original zones and splits")
        try await store.upsertWorkouts([row(start: 200, sport: "Walking")], deviceId: "A")
        let old = WorkoutKey(deviceId: "A", startTs: 100, sport: "Running")
        let new = WorkoutKey(deviceId: "A", startTs: 200, sport: "Walking")
        try await store.copyWorkoutRecording(from: old, to: new)
        try await store.deleteWorkouts(deviceId: "A", sport: "Running", from: 100, to: 100)
        let gone = try await store.workoutRecording(for: old)
        let kept = try await store.workoutRecording(for: new)
        XCTAssertNil(gone)
        XCTAssertEqual(kept, "original zones and splits")
        try await store.deleteWorkouts(deviceId: "A", sport: "Walking", from: 200, to: 200)
        let deleted = try await store.workoutRecording(for: new)
        XCTAssertNil(deleted)
    }

    func testNoFourHundredRecordingEviction() async throws {
        let store = try await WhoopStore.inMemory()
        for start in 1...401 {
            try await store.saveWorkoutRecording(row(start: start), deviceId: "A", payloadJSON: "capture \(start)")
        }
        let first = try await store.workoutRecording(for: WorkoutKey(deviceId: "A", startTs: 1, sport: "Running"))
        XCTAssertEqual(first, "capture 1")
    }
}
