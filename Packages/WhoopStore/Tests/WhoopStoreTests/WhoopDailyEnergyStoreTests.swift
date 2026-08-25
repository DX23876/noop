import XCTest
@testable import WhoopStore

final class WhoopDailyEnergyStoreTests: XCTestCase {
    func testUpsertIsIdempotentAndReadsProvenance() async throws {
        let store = try await WhoopStore.inMemory()
        let row = WhoopDailyEnergyRow(
            day: "2026-08-25", rawTotalKcal: 2_300, modelVersion: "whoop-bucket-v1",
            observedSeconds: 60_000, inferredSeconds: 10_000, modeledSeconds: 16_400,
            uncertaintyFraction: 0.16, weightKg: 79.5, weightSource: .history)
        let first = try await store.upsertWhoopDailyEnergy([row], deviceId: "whoop-a")
        let second = try await store.upsertWhoopDailyEnergy([row], deviceId: "whoop-a")
        let stored = try await store.whoopDailyEnergy(
            deviceId: "whoop-a", from: row.day, to: row.day)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(stored, [row])
    }

    func testInvalidRowsAreIgnoredAndDeleteIsDeviceScoped() async throws {
        let store = try await WhoopStore.inMemory()
        let valid = WhoopDailyEnergyRow(
            day: "2026-08-25", rawTotalKcal: 2_000, modelVersion: "v1",
            observedSeconds: 1, inferredSeconds: 2, modeledSeconds: 3,
            uncertaintyFraction: 0.2, weightKg: 80, weightSource: .profile)
        let invalid = WhoopDailyEnergyRow(
            day: "bad", rawTotalKcal: .nan, modelVersion: "",
            observedSeconds: -1, inferredSeconds: 0, modeledSeconds: 0,
            uncertaintyFraction: 2, weightKg: 0, weightSource: .profile)
        let first = try await store.upsertWhoopDailyEnergy([valid, invalid], deviceId: "a")
        let second = try await store.upsertWhoopDailyEnergy([valid], deviceId: "b")
        let deleted = try await store.deleteWhoopDailyEnergy(
            deviceId: "a", from: valid.day, to: valid.day)
        let aRows = try await store.whoopDailyEnergy(
            deviceId: "a", from: valid.day, to: valid.day)
        let bRows = try await store.whoopDailyEnergy(
            deviceId: "b", from: valid.day, to: valid.day)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)
        XCTAssertEqual(deleted, 1)
        XCTAssertTrue(aRows.isEmpty)
        XCTAssertEqual(bRows.count, 1)
    }
}
