import XCTest
@testable import StrandAnalytics
import WhoopStore

final class ReadinessEngineTests: XCTestCase {

    private func d(_ i: Int, hrv: Double?, rhr: Int?, strain: Double?, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: String(format: "2024-03-%02d", i), totalSleepMin: nil, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: hrv, recovery: nil, strain: strain, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: resp)
    }

    /// 28 baseline days with gentle variation (so SD > 0), then `today` as day 29.
    private func baseline(todayHrv: Double?, todayRhr: Int?, todayStrain: Double?,
                          todayResp: Double? = nil, baseStrain: Double = 10) -> [DailyMetric] {
        var days: [DailyMetric] = []
        for i in 1...28 {
            days.append(d(i, hrv: i % 2 == 0 ? 62 : 58, rhr: i % 2 == 0 ? 54 : 50,
                          strain: baseStrain, resp: i % 2 == 0 ? 14.5 : 13.5))
        }
        days.append(d(29, hrv: todayHrv, rhr: todayRhr, strain: todayStrain, resp: todayResp))
        return days
    }

    func testInsufficientWhenEmpty() {
        XCTAssertEqual(ReadinessEngine.evaluate(days: []).level, .insufficient)
    }

    private func lane(_ kind: TrainingLaneKind, _ band: RelativeLoadBand?, guard guardState: LaneGuard = .none,
                      percent: Double? = nil, monotony: Double? = nil) -> ReadinessLoadContext.Lane {
        ReadinessLoadContext.Lane(kind: kind, band: band, guardState: guardState,
                                  percentChange: percent, monotony: monotony)
    }

    func testPrimedWhenSignalsAligned() {
        // Today: HRV well above baseline, resting HR below. No load context: no load signal at all.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10))
        XCTAssertEqual(r.level, .primed)
        XCTAssertEqual(r.signals.first { $0.key == "hrv" }?.flag, .good)
        XCTAssertEqual(r.signals.first { $0.key == "rhr" }?.flag, .good)
        XCTAssertNil(r.signals.first { $0.key == "trainingLoad" })
        XCTAssertNil(r.loadContext)
        XCTAssertEqual(r.signals.first { $0.key == "hrv" }?.evidence, "72 vs 60 ms")
        XCTAssertEqual(r.signals.first { $0.key == "rhr" }?.evidence, "46 vs 52 bpm")
    }

    func testRundownWhenTwoRecoverySignalsDown() {
        // Today: HRV suppressed AND resting HR elevated → two "bad" recovery signals.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 50, todayRhr: 60, todayStrain: 10))
        XCTAssertEqual(r.level, .rundown)
    }

    // MARK: - Training load from the lanes (P2)

    /// B5: the old signal read an acute:chronic ratio of daily Effort. Effort is logarithmic, so tripled
    /// training read about 1.16 and the flag stood on "good". Daily strain alone must never produce a
    /// load signal again — only the lanes can.
    func testDailyEffortAloneNeverProducesALoadSignal() {
        var days: [DailyMetric] = []
        for i in 1...21 { days.append(d(i, hrv: 60, rhr: 52, strain: 5)) }
        for i in 22...29 { days.append(d(i, hrv: 60, rhr: 52, strain: 18)) }
        let r = ReadinessEngine.evaluate(days: days)
        XCTAssertNil(r.signals.first { $0.key == "trainingLoad" })
        XCTAssertNil(r.monotony)
    }

    /// A usual week is described, never counted as evidence of readiness: before, it was `.good` and
    /// helped push almost every read towards primed.
    func testUsualLaneIsDescribedWithoutAFlag() {
        let context = ReadinessLoadContext(lanes: [lane(.strength, .usual, percent: 4), lane(.cardio, .usual)])
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10),
                                         loadContext: context)
        let signal = r.signals.first { $0.key == "trainingLoad" }
        XCTAssertEqual(signal?.flag, .neutral)
        XCTAssertEqual(signal?.detail, "about your usual")
        XCTAssertEqual(signal?.evidenceData, .lanes(context.lanes))
        XCTAssertEqual(r.loadContext, context)
    }

    func testAboveAndBelowAreDescribed() {
        let above = ReadinessEngine.evaluate(
            days: baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10),
            loadContext: ReadinessLoadContext(lanes: [lane(.strength, .usual), lane(.cardio, .higher)]))
        XCTAssertEqual(above.signals.first { $0.key == "trainingLoad" }?.detail, "above your usual (cardio)")
        XCTAssertEqual(above.signals.first { $0.key == "trainingLoad" }?.flag, .neutral)

        let below = ReadinessEngine.evaluate(
            days: baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10),
            loadContext: ReadinessLoadContext(lanes: [lane(.strength, .below), lane(.cardio, .below)]))
        XCTAssertEqual(below.signals.first { $0.key == "trainingLoad" }?.detail, "below your usual")
    }

    /// Well above usual in either lane is a watch: it keeps a well-recovered read off primed.
    func testWellAboveInEitherLaneIsAWatch() {
        for kind in TrainingLaneKind.allCases {
            let other: TrainingLaneKind = kind == .strength ? .cardio : .strength
            let r = ReadinessEngine.evaluate(
                days: baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10),
                loadContext: ReadinessLoadContext(lanes: [lane(kind, .muchHigher, percent: 60), lane(other, .usual)]))
            let signal = r.signals.first { $0.key == "trainingLoad" }
            XCTAssertEqual(signal?.flag, .watch, "\(kind)")
            XCTAssertEqual(signal?.detail, "well above your usual (\(kind.rawValue)) - watch fatigue")
            XCTAssertEqual(r.level, .balanced, "a watch holds a primed read back to balanced")
        }
    }

    /// Well above usual with a recovery signal down is the run-down picture the old spike stood for.
    func testWellAboveWithRecoveryDownIsRunDown() {
        let context = ReadinessLoadContext(lanes: [lane(.cardio, .muchHigher)])
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 50, todayRhr: 52, todayStrain: 10),
                                         loadContext: context)
        XCTAssertEqual(r.signals.first { $0.key == "hrv" }?.flag, .bad)
        XCTAssertEqual(r.level, .rundown)

        let withoutLoad = ReadinessEngine.evaluate(days: baseline(todayHrv: 50, todayRhr: 52, todayStrain: 10),
                                                   loadContext: ReadinessLoadContext(lanes: [lane(.cardio, .usual)]))
        XCTAssertEqual(withoutLoad.level, .strained)
    }

    /// No band (too few sessions, or no comparison yet) is no signal: the guard's silence is kept.
    func testLanesWithoutABandGiveNoSignal() {
        let context = ReadinessLoadContext(lanes: [lane(.strength, nil, guard: .tooFewSessions),
                                                   lane(.cardio, nil)])
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10),
                                         loadContext: context)
        XCTAssertNil(r.signals.first { $0.key == "trainingLoad" })
        XCTAssertEqual(r.loadContext, context)
    }

    /// The low-volume guard has already capped the band at "above", so a sparse baseline never warns.
    func testLowVolumeCapNeverWarns() {
        let context = ReadinessLoadContext(lanes: [lane(.cardio, .higher, guard: .lowVolumeCap, percent: 100)])
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10),
                                         loadContext: context)
        XCTAssertEqual(r.signals.first { $0.key == "trainingLoad" }?.flag, .neutral)
        XCTAssertEqual(r.level, .primed)
    }

    func testRespRateRiseFlags() {
        // Today resp rate well above baseline (~14) → illness-ish watch/bad signal present.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10, todayResp: 18))
        XCTAssertTrue(r.signals.contains { $0.key == "respRate" })
        XCTAssertEqual(r.signals.first { $0.key == "respRate" }?.evidence, "18.0 vs 14.0 rpm")
    }

    func testExplicitTodayWithoutMatchingRowIsInsufficient() {
        // Stale historical import: newest row is 2024-03-29, but the device's real calendar day is later.
        // An explicit `today` with no matching row must read INSUFFICIENT — NOT synthesize off the newest
        // stored (stale) row (issue #23/#24).
        let days = baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10)
        XCTAssertEqual(ReadinessEngine.evaluate(days: days, today: "2026-06-08").level, .insufficient)
        // The day that IS present still computes (no regression for current data).
        XCTAssertNotEqual(ReadinessEngine.evaluate(days: days, today: "2024-03-29").level, .insufficient)
        // The legacy no-`today` path is unchanged — still falls back to the most recent row.
        XCTAssertNotEqual(ReadinessEngine.evaluate(days: days).level, .insufficient)
    }

    func testStatsHelpers() {
        XCTAssertEqual(ReadinessEngine.mean([2, 4, 6]), 4)
        XCTAssertEqual(ReadinessEngine.sampleSD([2, 4, 6])!, 2.0, accuracy: 0.0001)
        XCTAssertNil(ReadinessEngine.sampleSD([5]))
        XCTAssertNil(ReadinessEngine.mean([]))
    }
}
