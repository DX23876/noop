import XCTest
import WhoopStore
@testable import StrandCore

/// Android's Health Connect import banks weigh-ins under `health-connect`; the one weight series read only manual and
/// Apple Health, so none of them reached a screen (2026-11-11). They now feed the phone-store tier, and a manual
/// weigh-in still wins its day.
final class WeightSeriesHealthConnectTests: XCTestCase {
    func testHealthConnectWeighInsReachTheSeriesAndManualStillWins() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-11-09", key: WhoopStore.bodyWeightMetricKey, value: 80.2),
                                                MetricPoint(day: "2026-11-10", key: WhoopStore.bodyWeightMetricKey, value: 80.0)],
                                               deviceId: MetricResolver.healthConnectSource)
        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-11-10", key: WhoopStore.bodyWeightMetricKey, value: 79.5)],
                                               deviceId: WhoopStore.noopWeightSourceId)
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let points = await WeightSeries.series(reader: reader, from: "2026-11-01", to: "2026-11-30")
        XCTAssertEqual(points.map(\.day), ["2026-11-09", "2026-11-10"])
        XCTAssertEqual(points.first?.value, 80.2)
        XCTAssertEqual(points.first?.source, .appleHealth, "the phone's health store tier")
        XCTAssertEqual(points.last?.value, 79.5)
        XCTAssertEqual(points.last?.source, .manual)
    }
}
