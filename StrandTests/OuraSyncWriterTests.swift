// Tests the OURA_CLOUD_IMPORT-gated Oura import lane; compiled only when the flag is set
// (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if OURA_CLOUD_IMPORT
import XCTest
import WhoopStore
import WhoopProtocol
@testable import StrandImport
@testable import Strand

final class OuraSyncWriterTests: XCTestCase {
    private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testPersistWritesAllStoresAndRegistersCloudSource() async throws {
        let store = try await WhoopStore.inMemory()

        var day = WearableDailyRow(day: "2026-01-02")
        day.restingHr = 50; day.steps = 9000; day.totalSleepMin = 400

        let session = WearableSleepSession(
            start: iso("2026-01-01T23:00:00Z"), end: iso("2026-01-02T06:00:00Z"),
            deepMin: 100, lightMin: 200, remMin: 100, awakeMin: 20, totalSleepMin: 400,
            efficiencyPct: 92, avgHr: 55, lowestHr: 48, avgHrvMs: 65, respRateBpm: 14,
            sleepScore: nil, stages: [WearableSleepStageInterval(stage: "deep",
                start: iso("2026-01-01T23:00:00Z"), end: iso("2026-01-01T23:05:00Z"))])
        let period = OuraSleepPeriod(session: session, movement30s: [1, 2, 1],
                                     hr: [OuraHRPoint(ts: Int(iso("2026-01-01T23:00:00Z").timeIntervalSince1970), bpm: 60)])

        let result = OuraSyncResult(
            days: [day], sleepPeriods: [period],
            extras: [OuraDailyExtra(day: "2026-01-02", key: "ref_readiness_score", value: 80),
                     OuraDailyExtra(day: "2026-01-02", key: "vo2max", value: 44)],
            workouts: [OuraWorkout(start: iso("2026-01-02T07:00:00Z"), end: iso("2026-01-02T07:40:00Z"),
                                   activity: "running", source: "autodetected", energyKcal: 410, distanceM: 6200)],
            heartRate: [OuraHRPoint(ts: Int(iso("2026-01-02T07:00:00Z").timeIntervalSince1970), bpm: 120)],
            rawPages: [OuraRawRow(endpoint: "sleep", documentId: "s1", day: "2026-01-02",
                                  payloadJSON: "{}", fetchedAt: 100)],
            ringModel: "Oura Ring Gen3")

        let summary = try await OuraSyncWriter.persist(result, into: store)

        XCTAssertEqual(summary.days, 1)
        XCTAssertEqual(summary.sleeps, 1)
        XCTAssertEqual(summary.workouts, 1)
        XCTAssertEqual(summary.hrSamples, 2)           // in-sleep 60bpm + whole-day 120bpm, distinct ts
        XCTAssertGreaterThan(summary.metricPoints, 0)
        XCTAssertEqual(summary.rawPages, 1)

        // Cloud source registered as .cloudImport, .paired (never .active — single-active invariant;
        // an import source must never seize the live-device slot alongside a paired WHOOP).
        let devices = try DeviceRegistryStore(dbQueue: store.registryWriter).all()
        let oura = devices.first { $0.id == "oura-api" }
        XCTAssertEqual(oura?.sourceKind, .cloudImport)
        XCTAssertEqual(oura?.model, "Oura Ring Gen3")
        XCTAssertEqual(oura?.status, .paired)

        // Honest data: the reference score is a metricSeries key, never a DailyMetric score column.
        let refs = try await store.metricSeries(deviceId: "oura-api", key: "ref_readiness_score",
                                                 from: "2026-01-01", to: "2026-01-03")
        XCTAssertEqual(refs.first?.value, 80)
        let vo2 = try await store.metricSeries(deviceId: "oura-api", key: "vo2max",
                                               from: "2026-01-01", to: "2026-01-03")
        XCTAssertEqual(vo2.first?.value, 44)          // vo2max parity via extras

        // Honest data, read back through the day accessor: recovery/strain stay nil (never Oura's readiness).
        let days = try await store.dailyMetrics(deviceId: "oura-api", from: "2026-01-01", to: "2026-01-03")
        XCTAssertNil(days.first?.recovery)
        XCTAssertNil(days.first?.strain)
    }
}
#endif // OURA_CLOUD_IMPORT
