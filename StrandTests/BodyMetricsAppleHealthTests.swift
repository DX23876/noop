import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// AI-30: Apple Health's body fat and lean mass arrive as daily metric points under `apple-health`, and the one
/// body resolver has to read them there. Before, only body fat typed into NOOP reached AgeLess, the energy model,
/// the Body page and the body goals.
@MainActor
final class BodyMetricsAppleHealthTests: XCTestCase {

    private func day(_ back: Int) -> String {
        Repository.localDayKey(Date().addingTimeInterval(-Double(back) * 86_400))
    }

    func testAppleHealthBodyFatAndLeanMassReachTheResolver() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "test-body-apple")
        repo.setStoreForTesting(store)
        // What the HealthKit sync and the export importer write (`AppleHealthAggregator.metricPoints`).
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: day(40), key: "body_fat", value: 31.5),
            MetricPoint(day: day(10), key: "body_fat", value: 30.2),
            MetricPoint(day: day(10), key: "lean_mass", value: 141.0),
            MetricPoint(day: day(10), key: "bmi", value: 55.0),
        ], deviceId: Repository.appleHealthSource)
        // A DEXA result typed into NOOP stays its own series beside Apple's.
        _ = await repo.recordBodyMeasurements(["body_fat": 29.0],
                                              takenAt: Date().addingTimeInterval(-5 * 86_400), source: "dexa")

        let metrics = await repo.bodyMetrics()
        let fat = metrics.series("body_fat")
        XCTAssertEqual(fat.map(\.value), [31.5, 30.2, 29.0])
        XCTAssertEqual(fat.map(\.source), [Repository.appleHealthSource, Repository.appleHealthSource, "dexa"])
        XCTAssertNil(fat.first?.id, "Health's copy is edited in Health, not here")
        XCTAssertEqual(metrics.value("body_fat", on: day(8)), 30.2)
        XCTAssertEqual(metrics.latest("lean_mass")?.value, 141.0)
        XCTAssertTrue(metrics.series("bmi").isEmpty, "BMI is not mapped: no reader asks for it")
    }
}
