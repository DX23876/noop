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
        // VO₂max from the walk (ACSM at 80 m/min, 61.5 % of reserve), never from the non-exercise estimate.
        let walkVO2 = 3.5 + (0.1 * 80) / (80.0 / 130)
        let banked = try await value(store, IntelligenceEngine.healthspanTrainingVO2Key, newestDay)
        XCTAssertEqual(try XCTUnwrap(banked), walkVO2, accuracy: 0.05)
        let vo2 = try await input(.vo2max)
        XCTAssertEqual(try XCTUnwrap(vo2), walkVO2, accuracy: 0.05)
        let source = try await value(store, IntelligenceEngine.healthspanVO2SourceKey, newestDay)
        XCTAssertEqual(source, Double(HealthspanVO2.Source.training.rawValue))
        let lean = try await input(.leanMass)
        XCTAssertNil(lean)
        let recentRHR = try await value(store, IntelligenceEngine.healthspanRecentInputKey(.restingHR), newestDay)
        XCTAssertEqual(recentRHR, 60)
    }

    /// An entered VO₂max outranks the walk; body fat gives lean mass; a later pass without them leaves no
    /// stale input behind.
    func testManualVO2maxAndBodyFatThenRewrite() async throws {
        let store = try await seededStore()
        let window = HealthspanWindow.dayKey(newestDay, plus: -20)
        await IntelligenceEngine.runHealthspanPass(store: store, strapId: strap, computedId: computed, age: 30,
                                                   sex: "male", hrMaxOverride: 190, oldestDay: window,
                                                   newestDay: newestDay, tzOffset: 0,
                                                   manualVO2max: (day: "2026-10-01", value: 51),
                                                   bodyFat: [(day: "2026-09-01", value: 18)])
        let vo2 = try await value(store, IntelligenceEngine.healthspanInputKey(.vo2max), newestDay)
        XCTAssertEqual(vo2, 51)
        let source = try await value(store, IntelligenceEngine.healthspanVO2SourceKey, newestDay)
        XCTAssertEqual(source, Double(HealthspanVO2.Source.manual.rawValue))
        let lean = try await value(store, IntelligenceEngine.healthspanInputKey(.leanMass), newestDay)
        XCTAssertEqual(lean, 82)

        await IntelligenceEngine.runHealthspanPass(store: store, strapId: strap, computedId: computed, age: 30,
                                                   sex: "male", hrMaxOverride: 190, oldestDay: window,
                                                   newestDay: newestDay, tzOffset: 0)
        let leanAfter = try await value(store, IntelligenceEngine.healthspanInputKey(.leanMass), newestDay)
        XCTAssertNil(leanAfter)
        let sourceAfter = try await value(store, IntelligenceEngine.healthspanVO2SourceKey, newestDay)
        XCTAssertEqual(sourceAfter, Double(HealthspanVO2.Source.training.rawValue))
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
