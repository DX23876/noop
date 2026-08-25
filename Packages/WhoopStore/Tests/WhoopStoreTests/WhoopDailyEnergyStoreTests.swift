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

    // MARK: - v48 hourly profile

    func testHourlyProfileRoundTripsAndIsDeviceScoped() async throws {
        let store = try await WhoopStore.inMemory()
        let written = try await store.replaceWhoopEnergyHours(
            day: "2026-08-25", deviceId: "whoop-a", activeKcalByHour: [7: 120.5, 18: 60])
        try await store.replaceWhoopEnergyHours(
            day: "2026-08-25", deviceId: "whoop-b", activeKcalByHour: [9: 999])

        let rows = try await store.whoopEnergyHours(
            deviceId: "whoop-a", from: "2026-08-01", to: "2026-08-31")
        XCTAssertEqual(written, 2)
        XCTAssertEqual(rows.map(\.hour), [7, 18])
        XCTAssertEqual(rows.first?.activeKcal ?? 0, 120.5, accuracy: 0.001)
        // The other strap's day is untouched by this one's write.
        let other = try await store.whoopEnergyHours(
            deviceId: "whoop-b", from: "2026-08-01", to: "2026-08-31")
        XCTAssertEqual(other.map(\.hour), [9])
    }

    /// A recompute must REPLACE the day, not merge into it. If the new pass produces fewer hours than
    /// the last one, a merge would leave the old hour standing and the shape would be fitted from a
    /// day that never happened.
    func testRecomputingADayLeavesNoStaleHourBehind() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceWhoopEnergyHours(
            day: "2026-08-25", deviceId: "a", activeKcalByHour: [6: 100, 7: 100, 20: 100])
        try await store.replaceWhoopEnergyHours(
            day: "2026-08-25", deviceId: "a", activeKcalByHour: [6: 50])

        let rows = try await store.whoopEnergyHours(deviceId: "a", from: "2026-08-25", to: "2026-08-25")
        XCTAssertEqual(rows.map(\.hour), [6], "hours 7 and 20 must not survive a recompute")
        XCTAssertEqual(rows.first?.activeKcal ?? 0, 50, accuracy: 0.001)
    }

    func testImplausibleHoursAndValuesAreRejectedWithoutPoisoningTheDay() async throws {
        let store = try await WhoopStore.inMemory()
        let written = try await store.replaceWhoopEnergyHours(
            day: "2026-08-25", deviceId: "a",
            activeKcalByHour: [-1: 50, 24: 50, 8: .nan, 9: -5, 10: 99_999, 11: 42])
        let rows = try await store.whoopEnergyHours(deviceId: "a", from: "2026-08-25", to: "2026-08-25")
        XCTAssertEqual(written, 1)
        XCTAssertEqual(rows.map(\.hour), [11])
    }

    func testMalformedDayOrDeviceWritesNothing() async throws {
        let store = try await WhoopStore.inMemory()
        let badDay = try await store.replaceWhoopEnergyHours(
            day: "2026-8-25", deviceId: "a", activeKcalByHour: [8: 40])
        let noDevice = try await store.replaceWhoopEnergyHours(
            day: "2026-08-25", deviceId: "", activeKcalByHour: [8: 40])
        XCTAssertEqual(badDay, 0)
        XCTAssertEqual(noDevice, 0)
    }
}
