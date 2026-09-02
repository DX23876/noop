import Foundation
import XCTest
@testable import StrandAnalytics
import WhoopStore

/// Foster training monotony is mean/SD of the week's load, and it is only interpretable ALONGSIDE the
/// load itself. Without that gate the engine read a week of walks — uniform, but uniformly *tiny* — as
/// "your days were too similarly intense" and warned about overload and injury risk. The number was
/// right; the interpretation was backwards.
///
/// These pin the interpretation, not the arithmetic: the monotony VALUE must survive in every case, and
/// only the warning is conditional.
final class ReadinessMonotonyTests: XCTestCase {

    /// Days are laid out oldest→newest across two months so a 28-day window fits without date maths.
    private func metric(_ index: Int, strain: Double, hrv: Double = 60, rhr: Int = 52) -> DailyMetric {
        let day = index + 1
        let month = day <= 31 ? 1 : 2
        let inMonth = day <= 31 ? day : day - 31
        return DailyMetric(
            day: String(format: "2026-%02d-%02d", month, inMonth),
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: strain,
            exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: 14
        )
    }

    private func monotonySignal(_ r: ReadinessEngine.Readiness) -> ReadinessEngine.Signal? {
        r.signals.first { $0.key == "monotony" }
    }

    /// A gentle alternation gives a small SD and therefore a large mean/SD quotient at ANY level — which
    /// is exactly why the level has to be checked separately.
    private func alternating(_ base: Double, count: Int, jitter: Double = 0.6) -> [Double] {
        (0..<count).map { base + ($0.isMultiple(of: 2) ? jitter : -jitter) }
    }

    // MARK: - The reported case

    /// THE REPORT: three normal training weeks, then a week of walking. Monotony comes out high, and the
    /// app used to warn about overload and injury risk for a week the wearer spent resting.
    func testUniformlyLightWeekProducesNoOverloadWarning() {
        let trained = alternating(45, count: 21)
        let walked = alternating(6, count: 7, jitter: 0.4)
        let days = (trained + walked).enumerated().map { metric($0.offset, strain: $0.element) }

        let r = ReadinessEngine.evaluate(days: days)
        guard let mono = r.monotony else { return XCTFail("the monotony value must still be computed") }
        XCTAssertGreaterThan(mono, 2.0, "the quotient really is high — that was never the bug")
        XCTAssertNil(monotonySignal(r),
                     "a week of walks must not be read as 'too similarly intense'")
    }

    /// The value is diagnostic data and rides on regardless: charts, the coach briefing and the
    /// explanations all read it. Only the warning is conditional.
    func testMonotonyValueSurvivesEvenWhenTheWarningIsSuppressed() {
        let days = (alternating(45, count: 21) + alternating(6, count: 7, jitter: 0.4))
            .enumerated().map { metric($0.offset, strain: $0.element) }
        XCTAssertNotNil(ReadinessEngine.evaluate(days: days).monotony)
    }

    // MARK: - The counter-check

    /// The same tight spread on a real training level must still warn — the fix narrows the reading, it
    /// does not remove it.
    func testUniformlyHardWeekStillWarns() {
        let days = alternating(55, count: 28)
            .enumerated().map { metric($0.offset, strain: $0.element) }

        let r = ReadinessEngine.evaluate(days: days)
        XCTAssertGreaterThan(r.monotony ?? 0, 2.0)
        XCTAssertEqual(monotonySignal(r)?.flag, .watch,
                       "a genuinely monotonous hard block is what this signal is for")
    }

    // MARK: - The backstop

    /// The case the RELATIVE rule alone cannot catch: four weeks of near-nothing. Acute ≈ chronic, so a
    /// ratio test passes happily — and a thoroughly detrained wearer would be warned about overload.
    func testLongTermInactivityIsNotWarnedEither() {
        let days = alternating(6, count: 28, jitter: 0.4)
            .enumerated().map { metric($0.offset, strain: $0.element) }

        let r = ReadinessEngine.evaluate(days: days)
        XCTAssertGreaterThan(r.monotony ?? 0, 2.0, "the quotient is high here too")
        XCTAssertNil(monotonySignal(r),
                     "acute ≈ chronic passes the relative test; the absolute floor is what saves this")
    }

    /// Both gates are real: each one alone would let a wrong warning through.
    func testBothGatesAreLoadBearing() {
        // Passes the absolute floor (mean ~40) but is far below the wearer's own norm (~80).
        let steppedDown = (alternating(80, count: 21) + alternating(40, count: 7))
            .enumerated().map { metric($0.offset, strain: $0.element) }
        XCTAssertNil(monotonySignal(ReadinessEngine.evaluate(days: steppedDown)),
                     "a real deload week is not an overload risk")

        // Passes the relative test (acute ≈ chronic) but sits under the absolute floor.
        let alwaysLight = alternating(20, count: 28)
            .enumerated().map { metric($0.offset, strain: $0.element) }
        XCTAssertNil(monotonySignal(ReadinessEngine.evaluate(days: alwaysLight)))
    }

    // MARK: - The blocked green light

    /// A ramp-down used to carry `.watch`, and `synthesize` only awards `primed` when no watch is
    /// present — so resting well actively prevented the app from saying "you have room". The signal's
    /// own text ("room to build") was already saying the opposite of its flag.
    func testRampingDownReadsNeutralSoARestedWeekCanBePrimed() {
        let days = (alternating(60, count: 21) + alternating(20, count: 7))
            .enumerated().map { index, strain in
                // Recovery signals clearly good, so the only thing that could hold `primed` back is the
                // load flag.
                metric(index, strain: strain, hrv: index >= 21 ? 85 : 60, rhr: index >= 21 ? 44 : 52)
            }

        let r = ReadinessEngine.evaluate(days: days)
        let acwr = r.signals.first { $0.key == "acwr" }
        XCTAssertEqual(acwr?.flag, .neutral, "ramping down is a state, not a concern")
        XCTAssertTrue(acwr?.detail.contains("room to build") ?? false)
        XCTAssertEqual(r.level, .primed, "a rested, well-recovered wearer must get the green light")
    }

    // MARK: - The cache must not confuse two histories

    /// Found while writing the tests above, and far more serious than the bug they were written for.
    ///
    /// `evaluate` memoizes on a fingerprint of the readiness-relevant columns (#707 perf). That
    /// fingerprint XOR-folded the row hashes, and XOR CANCELS: a week alternating +j/-j around a base
    /// has 14 of each value, so the entire strain contribution folded to zero. Every such history —
    /// a walking week and a hard training block alike — keyed the SAME cache entry, and whichever ran
    /// first won. The engine then handed a wearer who had done nothing the verdict of someone who had
    /// trained hard, and the coach briefed on it.
    ///
    /// The two histories below differ ONLY in load, over the same days, in exactly that shape.
    func testTwoDifferentHistoriesDoNotShareACacheEntry() {
        let light = alternating(6, count: 28, jitter: 0.4)
            .enumerated().map { metric($0.offset, strain: $0.element) }
        let hard = alternating(55, count: 28)
            .enumerated().map { metric($0.offset, strain: $0.element) }

        // Evaluate in both orders: a collision shows up as the second call inheriting the first's answer.
        let hardFirst = ReadinessEngine.evaluate(days: hard)
        let lightSecond = ReadinessEngine.evaluate(days: light)
        XCTAssertNotEqual(hardFirst.monotony, lightSecond.monotony,
                          "a walking week and a hard block must not share a readiness verdict")
        XCTAssertNotNil(monotonySignal(hardFirst))
        XCTAssertNil(monotonySignal(lightSecond))
    }

    /// The fold must stay ORDER-INDEPENDENT — that property is what lets a cosmetic reorder hit the
    /// cache, and the fix must not have traded it away for collision resistance.
    func testShuffledHistoryStillHitsTheSameVerdict() {
        let days = (alternating(60, count: 21) + alternating(20, count: 7))
            .enumerated().map { metric($0.offset, strain: $0.element) }
        XCTAssertEqual(ReadinessEngine.evaluate(days: days),
                       ReadinessEngine.evaluate(days: days.reversed()))
    }

    /// Ramping up too fast keeps its warning — the change is narrow on purpose.
    func testRampingUpFastStillWarns() {
        let days = (alternating(30, count: 21) + alternating(48, count: 7))
            .enumerated().map { metric($0.offset, strain: $0.element) }
        let acwr = ReadinessEngine.evaluate(days: days).signals.first { $0.key == "acwr" }
        XCTAssertEqual(acwr?.flag, .watch)
        XCTAssertTrue(acwr?.detail.contains("watch fatigue") ?? false)
    }
}
