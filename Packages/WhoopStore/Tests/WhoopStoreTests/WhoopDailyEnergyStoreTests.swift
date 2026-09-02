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

    // MARK: - v49 atomic model window

    func testEnergyWindowPublishesDailyAndHourlyRowsTogether() async throws {
        let store = try await WhoopStore.inMemory()
        let daily = WhoopDailyEnergyRow(
            day: "2026-08-28", rawTotalKcal: 2_150, modelVersion: "whoop-bucket-v4",
            observedSeconds: 72_000, inferredSeconds: 8_000, modeledSeconds: 4_000,
            physiologicalSeconds: 2_000,
            contextJSON: "{\"locomotion\":3600,\"unresolvedElevatedHR\":300}",
            uncertaintyFraction: 0.21, weightKg: 80, weightSource: .history)

        let changed = try await store.replaceWhoopEnergyWindow(
            [.init(daily: daily, activeKcalByHour: [7: 140, 18: 90])], deviceId: "whoop-a")
        let dailyRows = try await store.whoopDailyEnergy(
            deviceId: "whoop-a", from: daily.day, to: daily.day)
        let hours = try await store.whoopEnergyHours(
            deviceId: "whoop-a", from: daily.day, to: daily.day)

        XCTAssertGreaterThan(changed, 0)
        XCTAssertEqual(dailyRows, [daily])
        XCTAssertEqual(hours.map(\.hour), [7, 18])
    }

    func testEnergyWindowPublishesAndReplacesTimelineBucketsAtomically() async throws {
        let store = try await WhoopStore.inMemory()
        let daily = WhoopDailyEnergyRow(
            day: "2026-08-28", rawTotalKcal: 2_150, modelVersion: "whoop-bucket-v5",
            observedSeconds: 72_000, inferredSeconds: 8_000, modeledSeconds: 4_000,
            uncertaintyFraction: 0.21, weightKg: 80, weightSource: .history)
        let first = WhoopEnergyBucketRow(
            day: daily.day, bucketStart: 1_777_334_400, durationSeconds: 300,
            basalKcal: 6.2, activeKcal: 0, context: "unresolvedElevatedHR",
            evidence: "physiological", uncertaintyFraction: 0.3)
        let second = WhoopEnergyBucketRow(
            day: daily.day, bucketStart: 1_777_334_700, durationSeconds: 300,
            basalKcal: 6.2, activeKcal: 4.5, context: "locomotion",
            evidence: "movement", uncertaintyFraction: 0.15)

        try await store.replaceWhoopEnergyWindow(
            [.init(daily: daily, activeKcalByHour: [7: 4.5], buckets: [first, second])],
            deviceId: "whoop-a")
        try await store.replaceWhoopEnergyWindow(
            [.init(daily: daily, activeKcalByHour: [:], buckets: [first])],
            deviceId: "whoop-a")

        let buckets = try await store.whoopEnergyBuckets(deviceId: "whoop-a", day: daily.day)
        XCTAssertEqual(buckets, [first], "a recompute must not leave stale timeline buckets")
    }

    func testInvalidEnergyWindowDoesNotPartiallyReplaceExistingRows() async throws {
        let store = try await WhoopStore.inMemory()
        let existing = WhoopDailyEnergyRow(
            day: "2026-08-28", rawTotalKcal: 2_000, modelVersion: "whoop-bucket-v4",
            observedSeconds: 80_000, inferredSeconds: 0, modeledSeconds: 0,
            uncertaintyFraction: 0.2, weightKg: 80, weightSource: .profile)
        try await store.replaceWhoopEnergyWindow(
            [.init(daily: existing, activeKcalByHour: [6: 100])], deviceId: "whoop-a")
        let invalid = WhoopDailyEnergyRow(
            day: "bad", rawTotalKcal: .nan, modelVersion: "",
            observedSeconds: -1, inferredSeconds: 0, modeledSeconds: 0,
            uncertaintyFraction: 2, weightKg: 0, weightSource: .profile)

        let changed = try await store.replaceWhoopEnergyWindow(
            [.init(daily: existing, activeKcalByHour: [6: 50]),
             .init(daily: invalid, activeKcalByHour: [7: 50])], deviceId: "whoop-a")
        let hours = try await store.whoopEnergyHours(
            deviceId: "whoop-a", from: existing.day, to: existing.day)

        XCTAssertEqual(changed, 0)
        XCTAssertEqual(hours.map(\.activeKcal), [100])
    }
}
