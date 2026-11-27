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

    /// v71: the activity evidence and the ceiling the day was priced with survive a round trip, and a
    /// change to either alone is a change (the upsert's "anything differs" guard names every column).
    func testFitnessColumnsRoundTripAndCountAsChanges() async throws {
        let store = try await WhoopStore.inMemory()
        let row = WhoopDailyEnergyRow(
            day: "2026-09-13", rawTotalKcal: 4_200, modelVersion: "whoop-bucket-v8",
            observedSeconds: 60_000, inferredSeconds: 10_000, modeledSeconds: 16_400,
            uncertaintyFraction: 0.2, weightKg: 212, weightSource: .history,
            aerobicSeconds: 6_900, hadLightActivity: true, peakMET: 5.43, peakMETSource: "appleWatch",
            peakMETSourceDay: "2026-08-24", measuredVO2max: 18.86, measuredWeightKg: 214.2,
            activityLevel: nil)
        _ = try await store.upsertWhoopDailyEnergy([row], deviceId: "w")
        let stored = try await store.whoopDailyEnergy(deviceId: "w", from: row.day, to: row.day)
        XCTAssertEqual(stored, [row])

        let estimated = WhoopDailyEnergyRow(
            day: row.day, rawTotalKcal: row.rawTotalKcal, modelVersion: row.modelVersion,
            observedSeconds: row.observedSeconds, inferredSeconds: row.inferredSeconds,
            modeledSeconds: row.modeledSeconds, uncertaintyFraction: row.uncertaintyFraction,
            weightKg: row.weightKg, weightSource: row.weightSource, aerobicSeconds: row.aerobicSeconds,
            hadLightActivity: true, peakMET: 6.4, peakMETSource: "jurca", activityLevel: 3)
        let changed = try await store.upsertWhoopDailyEnergy([estimated], deviceId: "w")
        XCTAssertEqual(changed, 1)
        let reread = try await store.whoopDailyEnergy(deviceId: "w", from: row.day, to: row.day)
        XCTAssertEqual(reread, [estimated])
    }

    /// v93: the everyday allowance and the sleep window it was resolved against survive a round trip on
    /// the day and on its buckets, a change to the allowance alone is a change, and an older row reads zero.
    func testEverydayColumnsRoundTripAndCountAsChanges() async throws {
        let store = try await WhoopStore.inMemory()
        let daily = WhoopDailyEnergyRow(
            day: "2026-11-21", rawTotalKcal: 4_450, modelVersion: "whoop-bucket-v10",
            observedSeconds: 60_000, inferredSeconds: 10_000, modeledSeconds: 16_400,
            uncertaintyFraction: 0.2, weightKg: 200.2, weightSource: .history,
            everydayKcal: 537, sleepWindowStartMinute: 1_410, sleepWindowEndMinute: 420)
        let bucket = WhoopEnergyBucketRow(
            day: daily.day, bucketStart: 1_795_300_000, durationSeconds: 300,
            basalKcal: 10.6, activeKcal: 0, context: "sedentary", evidence: "physiological",
            uncertaintyFraction: 0.35, everydayKcal: 3.2)
        try await store.replaceWhoopEnergyWindow(
            [.init(daily: daily, activeKcalByHour: [:], buckets: [bucket])], deviceId: "w")
        let storedDaily = try await store.whoopDailyEnergy(deviceId: "w", from: daily.day, to: daily.day)
        let storedBuckets = try await store.whoopEnergyBuckets(deviceId: "w", day: daily.day)
        XCTAssertEqual(storedDaily, [daily])
        XCTAssertEqual(storedBuckets, [bucket])

        let more = WhoopDailyEnergyRow(
            day: daily.day, rawTotalKcal: daily.rawTotalKcal, modelVersion: daily.modelVersion,
            observedSeconds: daily.observedSeconds, inferredSeconds: daily.inferredSeconds,
            modeledSeconds: daily.modeledSeconds, uncertaintyFraction: daily.uncertaintyFraction,
            weightKg: daily.weightKg, weightSource: daily.weightSource, everydayKcal: 540,
            sleepWindowStartMinute: 1_410, sleepWindowEndMinute: 420)
        let changed = try await store.upsertWhoopDailyEnergy([more], deviceId: "w")
        XCTAssertEqual(changed, 1)

        let older = WhoopDailyEnergyRow(
            day: "2026-11-01", rawTotalKcal: 3_900, modelVersion: "whoop-bucket-v9",
            observedSeconds: 1, inferredSeconds: 2, modeledSeconds: 3,
            uncertaintyFraction: 0.2, weightKg: 208.7, weightSource: .history)
        _ = try await store.upsertWhoopDailyEnergy([older], deviceId: "w")
        let olderRows = try await store.whoopDailyEnergy(deviceId: "w", from: older.day, to: older.day)
        let reread = try XCTUnwrap(olderRows.first)
        XCTAssertEqual(reread.everydayKcal, 0)
        XCTAssertNil(reread.sleepWindowStartMinute)
    }

    /// An allowance larger than the day it is part of, or a window minute outside a day, is refused.
    func testImplausibleEverydayValuesAreRefused() async throws {
        let store = try await WhoopStore.inMemory()
        let tooMuch = WhoopDailyEnergyRow(
            day: "2026-11-21", rawTotalKcal: 400, modelVersion: "whoop-bucket-v10",
            observedSeconds: 1, inferredSeconds: 2, modeledSeconds: 3,
            uncertaintyFraction: 0.2, weightKg: 80, weightSource: .history, everydayKcal: 500)
        let badMinute = WhoopDailyEnergyRow(
            day: "2026-11-22", rawTotalKcal: 2_400, modelVersion: "whoop-bucket-v10",
            observedSeconds: 1, inferredSeconds: 2, modeledSeconds: 3,
            uncertaintyFraction: 0.2, weightKg: 80, weightSource: .history, everydayKcal: 200,
            sleepWindowStartMinute: 1_440, sleepWindowEndMinute: 420)
        let written = try await store.upsertWhoopDailyEnergy([tooMuch, badMinute], deviceId: "w")
        XCTAssertEqual(written, 0)
    }

    /// A row written before v71 reads back with neutral evidence and no ceiling.
    func testAPreFitnessRowReadsNeutralDefaults() async throws {
        let store = try await WhoopStore.inMemory()
        let row = WhoopDailyEnergyRow(
            day: "2026-09-01", rawTotalKcal: 3_000, modelVersion: "whoop-bucket-v7",
            observedSeconds: 1, inferredSeconds: 2, modeledSeconds: 3,
            uncertaintyFraction: 0.2, weightKg: 212, weightSource: .profile)
        _ = try await store.upsertWhoopDailyEnergy([row], deviceId: "w")
        let rows = try await store.whoopDailyEnergy(deviceId: "w", from: row.day, to: row.day)
        let stored = try XCTUnwrap(rows.first)
        XCTAssertEqual(stored.aerobicSeconds, 0)
        XCTAssertFalse(stored.hadLightActivity)
        XCTAssertNil(stored.peakMET)
        XCTAssertNil(stored.activityLevel)
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

    /// The 2026-09-30 phone database: single-day repairs had filed each day's 23:55 bucket under the
    /// NEXT day. A multi-day recompute then wrote that bucket under its own day before the loop reached
    /// the next one, hit the (deviceId, bucketStart) key, and rolled the whole window back, which kept
    /// the history on superseded models. The window must land, with the bucket under its own day.
    func testWindowMovesABucketFiledUnderTheNextDayInsteadOfFailing() async throws {
        let store = try await WhoopStore.inMemory()
        func daily(_ day: String, _ version: String) -> WhoopDailyEnergyRow {
            WhoopDailyEnergyRow(day: day, rawTotalKcal: 2_000, modelVersion: version,
                                observedSeconds: 80_000, inferredSeconds: 0, modeledSeconds: 0,
                                uncertaintyFraction: 0.2, weightKg: 80, weightSource: .profile)
        }
        func bucket(_ day: String, _ start: Int) -> WhoopEnergyBucketRow {
            WhoopEnergyBucketRow(day: day, bucketStart: start, durationSeconds: 300, basalKcal: 6,
                                 activeKcal: 1, context: "rest", evidence: "physiological",
                                 uncertaintyFraction: 0.3)
        }
        let lateBucket = 1_789_000_000
        // The old single-day repair of the 29th, carrying the 28th's last bucket.
        try await store.replaceWhoopEnergyWindow(
            [.init(daily: daily("2026-09-29", "whoop-bucket-v6"), activeKcalByHour: [:],
                   buckets: [bucket("2026-09-29", lateBucket), bucket("2026-09-29", lateBucket + 300)])],
            deviceId: "whoop-a")

        let changed = try await store.replaceWhoopEnergyWindow([
            .init(daily: daily("2026-09-28", "whoop-bucket-v8"), activeKcalByHour: [:],
                  buckets: [bucket("2026-09-28", lateBucket)]),
            .init(daily: daily("2026-09-29", "whoop-bucket-v8"), activeKcalByHour: [:],
                  buckets: [bucket("2026-09-29", lateBucket + 300)]),
        ], deviceId: "whoop-a")

        XCTAssertGreaterThan(changed, 0)
        let rows = try await store.whoopDailyEnergy(deviceId: "whoop-a", from: "2026-09-28", to: "2026-09-29")
        XCTAssertEqual(rows.map(\.modelVersion), ["whoop-bucket-v8", "whoop-bucket-v8"])
        let day28 = try await store.whoopEnergyBuckets(deviceId: "whoop-a", day: "2026-09-28")
        let day29 = try await store.whoopEnergyBuckets(deviceId: "whoop-a", day: "2026-09-29")
        XCTAssertEqual(day28.map(\.bucketStart), [lateBucket])
        XCTAssertEqual(day29.map(\.bucketStart), [lateBucket + 300])
    }

    /// A bucket still filed under a day OUTSIDE the window moves to the day now claiming it.
    func testWindowTakesOverABucketFiledUnderADayOutsideIt() async throws {
        let store = try await WhoopStore.inMemory()
        func daily(_ day: String) -> WhoopDailyEnergyRow {
            WhoopDailyEnergyRow(day: day, rawTotalKcal: 2_000, modelVersion: "whoop-bucket-v8",
                                observedSeconds: 80_000, inferredSeconds: 0, modeledSeconds: 0,
                                uncertaintyFraction: 0.2, weightKg: 80, weightSource: .profile)
        }
        func bucket(_ day: String) -> WhoopEnergyBucketRow {
            WhoopEnergyBucketRow(day: day, bucketStart: 1_788_000_000, durationSeconds: 300, basalKcal: 6,
                                 activeKcal: 1, context: "rest", evidence: "physiological",
                                 uncertaintyFraction: 0.3)
        }
        try await store.replaceWhoopEnergyWindow(
            [.init(daily: daily("2026-09-11"), activeKcalByHour: [:], buckets: [bucket("2026-09-11")])],
            deviceId: "whoop-a")
        try await store.replaceWhoopEnergyWindow(
            [.init(daily: daily("2026-09-10"), activeKcalByHour: [:], buckets: [bucket("2026-09-10")])],
            deviceId: "whoop-a")
        let moved = try await store.whoopEnergyBuckets(deviceId: "whoop-a", day: "2026-09-10")
        let left = try await store.whoopEnergyBuckets(deviceId: "whoop-a", day: "2026-09-11")
        XCTAssertEqual(moved.count, 1)
        XCTAssertTrue(left.isEmpty)
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

final class WorkoutEnergySourceStoreTests: XCTestCase {
    func testASourceIsRecordedReplacedAndCleared() async throws {
        let store = try await WhoopStore.inMemory()
        let key = WorkoutKey(deviceId: "w", startTs: 1_000, sport: "Walking")
        try await store.setWorkoutEnergySource(.computed, for: key)
        var read = try await store.workoutEnergySources(deviceId: "w", from: 0, to: 2_000)
        XCTAssertEqual(read[key], .computed)
        try await store.setWorkoutEnergySource(.entered, for: key)
        read = try await store.workoutEnergySources(deviceId: "w", from: 0, to: 2_000)
        XCTAssertEqual(read[key], .entered)
        let other = try await store.workoutEnergySources(deviceId: "x", from: 0, to: 2_000)
        XCTAssertTrue(other.isEmpty)
        try await store.clearWorkoutEnergySource(for: key)
        read = try await store.workoutEnergySources(deviceId: "w", from: 0, to: 2_000)
        XCTAssertNil(read[key])
    }
}
