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
        XCTAssertEqual(json, #"{"charge":72,"day":"2026-10-02","deepMinutes":80,"efficiency":0.9,"effort":42,"heroSource":[],"hrv":62,"lightMinutes":230,"remMinutes":90,"rest":88,"restingHr":52,"sleepMinutes":402}"#)
    }

    func testTheDemoHistoryReadsBackAsDaysNightsAndRestOnce() async throws {
        let store = try await WhoopStore.inMemory()
        // Noon keeps the seven-night window clear of the demo night's bedtime boundary, on every test run.
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12)))
        let written = try await CoreDemo.seedIfEmpty(store: store, deviceId: "my-whoop", now: now)
        XCTAssertEqual(written, CoreDemo.days)
        let again = try await CoreDemo.seedIfEmpty(store: store, deviceId: "my-whoop", now: now)
        XCTAssertEqual(again, 0, "a store with scored days is left alone")
        let r = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let today = await CoreRead.day(StoreReader.localDayKey(now), reader: r)
        XCTAssertNotNil(today?.charge)
        XCTAssertNotNil(today?.rest)
        XCTAssertEqual(today?.heroSource, ["WHOOP"], "the demo names its source like the daily analysis would")
        let nowTs = Int(now.timeIntervalSince1970)
        let nights = await CoreRead.nights(from: nowTs - 7 * 86_400, to: nowTs, reader: r)
        XCTAssertEqual(nights.count, 7, "one night per day, today's included")
        XCTAssertTrue(nights.allSatisfy { $0.stages.contains { $0.stage == "deep" } })
        let trace = await CoreRead.heartRate(from: nowTs - 86_400, to: nowTs, reader: r)
        XCTAssertGreaterThan(trace.count, 280, "a day of five-minute means")
        XCTAssertEqual(trace.map(\.ts), trace.map(\.ts).sorted())
        XCTAssertTrue(trace.allSatisfy { $0.ts % 300 == 0 && $0.bpm > 40 && $0.bpm < 160 })
    }

    func testJSONHasSortedKeysAndNullsForGaps() {
        let json = CoreRead.json(CoreRead.Point(day: "2026-10-02", value: 1.5))
        XCTAssertEqual(json, #"{"day":"2026-10-02","value":1.5}"#)
    }

    func testStepsAndSpO2TheStrapLacksComeFromThePhonesHealthStore() async throws {
        let r = try await reader()
        // A WHOOP 4.0 counts no steps: Health Connect's counts fill the days, including one with no strap row.
        _ = try await r.store.upsertAppleDaily([
            AppleDaily(day: "2026-10-02", steps: 7_000, activeKcal: nil, basalKcal: nil, vo2max: nil, avgHr: nil, maxHr: nil,
                       walkingHr: nil, weightKg: nil),
            AppleDaily(day: "2026-10-04", steps: 8_000, activeKcal: nil, basalKcal: nil, vo2max: nil, avgHr: nil, maxHr: nil,
                       walkingHr: nil, weightKg: nil),
        ], deviceId: MetricResolver.healthConnectSource)
        _ = try await r.store.upsertMetricSeries([MetricPoint(day: "2026-10-03", key: "spo2", value: 96)],
                                                 deviceId: MetricResolver.healthConnectSource)
        let steps = await CoreRead.series(.steps, from: "2026-10-01", to: "2026-10-05", reader: r)
        XCTAssertEqual(steps, [CoreRead.Point(day: "2026-10-02", value: 7_000), CoreRead.Point(day: "2026-10-04", value: 8_000)])
        let spo2 = await CoreRead.series(.spo2, from: "2026-10-01", to: "2026-10-05", reader: r)
        XCTAssertEqual(spo2, [CoreRead.Point(day: "2026-10-03", value: 96)])
    }

    /// The wearer chooses where steps come from (`StepsSource`): automatically the strap's count wins a day the phone
    /// also counted, the strap alone leaves the phone's days out, the phone alone leaves the strap's out.
    func testTheChosenStepsSourceDecidesTheCount() async throws {
        let r = try await reader()
        defer { UserDefaults.standard.removeObject(forKey: StepsSource.defaultsKey) }
        _ = try await r.store.upsertAppleDaily([
            AppleDaily(day: "2026-10-02", steps: 7_000, activeKcal: nil, basalKcal: nil, vo2max: nil, avgHr: nil, maxHr: nil,
                       walkingHr: nil, weightKg: nil),
            AppleDaily(day: "2026-10-03", steps: 6_000, activeKcal: nil, basalKcal: nil, vo2max: nil, avgHr: nil, maxHr: nil,
                       walkingHr: nil, weightKg: nil),
        ], deviceId: MetricResolver.healthConnectSource)
        _ = try await r.store.upsertDailyMetrics([DailyMetric(day: "2026-10-03", totalSleepMin: nil, efficiency: nil, deepMin: nil,
                                                              remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                                                              avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil,
                                                              steps: 9_000)], deviceId: r.activeDeviceId)
        func counts() async -> [String: Double] {
            Dictionary(uniqueKeysWithValues: await CoreRead.series(.steps, from: "2026-10-01", to: "2026-10-05", reader: r)
                .map { ($0.day, $0.value) })
        }
        let automatic = await counts()
        XCTAssertEqual(automatic, ["2026-10-02": 7_000, "2026-10-03": 9_000])
        UserDefaults.standard.set(StepsSource.strap.rawValue, forKey: StepsSource.defaultsKey)
        let strap = await counts()
        XCTAssertEqual(strap, ["2026-10-03": 9_000])
        UserDefaults.standard.set(StepsSource.phone.rawValue, forKey: StepsSource.defaultsKey)
        let phone = await counts()
        XCTAssertEqual(phone, ["2026-10-02": 7_000, "2026-10-03": 6_000])
    }
}
