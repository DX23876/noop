import XCTest
@testable import WhoopStore

final class EnergyCalibrationStoreTests: XCTestCase {
    func testV45BucketsRoundTripAndUpsertIdempotently() async throws {
        let store = try await WhoopStore.inMemory()
        let first = HealthEnergyBucketRow(
            deviceId: "apple-health", sourceId: "com.apple.watch", sourceKind: .appleWatch,
            bucketStart: 1_700_000_123, activeKcal: 12, averageHr: 110, steps: 130,
            distanceM: 98, strideM: 0.75, workout: true, coverageSeconds: 290,
            sampleCount: 12, quality: 0.9)
        try await store.upsertHealthEnergyBuckets([first])
        var rows = try await store.healthEnergyBuckets(
            deviceId: "apple-health", from: 1_700_000_000, to: 1_700_001_000,
            eligibleOnly: true)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bucketStart % 300, 0)
        XCTAssertEqual(rows[0].activeKcal, 12)

        var changed = first
        changed.activeKcal = 15
        try await store.upsertHealthEnergyBuckets([changed])
        rows = try await store.healthEnergyBuckets(
            deviceId: "apple-health", from: 1_700_000_000, to: 1_700_001_000)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].activeKcal, 15)
    }

    func testOnlyAppleWatchIsCalibrationEligibleAndWindowDeleteIsBounded() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertHealthEnergyBuckets([
            .init(deviceId: "apple-health", sourceId: "watch", sourceKind: .appleWatch,
                  bucketStart: 1_000, activeKcal: 3),
            .init(deviceId: "apple-health", sourceId: "phone", sourceKind: .iPhone,
                  bucketStart: 1_000, activeKcal: 4),
            .init(deviceId: "apple-health", sourceId: "watch", sourceKind: .appleWatch,
                  bucketStart: 2_000, activeKcal: 5),
        ])
        let eligible = try await store.healthEnergyBuckets(
            deviceId: "apple-health", from: 0, to: 3_000, eligibleOnly: true)
        XCTAssertEqual(eligible.count, 2)
        try await store.deleteHealthEnergyBuckets(deviceId: "apple-health", from: 900, to: 1_500)
        let remaining = try await store.healthEnergyBuckets(
            deviceId: "apple-health", from: 0, to: 3_000)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].activeKcal, 5)
    }

    func testMalformedValuesAreDroppedAndBoundsClamped() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertHealthEnergyBuckets([
            .init(deviceId: "apple-health", sourceId: "watch", sourceKind: .appleWatch,
                  bucketStart: 300, activeKcal: .infinity, averageHr: 500, steps: -1,
                  coverageSeconds: 900, sampleCount: -2, quality: 5)
        ])
        let rows = try await store.healthEnergyBuckets(
            deviceId: "apple-health", from: 0, to: 1_000)
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.activeKcal)
        XCTAssertNil(row.averageHr)
        XCTAssertNil(row.steps)
        XCTAssertEqual(row.coverageSeconds, 300)
        XCTAssertEqual(row.sampleCount, 0)
        XCTAssertEqual(row.quality, 1)
    }
}
