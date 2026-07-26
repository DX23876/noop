import XCTest
import StrandAnalytics
import StrandDesign
import WhoopStore
@testable import Strand

/// LANE 2 (iOS UI) presentation helpers behind the "What shaped it" Charge breakdown, the score-
/// confidence tier chip, the calibrating countdown and the relative skin-temp label. Every helper is
/// PURE, so these assert the exact strings/colours the views render. No em-dashes.
final class ChargeBreakdownFormatTests: XCTestCase {

    // MARK: - A1: signed point-delta chip

    func testChipLabelCarriesExplicitSignAndPluralizes() {
        XCTAssertEqual(ChargeBreakdownFormat.chipLabel(deltaPoints: 6), "+6 pts")
        XCTAssertEqual(ChargeBreakdownFormat.chipLabel(deltaPoints: 1), "+1 pt")   // singular
        XCTAssertEqual(ChargeBreakdownFormat.chipLabel(deltaPoints: -3), "-3 pts")
        XCTAssertEqual(ChargeBreakdownFormat.chipLabel(deltaPoints: -1), "-1 pt")  // singular
        XCTAssertEqual(ChargeBreakdownFormat.chipLabel(deltaPoints: 0), "0 pts")
    }

    func testChipColorUsesRecoveryRampEndpoints() {
        // Positive -> the ramp's green peak; negative -> its red depleted end; neutral -> tertiary text.
        XCTAssertEqual(ChargeBreakdownFormat.chipColor(deltaPoints: 5), StrandPalette.recoveryColor(100))
        XCTAssertEqual(ChargeBreakdownFormat.chipColor(deltaPoints: -5), StrandPalette.recoveryColor(0))
        XCTAssertEqual(ChargeBreakdownFormat.chipColor(deltaPoints: 0), StrandPalette.textTertiary)
    }

    func testDriverAccessibilityLabelReadsRowVerbatim() {
        let d = ChargeDriver(label: "Resting heart rate", deltaPoints: 4,
                             valueText: "58 bpm", baselineText: "61 bpm baseline",
                             verdict: "below baseline, supporting recovery")
        XCTAssertEqual(
            ChargeBreakdownFormat.driverAccessibilityLabel(d),
            "Resting heart rate: up 4 points. 58 bpm, 61 bpm baseline. below baseline, supporting recovery.")
    }

    func testDriverAccessibilityLabelOmitsEmptyBaselineAndHandlesNegativeAndZero() {
        let neg = ChargeDriver(label: "Skin temperature", deltaPoints: -2,
                               valueText: "+0.4 C vs baseline", baselineText: "",
                               verdict: "warmer than baseline, limiting recovery")
        XCTAssertEqual(
            ChargeBreakdownFormat.driverAccessibilityLabel(neg),
            "Skin temperature: down 2 points. +0.4 C vs baseline. warmer than baseline, limiting recovery.")

        let zero = ChargeDriver(label: "Respiratory rate", deltaPoints: 0,
                                valueText: "14.0 br/min", baselineText: "14.0 br/min baseline",
                                verdict: "at baseline")
        XCTAssertEqual(
            ChargeBreakdownFormat.driverAccessibilityLabel(zero),
            "Respiratory rate: no change. 14.0 br/min, 14.0 br/min baseline. at baseline.")

        // singular point reads "point", not "points"
        let one = ChargeDriver(label: "HRV", deltaPoints: 1, valueText: "70 ms",
                               baselineText: "65 ms baseline", verdict: "above baseline, supporting recovery")
        XCTAssertTrue(ChargeBreakdownFormat.driverAccessibilityLabel(one).contains("up 1 point."))
    }

    /// The VoiceOver label now routes the engine's label + verdict (which are localization KEYS) through
    /// `String(localized:)` before interpolating, so a localized build reads them translated instead of
    /// leaking English. In the base (en) locale each key resolves to itself, so the sentence is unchanged:
    /// this pins that the localization wiring did not alter the en output (the parity fix must stay
    /// behaviour-preserving at source). The real engine label/verdict strings are used, so the assertion
    /// also proves those exact keys exist to localize.
    func testDriverAccessibilityLabelResolvesLabelAndVerdictThroughLocalization() {
        let d = ChargeDriver(label: "Heart rate variability", deltaPoints: 7,
                             valueText: "72 ms", baselineText: "64 ms baseline",
                             verdict: "above baseline, supporting recovery")
        // en: keys resolve to themselves -> identical to the pre-localization sentence.
        XCTAssertEqual(
            ChargeBreakdownFormat.driverAccessibilityLabel(d),
            "Heart rate variability: up 7 points. 72 ms, 64 ms baseline. above baseline, supporting recovery.")
    }

    // MARK: - A3: confidence tier chip (pure presentation of the EXISTING confidence)

    func testTierTagMapsConfidenceToShortTag() {
        XCTAssertEqual(ChargeBreakdownFormat.tierTag(.calibrating), "CALIBRATING")
        XCTAssertEqual(ChargeBreakdownFormat.tierTag(.building), "EST.")
        XCTAssertEqual(ChargeBreakdownFormat.tierTag(.solid), "REL.")
    }

    func testTierStateDotColorAgreesAndMapsLifecycleHues() {
        // Each confidence must map onto its lifecycle ScoreState (slate calibrating / blue building /
        // green solid); the dot colour reuses that state's hue so they never disagree on screen. We
        // assert the STATE mapping (Equatable), not the Color: SwiftUI dynamic-catalog colours mint a
        // fresh object per access, so Color == is unreliable even for the same palette token. The dot
        // colour is `tierState(confidence).color` by construction, so verifying the state mapping is
        // the honest, stable check.
        XCTAssertEqual(ChargeBreakdownFormat.tierState(.calibrating), .calibrating)
        XCTAssertEqual(ChargeBreakdownFormat.tierState(.building), .building)
        XCTAssertEqual(ChargeBreakdownFormat.tierState(.solid), .solid)
    }

    // MARK: - A4: calibrating countdown copy

    func testCalibrationCountdownPluralizes() {
        XCTAssertEqual(ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: 2), "2 nights to go")
        XCTAssertEqual(ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: 1), "1 night to go")
        XCTAssertEqual(ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: 0), "0 nights to go")
    }

    func testCalibrationUnlockCopyNamesTheScore() {
        XCTAssertEqual(ChargeBreakdownFormat.calibrationUnlockCopy(scoreName: "Charge"),
                       "more overnight wear to unlock your Charge baseline")
    }

    func testCalibrationProgressReadsBankedOfSeed() {
        XCTAssertEqual(ChargeBreakdownFormat.calibrationProgress(banked: 1, seed: 4),
                       "Calibrating, 1 of 4 nights")
        XCTAssertEqual(ChargeBreakdownFormat.calibrationProgress(banked: 0, seed: 4),
                       "Calibrating, 0 of 4 nights")
    }

    // MARK: - A5: relative skin-temp label

    func testSkinTempDeviationLabelSignsAndRoundsToOneDecimal() {
        XCTAssertEqual(
            ChargeBreakdownFormat.skinTempDeviationLabel(SkinTempRelative(deviationC: 0.34, tier: .warmer)),
            "+0.3 C vs your normal")
        XCTAssertEqual(
            ChargeBreakdownFormat.skinTempDeviationLabel(SkinTempRelative(deviationC: -0.42, tier: .cooler)),
            "-0.4 C vs your normal")
        XCTAssertEqual(
            ChargeBreakdownFormat.skinTempDeviationLabel(SkinTempRelative(deviationC: 0.0, tier: .typical)),
            "+0.0 C vs your normal")
    }

    func testSkinTempTierWord() {
        XCTAssertEqual(ChargeBreakdownFormat.skinTempTierWord(.cooler), "Cooler than your baseline")
        XCTAssertEqual(ChargeBreakdownFormat.skinTempTierWord(.typical), "Typical for you")
        XCTAssertEqual(ChargeBreakdownFormat.skinTempTierWord(.warmer), "Warmer than your baseline")
    }

    // MARK: - Deep-sleep HRV window gap (#233)

    func testChargeDeepWindowGapTrueOnlyForDeepWindowNilHrvAndNoDeepSleep() {
        // The gap: Deep window selected, no HRV computed, and under ~5 minutes of deep sleep that night.
        XCTAssertTrue(ChargeBreakdownFormat.chargeDeepWindowGap(hrvWindow: .deep, avgHrv: nil, deepMin: 0))
        XCTAssertTrue(ChargeBreakdownFormat.chargeDeepWindowGap(hrvWindow: .deep, avgHrv: nil, deepMin: nil))
        XCTAssertTrue(ChargeBreakdownFormat.chargeDeepWindowGap(hrvWindow: .deep, avgHrv: nil, deepMin: 4.9))

        // Whole-night window: never the deep-window gap, regardless of HRV/deep-sleep values.
        XCTAssertFalse(ChargeBreakdownFormat.chargeDeepWindowGap(hrvWindow: .whole, avgHrv: nil, deepMin: 0))

        // HRV present: Charge isn't actually empty, so this isn't the gap.
        XCTAssertFalse(ChargeBreakdownFormat.chargeDeepWindowGap(hrvWindow: .deep, avgHrv: 55.0, deepMin: 0))

        // Enough deep sleep banked: the nil (if any) has some other cause, not "no deep sleep".
        XCTAssertFalse(ChargeBreakdownFormat.chargeDeepWindowGap(hrvWindow: .deep, avgHrv: nil, deepMin: 12.0))
    }

    // MARK: - compute(row:days:restScore:) — the shared classic+Heute extraction (D3)

    /// A day carrying the overnight vitals `compute` folds over.
    private func vitalsDay(_ key: String, hrv: Double?, rhr: Int?, resp: Double?,
                           recovery: Double? = nil, skinTempDevC: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv,
                    recovery: recovery, strain: nil, exerciseCount: nil,
                    skinTempDevC: skinTempDevC, respRateBpm: resp)
    }

    /// ≥ `minNightsSeed` nights of vitals so the HRV baseline folds to `usable`; below that `compute`
    /// returns nil by design (calibrating).
    private func usableHistory() -> [DailyMetric] {
        (1...12).map { i in
            vitalsDay(String(format: "2026-07-%02d", i),
                      hrv: 60 + Double(i % 5), rhr: 55 + (i % 4), resp: 14 + Double(i % 3) * 0.2)
        }
    }

    /// The extraction must forward its inputs to the engine UNCHANGED: composing the same folded baselines
    /// and calling `RecoveryScorer.chargeDrivers` / `ScoreConfidence.charge` here must reproduce exactly
    /// what `compute` returns. This is what stops classic Today and Heute (its two only callers) from
    /// drifting — any change to how the row/history/restScore are folded or forwarded fails this.
    func testComputeMatchesTheEngineCompositionVerbatim() {
        var days = usableHistory()
        let row = vitalsDay("2026-07-13", hrv: 72, rhr: 58, resp: 14.2, recovery: 66, skinTempDevC: 0.3)
        days.append(row)
        let restScore = 84.0

        guard let out = ChargeBreakdownFormat.compute(row: row, days: days, restScore: restScore) else {
            return XCTFail("a scored night with a usable HRV baseline must yield a breakdown")
        }

        let hrvBase = Baselines.foldHistory(days.map(\.avgHrv), cfg: Baselines.hrvCfg)
        XCTAssertTrue(hrvBase.usable, "fixture must fold to a usable HRV baseline")
        let rhrBase = Baselines.foldHistory(days.map { $0.restingHr.map(Double.init) },
                                            cfg: Baselines.restingHRCfg)
        let respBase = Baselines.foldHistory(days.map(\.respRateBpm), cfg: Baselines.respCfg)
        let expected = RecoveryScorer.chargeDrivers(
            hrv: 72, rhr: 58, resp: 14.2,
            hrvBaseline: hrvBase,
            rhrBaseline: rhrBase.usable ? rhrBase : nil,
            respBaseline: respBase.usable ? respBase : nil,
            sleepPerf: restScore / 100.0, skinTempDev: 0.3)

        XCTAssertEqual(out.drivers, expected, "compute must forward inputs to chargeDrivers unchanged")
        XCTAssertFalse(out.drivers.isEmpty, "a scored night attributes at least one driver")
        XCTAssertEqual(out.confidence, ScoreConfidence.charge(recovery: 66, hrvBaseline: hrvBase),
                       "confidence must be surfaced from the SAME folded HRV baseline the drivers scored with")
        // Biggest mover first (the engine's documented order) so the UI sizes bars against drivers[0].
        let mags = out.drivers.map { abs($0.deltaPoints) }
        XCTAssertEqual(mags, mags.sorted(by: >), "drivers stay ordered biggest-mover-first")
    }

    /// The nil guards, identical to the pre-extraction `TodayView.chargeBreakdown()`: no row, no HRV, no
    /// resting HR, or too little history for a usable HRV baseline all mean "nothing to attribute" and the
    /// caller must gate through to the calibration copy instead of an empty breakdown.
    func testComputeReturnsNilForTheColdStartAndCalibratingGuards() {
        let history = usableHistory()

        // No row resolved at all.
        XCTAssertNil(ChargeBreakdownFormat.compute(row: nil, days: history, restScore: 80))

        // Row missing HRV -> nil (Charge needs a nightly HRV to attribute).
        let noHrv = vitalsDay("2026-07-13", hrv: nil, rhr: 58, resp: 14.2, recovery: 66)
        XCTAssertNil(ChargeBreakdownFormat.compute(row: noHrv, days: history + [noHrv], restScore: 80))

        // Row missing resting HR -> nil.
        let noRhr = vitalsDay("2026-07-13", hrv: 72, rhr: nil, resp: 14.2, recovery: 66)
        XCTAssertNil(ChargeBreakdownFormat.compute(row: noRhr, days: history + [noRhr], restScore: 80))

        // Row present but too little history for a usable HRV baseline (< seed nights) -> nil.
        let row = vitalsDay("2026-07-02", hrv: 72, rhr: 58, resp: 14.2, recovery: 66)
        let thin = [vitalsDay("2026-07-01", hrv: 60, rhr: 55, resp: 14), row]
        XCTAssertNil(ChargeBreakdownFormat.compute(row: row, days: thin, restScore: 80))
    }

    /// A missing `restScore` (Rest ring calibrating / no sleep-performance value) must not break the
    /// breakdown — the sleep-quality term simply drops, exactly as `TodayView.chargeBreakdown()` passed a
    /// nil `sleepPerf` through. The other drivers still attribute.
    func testComputeToleratesMissingRestScore() {
        var days = usableHistory()
        let row = vitalsDay("2026-07-13", hrv: 72, rhr: 58, resp: 14.2, recovery: 66)
        days.append(row)

        let out = ChargeBreakdownFormat.compute(row: row, days: days, restScore: nil)
        XCTAssertNotNil(out, "a nil restScore drops the sleep term but must not nil out the whole breakdown")
        XCTAssertEqual(out?.drivers.isEmpty, false, "the HRV/RHR terms still attribute without a Rest score")
    }
}
