import XCTest
import GRDB
@testable import WhoopStore

final class HealthSyncStoreTests: XCTestCase {
    func testHistoricalBodySnapshotPreservesUnqueriedActivityAndVitals() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO appleDaily(deviceId,day,steps,activeKcal,weightKg) VALUES ('apple-health','2020-01-01',9000,400,80)")
            try db.execute(sql: "INSERT INTO dailyMetric(deviceId,day,restingHr,totalSleepMin) VALUES ('apple-health','2020-01-01',50,480)")
            try db.execute(sql: "INSERT INTO metricSeries(deviceId,day,key,value) VALUES ('apple-health','2020-01-01','steps',9000)")
        }
        let weight = AppleDaily(day: "2020-01-01", steps: nil, activeKcal: nil, basalKcal: nil, vo2max: nil, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: 75)
        try await store.replaceHealthDailySnapshot(appleRows: [weight], metrics: [], points: [.init(day: "2020-01-01", key: "weight", value: 75)],
            deviceId: "apple-health", from: "2026-10-01", to: "2026-10-06", bodyFrom: "2016-10-06", bodyTo: "2026-10-06")
        let facts = try await store.registryWriter.read { db in
            (try Int.fetchOne(db, sql: "SELECT steps FROM appleDaily WHERE day = '2020-01-01'"),
             try Double.fetchOne(db, sql: "SELECT weightKg FROM appleDaily WHERE day = '2020-01-01'"),
             try Int.fetchOne(db, sql: "SELECT restingHr FROM dailyMetric WHERE day = '2020-01-01'"),
             try Int.fetchOne(db, sql: "SELECT value FROM metricSeries WHERE key = 'steps'"))
        }
        XCTAssertEqual(facts.0, 9000); XCTAssertEqual(facts.1, 75); XCTAssertEqual(facts.2, 50); XCTAssertEqual(facts.3, 9000)
    }

    func testAuthoritativeEmptyWindowClearsOnlyImportedWindow() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO appleDaily(deviceId,day,steps) VALUES ('apple-health','2026-10-01',9000),('my-whoop','2026-10-01',8000),('apple-health','2020-01-01',7000)")
            try db.execute(sql: "INSERT INTO metricSeries(deviceId,day,key,value) VALUES ('apple-health','2026-10-01','steps',9000)")
        }
        try await store.replaceHealthDailySnapshot(appleRows: [], metrics: [], points: [], deviceId: "apple-health",
            from: "2026-10-01", to: "2026-10-06", bodyFrom: "2016-10-06", bodyTo: "2026-10-06")
        let count = try await store.registryWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM appleDaily") }
        XCTAssertEqual(count, 2)
    }

    func testSnapshotFailureRollsBackAllWideAndSeriesRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO appleDaily(deviceId,day,steps) VALUES ('apple-health','2026-10-01',9000)")
            try db.execute(sql: "CREATE TRIGGER rejectSnapshot BEFORE INSERT ON metricSeries BEGIN SELECT RAISE(ABORT, 'forced failure'); END")
        }
        do {
            try await store.replaceHealthDailySnapshot(appleRows: [], metrics: [], points: [.init(day: "2026-10-01", key: "steps", value: 1)], deviceId: "apple-health",
                from: "2026-10-01", to: "2026-10-06", bodyFrom: "2016-10-06", bodyTo: "2026-10-06")
            XCTFail("Snapshot must fail")
        } catch { }
        let steps = try await store.registryWriter.read { db in try Int.fetchOne(db, sql: "SELECT steps FROM appleDaily") }
        XCTAssertEqual(steps, 9000)
    }

    func testMutationDuringExportCannotBeAcknowledgedByOlderPass() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.enqueueHealthExport(kind: "sleep", fromTs: 100, toTs: 200)
        let firstPending = try await store.pendingHealthExports()
        let first = try XCTUnwrap(firstPending.first)
        try await store.enqueueHealthExport(kind: "sleep", fromTs: 50, toTs: 250)
        try await store.acknowledgeHealthExport(first)
        let nextPending = try await store.pendingHealthExports()
        let next = try XCTUnwrap(nextPending.first)
        XCTAssertEqual(next.fromTs, 50); XCTAssertEqual(next.toTs, 250)
        XCTAssertGreaterThan(next.revision, first.revision)
        try await store.acknowledgeHealthExport(next)
        let pending = try await store.pendingHealthExports()
        XCTAssertTrue(pending.isEmpty)
    }

    func testVersionsRetryInterruptedSaveAndAdvanceOnlyForChangedOrRestoredPayload() async throws {
        let store = try await WhoopStore.inMemory()
        let first = try await store.planHealthExports([(id: "workout:100", fingerprint: "original")])
        let retry = try await store.planHealthExports([(id: "workout:100", fingerprint: "original")])
        XCTAssertEqual(first, retry); XCTAssertTrue(first[0].needsSave)
        let changed = try await store.planHealthExports([(id: "workout:100", fingerprint: "edited")])
        try await store.commitHealthExports(first)
        let stillOwed = try await store.planHealthExports([(id: "workout:100", fingerprint: "edited")])
        XCTAssertTrue(stillOwed[0].needsSave); XCTAssertGreaterThan(changed[0].revision, first[0].revision)
        try await store.commitHealthExports(changed)
        let stable = try await store.planHealthExports([(id: "workout:100", fingerprint: "edited")])
        XCTAssertFalse(stable[0].needsSave)
        try await store.invalidateHealthExports(ids: ["workout:100"])
        let undo = try await store.planHealthExports([(id: "workout:100", fingerprint: "edited")])
        XCTAssertGreaterThan(undo[0].revision, changed[0].revision); XCTAssertTrue(undo[0].needsSave)
    }

    func testRestoredStateUsesVersionFloorAndBackwardClockStillAdvances() async throws {
        let store = try await WhoopStore.inMemory()
        let old = try await store.planHealthExports([(id: "sample", fingerprint: "old")], versionFloor: 100)
        try await store.commitHealthExports(old)
        let restored = try await store.planHealthExports([(id: "sample", fingerprint: "new")], versionFloor: 1_000)
        XCTAssertEqual(restored[0].revision, 1_000)
        let backward = try await store.planHealthExports([(id: "sample", fingerprint: "newer")], versionFloor: 500)
        XCTAssertEqual(backward[0].revision, 1_001)
    }

    func testWorkoutDeletionAndMovedStartQueueOldAndNewIntervals() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO workout(deviceId,startTs,endTs,sport,source) VALUES ('whoop-old-noop',100,200,'Running','manual')")
        }
        let inserted = try await store.pendingHealthExports()
        XCTAssertEqual(inserted.first?.kind, "workouts")
        try await store.registryWriter.write { db in
            try db.execute(sql: "UPDATE workout SET startTs = 300,endTs = 400 WHERE startTs = 100")
            try db.execute(sql: "DELETE FROM workout WHERE startTs = 300")
        }
        let changed = try await store.pendingHealthExports()
        XCTAssertEqual(changed.first?.fromTs, 100); XCTAssertEqual(changed.first?.toTs, 400)
    }

    func testHealthWorkoutDeletionIsUUIDAndSourceScoped() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO workout(deviceId,startTs,endTs,sport,source) VALUES ('apple-health',100,200,'Running','apple-health'),('my-whoop',100,200,'Running','manual')")
        }
        let ids = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()]
        let metadata = ids.enumerated().map { index, id in
            WorkoutSourceMetadataRow(componentKey: "watch-\(index)", source: "apple-health", startTs: 100, sport: "Running", externalId: id,
                                     sourceBundleId: nil, rawActivityType: nil, activitiesJSON: nil, updatedAtTs: 100)
        }
        try await store.upsertWorkoutSourceMetadata(metadata)
        _ = try await store.deleteImportedHealthWorkouts(externalIds: [ids[0].uppercased()], deviceId: "apple-health")
        let retained = try await store.workouts(deviceId: "apple-health", from: 0, to: 300, limit: 100)
        XCTAssertEqual(retained.count, 1)
        _ = try await store.deleteImportedHealthWorkouts(externalIds: [ids[1]], deviceId: "apple-health")
        let removed = try await store.workouts(deviceId: "apple-health", from: 0, to: 300, limit: 100)
        let own = try await store.workouts(deviceId: "my-whoop", from: 0, to: 300, limit: 100)
        XCTAssertTrue(removed.isEmpty); XCTAssertEqual(own.count, 1)
    }

    func testProjectionRepairResumesAndNeverOverwritesCorrections() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO metricSeries(deviceId,day,key,value) VALUES ('apple-health','2020-01-01','steps',9000),('apple-health','2020-01-02','steps',7000)")
            try db.execute(sql: "INSERT INTO appleDaily(deviceId,day,steps) VALUES ('apple-health','2020-01-02',8000)")
        }
        let first = try await store.repairHealthProjectionsV1(batchSize: 1)
        let second = try await store.repairHealthProjectionsV1(batchSize: 1)
        let done = try await store.repairHealthProjectionsV1(batchSize: 1)
        XCTAssertFalse(first); XCTAssertFalse(second); XCTAssertTrue(done)
        let steps = try await store.registryWriter.read { db in try Int.fetchAll(db, sql: "SELECT steps FROM appleDaily ORDER BY day") }
        XCTAssertEqual(steps, [9000, 8000])
    }
}

extension HealthSyncStoreTests {
    func testManualBodyMeasurementsQueueDeletionAndHealthRowsNeverExport() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO labMarker(id,deviceId,markerKey,category,day,takenAt,value,unit,source)
                VALUES ('manual-waist','my-whoop','waist','bodyMeasurement','2020-01-01',100,80,'cm','manual'),
                       ('health-waist','apple-health','waist','bodyMeasurement','2020-01-01',200,90,'cm','apple-health')
                """)
        }
        let readings = try await store.healthBodyMeasurements(kind: "waist", from: "2020-01-01", to: "2020-01-01")
        XCTAssertEqual(readings.map(\.value), [80])
        let pending = try await store.pendingHealthExports()
        XCTAssertEqual(pending.first?.kind, "waist")
        if let first = pending.first { try await store.acknowledgeHealthExport(first) }
        _ = try await store.deleteLabMarker(id: "manual-waist")
        let deletion = try await store.pendingHealthExports()
        XCTAssertEqual(deletion.first?.fromTs, 100)
        let empty = try await store.healthBodyMeasurements(kind: "waist", from: "2020-01-01", to: "2020-01-01")
        XCTAssertTrue(empty.isEmpty)
    }

    func testEmptyHealthWaistSnapshotPreservesManualMeasurement() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO labMarker(id,deviceId,markerKey,category,day,takenAt,value,unit,source)
                VALUES ('manual','my-whoop','waist','bodyMeasurement','2020-01-01',100,80,'cm','manual'),
                       ('health','apple-health','waist','bodyMeasurement','2020-01-01',200,90,'cm','apple-health')
                """)
        }
        try await store.replaceHealthWaistSnapshot([], from: "2020-01-01", to: "2020-01-01")
        let readings = try await store.labMarkers(deviceId: "my-whoop", markerKey: "waist")
        let imported = try await store.labMarkers(deviceId: "apple-health", markerKey: "waist")
        XCTAssertEqual(readings.count, 1); XCTAssertTrue(imported.isEmpty)
    }
}

extension HealthSyncStoreTests {
    func testDeletedWorkoutRepairDatesSurviveMetadataRemovalAndNewMutation() async throws {
        let store = try await WhoopStore.inMemory()
        let id = UUID().uuidString.lowercased()
        try await store.upsertWorkoutSourceMetadata([.init(componentKey: "apple-health|" + id,
            source: "apple-health", startTs: 100, sport: "Running", externalId: id,
            sourceBundleId: nil, rawActivityType: nil, activitiesJSON: nil, updatedAtTs: 200)])
        try await store.queueDeletedHealthWorkoutRepair(externalIds: [id])
        _ = try await store.deleteImportedHealthWorkouts(externalIds: [id], deviceId: "apple-health")
        let pending = try await store.pendingHealthExports()
        let repair = try XCTUnwrap(pending.first)
        XCTAssertEqual(repair.kind, "importWorkouts"); XCTAssertEqual(repair.fromTs, 100)
        try await store.enqueueHealthExport(kind: "importWorkouts", fromTs: 50, toTs: 250)
        try await store.advanceHealthExport(repair, pastTs: 200)
        try await store.acknowledgeHealthExport(repair)
        let newer = try await store.pendingHealthExports()
        XCTAssertEqual(newer.first?.fromTs, 50); XCTAssertEqual(newer.first?.toTs, 250)
    }

    func testProjectionRepairFailureDoesNotAdvanceCursor() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO metricSeries(deviceId,day,key,value) VALUES ('apple-health','2020-01-01','steps',9000)")
            try db.execute(sql: "CREATE TRIGGER rejectRepair BEFORE INSERT ON appleDaily BEGIN SELECT RAISE(ABORT, 'forced failure'); END")
        }
        do { _ = try await store.repairHealthProjectionsV1(); XCTFail("Repair must fail") } catch { }
        let cursor = try await store.registryWriter.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM cursors WHERE name = 'health:wideProjectionRepair.v1'")
        }
        XCTAssertNil(cursor)
        try await store.registryWriter.write { db in try db.execute(sql: "DROP TRIGGER rejectRepair") }
        let complete = try await store.repairHealthProjectionsV1()
        XCTAssertTrue(complete)
    }
}

extension HealthSyncStoreTests {
    func testHistoricalVitalCorrectionQueuesOnlyItsCivilDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO dailyMetric(deviceId,day,restingHr) VALUES ('whoop-old-noop','2020-01-01',50)")
        }
        let pending = try await store.pendingHealthExports()
        let change = try XCTUnwrap(pending.first)
        XCTAssertEqual(change.kind, "vitals")
        XCTAssertEqual(change.fromTs, 1_577_836_800)
        XCTAssertEqual(change.toTs, 1_577_923_199)
    }
}

extension HealthSyncStoreTests {
    func testPermissionRewindCannotBeOverwrittenByAnOlderHistoryPage() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.requestHealthImportRepair(endTs: 1000)
        let first = try await store.cursor("health:importRepairGeneration.v1") ?? 0
        try await store.requestHealthImportRepair(endTs: 1000)
        let stale = try await store.checkpointHealthImportRepair(endTs: 500, generation: first)
        XCTAssertFalse(stale)
        let cursor = try await store.cursor("health:importRepair.v1")
        XCTAssertEqual(cursor, 1000)
        let current = try await store.cursor("health:importRepairGeneration.v1") ?? 0
        let success = try await store.checkpointHealthImportRepair(endTs: 500, generation: current)
        XCTAssertTrue(success)
    }
}

extension HealthSyncStoreTests {
    func testFractionalHeartRateProjectionUsesTheImporterIntegerRounding() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            .init(day: "2020-01-01", key: "avg_hr", value: 62.4),
            .init(day: "2020-01-01", key: "max_hr", value: 155.6),
            .init(day: "2020-01-01", key: "resting_hr", value: 54.6)
        ], deviceId: "apple-health")
        _ = try await store.repairHealthProjectionsV1()
        let apple = try await store.appleDaily(deviceId: "apple-health", from: "2020-01-01", to: "2020-01-01")
        let daily = try await store.dailyMetrics(deviceId: "apple-health", from: "2020-01-01", to: "2020-01-01")
        XCTAssertEqual(apple.first?.avgHr, 62); XCTAssertEqual(apple.first?.maxHr, 156)
        XCTAssertEqual(daily.first?.restingHr, 55)
    }

    func testLegacyUnidentifiedWorkoutMetadataDoesNotBreakSnapshotReconciliation() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertWorkoutSourceMetadata([.init(componentKey: "legacy",
            source: "apple-health", startTs: 100, sport: "Running", externalId: nil,
            sourceBundleId: nil, rawActivityType: nil, activitiesJSON: nil, updatedAtTs: 200)])
        let stale = try await store.staleHealthWorkoutIDs(from: 0, to: 300, keeping: [])
        XCTAssertTrue(stale.isEmpty)
    }
}
