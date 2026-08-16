import XCTest
import Foundation
@testable import StrandAnalytics

/// Parasympathetic-saturation guard on Charge (recovery), shipped INSTRUMENT-FIRST.
///
/// A low nightly HRV normally drives Charge DOWN via the dominant HRV term. In a very fit / very
/// relaxed state HRV can read LOW while resting HR reads LOW too and the two decouple, which MAY be a
/// benign saturated vagal state rather than fatigue. The guard DETECTS that signature and computes the
/// easing it would apply, but the easing is deliberately NOT applied: Charge is byte-identical to
/// pre-guard behaviour, and the would-be easing is only reported (trace line + driver verdict).
///
/// So these tests pin THREE things:
///   1. Detection: the gate, the weaker-arm coupling strength, and the damp fraction (unchanged logic).
///   2. Non-application: a firing night scores EXACTLY the raw, unguarded composite.
///   3. Reporting: the trace names the would-be easing and its point delta; the driver verdict names
///      the pattern without claiming the penalty was eased.
///
/// See the MARK header in RecoveryScorer.swift for why the easing is off (zero real firings observed;
/// low HRV + low RHR is also a reported non-functional-overreaching signature). No em-dashes.
final class RecoverySaturationGuardTests: XCTestCase {

    /// A usable (trusted) baseline with a given mean and Gaussian sigma (spread is internal
    /// abs-dev units; zScore multiplies by 1.253 to recover sigma).
    private func baseline(mean: Double, sigma: Double, nValid: Int = 14) -> BaselineState {
        BaselineState(baseline: mean, spread: sigma / 1.253, nValid: nValid,
                      nightsSinceUpdate: 0, status: nValid >= 14 ? .trusted : .provisional)
    }

    /// The plain HRV+RHR composite with NO easing: the score pre-guard behaviour produces.
    private func undampedScore(hrv: Double, rhr: Double,
                               hrvB: BaselineState, rhrB: BaselineState) -> Double {
        let hrvZ = RecoveryScorer.zScore(hrv, mean: hrvB.baseline, spread: hrvB.spread)
        let rhrZ = RecoveryScorer.zScore(rhrB.baseline, mean: rhr, spread: rhrB.spread)
        let wsum = RecoveryScorer.wHRV + RecoveryScorer.wRHR
        let z = (RecoveryScorer.wHRV * hrvZ + RecoveryScorer.wRHR * rhrZ) / wsum
        return 100.0 / (1.0 + exp(-RecoveryScorer.logisticK * (z - RecoveryScorer.logisticZ0)))
    }

    // MARK: - Detection: the guard helper in isolation (logic unchanged; easing is a counterfactual)

    func testGuardFiresOnSaturationSignatureAndWouldEaseButNeverRemovePenalty() {
        // HRV clearly below baseline (penalty direction) AND resting HR clearly below baseline
        // (recovery-good direction): the saturation signature. The would-be eased z is closer to 0
        // but stays negative: the easing would never invert or fully remove the penalty.
        let s = RecoveryScorer.parasympatheticSaturation(hrvZ: -1.5, rhrZ: 1.5)
        XCTAssertTrue(s.active)
        XCTAssertGreaterThan(s.easedHrvZ, -1.5)          // would ease toward 0
        XCTAssertLessThan(s.easedHrvZ, 0.0)               // would still be a penalty (never inverted)
        XCTAssertGreaterThan(s.dampFraction, 0.0)
        XCTAssertLessThanOrEqual(s.dampFraction, RecoveryScorer.satMaxDampFraction)  // capped
    }

    func testGuardIsSilentOnRealFatigue() {
        // Low HRV + HIGH resting HR (rhrZ negative): normal sympathetic coupling, genuine fatigue.
        // The guard must NOT fire.
        let s = RecoveryScorer.parasympatheticSaturation(hrvZ: -1.5, rhrZ: -1.5)
        XCTAssertFalse(s.active)
        XCTAssertEqual(s.easedHrvZ, -1.5, accuracy: 1e-12)
        XCTAssertEqual(s.dampFraction, 0.0, accuracy: 1e-12)
    }

    func testGuardIsSilentWhenHRVIsNotLow() {
        // HRV at or above baseline is not a penalty to ease, even with a very low resting HR.
        XCTAssertFalse(RecoveryScorer.parasympatheticSaturation(hrvZ: 1.5, rhrZ: 1.5).active)
        XCTAssertFalse(RecoveryScorer.parasympatheticSaturation(hrvZ: 0.0, rhrZ: 1.5).active)
    }

    func testGuardIsSilentWithoutARestingHRSignal() {
        // No RHR term (nil): nothing corroborates the low HRV, so real fatigue and benign
        // saturation are indistinguishable from HRV alone. Refuse to guess -> no detection.
        let s = RecoveryScorer.parasympatheticSaturation(hrvZ: -1.5, rhrZ: nil)
        XCTAssertFalse(s.active)
        XCTAssertEqual(s.easedHrvZ, -1.5, accuracy: 1e-12)
    }

    func testGuardIsSilentOnMarginalDivergenceBelowTheGate() {
        // Both arms present but shallow (below satEnterZ): marginal noise, not a clear pattern.
        let below = RecoveryScorer.satEnterZ - 0.05
        let s = RecoveryScorer.parasympatheticSaturation(hrvZ: -below, rhrZ: below)
        XCTAssertFalse(s.active)
        XCTAssertEqual(s.easedHrvZ, -below, accuracy: 1e-12)
    }

    func testDampingIsMonotonicInCorroborationAndCapped() {
        // Stronger corroboration (both arms deeper below baseline) would ease more, up to the cap.
        let weak = RecoveryScorer.parasympatheticSaturation(hrvZ: -0.8, rhrZ: 0.8).dampFraction
        let strong = RecoveryScorer.parasympatheticSaturation(hrvZ: -1.4, rhrZ: 1.4).dampFraction
        let saturated = RecoveryScorer.parasympatheticSaturation(hrvZ: -3.0, rhrZ: 3.0).dampFraction
        XCTAssertGreaterThan(strong, weak)
        XCTAssertEqual(saturated, RecoveryScorer.satMaxDampFraction, accuracy: 1e-12)  // never exceeds cap
        // The weaker arm caps the strength (conservative): a very low HRV with only a mildly low
        // resting HR is limited by the resting-HR arm.
        let limited = RecoveryScorer.parasympatheticSaturation(hrvZ: -3.0, rhrZ: 0.8)
        let bothStrong = RecoveryScorer.parasympatheticSaturation(hrvZ: -3.0, rhrZ: 3.0)
        XCTAssertLessThan(limited.dampFraction, bothStrong.dampFraction)
    }

    // MARK: - Non-application: the detected easing must NOT move Charge

    func testSaturationNightScoresTheRawUndampedCompositeUnchanged() {
        // THE CORE INSTRUMENT-FIRST GUARANTEE. This night fires the guard (damp = 0.45, a would-be
        // ~18-point lift), yet recovery() must return EXACTLY the raw composite: the score is
        // byte-identical to pre-guard behaviour.
        let hrvB = baseline(mean: 50, sigma: 6.265)
        let rhrB = baseline(mean: 55, sigma: 5.0)

        // Confirm this fixture really does trip the detector (otherwise the test proves nothing).
        let hrvZ = RecoveryScorer.zScore(41, mean: hrvB.baseline, spread: hrvB.spread)
        let rhrZ = RecoveryScorer.zScore(rhrB.baseline, mean: 48, spread: rhrB.spread)
        let sat = RecoveryScorer.parasympatheticSaturation(hrvZ: hrvZ, rhrZ: rhrZ)
        XCTAssertTrue(sat.active, "fixture must fire the guard for this test to mean anything")
        XCTAssertGreaterThan(sat.dampFraction, 0.4)

        let scored = RecoveryScorer.recovery(
            hrv: 41, rhr: 48, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)!
        XCTAssertEqual(scored, undampedScore(hrv: 41, rhr: 48, hrvB: hrvB, rhrB: rhrB),
                       accuracy: 1e-9, "a firing night must still score the RAW composite (easing not applied)")
    }

    func testSaturationNightStaysRedExactlyLikeBeforeTheGuard() {
        // The would-be easing on this fixture is large enough to cross red -> yellow. Instrument-first
        // means the band must NOT move: the night stays red until the easing is validated and enabled.
        let hrvB = baseline(mean: 50, sigma: 6.265)
        let rhrB = baseline(mean: 55, sigma: 5.0)
        let saturation = RecoveryScorer.recovery(
            hrv: 41, rhr: 48, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)!
        XCTAssertLessThan(saturation, RecoveryScorer.bandRedMax,
                          "detection must not lift the night out of red while the easing is off")
    }

    func testRealFatigueNightIsUnchangedToo() {
        // Low HRV + HIGH resting HR: the guard never fired here before and still does not.
        let hrvB = baseline(mean: 50, sigma: 6.265)
        let rhrB = baseline(mean: 55, sigma: 5.0)
        let fatigue = RecoveryScorer.recovery(
            hrv: 41, rhr: 62, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)!
        XCTAssertLessThan(fatigue, RecoveryScorer.bandRedMax, "low HRV + high resting HR must stay red")
        XCTAssertEqual(fatigue, undampedScore(hrv: 41, rhr: 62, hrvB: hrvB, rhrB: rhrB), accuracy: 1e-9)
    }

    func testHighHRVGoodNightIsUnchangedByGuard() {
        // A genuinely great night (HRV up, resting HR down) must be untouched: the guard only
        // engages when HRV is BELOW baseline. Recompute the plain composite and require equality.
        let hrvB = baseline(mean: 50, sigma: 6.265)
        let rhrB = baseline(mean: 55, sigma: 5.0)
        let actual = RecoveryScorer.recovery(
            hrv: 62, rhr: 49, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)!
        XCTAssertEqual(actual, undampedScore(hrv: 62, rhr: 49, hrvB: hrvB, rhrB: rhrB),
                       accuracy: 1e-9, "HRV-above-baseline night must bypass the guard")
    }

    // MARK: - Reporting: trace + driver breakdown surface the would-be easing

    func testTraceReportsWouldBeEasingWithoutChangingTheScore() {
        let hrvB = baseline(mean: 50, sigma: 6.265)
        let rhrB = baseline(mean: 55, sigma: 5.0)

        let (satScore, satLines) = RecoveryScorer.recoveryTrace(
            hrv: 41, rhr: 48, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)
        let plain = RecoveryScorer.recovery(
            hrv: 41, rhr: 48, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)
        XCTAssertEqual(satScore, plain)

        // The saturation line fires and reports the counterfactual.
        let satLine = satLines.first { $0.contains("charge saturation active") }
        XCTAssertNotNil(satLine, "a firing night must emit the saturation diagnostic")
        XCTAssertTrue(satLine!.contains("wouldRaiseCharge="), "must report the would-be point delta")
        XCTAssertTrue(satLine!.contains("wouldEaseHrvZTo="), "must report the would-be eased z")
        XCTAssertTrue(satLine!.contains("not applied"), "must state the easing was not applied")

        // The reported would-be lift must be real and positive (this fixture: ~18 points).
        let delta = Double(satLine!.split(separator: " ")
            .first { $0.hasPrefix("wouldRaiseCharge=") }!
            .dropFirst("wouldRaiseCharge=".count))!
        XCTAssertGreaterThan(delta, 15.0)
        XCTAssertLessThan(delta, 21.0)

        // ...and the HRV TERM in the trace is the RAW z, matching what was actually scored.
        let hrvZRaw = RecoveryScorer.zScore(41, mean: hrvB.baseline, spread: hrvB.spread)
        let hrvTerm = satLines.first { $0.hasPrefix("charge term hrv ") }!
        XCTAssertTrue(hrvTerm.contains("z=\((hrvZRaw * 100).rounded() / 100)"),
                      "trace HRV term must be the raw scored z, not the eased one: \(hrvTerm)")

        // Real-fatigue night: NO saturation line (guard silent).
        let (_, fatLines) = RecoveryScorer.recoveryTrace(
            hrv: 41, rhr: 62, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)
        XCTAssertFalse(fatLines.contains { $0.contains("charge saturation") })
        for l in satLines + fatLines { XCTAssertFalse(l.contains("\u{2014}"), "em-dash in: \(l)") }
    }

    func testChargeDriversHRVPenaltyIsFullAndVerdictNamesSaturationWithoutClaimingEasing() {
        let hrvB = baseline(mean: 50, sigma: 6.265)
        let rhrB = baseline(mean: 55, sigma: 5.0)

        // Saturation night: the verdict NAMES the detected pattern but still reports the penalty as
        // limiting, because the easing was not applied.
        let sat = RecoveryScorer.chargeDrivers(
            hrv: 41, rhr: 48, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)
        let satHRV = sat.first { $0.label == "Heart rate variability" }!
        XCTAssertTrue(satHRV.verdict.contains("saturation"), "verdict must surface the detection")
        XCTAssertTrue(satHRV.verdict.contains("limiting recovery"),
                      "verdict must not imply the penalty was lifted: \(satHRV.verdict)")
        XCTAssertFalse(satHRV.verdict.contains("penalty is eased"))
        XCTAssertFalse(satHRV.verdict.contains("\u{2014}"))
        XCTAssertLessThan(satHRV.deltaPoints, 0, "the HRV penalty is still fully charged")

        // Real-fatigue night: plain limiting verdict, no saturation mention.
        let fat = RecoveryScorer.chargeDrivers(
            hrv: 41, rhr: 62, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: nil, sleepPerf: nil)
        let fatHRV = fat.first { $0.label == "Heart rate variability" }!
        XCTAssertTrue(fatHRV.verdict.contains("limiting recovery"))
        XCTAssertFalse(fatHRV.verdict.contains("saturation"))
        XCTAssertLessThan(fatHRV.deltaPoints, 0)
    }
}
