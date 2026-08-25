import XCTest
import GRDB
@testable import WhoopStore

/// v43 `bodyWeightEntry` — the weigh-in book and its daily `metricSeries` projection.
///
/// The projection is the part worth pinning: every other reader in the app (Explore, Compare,
/// correlation, goal tracking, the Coach) sees weight as an ordinary metric series and knows
/// nothing about this table, so a projection that drifts from the book is invisible until a goal
/// verdict is wrong.
final class BodyWeightStoreTests: XCTestCase {

    private let device = "test-device"

    // MARK: - v43 migration (additive: new table + indexes, nothing dropped)

    func testV43CreatesBodyWeightTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("bodyWeightEntry"))

        let pk = try await store.primaryKeyColumns("bodyWeightEntry")
        XCTAssertEqual(pk, ["id"])

        let cols = try await store.columnNamesForTest(table: "bodyWeightEntry")
        for c in ["id", "deviceId", "day", "takenAt", "weightKg", "source", "note"] {
            XCTAssertTrue(cols.contains(c), "bodyWeightEntry missing column \(c)")
        }
    }

    func testV43CreatesIndexes() async throws {
        let store = try await WhoopStore.inMemory()
        let names = try await store.indexNamesForTest(table: "bodyWeightEntry")
        XCTAssertTrue(names.contains("idx_bodyWeightEntry_natural"))
        XCTAssertTrue(names.contains("idx_bodyWeightEntry_device_takenAt"))
    }

    /// Additive: v43 must not drop anything that existed before it — `metricSeries` above all,
    /// since it is this store's projection sink.
    func testV43IsAdditive() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "dailyMetric", "workout", "appleDaily",
                  "metricSeries", "labMarker", "appleStepHour"] {
            XCTAssertTrue(tables.contains(t), "v43 must not drop \(t)")
        }
    }

    /// Internal builds briefly used v42 for weight and v43 for energy coverage before upstream took
    /// v42 and forced both identifiers forward by one. Opening one of those databases with the final
    /// migrator must adopt the identical schema, preserve its rows, and record the released markers.
    func testPrototypeMigrationIdentifiersUpgradeWithoutDataLoss() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v42-ppg-burst-index")

        try dbQueue.write { db in
            try db.create(table: "bodyWeightEntry") { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("takenAt", .integer).notNull()
                t.column("weightKg", .double).notNull()
                t.column("source", .text).notNull()
                t.column("note", .text)
            }
            try db.create(index: "idx_bodyWeightEntry_natural", on: "bodyWeightEntry",
                          columns: ["deviceId", "takenAt", "source"], unique: true)
            try db.create(index: "idx_bodyWeightEntry_device_takenAt", on: "bodyWeightEntry",
                          columns: ["deviceId", "takenAt"])
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "energyCoverageSeconds", .integer)
            }
            try db.execute(sql: """
                INSERT INTO grdb_migrations (identifier)
                VALUES ('v42-body-weight'), ('v43-energy-coverage')
                """)
            try db.execute(sql: """
                INSERT INTO bodyWeightEntry
                    (id, deviceId, day, takenAt, weightKg, source, note)
                VALUES ('legacy-weight', 'noop-weight', '2026-08-24', 1770000000, 81.7, 'manual', 'keep me')
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, energyCoverageSeconds)
                VALUES ('my-whoop', '2026-08-24', 43200)
                """)
        }

        XCTAssertNoThrow(try migrator.migrate(dbQueue))

        try dbQueue.read { db in
            XCTAssertEqual(try Double.fetchOne(db, sql: """
                SELECT weightKg FROM bodyWeightEntry WHERE id = 'legacy-weight'
                """), 81.7)
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT note FROM bodyWeightEntry WHERE id = 'legacy-weight'
                """), "keep me")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT energyCoverageSeconds FROM dailyMetric
                WHERE deviceId = 'my-whoop' AND day = '2026-08-24'
                """), 43_200)
            let applied = try Set(String.fetchAll(db, sql: """
                SELECT identifier FROM grdb_migrations
                WHERE identifier IN ('v42-body-weight', 'v43-body-weight',
                                     'v43-energy-coverage', 'v44-energy-coverage')
                """))
            XCTAssertEqual(applied, ["v42-body-weight", "v43-body-weight",
                                     "v43-energy-coverage", "v44-energy-coverage"])
        }
    }

    // MARK: - Write + read back

    func testUpsertStoresAndReadsBack() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertBodyWeights([row(day: "2026-08-01", takenAt: 1_000, kg: 82.4, note: "morning")])

        let all = try await store.bodyWeights(deviceId: device)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].weightKg, 82.4)
        XCTAssertEqual(all[0].day, "2026-08-01")
        XCTAssertEqual(all[0].note, "morning")
        XCTAssertEqual(all[0].source, BodyWeightRow.Source.manual.rawValue)
    }

    func testHistoryIsOldestFirst() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertBodyWeights([
            row(day: "2026-08-03", takenAt: 3_000, kg: 82.0),
            row(day: "2026-08-01", takenAt: 1_000, kg: 83.0),
            row(day: "2026-08-02", takenAt: 2_000, kg: 82.5),
        ])
        let all = try await store.bodyWeights(deviceId: device)
        XCTAssertEqual(all.map(\.day), ["2026-08-01", "2026-08-02", "2026-08-03"])
    }

    func testLatestReadsTheNewestMeasurement() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertBodyWeights([
            row(day: "2026-08-01", takenAt: 1_000, kg: 83.0),
            row(day: "2026-08-02", takenAt: 2_000, kg: 82.5),
        ])
        let latest = try await store.latestBodyWeight(deviceId: device)
        XCTAssertEqual(latest?.weightKg, 82.5)
    }

    func testRangeReadIsBoundedByDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertBodyWeights([
            row(day: "2026-07-31", takenAt: 1_000, kg: 83.0),
            row(day: "2026-08-01", takenAt: 2_000, kg: 82.5),
            row(day: "2026-08-02", takenAt: 3_000, kg: 82.0),
        ])
        let window = try await store.bodyWeights(deviceId: device, from: "2026-08-01", to: "2026-08-01")
        XCTAssertEqual(window.map(\.weightKg), [82.5])
    }

    // MARK: - Idempotence

    /// Re-logging the SAME measurement (deviceId + takenAt + source) updates in place, even when
    /// the caller mints a fresh id — the natural key is what identifies a reading, not the id.
    func testReUpsertOfSameInstantUpdatesInsteadOfDuplicating() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertBodyWeights([row(id: "a", day: "2026-08-01", takenAt: 1_000, kg: 82.4)])
        try await store.upsertBodyWeights([row(id: "b", day: "2026-08-01", takenAt: 1_000, kg: 82.9)])

        let all = try await store.bodyWeights(deviceId: device)
        XCTAssertEqual(all.count, 1, "same instant + source must update, not duplicate")
        XCTAssertEqual(all[0].weightKg, 82.9)
        XCTAssertEqual(all[0].id, "a", "the stored row keeps its original id")
    }

    /// A measurement from a DIFFERENT source at the same instant is a different reading.
    func testSameInstantFromDifferentSourceIsItsOwnRow() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertBodyWeights([
            row(id: "a", day: "2026-08-01", takenAt: 1_000, kg: 82.4, source: .manual),
            row(id: "b", day: "2026-08-01", takenAt: 1_000, kg: 82.4, source: .imported),
        ])
        let all = try await store.bodyWeights(deviceId: device)
        XCTAssertEqual(all.count, 2)
    }

    // MARK: - Daily projection

    func testWriteProjectsTheDayIntoMetricSeries() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertBodyWeights([row(day: "2026-08-01", takenAt: 1_000, kg: 82.4)])

        let points = try await store.metricSeries(deviceId: WhoopStore.noopWeightSourceId,
                                                  key: WhoopStore.bodyWeightMetricKey,
                                                  from: "2026-08-01", to: "2026-08-01")
        XCTAssertEqual(points.map(\.value), [82.4])
    }

    /// Several weigh-ins on one day: the LATEST instant wins the projected cell — the same
    /// latest-of-day rule Apple's own import applies, so the two series mean the same thing.
    func testLatestOfDayWinsTheProjection() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertBodyWeights([
            row(id: "morning", day: "2026-08-01", takenAt: 1_000, kg: 82.4),
            row(id: "evening", day: "2026-08-01", takenAt: 2_000, kg: 83.1),
        ])
        let points = try await store.metricSeries(deviceId: WhoopStore.noopWeightSourceId,
                                                  key: WhoopStore.bodyWeightMetricKey,
                                                  from: "2026-08-01", to: "2026-08-01")
        XCTAssertEqual(points.map(\.value), [83.1])
    }

    /// Editing a value re-projects the day rather than leaving the old number behind.
    func testEditReProjectsTheDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertBodyWeights([row(id: "a", day: "2026-08-01", takenAt: 1_000, kg: 82.4)])
        try await store.upsertBodyWeights([row(id: "a", day: "2026-08-01", takenAt: 1_000, kg: 80.0)])

        let points = try await store.metricSeries(deviceId: WhoopStore.noopWeightSourceId,
                                                  key: WhoopStore.bodyWeightMetricKey,
                                                  from: "2026-08-01", to: "2026-08-01")
        XCTAssertEqual(points.map(\.value), [80.0])
    }

    /// Deleting one of several same-day weigh-ins falls back to the newest remaining one.
    func testDeletingOneOfSeveralReProjectsFromWhatRemains() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertBodyWeights([
            row(id: "morning", day: "2026-08-01", takenAt: 1_000, kg: 82.4),
            row(id: "evening", day: "2026-08-01", takenAt: 2_000, kg: 83.1),
        ])
        let deleted = try await store.deleteBodyWeight(id: "evening")
        XCTAssertTrue(deleted)

        let points = try await store.metricSeries(deviceId: WhoopStore.noopWeightSourceId,
                                                  key: WhoopStore.bodyWeightMetricKey,
                                                  from: "2026-08-01", to: "2026-08-01")
        XCTAssertEqual(points.map(\.value), [82.4])
    }

    /// Deleting the LAST weigh-in of a day removes the projected cell — a deleted measurement must
    /// not survive as a stale series value that goal tracking would still read.
    func testDeletingTheLastEntryDropsTheProjectedDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertBodyWeights([row(id: "only", day: "2026-08-01", takenAt: 1_000, kg: 82.4)])
        _ = try await store.deleteBodyWeight(id: "only")

        let points = try await store.metricSeries(deviceId: WhoopStore.noopWeightSourceId,
                                                  key: WhoopStore.bodyWeightMetricKey,
                                                  from: "2026-08-01", to: "2026-08-01")
        XCTAssertTrue(points.isEmpty)
    }

    func testDeletingAnUnknownIdReportsNothingDeleted() async throws {
        let store = try await WhoopStore.inMemory()
        let deleted = try await store.deleteBodyWeight(id: "nope")
        XCTAssertFalse(deleted)
    }

    /// The projection must not touch Apple Health's own weight series: they are separate sources
    /// precisely so the resolver can choose between them per day.
    func testProjectionDoesNotTouchAppleHealthWeight() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([MetricPoint(day: "2026-08-01", key: "weight", value: 90.0)],
                                           deviceId: "apple-health")
        try await store.upsertBodyWeights([row(day: "2026-08-01", takenAt: 1_000, kg: 82.4)])

        let apple = try await store.metricSeries(deviceId: "apple-health", key: "weight",
                                                 from: "2026-08-01", to: "2026-08-01")
        XCTAssertEqual(apple.map(\.value), [90.0], "the NOOP projection must not overwrite Apple's series")
    }

    // MARK: - Helper

    private func row(id: String = UUID().uuidString,
                     day: String,
                     takenAt: Int,
                     kg: Double,
                     source: BodyWeightRow.Source = .manual,
                     note: String? = nil) -> BodyWeightRow {
        BodyWeightRow(id: id, deviceId: device, day: day, takenAt: takenAt,
                      weightKg: kg, source: source.rawValue, note: note)
    }
}
