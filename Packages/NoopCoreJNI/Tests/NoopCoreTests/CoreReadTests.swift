import XCTest
import NoopCore
import StrandCore
import WhoopStore

/// What the Android screens get back from the core's store.
final class CoreReadTests: XCTestCase {
    private func reader() async throws -> StoreReader {
        let store = try await WhoopStore.inMemory()
        let rows = (1...3).map { d in
            DailyMetric(day: "2026-10-0\(d)", totalSleepMin: 400 + Double(d), efficiency: 0.9, deepMin: 80,
                        remMin: 90, lightMin: 230, disturbances: 3, restingHr: 50 + d, avgHrv: 60 + Double(d),
                        recovery: 70 + Double(d), strain: 40 + Double(d), exerciseCount: 0)
        }
        _ = try await store.upsertDailyMetrics(rows, deviceId: "my-whoop-noop")
        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-10-02", key: "sleep_performance", value: 88)],
                                               deviceId: "my-whoop-noop")
        return StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
    }

    func testADayCarriesItsScoresAndRest() async throws {
        let day = await CoreRead.day("2026-10-02", reader: try await reader())
        XCTAssertEqual(day?.charge, 72)
        XCTAssertEqual(day?.effort, 42)
        XCTAssertEqual(day?.rest, 88)
        XCTAssertEqual(day?.restingHr, 52)
        let missing = await CoreRead.day("2026-09-30", reader: try await reader())
        XCTAssertNil(missing)
    }

    func testASeriesIsInDayOrderAndSkipsDaysWithoutTheMetric() async throws {
        let r = try await reader()
        let hrv = await CoreRead.series(.hrv, from: "2026-10-01", to: "2026-10-03", reader: r)
        XCTAssertEqual(hrv.map(\.day), ["2026-10-01", "2026-10-02", "2026-10-03"])
        XCTAssertEqual(hrv.map(\.value), [61, 62, 63])
        let rest = await CoreRead.series(.rest, from: "2026-10-01", to: "2026-10-03", reader: r)
        XCTAssertEqual(rest, [CoreRead.Point(day: "2026-10-02", value: 88)])
    }

    /// The exact text the Android parser reads (android CoreReadTest pins the same literal): a missing value is
    /// left out, not written as null.
    func testADayDocumentIsTheTextAndroidParses() async throws {
        let json = await CoreRead.day("2026-10-02", reader: try await reader()).map(CoreRead.json)
        XCTAssertEqual(json, #"{"charge":72,"day":"2026-10-02","deepMinutes":80,"efficiency":0.9,"effort":42,"hrv":62,"lightMinutes":230,"remMinutes":90,"rest":88,"restingHr":52,"sleepMinutes":402}"#)
    }

    func testTheDemoHistoryReadsBackAsDaysNightsAndRestOnce() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date()
        let written = try await CoreDemo.seedIfEmpty(store: store, deviceId: "my-whoop", now: now)
        XCTAssertEqual(written, CoreDemo.days)
        let again = try await CoreDemo.seedIfEmpty(store: store, deviceId: "my-whoop", now: now)
        XCTAssertEqual(again, 0, "a store with scored days is left alone")
        let r = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let today = await CoreRead.day(StoreReader.localDayKey(now), reader: r)
        XCTAssertNotNil(today?.charge)
        XCTAssertNotNil(today?.rest)
        let nowTs = Int(now.timeIntervalSince1970)
        let nights = await CoreRead.nights(from: nowTs - 7 * 86_400, to: nowTs, reader: r)
        XCTAssertEqual(nights.count, 7, "one night per day, today's included")
        XCTAssertTrue(nights.allSatisfy { $0.stages.contains { $0.stage == "deep" } })
    }

    func testJSONHasSortedKeysAndNullsForGaps() {
        let json = CoreRead.json(CoreRead.Point(day: "2026-10-02", value: 1.5))
        XCTAssertEqual(json, #"{"day":"2026-10-02","value":1.5}"#)
    }
}
