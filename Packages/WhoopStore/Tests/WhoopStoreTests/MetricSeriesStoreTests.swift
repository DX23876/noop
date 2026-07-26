import XCTest
import GRDB
@testable import WhoopStore

final class MetricSeriesStoreTests: XCTestCase {

    // MARK: - migration (v9 creates the table with the right PK + index)

    func testV9CreatesMetricSeriesTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("metricSeries"))

        let pk = try await store.primaryKeyColumns("metricSeries")
        XCTAssertEqual(pk, ["deviceId", "day", "key"])

        let cols = try await store.columnNamesForTest(table: "metricSeries")
        for c in ["deviceId", "day", "key", "value"] {
            XCTAssertTrue(cols.contains(c), "metricSeries missing column \(c)")
        }
    }

    func testV9CreatesPerMetricIndex() async throws {
        let store = try await WhoopStore.inMemory()
        let names = try await store.indexNamesForTest(table: "metricSeries")
        XCTAssertTrue(names.contains("idx_metricSeries_device_key_day"),
                      "v9 must create the (deviceId, key, day) index for fast per-metric reads")
    }

    func testExistingTablesStillPresentAfterV9() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch",
                  "sleepSession", "dailyMetric", "journal", "workout", "appleDaily"] {
            XCTAssertTrue(tables.contains(t), "v9 must not drop \(t)")
        }
    }

    // MARK: - upsert + read by key + range + ordering

    func testUpsertReadByKeyAndRangeOrdering() async throws {
        let store = try await WhoopStore.inMemory()
        // Insert out of order across two keys.
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-20", key: "restingHr", value: 54),
            MetricPoint(day: "2026-05-01", key: "restingHr", value: 58),
            MetricPoint(day: "2026-05-10", key: "restingHr", value: 56),
            MetricPoint(day: "2026-05-10", key: "recovery", value: 72),
        ], deviceId: "devA")

        let hr = try await store.metricSeries(deviceId: "devA", key: "restingHr",
                                              from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(hr.map { $0.day }, ["2026-05-01", "2026-05-10", "2026-05-20"], "day ASC")
        XCTAssertEqual(hr.map { $0.value }, [58, 56, 54])
        XCTAssertEqual(hr.map { $0.key }, ["restingHr", "restingHr", "restingHr"])

        // Range filter (lexicographic compare) + key isolation.
        let ranged = try await store.metricSeries(deviceId: "devA", key: "restingHr",
                                                  from: "2026-05-05", to: "2026-05-15")
        XCTAssertEqual(ranged.map { $0.day }, ["2026-05-10"])

        let rec = try await store.metricSeries(deviceId: "devA", key: "recovery",
                                               from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rec.count, 1)
        XCTAssertEqual(rec[0], MetricPoint(day: "2026-05-10", key: "recovery", value: 72))
    }

    // MARK: - idempotency + conflict-update

    func testIdempotencyAndConflictUpdate() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-10", key: "recovery", value: 60),
        ], deviceId: "devA")

        // Re-upsert same (deviceId, day, key) with a new value → no duplicate, value updated.
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-10", key: "recovery", value: 88),
        ], deviceId: "devA")

        let rows = try await store.metricSeries(deviceId: "devA", key: "recovery",
                                                from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1, "same (deviceId,day,key) must not duplicate")
        XCTAssertEqual(rows[0].value, 88, "conflict must update value in place")
    }

    func testUpsertReturnsChangeCount() async throws {
        let store = try await WhoopStore.inMemory()
        let n = try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-01", key: "steps", value: 9000),
            MetricPoint(day: "2026-05-02", key: "steps", value: 11000),
        ], deviceId: "devA")
        XCTAssertEqual(n, 2)
    }

    func testDeviceIsolation() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-10", key: "steps", value: 1),
        ], deviceId: "devA")
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-10", key: "steps", value: 2),
        ], deviceId: "devB")

        let a = try await store.metricSeries(deviceId: "devA", key: "steps",
                                             from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(a.map { $0.value }, [1], "must not bleed devB's row")
        let keys = try await store.metricKeys(deviceId: "devB")
        XCTAssertEqual(keys, ["steps"])
    }

    // MARK: - distinct metricKeys (sorted)

    func testMetricKeysDistinctAndSorted() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-01", key: "steps", value: 1),
            MetricPoint(day: "2026-05-02", key: "steps", value: 2),     // dup key, different day
            MetricPoint(day: "2026-05-01", key: "recovery", value: 70),
            MetricPoint(day: "2026-05-01", key: "avgHrv", value: 65),
        ], deviceId: "devA")

        let keys = try await store.metricKeys(deviceId: "devA")
        XCTAssertEqual(keys, ["avgHrv", "recovery", "steps"], "distinct + sorted ascending")
    }

    func testMetricKeysEmptyForUnknownDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let keys = try await store.metricKeys(deviceId: "ghost")
        XCTAssertEqual(keys, [])
    }

    // MARK: - source discovery by metric key

    func testMetricSourcesDiscoversEverySourceHoldingTheKey() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([MetricPoint(day: "2026-01-01", key: "weight", value: 80)],
                                           deviceId: "apple-health")
        try await store.upsertMetricSeries([MetricPoint(day: "2026-01-02", key: "weight", value: 79)],
                                           deviceId: "garmin-import")
        try await store.upsertMetricSeries([MetricPoint(day: "2026-01-02", key: "hrv", value: 50)],
                                           deviceId: "garmin-import")

        let weightSources = try await store.metricSources(key: "weight")
        let unknownSources = try await store.metricSources(key: "unknown")
        XCTAssertEqual(weightSources, ["apple-health", "garmin-import"])
        XCTAssertEqual(unknownSources, [])
    }

    func testMetricCatalogContainsOnlyMetadataAndGroupsEachSeries() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-01-01", key: "weight", value: 80),
            MetricPoint(day: "2026-01-03", key: "weight", value: 79),
        ], deviceId: "apple-health")
        try await store.upsertMetricSeries([MetricPoint(day: "2026-01-02", key: "hrv", value: 50)],
                                           deviceId: "garmin-import")

        let catalog = try await store.metricCatalog()
        XCTAssertEqual(catalog, [
            MetricCatalogEntry(source: "garmin-import", key: "hrv", pointCount: 1,
                               earliestDay: "2026-01-02", latestDay: "2026-01-02"),
            MetricCatalogEntry(source: "apple-health", key: "weight", pointCount: 2,
                               earliestDay: "2026-01-01", latestDay: "2026-01-03"),
        ])
    }

    // MARK: - metricDays (min/max)

    func testMetricDaysReturnsEarliestAndLatest() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-05-20", key: "restingHr", value: 54),
            MetricPoint(day: "2026-05-01", key: "restingHr", value: 58),
            MetricPoint(day: "2026-05-10", key: "restingHr", value: 56),
            MetricPoint(day: "2026-06-01", key: "steps", value: 9000),
        ], deviceId: "devA")

        let span = try await store.metricDays(deviceId: "devA", key: "restingHr")
        XCTAssertEqual(span?.earliest, "2026-05-01")
        XCTAssertEqual(span?.latest, "2026-05-20")

        let stepsSpan = try await store.metricDays(deviceId: "devA", key: "steps")
        XCTAssertEqual(stepsSpan?.earliest, "2026-06-01")
        XCTAssertEqual(stepsSpan?.latest, "2026-06-01")
    }

    func testMetricDaysNilWhenAbsent() async throws {
        let store = try await WhoopStore.inMemory()
        let span = try await store.metricDays(deviceId: "devA", key: "missing")
        XCTAssertNil(span)
    }
}
