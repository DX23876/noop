import XCTest
@testable import StrandAnalytics
import WhoopStore

/// The pure rules behind recipe AI-35 (the algorithm review of 2026-11-10): the early spread half-life of the
/// Charge baselines, and the per-night Rest traits.
final class AnalysisReviewAI35Tests: XCTestCase {

    // MARK: - Early spread (MetricCfg.earlyHalfLifeS)

    /// A config without an early spread half-life folds exactly as before the field existed.
    func testNoEarlySpreadHalfLifeIsTheOldFold() {
        let values: [Double?] = [50, 41, 58, nil, 47, 39, 61, 52, 44, 55, 49, 63, 38, 51]
        let shared = Baselines.hrvCfg
        let explicitNil = MetricCfg(minVal: shared.minVal, maxVal: shared.maxVal, floorSpread: shared.floorSpread,
                                    halfLifeB: shared.halfLifeB, halfLifeS: shared.halfLifeS, earlyHalfLifeS: nil)
        XCTAssertEqual(Baselines.foldHistory(values, cfg: shared), Baselines.foldHistory(values, cfg: explicitNil))
    }

    /// With the early half-life the spread reaches a varied history's real spread within the young phase,
    /// where the 21-night half-life leaves it near the floor.
    func testTheEarlySpreadHalfLifeLearnsTheRealSpreadQuickly() {
        let values: [Double?] = [55, 61, 52, 63, 50, 58, 64, 51]   // resting HR swinging about ±5 bpm
        let slow = Baselines.foldHistory(values, cfg: Baselines.restingHRCfg)
        let fast = Baselines.foldHistory(values, cfg: ChargeBaselines.restingHRCfg)
        XCTAssertGreaterThan(fast.spread, slow.spread)
        XCTAssertGreaterThan(fast.spread, 3.0)
        XCTAssertLessThan(slow.spread, 3.0)
    }

    /// After the young phase both learn at the same 21-night half-life.
    func testAfterTheYoungPhaseTheSpreadHalfLifeIsUnchanged() {
        let cfg = ChargeBaselines.restingHRCfg
        let young = BaselineState(baseline: 55, spread: 3, nValid: Baselines.earlyAdaptNights,
                                  nightsSinceUpdate: 0, status: .provisional)
        let charge = Baselines.update(young, value: 58, cfg: cfg)
        let shared = Baselines.update(young, value: 58, cfg: Baselines.restingHRCfg)
        XCTAssertEqual(charge, shared)
    }

    // MARK: - Per-night Rest traits

    private static func nights(from start: String, _ hours: [Double]) -> [AnalyticsEngine.Rest.Night] {
        hours.enumerated().map { i, h in .init(day: HealthspanWindow.dayKey(start, plus: i), tstHours: h) }
    }

    /// A night's need reads only the nights before it: a long or short night cannot move its own target.
    func testANightsNeedReadsOnlyTheNightsBeforeIt() {
        let before = Self.nights(from: "2026-10-01", Array(repeating: 9.0, count: 20))
        let day = "2026-10-21"
        let a = AnalyticsEngine.Rest.inputs(forDay: day, nights: before + [.init(day: day, tstHours: 4)], age: 35)
        let b = AnalyticsEngine.Rest.inputs(forDay: day, nights: before + [.init(day: day, tstHours: 12)], age: 35)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.needHours, 9.0, accuracy: 1e-9)
    }

    /// Later nights never change an earlier night's traits.
    func testLaterNightsDoNotMoveAnEarlierNightsTraits() {
        let history = Self.nights(from: "2026-09-01", (0..<40).map { 7 + Double($0 % 5) * 0.4 })
        let later = Self.nights(from: "2026-10-11", Array(repeating: 4.0, count: 10))
        let day = "2026-10-11"
        XCTAssertEqual(AnalyticsEngine.Rest.inputs(forDay: day, nights: history, age: 35),
                       AnalyticsEngine.Rest.inputs(forDay: day, nights: history + later, age: 35))
    }

    /// The need reads the last 90 days only, so a long-past run of long nights ages out.
    func testTheNeedWindowIsNinetyDays() {
        let old = Self.nights(from: "2026-01-01", Array(repeating: 9.5, count: 30))
        let recent = Self.nights(from: "2026-08-01", Array(repeating: 7.0, count: 30))
        let inputs = AnalyticsEngine.Rest.inputs(forDay: "2026-09-01", nights: old + recent, age: 35)
        XCTAssertEqual(inputs.needHours, AnalyticsEngine.Rest.populationNeedFloorHours(age: 35), accuracy: 1e-9)
    }

    /// The regularity is the last 28 nights before the night; fewer than three nights is no signal.
    func testTheRegularityReadsTheTwentyEightNightsBefore() {
        let nights = Self.nights(from: "2026-09-01", (0..<40).map { $0 < 12 ? 4.0 : 8.0 })
        let inputs = AnalyticsEngine.Rest.inputs(forDay: "2026-10-11", nights: nights, age: 35)
        XCTAssertEqual(inputs.consistency, 1.0)   // the 28 nights before are all 8 h
        XCTAssertNil(AnalyticsEngine.Rest.inputs(forDay: "2026-09-03", nights: nights, age: 35).consistency)
    }

    /// The stored units round-trip: minutes and percent in, hours and 0…1 out.
    func testStoredTraitsConvertTheirUnits() {
        let stored = AnalyticsEngine.Rest.Inputs.stored(needMin: 540, consistencyPct: 82)
        XCTAssertEqual(stored.needHours, 9.0, accuracy: 1e-9)
        XCTAssertEqual(stored.consistency ?? -1, 0.82, accuracy: 1e-9)
        XCTAssertEqual(AnalyticsEngine.Rest.Inputs.stored(needMin: nil, consistencyPct: nil), .coldStart)
    }

    /// The composite uses the night's own need: the same night scores lower against a 9 h need than 8 h.
    func testTheCompositeUsesTheNightsNeed() {
        let night = DailyMetric(day: "2026-10-20", totalSleepMin: 450, efficiency: 0.92, deepMin: 100,
                                remMin: 110, lightMin: 240, disturbances: 2, restingHr: 55, avgHrv: 50,
                                recovery: nil, strain: nil, exerciseCount: nil)
        let at8 = AnalyticsEngine.Rest.composite(daily: night, inputs: .coldStart)!
        let at9 = AnalyticsEngine.Rest.composite(daily: night, inputs: .init(needHours: 9, consistency: nil))!
        XCTAssertLessThan(at9, at8)
        XCTAssertEqual(at8 - at9, 50 * (450.0 / 480 - 450.0 / 540), accuracy: 0.01)
    }
}
