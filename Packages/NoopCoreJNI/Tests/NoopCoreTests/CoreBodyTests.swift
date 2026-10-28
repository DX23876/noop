import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

/// The Body screen on Android (parity plan 2.3): a measurement session is built by the core and read back through
/// the shared reader, comparisons and Navy estimate.
@MainActor
final class CoreBodyTests: XCTestCase {
    func testSessionRowsReadBackWithTheirComparisonAndNavyEstimate() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let now = Date()
        let before = CoreBody.rows(values: ["waist": 92, "neck": 40, "height": 180], deviceId: "my-whoop",
                                   takenAt: now.addingTimeInterval(-45 * 86_400), note: nil)
        XCTAssertEqual(before.count, 3)
        XCTAssertTrue(before.allSatisfy { $0.id.hasPrefix($0.markerKey + "-") })
        _ = try await store.upsertLabMarkers(before)
        _ = try await store.upsertLabMarkers(CoreBody.rows(values: ["waist": 89, "bogus": -1],
                                                           deviceId: "my-whoop", takenAt: now, note: "after"))
        let weighed = await CoreBody.logWeight(store: store, kg: 88, at: now, note: nil)
        XCTAssertTrue(weighed)
        let output = await CoreBody.snapshot(reader: reader, days: 120, comparisonDays: 42, equation: .male, now: now)
        XCTAssertEqual(output.changes.first { $0.key == "waist" }?.deltaCm ?? 0, -3, accuracy: 1e-9)
        XCTAssertNotNil(output.navyEstimate)
        XCTAssertTrue(output.navyMissing.isEmpty)
        XCTAssertEqual(output.weight.last?.value, 88)
        XCTAssertNotNil(output.weighIns.first?.id)
        XCTAssertTrue(output.measured.contains { $0.key == "neck" })
    }
}
