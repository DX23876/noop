package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.exp

/**
 * Parasympathetic-saturation guard on Charge (recovery), shipped INSTRUMENT-FIRST — Kotlin twin of the Swift
 * `RecoverySaturationGuardTests` (StrandAnalytics, PR #461).
 *
 * A low nightly HRV normally drives Charge DOWN via the dominant HRV term. In a very fit / very relaxed state
 * HRV can read LOW while resting HR reads LOW too and the two decouple, which MAY be a benign saturated vagal
 * state rather than fatigue. The guard DETECTS that signature and computes the easing it would apply, but the
 * easing is deliberately NOT applied: Charge is byte-identical to pre-guard behaviour, and the would-be easing
 * is only reported (trace line + driver verdict).
 *
 * So these tests pin THREE things:
 *   1. Detection: the gate, the weaker-arm coupling strength, and the damp fraction (unchanged logic).
 *   2. Non-application: a firing night scores EXACTLY the raw, unguarded composite.
 *   3. Reporting: the trace names the would-be easing and its point delta; the driver verdict names the
 *      pattern without claiming the penalty was eased.
 *
 * See the header in RecoveryScorer.kt for why the easing is off (zero real firings observed; low HRV + low RHR
 * is also a reported non-functional-overreaching signature). Byte-identical inputs/expectations to the Swift
 * reference. No em-dashes.
 */
class RecoverySaturationGuardTest {

    /** A usable (trusted) baseline with a given mean and Gaussian sigma (spread is internal abs-dev units;
     *  zScore multiplies by 1.253 to recover sigma). Mirrors the Swift `baseline(mean:sigma:nValid:)`. */
    private fun baseline(mean: Double, sigma: Double, nValid: Int = 14): BaselineState =
        BaselineState(
            baseline = mean, spread = sigma / 1.253, nValid = nValid, nightsSinceUpdate = 0,
            status = if (nValid >= 14) BaselineStatus.TRUSTED else BaselineStatus.PROVISIONAL,
        )

    /** The plain HRV+RHR composite with NO easing: the score pre-guard behaviour produces. Mirrors the Swift
     *  `undampedScore(hrv:rhr:hrvB:rhrB:)`. */
    private fun undampedScore(hrv: Double, rhr: Double, hrvB: BaselineState, rhrB: BaselineState): Double {
        val hrvZ = RecoveryScorer.zScore(hrv, hrvB.baseline, hrvB.spread)
        val rhrZ = RecoveryScorer.zScore(rhrB.baseline, rhr, rhrB.spread)
        val wsum = RecoveryScorer.wHRV + RecoveryScorer.wRHR
        val z = (RecoveryScorer.wHRV * hrvZ + RecoveryScorer.wRHR * rhrZ) / wsum
        return 100.0 / (1.0 + exp(-RecoveryScorer.logisticK * (z - RecoveryScorer.logisticZ0)))
    }

    // MARK: - Detection: the guard helper in isolation (logic unchanged; easing is a counterfactual)

    @Test fun guardFiresOnSaturationSignatureAndWouldEaseButNeverRemovePenalty() {
        // HRV clearly below baseline (penalty direction) AND resting HR clearly below baseline (recovery-good
        // direction): the saturation signature. The would-be eased z is closer to 0 but stays negative: the
        // easing would never invert or fully remove the penalty.
        val s = RecoveryScorer.parasympatheticSaturation(hrvZ = -1.5, rhrZ = 1.5)
        assertTrue(s.active)
        assertTrue("would ease toward 0", s.easedHrvZ > -1.5)
        assertTrue("would still be a penalty (never inverted)", s.easedHrvZ < 0.0)
        assertTrue(s.dampFraction > 0.0)
        assertTrue("capped", s.dampFraction <= RecoveryScorer.satMaxDampFraction)
    }

    @Test fun guardIsSilentOnRealFatigue() {
        // Low HRV + HIGH resting HR (rhrZ negative): normal sympathetic coupling, genuine fatigue. The guard
        // must NOT fire.
        val s = RecoveryScorer.parasympatheticSaturation(hrvZ = -1.5, rhrZ = -1.5)
        assertFalse(s.active)
        assertEquals(-1.5, s.easedHrvZ, 1e-12)
        assertEquals(0.0, s.dampFraction, 1e-12)
    }

    @Test fun guardIsSilentWhenHRVIsNotLow() {
        // HRV at or above baseline is not a penalty to ease, even with a very low resting HR.
        assertFalse(RecoveryScorer.parasympatheticSaturation(hrvZ = 1.5, rhrZ = 1.5).active)
        assertFalse(RecoveryScorer.parasympatheticSaturation(hrvZ = 0.0, rhrZ = 1.5).active)
    }

    @Test fun guardIsSilentWithoutARestingHRSignal() {
        // No RHR term (null): nothing corroborates the low HRV, so real fatigue and benign saturation are
        // indistinguishable from HRV alone. Refuse to guess -> no detection.
        val s = RecoveryScorer.parasympatheticSaturation(hrvZ = -1.5, rhrZ = null)
        assertFalse(s.active)
        assertEquals(-1.5, s.easedHrvZ, 1e-12)
    }

    @Test fun guardIsSilentOnMarginalDivergenceBelowTheGate() {
        // Both arms present but shallow (below satEnterZ): marginal noise, not a clear pattern.
        val below = RecoveryScorer.satEnterZ - 0.05
        val s = RecoveryScorer.parasympatheticSaturation(hrvZ = -below, rhrZ = below)
        assertFalse(s.active)
        assertEquals(-below, s.easedHrvZ, 1e-12)
    }

    @Test fun dampingIsMonotonicInCorroborationAndCapped() {
        // Stronger corroboration (both arms deeper below baseline) would ease more, up to the cap.
        val weak = RecoveryScorer.parasympatheticSaturation(hrvZ = -0.8, rhrZ = 0.8).dampFraction
        val strong = RecoveryScorer.parasympatheticSaturation(hrvZ = -1.4, rhrZ = 1.4).dampFraction
        val saturated = RecoveryScorer.parasympatheticSaturation(hrvZ = -3.0, rhrZ = 3.0).dampFraction
        assertTrue(strong > weak)
        assertEquals(RecoveryScorer.satMaxDampFraction, saturated, 1e-12)   // never exceeds cap
        // The weaker arm caps the strength (conservative): a very low HRV with only a mildly low resting HR
        // is limited by the resting-HR arm.
        val limited = RecoveryScorer.parasympatheticSaturation(hrvZ = -3.0, rhrZ = 0.8)
        val bothStrong = RecoveryScorer.parasympatheticSaturation(hrvZ = -3.0, rhrZ = 3.0)
        assertTrue(limited.dampFraction < bothStrong.dampFraction)
    }

    // MARK: - Non-application: the detected easing must NOT move Charge

    @Test fun saturationNightScoresTheRawUndampedCompositeUnchanged() {
        // THE CORE INSTRUMENT-FIRST GUARANTEE. This night fires the guard (damp = 0.45, a would-be ~18-point
        // lift), yet recovery() must return EXACTLY the raw composite: the score is byte-identical to
        // pre-guard behaviour.
        val hrvB = baseline(mean = 50.0, sigma = 6.265)
        val rhrB = baseline(mean = 55.0, sigma = 5.0)

        // Confirm this fixture really does trip the detector (otherwise the test proves nothing).
        val hrvZ = RecoveryScorer.zScore(41.0, hrvB.baseline, hrvB.spread)
        val rhrZ = RecoveryScorer.zScore(rhrB.baseline, 48.0, rhrB.spread)
        val sat = RecoveryScorer.parasympatheticSaturation(hrvZ = hrvZ, rhrZ = rhrZ)
        assertTrue("fixture must fire the guard for this test to mean anything", sat.active)
        assertTrue(sat.dampFraction > 0.4)

        val scored = RecoveryScorer.recovery(
            hrv = 41.0, rhr = 48.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )!!
        assertEquals(
            "a firing night must still score the RAW composite (easing not applied)",
            undampedScore(41.0, 48.0, hrvB, rhrB), scored, 1e-9,
        )
    }

    @Test fun saturationNightStaysRedExactlyLikeBeforeTheGuard() {
        // The would-be easing on this fixture is large enough to cross red -> yellow. Instrument-first means
        // the band must NOT move: the night stays red until the easing is validated and enabled.
        val hrvB = baseline(mean = 50.0, sigma = 6.265)
        val rhrB = baseline(mean = 55.0, sigma = 5.0)
        val saturation = RecoveryScorer.recovery(
            hrv = 41.0, rhr = 48.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )!!
        assertTrue(
            "detection must not lift the night out of red while the easing is off",
            saturation < RecoveryScorer.bandRedMax,
        )
    }

    @Test fun realFatigueNightIsUnchangedToo() {
        // Low HRV + HIGH resting HR: the guard never fired here before and still does not.
        val hrvB = baseline(mean = 50.0, sigma = 6.265)
        val rhrB = baseline(mean = 55.0, sigma = 5.0)
        val fatigue = RecoveryScorer.recovery(
            hrv = 41.0, rhr = 62.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )!!
        assertTrue("low HRV + high resting HR must stay red", fatigue < RecoveryScorer.bandRedMax)
        assertEquals(undampedScore(41.0, 62.0, hrvB, rhrB), fatigue, 1e-9)
    }

    @Test fun highHRVGoodNightIsUnchangedByGuard() {
        // A genuinely great night (HRV up, resting HR down) must be untouched: the guard only engages when HRV
        // is BELOW baseline. Recompute the plain composite and require equality.
        val hrvB = baseline(mean = 50.0, sigma = 6.265)
        val rhrB = baseline(mean = 55.0, sigma = 5.0)
        val actual = RecoveryScorer.recovery(
            hrv = 62.0, rhr = 49.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )!!
        assertEquals(
            "HRV-above-baseline night must bypass the guard",
            undampedScore(62.0, 49.0, hrvB, rhrB), actual, 1e-9,
        )
    }

    // MARK: - Reporting: trace + driver breakdown surface the would-be easing

    @Test fun traceReportsWouldBeEasingWithoutChangingTheScore() {
        val hrvB = baseline(mean = 50.0, sigma = 6.265)
        val rhrB = baseline(mean = 55.0, sigma = 5.0)

        val (satScore, satLines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 41.0, rhr = 48.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )
        val plain = RecoveryScorer.recovery(
            hrv = 41.0, rhr = 48.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )
        assertEquals(plain, satScore)

        // The saturation line fires and reports the counterfactual.
        val satLine = satLines.firstOrNull { it.contains("charge saturation active") }
        assertNotNull("a firing night must emit the saturation diagnostic", satLine)
        assertTrue("must report the would-be point delta", satLine!!.contains("wouldRaiseCharge="))
        assertTrue("must report the would-be eased z", satLine.contains("wouldEaseHrvZTo="))
        assertTrue("must state the easing was not applied", satLine.contains("not applied"))

        // The reported would-be lift must be real and positive (this fixture: ~18 points).
        val delta = satLine.split(" ").first { it.startsWith("wouldRaiseCharge=") }
            .removePrefix("wouldRaiseCharge=").toDouble()
        assertTrue(delta > 15.0)
        assertTrue(delta < 21.0)

        // ...and the HRV TERM in the trace is the RAW z, matching what was actually scored.
        val hrvZRaw = RecoveryScorer.zScore(41.0, hrvB.baseline, hrvB.spread)
        val hrvTerm = satLines.first { it.startsWith("charge term hrv ") }
        assertTrue(
            "trace HRV term must be the raw scored z, not the eased one: $hrvTerm",
            hrvTerm.contains("z=${Math.round(hrvZRaw * 100.0) / 100.0}"),
        )

        // Real-fatigue night: NO saturation line (guard silent).
        val (_, fatLines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 41.0, rhr = 62.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )
        assertFalse(fatLines.any { it.contains("charge saturation") })
        for (l in satLines + fatLines) assertFalse("em-dash in: $l", l.contains("—"))
    }

    @Test fun chargeDriversHRVPenaltyIsFullAndVerdictNamesSaturationWithoutClaimingEasing() {
        val hrvB = baseline(mean = 50.0, sigma = 6.265)
        val rhrB = baseline(mean = 55.0, sigma = 5.0)

        // Saturation night: the verdict NAMES the detected pattern but still reports the penalty as limiting,
        // because the easing was not applied.
        val sat = RecoveryDrivers.chargeDrivers(
            hrv = 41.0, rhr = 48.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )
        val satHRV = sat.first { it.label == "Heart rate variability" }
        assertTrue("verdict must surface the detection", satHRV.verdict.contains("saturation"))
        assertTrue(
            "verdict must not imply the penalty was lifted: ${satHRV.verdict}",
            satHRV.verdict.contains("limiting recovery"),
        )
        assertFalse(satHRV.verdict.contains("penalty is eased"))
        assertFalse(satHRV.verdict.contains("—"))
        assertTrue("the HRV penalty is still fully charged", satHRV.deltaPoints < 0)

        // Real-fatigue night: plain limiting verdict, no saturation mention.
        val fat = RecoveryDrivers.chargeDrivers(
            hrv = 41.0, rhr = 62.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = null, sleepPerf = null,
        )
        val fatHRV = fat.first { it.label == "Heart rate variability" }
        assertTrue(fatHRV.verdict.contains("limiting recovery"))
        assertFalse(fatHRV.verdict.contains("saturation"))
        assertTrue(fatHRV.deltaPoints < 0)
    }
}
