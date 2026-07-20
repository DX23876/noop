import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins the Liquid Today Charge hero's carry-over truth table.
///
/// #543 gave the classic `TodayView` a prior-day Charge carry: right after the 04:00 logical-day rollover
/// the new day has no recovery (tonight's night isn't scored until it's worn and offloaded), so a
/// baseline-established wearer saw a blank Charge while live HR kept ticking — which reads as broken. The
/// widget / watch / Live Activity got the same carry via `Repository.widgetAnchor` (#911), and Android has
/// it as `TodayScreen.lastScoredRecoveryDay`. The v8 Liquid redesign — the DEFAULT iOS Today — shipped
/// without it: its Rest hero carries (`freshRestScore`, #977) and its vitals carry (`Repository
/// .lastVitalsDay`), but the Charge hero read `displayDay?.recovery` raw. So Charge alone blanked while
/// everything around it held, on a screen where every other surface in the app showed a number.
///
/// The selection itself is NOT re-implemented here: `resolve` composes `TodayView.lastScoredRecoveryDay`
/// (the #547 future-day guard included) and `TodayView.carriedCaption`, so Liquid and Classic cannot drift.
/// This pins the presentation decision on top of them. Pure, so it needs no strap, no clock and no view.
final class LiquidChargeCarryTests: XCTestCase {

    private typealias Display = LiquidTodayView.ChargeDisplay

    private func day(_ key: String, recovery: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                    recovery: recovery, strain: nil, exerciseCount: nil)
    }

    // MARK: - Today's own score always wins

    func testTodaysOwnScoreWinsOverAnyCarry() {
        let d = Display.resolve(todayRecovery: 61, priorScored: day("2026-07-14", recovery: 82.3),
                                calibrationNights: nil, todayKey: "2026-07-15")
        XCTAssertEqual(d, .scored(pct: 61), "a scored today must never be displaced by a carry")
    }

    // MARK: - THE regression: an unscored today must carry, not blank

    /// The rollover case (#543). Liquid blanked here; classic/widget/watch/Android all carry.
    func testUnscoredTodayCarriesTheLastScoredNight() {
        let d = Display.resolve(todayRecovery: nil, priorScored: day("2026-07-14", recovery: 82.3),
                                calibrationNights: nil, todayKey: "2026-07-15")
        guard case .carried(let pct, let caption) = d else {
            return XCTFail("an unscored today with a scored prior night must carry it, got \(d)")
        }
        XCTAssertEqual(pct, 82.3, "the carried value is the prior row's REAL recovery, never fabricated")
        XCTAssertTrue(caption.hasPrefix("Last night"),
                      "a fresh carry is stamped as last night's, not passed off as today's: \(caption)")
    }

    /// #779: a weeks-old carry is still shown, but must NOT claim to be "last night".
    func testStaleCarryIsLabelledLatestSleepNotLastNight() {
        let d = Display.resolve(todayRecovery: nil, priorScored: day("2026-06-01", recovery: 55),
                                calibrationNights: nil, todayKey: "2026-07-15")
        guard case .carried(_, let caption) = d else { return XCTFail("expected a carry, got \(d)") }
        XCTAssertTrue(caption.hasPrefix("Latest sleep"),
                      "a month-old night must not be surfaced as 'Last night': \(caption)")
    }

    // MARK: - Calibration owns its own copy

    /// Calibration must beat the carry: mid-calibration there is no trustworthy prior score to carry, and
    /// the calibrating state has its own honest "N of 4 nights" copy. Mirrors `lastScoredRecoveryDay`,
    /// which returns nil when `isCalibrating`.
    func testCalibrationBeatsTheCarry() {
        let d = Display.resolve(todayRecovery: nil, priorScored: day("2026-07-14", recovery: 82.3),
                                calibrationNights: 2, todayKey: "2026-07-15")
        XCTAssertEqual(d, .calibrating(nights: 2))
    }

    // MARK: - The label must not lie

    /// The second half of the bug. Liquid rendered `recovery != nil ? "Solid" : "Calibrating"`, so EVERY
    /// nil claimed "Calibrating" — including a day with a trusted baseline and simply no sleep recorded
    /// (a no-wear day, or daytime-only wear). That is a false statement about the baseline's state; a
    /// wearer past the seed gate is not calibrating. No prior score and no calibration = no data, and the
    /// view must be able to say so.
    func testNoPriorScoreAndNoCalibrationIsNoDataNotCalibrating() {
        let d = Display.resolve(todayRecovery: nil, priorScored: nil,
                                calibrationNights: nil, todayKey: "2026-07-15")
        XCTAssertEqual(d, .noData)
        XCTAssertNotEqual(d, .calibrating(nights: 0),
                          "'no sleep recorded' must not be reported as a calibrating baseline")
    }

    /// A prior row selected by `lastScoredRecoveryDay` always has a recovery by construction, but the
    /// resolver must not trust that — a nil-recovery row falls through to noData rather than crashing or
    /// fabricating a carry.
    func testPriorRowWithoutRecoveryDoesNotCarry() {
        let d = Display.resolve(todayRecovery: nil, priorScored: day("2026-07-14", recovery: nil),
                                calibrationNights: nil, todayKey: "2026-07-15")
        XCTAssertEqual(d, .noData)
    }

    // MARK: - What the view draws

    /// The hero draws `pct`. A carried state MUST yield a number — that is the whole fix; before it, the
    /// vessel got nil and rendered its "–" empty state.
    func testCarriedStateYieldsANumberForTheHero() {
        XCTAssertEqual(Display.carried(pct: 82.3, caption: "Last night · 4 Jul").pct, 82.3)
        XCTAssertEqual(Display.scored(pct: 61).pct, 61)
    }

    /// Calibrating and no-data draw nothing — the honest empty vessel. Never a fabricated 0.
    func testStatesWithNoHonestNumberDrawNothing() {
        XCTAssertNil(Display.calibrating(nights: 2).pct)
        XCTAssertNil(Display.noData.pct)
        XCTAssertNotEqual(Display.noData.pct, 0, "an absent Charge is not a Charge of zero")
    }

    /// The label half of the bug: only a genuinely calibrating baseline may say "Calibrating".
    func testOnlyCalibratingStateClaimsCalibrating() {
        XCTAssertEqual(Display.calibrating(nights: 2).stateLabel, "Calibrating")
        XCTAssertNotEqual(Display.noData.stateLabel, "Calibrating",
                          "a trusted baseline with no scored night is missing data, not calibrating")
        XCTAssertEqual(Display.scored(pct: 61).stateLabel, "Solid")
        XCTAssertEqual(Display.carried(pct: 82.3, caption: "Last night · 4 Jul").stateLabel, "Last night",
                       "the pill labels the carry as prior — the number beside it is not today's")
    }

    // MARK: - Calibration surfaces its "N of 4" progress (parity with classic TodayView)

    /// The greeting pill is deliberately short ("Calibrating") because it shares a `fixedSize` row with the
    /// greeting, so the honest "N of 4 nights" progress that classic `TodayView.calibrationDetail` shows must
    /// live in Liquid's synthesis detail instead. `calibrationDetail` carries that copy verbatim so a wearer
    /// in their first `Baselines.minNightsSeed` nights reads identical calibration progress on both Today
    /// screens — before this, Liquid dropped the count and showed a bare "Calibrating".
    func testCalibratingCarriesTheClassicNightCountCopy() {
        XCTAssertEqual(Display.calibrating(nights: 2).calibrationDetail,
                       "Learning your baseline, 2 of 4 nights.",
                       "Liquid must mirror TodayView.calibrationDetail's copy verbatim (\(Baselines.minNightsSeed)-night seed)")
        XCTAssertEqual(Display.calibrating(nights: 0).calibrationDetail,
                       "Learning your baseline, 0 of 4 nights.",
                       "night zero still reads honestly with its count, never a bare 'Calibrating'")
    }

    /// Only the calibrating state owns a synthesis detail line. A scored / carried / no-data day leaves the
    /// readiness one-liner (`synthLine`) untouched — no stray "N of 4" appears once the baseline is trusted.
    func testOnlyCalibratingStateHasASynthesisDetailLine() {
        XCTAssertNil(Display.scored(pct: 61).calibrationDetail)
        XCTAssertNil(Display.carried(pct: 82.3, caption: "Last night · 4 Jul").calibrationDetail)
        XCTAssertNil(Display.noData.calibrationDetail)
    }
}
