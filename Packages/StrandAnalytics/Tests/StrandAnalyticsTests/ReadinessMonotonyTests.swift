import Foundation
import XCTest
@testable import StrandAnalytics
import WhoopStore

/// Foster training monotony is mean/SD of the week's load, and it is only interpretable ALONGSIDE the
/// load itself. Without that gate the engine read a week of walks — uniform, but uniformly *tiny* — as
/// "your days were too similarly intense" and warned about overload and injury risk. The number was
/// right; the interpretation was backwards (#monotony-lowload).
///
/// Monotony now comes from the Training Load lanes (P2): each lane's `TrainingLoad.distribution`, the
/// figure the Training Load screen shows. The gate is the lane's own band — a lane below its usual
/// never warns. These pin the interpretation: the monotony VALUE survives in every case, and only the
/// warning is conditional.
final class ReadinessMonotonyTests: XCTestCase {

    private func metric(_ index: Int, hrv: Double = 60, rhr: Int = 52) -> DailyMetric {
        DailyMetric(
            day: WeeklyDigestEngine.addDays("2026-01-01", index),
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: nil,
            exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: 14
        )
    }

    private var days: [DailyMetric] {
        (0..<29).map { metric($0, hrv: $0.isMultiple(of: 2) ? 62 : 58, rhr: $0.isMultiple(of: 2) ? 54 : 50) }
    }

    private func lane(_ kind: TrainingLaneKind, _ band: RelativeLoadBand?, monotony: Double?) -> ReadinessLoadContext.Lane {
        ReadinessLoadContext.Lane(kind: kind, band: band, guardState: .none, percentChange: nil, monotony: monotony)
    }

    private func monotonySignal(_ r: ReadinessEngine.Readiness) -> ReadinessEngine.Signal? {
        r.signals.first { $0.key == "monotony" }
    }

    // MARK: - The reported case

    /// THE REPORT: a week of walking after normal training. Monotony comes out high, and the app used to
    /// warn about overload for a week the wearer spent resting. A lane below its usual never warns.
    func testUniformlyLightWeekProducesNoOverloadWarning() {
        let r = ReadinessEngine.evaluate(days: days,
                                         loadContext: ReadinessLoadContext(lanes: [lane(.cardio, .below, monotony: 4.2)]))
        XCTAssertEqual(r.monotony, 4.2, "the quotient really is high — that was never the bug")
        XCTAssertNil(monotonySignal(r), "a week of walks must not be read as 'too similarly intense'")
    }

    /// A lane without a band (too few sessions, detrained) cannot carry an overload reading either.
    func testLaneWithoutABandDoesNotWarn() {
        let r = ReadinessEngine.evaluate(days: days,
                                         loadContext: ReadinessLoadContext(lanes: [lane(.strength, nil, monotony: 3.0)]))
        XCTAssertEqual(r.monotony, 3.0)
        XCTAssertNil(monotonySignal(r))
    }

    // MARK: - The counter-check

    /// The same tight spread in a lane that carried its usual load or more must still warn.
    func testMonotonousLaneAtUsualOrAboveWarns() {
        for band in [RelativeLoadBand.usual, .higher, .muchHigher] {
            let r = ReadinessEngine.evaluate(days: days,
                                             loadContext: ReadinessLoadContext(lanes: [lane(.cardio, band, monotony: 2.4)]))
            XCTAssertEqual(monotonySignal(r)?.flag, .watch, "\(band)")
            XCTAssertEqual(monotonySignal(r)?.evidenceData, .monotony(2.4))
        }
    }

    func testVariedWeekDoesNotWarn() {
        let r = ReadinessEngine.evaluate(days: days,
                                         loadContext: ReadinessLoadContext(lanes: [lane(.cardio, .usual, monotony: 1.2)]))
        XCTAssertNil(monotonySignal(r))
    }

    /// The warning reads the lane that carried load; a monotonous light lane beside it does not borrow
    /// that lane's band.
    func testWarningReadsOnlyLanesThatCarriedLoad() {
        let context = ReadinessLoadContext(lanes: [lane(.strength, .below, monotony: 5.0),
                                                   lane(.cardio, .usual, monotony: 1.1)])
        let r = ReadinessEngine.evaluate(days: days, loadContext: context)
        XCTAssertEqual(r.monotony, 5.0, "the reported value is the highest lane's")
        XCTAssertNil(monotonySignal(r))
    }

    // MARK: - One definition

    /// The lane's monotony is `TrainingLoad.distribution` over the seven days ending on the reading's
    /// day — the figure the Training Load screen shows — and not a second formula (Readiness used to
    /// divide by the sample SD of daily Effort).
    func testLaneMonotonyIsTheScreensDistribution() {
        var byDay: [String: Double] = [:]
        for index in 0..<70 { byDay[WeeklyDigestEngine.addDays("2026-01-01", index)] = index.isMultiple(of: 2) ? 110 : 90 }
        let day = WeeklyDigestEngine.addDays("2026-01-01", 69)
        let reading = LaneEngine.reading(dailyByDay: byDay,
                                         activity: LaneActivity(sessionsByDay: byDay.mapValues { _ in 1 }),
                                         lane: .strength, through: day)
        let built = ReadinessLoadContext.Lane(kind: .strength, reading: reading, dailyByDay: byDay)
        let screen = TrainingLoad.distribution(dailyByDay: byDay, through: day)
        XCTAssertNotNil(screen)
        XCTAssertEqual(built.monotony, screen?.monotony)
        XCTAssertEqual(built.band, reading.band)
        XCTAssertEqual(built.percentChange, reading.trend?.percentChange)
    }

    // MARK: - The cache must not confuse two contexts

    /// `evaluate` memoizes on the rows' fingerprint; the load context is part of the key, so two reads
    /// over the same nights with different lanes can never share an answer.
    func testTwoContextsDoNotShareACacheEntry() {
        let calm = ReadinessEngine.evaluate(days: days,
                                            loadContext: ReadinessLoadContext(lanes: [lane(.cardio, .usual, monotony: 1.0)]))
        let heavy = ReadinessEngine.evaluate(days: days,
                                             loadContext: ReadinessLoadContext(lanes: [lane(.cardio, .muchHigher, monotony: 2.5)]))
        XCTAssertNotEqual(calm, heavy)
        XCTAssertNil(monotonySignal(calm))
        XCTAssertNotNil(monotonySignal(heavy))
        XCTAssertNil(ReadinessEngine.evaluate(days: days).loadContext)
    }

    /// The fold must stay ORDER-INDEPENDENT — that property is what lets a cosmetic reorder hit the cache.
    func testShuffledHistoryStillHitsTheSameVerdict() {
        let context = ReadinessLoadContext(lanes: [lane(.cardio, .usual, monotony: 1.0)])
        XCTAssertEqual(ReadinessEngine.evaluate(days: days, loadContext: context),
                       ReadinessEngine.evaluate(days: days.reversed(), loadContext: context))
    }
}
