import XCTest
@testable import Strand
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// The healthspan pass against a real in-memory store: zone minutes banked from raw HR, weekly rows
/// re-derived from permanent per-day data, a workout logged by two sources counted once.
@MainActor
final class HealthspanPassTests: XCTestCase {

    private let strap = "my-whoop", computed = "my-whoop-noop"
    private let newestDay = "2026-10-10"   // a Saturday

    private func midnight(_ day: String) -> Int { IntelligenceEngine.midnightForDayKey(day, offsetSec: 0)! }

    private func seededStore() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        let days = (0..<40).map { HealthspanWindow.dayKey(newestDay, plus: -$0) }
        _ = try await store.upsertDailyMetrics(days.map {
            DailyMetric(day: $0, totalSleepMin: 420, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                        disturbances: nil, restingHr: 52, avgHrv: nil, recovery: nil, strain: nil,
                        exerciseCount: nil, steps: 8000)
        }, deviceId: computed)
        _ = try await store.upsertMetricSeries(days.map { MetricPoint(day: $0, key: "rhr_primary_session", value: 60) }
                                               + [MetricPoint(day: "2026-09-20", key: "vo2max_est", value: 44)],
                                               deviceId: computed)
        // Every night 23:00–06:00: perfectly regular.
        _ = try await store.upsertSleepSessions(days.map {
            CachedSleepSession(startTs: midnight($0) - 3_600, endTs: midnight($0) + 6 * 3_600, efficiency: nil,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil)
        }, deviceId: computed)
        // 60 min of strength every Saturday, logged by both Apple Health and Hevy.
        let saturdays = days.filter { IntelligenceEngine.saturdayKey(onOrBefore: $0) == $0 }
        for source in ["apple-health", "hevy"] {
            _ = try await store.upsertWorkouts(saturdays.map {
                WorkoutRow(startTs: midnight($0) + 10 * 3_600, endTs: midnight($0) + 11 * 3_600,
                           sport: "Strength Training", source: source, durationS: 3_600, energyKcal: nil,
                           avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
            }, deviceId: source)
        }
        // A 30-minute, 2.4 km walk on the newest day at 140 bpm: 61 % of the 60–190 reserve, zone 1–3.
        let walk = midnight(newestDay) + 17 * 3_600
        _ = try await store.upsertWorkouts([
            WorkoutRow(startTs: walk, endTs: walk + 1_800, sport: "Walking", source: strap, durationS: 1_800,
                       energyKcal: nil, avgHr: 140, maxHr: nil, strain: nil, distanceM: 2_400, zonesJSON: nil,
                       notes: nil, steps: nil)
        ], deviceId: strap)
        _ = try await store.insert(Streams(hr: (0..<1_800).map { HRSample(ts: walk + $0, bpm: 140) }), deviceId: strap)
        // Raw heart rate for every worn day (one quiet reading an hour, away from the walk) except one whose
        // raw data is already gone, 25 days back.
        let rawGone = HealthspanWindow.dayKey(newestDay, plus: -25)
        _ = try await store.insert(Streams(hr: days.filter { $0 != rawGone }.flatMap { day in
            (0..<24).filter { $0 != 17 }.map { HRSample(ts: midnight(day) + $0 * 3_600 + 30, bpm: 58) }
        }), deviceId: strap)
        return store
    }

    private func value(_ store: WhoopStore, _ key: String, _ day: String) async throws -> Double? {
        try await store.metricSeries(deviceId: computed, key: key, from: day, to: day).first?.value
    }

    func testFirstRunBanksZonesAndWritesEveryEligibleWeek() async throws {
        let store = try await seededStore()
        await IntelligenceEngine.runHealthspanPass(store: store, strapId: strap, computedId: computed, age: 30,
                                                   sex: "male", hrMaxOverride: 190,
                                                   oldestDay: HealthspanWindow.dayKey(newestDay, plus: -20),
                                                   newestDay: newestDay, tzOffset: 0)

        let zone13 = try await value(store, IntelligenceEngine.healthspanZone13Key, newestDay)
        XCTAssertEqual(try XCTUnwrap(zone13), 30, accuracy: 0.1)
        let quietDay = try await value(store, IntelligenceEngine.healthspanZone13Key, "2026-10-09")
        XCTAssertEqual(quietDay, 0)

        // 40 days of data: the weeks keyed 09-26, 10-03 and 10-10 have 30+ nights, 09-19 does not.
        let ages = try await store.metricSeries(deviceId: computed, key: IntelligenceEngine.healthspanAgeKey,
                                                from: "2026-01-01", to: newestDay)
        XCTAssertEqual(ages.map(\.day), ["2026-09-26", "2026-10-03", "2026-10-10"])

        func input(_ c: HealthspanEngine.Component) async throws -> Double? {
            try await value(store, IntelligenceEngine.healthspanInputKey(c), newestDay)
        }
        let consistency = try await input(.sleepConsistency)
        XCTAssertEqual(try XCTUnwrap(consistency), 100, accuracy: 1e-9)
        let rhr = try await input(.restingHR)
        XCTAssertEqual(rhr, 60)
        // Six Saturdays of 60 min in 40 days, the Apple Health and Hevy copies counted once.
        let strength = try await input(.strength)
        XCTAssertEqual(try XCTUnwrap(strength), 6 * 60.0 / 40 * 7, accuracy: 1e-9)
        let covered = try await value(store, IntelligenceEngine.healthspanCoveredDaysKey, newestDay)
        XCTAssertEqual(covered, 40)
        // Without an entered value, Apple Health or a training estimate there is no VO₂max: the stored
        // non-exercise estimate is never read.
        let vo2 = try await input(.vo2max)
        XCTAssertNil(vo2)
        let lean = try await input(.leanMass)
        XCTAssertNil(lean)
        let recentRHR = try await value(store, IntelligenceEngine.healthspanRecentInputKey(.restingHR), newestDay)
        XCTAssertEqual(recentRHR, 60)

        // What each measure stands on, from the same window days: every night and day, consistency from the
        // fifth night on (it needs four before it), zone minutes on the 34 days raw HR still covered, and six
        // strength sessions with the two-source copies counted once. No VO₂max, so no readings.
        func count(_ c: HealthspanEngine.Component) async throws -> Double? {
            try await value(store, IntelligenceEngine.healthspanCountKey(c), newestDay)
        }
        let nights = try await count(.sleepDuration), steps = try await count(.dailySteps)
        let hrNights = try await count(.restingHR), consistent = try await count(.sleepConsistency)
        let zoneDays = try await count(.zone13), sessions = try await count(.strength)
        let readings = try await count(.vo2max)
        XCTAssertEqual(nights, 40)
        XCTAssertEqual(steps, 40)
        XCTAssertEqual(hrNights, 40)
        XCTAssertEqual(consistent, 36)
        XCTAssertEqual(zoneDays, 34)
        XCTAssertEqual(sessions, 6)
        XCTAssertNil(readings)
    }

    /// An entered VO₂max outranks the training estimate; body fat gives lean mass; a later pass without them
    /// leaves no stale input behind.
    func testManualVO2maxAndBodyFatThenRewrite() async throws {
        let store = try await seededStore()
        let window = HealthspanWindow.dayKey(newestDay, plus: -20)
        await IntelligenceEngine.runHealthspanPass(store: store, strapId: strap, computedId: computed, age: 30,
                                                   sex: "male", hrMaxOverride: 190, oldestDay: window,
                                                   newestDay: newestDay, tzOffset: 0,
                                                   manualVO2max: (day: "2026-10-01", value: 51),
                                                   trainingVO2max: [(day: "2026-10-08", value: 44)],
                                                   bodyFat: [(day: "2026-09-01", value: 18)])
        let vo2 = try await value(store, IntelligenceEngine.healthspanInputKey(.vo2max), newestDay)
        XCTAssertEqual(vo2, 51)
        let source = try await value(store, IntelligenceEngine.healthspanVO2SourceKey, newestDay)
        XCTAssertEqual(source, Double(HealthspanVO2.Source.manual.rawValue))
        let lean = try await value(store, IntelligenceEngine.healthspanInputKey(.leanMass), newestDay)
        XCTAssertEqual(lean, 82)
        // The basis: one entered reading measured 10-01, lean mass from the 09-01 body-fat reading.
        let readings = try await value(store, IntelligenceEngine.healthspanCountKey(.vo2max), newestDay)
        XCTAssertEqual(readings, 1)
        let vo2Day = try await value(store, IntelligenceEngine.healthspanVO2DayKey, newestDay)
        XCTAssertEqual(vo2Day.flatMap { HealthspanBasis.dayKey(number: $0) }, "2026-10-01")
        let fatDay = try await value(store, IntelligenceEngine.healthspanBodyFatDayKey, newestDay)
        XCTAssertEqual(fatDay.flatMap { HealthspanBasis.dayKey(number: $0) }, "2026-09-01")

        await IntelligenceEngine.runHealthspanPass(store: store, strapId: strap, computedId: computed, age: 30,
                                                   sex: "male", hrMaxOverride: 190, oldestDay: window,
                                                   newestDay: newestDay, tzOffset: 0,
                                                   trainingVO2max: [(day: "2026-10-08", value: 44)])
        let vo2After = try await value(store, IntelligenceEngine.healthspanInputKey(.vo2max), newestDay)
        XCTAssertEqual(vo2After, 44)
        let leanAfter = try await value(store, IntelligenceEngine.healthspanInputKey(.leanMass), newestDay)
        XCTAssertNil(leanAfter)
        let sourceAfter = try await value(store, IntelligenceEngine.healthspanVO2SourceKey, newestDay)
        XCTAssertEqual(sourceAfter, Double(HealthspanVO2.Source.training.rawValue))
        let vo2DayAfter = try await value(store, IntelligenceEngine.healthspanVO2DayKey, newestDay)
        XCTAssertEqual(vo2DayAfter.flatMap { HealthspanBasis.dayKey(number: $0) }, "2026-10-08")
        let fatDayAfter = try await value(store, IntelligenceEngine.healthspanBodyFatDayKey, newestDay)
        XCTAssertNil(fatDayAfter)
    }

    /// A first run banks zone minutes for every day raw heart rate still covers, not only the pass window;
    /// a worn day whose raw heart rate is gone keeps what was banked while it existed.
    func testFirstRunBanksTheWholeRawRetention() async throws {
        let store = try await seededStore()
        let early = HealthspanWindow.dayKey(newestDay, plus: -30)
        let walk = midnight(early) + 17 * 3_600
        _ = try await store.upsertWorkouts([
            WorkoutRow(startTs: walk, endTs: walk + 1_200, sport: "Walking", source: strap, durationS: 1_200,
                       energyKcal: nil, avgHr: 140, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil,
                       notes: nil, steps: nil)
        ], deviceId: strap)
        _ = try await store.insert(Streams(hr: (0..<1_200).map { HRSample(ts: walk + $0, bpm: 140) }), deviceId: strap)
        let noRaw = HealthspanWindow.dayKey(newestDay, plus: -25)
        _ = try await store.upsertMetricSeries([MetricPoint(day: noRaw, key: IntelligenceEngine.healthspanZone13Key,
                                                            value: 77)], deviceId: computed)
        await IntelligenceEngine.runHealthspanPass(store: store, strapId: strap, computedId: computed, age: 30,
                                                   sex: "male", hrMaxOverride: 190,
                                                   oldestDay: HealthspanWindow.dayKey(newestDay, plus: -2),
                                                   newestDay: newestDay, tzOffset: 0)
        let earlyZone = try await value(store, IntelligenceEngine.healthspanZone13Key, early)
        XCTAssertEqual(try XCTUnwrap(earlyZone), 20, accuracy: 0.1)
        let kept = try await value(store, IntelligenceEngine.healthspanZone13Key, noRaw)
        XCTAssertEqual(kept, 77)
    }

    /// The AI-21/AI-22 rebuild end to end: the deletion clears every week and the AI-21 training days but
    /// keeps banked zone minutes, and the next pass writes the weeks again.
    func testMigrationDeletesThenPassRebuilds() async throws {
        let store = try await seededStore()
        let window = HealthspanWindow.dayKey(newestDay, plus: -20)
        await IntelligenceEngine.runHealthspanPass(store: store, strapId: strap, computedId: computed, age: 30,
                                                   sex: "male", hrMaxOverride: 190, oldestDay: window,
                                                   newestDay: newestDay, tzOffset: 0)
        _ = try await store.upsertMetricSeries([MetricPoint(day: newestDay,
                                                            key: IntelligenceEngine.healthspanLegacyTrainingVO2Key,
                                                            value: 40)], deviceId: computed)
        try await IntelligenceEngine.deleteHealthspanWeeks(store: store, deviceId: strap)
        let cleared = try await store.metricSeries(deviceId: computed, key: IntelligenceEngine.healthspanAgeKey,
                                                   from: "2026-01-01", to: newestDay)
        XCTAssertTrue(cleared.isEmpty)
        let legacy = try await value(store, IntelligenceEngine.healthspanLegacyTrainingVO2Key, newestDay)
        XCTAssertNil(legacy)
        let zone = try await value(store, IntelligenceEngine.healthspanZone13Key, newestDay)
        XCTAssertNotNil(zone)

        await IntelligenceEngine.runHealthspanPass(store: store, strapId: strap, computedId: computed, age: 30,
                                                   sex: "male", hrMaxOverride: 190, oldestDay: window,
                                                   newestDay: newestDay, tzOffset: 0)
        let rebuilt = try await store.metricSeries(deviceId: computed, key: IntelligenceEngine.healthspanAgeKey,
                                                   from: "2026-01-01", to: newestDay)
        XCTAssertEqual(rebuilt.map(\.day), ["2026-09-26", "2026-10-03", "2026-10-10"])
    }

    func testNoTargetsForAnUnsetSexWritesNothing() async throws {
        let store = try await seededStore()
        await IntelligenceEngine.runHealthspanPass(store: store, strapId: strap, computedId: computed, age: 30,
                                                   sex: "nonbinary", hrMaxOverride: 190,
                                                   oldestDay: HealthspanWindow.dayKey(newestDay, plus: -20),
                                                   newestDay: newestDay, tzOffset: 0)
        let ages = try await store.metricSeries(deviceId: computed, key: IntelligenceEngine.healthspanAgeKey,
                                                from: "2026-01-01", to: newestDay)
        XCTAssertTrue(ages.isEmpty)
    }
}
