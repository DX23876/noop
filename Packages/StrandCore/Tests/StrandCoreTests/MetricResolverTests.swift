import XCTest
import StrandCore
import WhoopStore

/// The per-day source precedence, against a real store: imported strap first, NOOP-computed for the days it
/// does not cover, Apple Health only for declared-compatible vitals, and deleted nights' sleep hidden.
final class MetricResolverTests: XCTestCase {
    private func store() async throws -> WhoopStore { try await WhoopStore.inMemory() }

    private func resolve(_ store: WhoopStore, _ key: String, source: String = MetricResolver.whoopSource,
                         suppressed: Set<String> = []) async -> [String: String] {
        let r = await MetricResolver.resolve(store: store, key: key, preferredSource: source,
                                             actualWhoopSource: "my-whoop", from: "2026-10-01", to: "2026-10-05",
                                             suppressedSleepWakeDays: suppressed)
        return Dictionary(uniqueKeysWithValues: r.points.map { ($0.day, "\($0.source):\($0.value)") })
    }

    func testImportedWinsComputedFillsAndAppleOnlyFillsCompatibleVitals() async throws {
        let s = try await store()
        _ = try await s.upsertMetricSeries([MetricPoint(day: "2026-10-01", key: "hrv", value: 60)], deviceId: "my-whoop")
        _ = try await s.upsertMetricSeries([MetricPoint(day: "2026-10-01", key: "hrv", value: 55),
                                            MetricPoint(day: "2026-10-02", key: "hrv", value: 57)],
                                           deviceId: "my-whoop-noop")
        _ = try await s.upsertMetricSeries([MetricPoint(day: "2026-10-02", key: "hrv", value: 40),
                                            MetricPoint(day: "2026-10-03", key: "hrv", value: 42),
                                            MetricPoint(day: "2026-10-03", key: "recovery", value: 99)],
                                           deviceId: "apple-health")
        let hrv = await resolve(s, "hrv")
        XCTAssertEqual(hrv, ["2026-10-01": "my-whoop:60.0", "2026-10-02": "my-whoop-noop:57.0",
                             "2026-10-03": "apple-health:42.0"])
        let recovery = await resolve(s, "recovery")
        XCTAssertTrue(recovery.isEmpty, "Charge has no Apple equivalent, so Apple never fills it")
    }

    func testADeletedNightHidesOnlyItsSleepValues() async throws {
        let s = try await store()
        _ = try await s.upsertMetricSeries([MetricPoint(day: "2026-10-02", key: "sleep_total_min", value: 420),
                                            MetricPoint(day: "2026-10-02", key: "hrv", value: 50)],
                                           deviceId: "my-whoop-noop")
        let sleep = await resolve(s, "sleep_total_min", suppressed: ["2026-10-02"])
        XCTAssertTrue(sleep.isEmpty)
        let hrv = await resolve(s, "hrv", suppressed: ["2026-10-02"])
        XCTAssertEqual(hrv["2026-10-02"], "my-whoop-noop:50.0")
    }

    func testStepsPreferTheStrapThenThePhoneThenTheEstimate() async throws {
        let s = try await store()
        _ = try await s.upsertMetricSeries([MetricPoint(day: "2026-10-01", key: "steps", value: 9000)],
                                           deviceId: "my-whoop")
        _ = try await s.upsertMetricSeries([MetricPoint(day: "2026-10-01", key: "steps", value: 8000),
                                            MetricPoint(day: "2026-10-02", key: "steps", value: 7000)],
                                           deviceId: "apple-health")
        _ = try await s.upsertMetricSeries([MetricPoint(day: "2026-10-02", key: "steps_est", value: 6500),
                                            MetricPoint(day: "2026-10-03", key: "steps_est", value: 6000)],
                                           deviceId: "my-whoop-noop")
        let r = await MetricResolver.resolvedSteps(store: s, actualWhoopSource: "my-whoop",
                                                   from: "2026-10-01", to: "2026-10-05")
        XCTAssertEqual(r.values.map(\.value), [9000, 7000, 6000])
        XCTAssertEqual(r.usedSources, ["my-whoop", "apple-health", "my-whoop-noop"])
    }
}
