package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for [NapDetector] — the pure core of on-device short-nap detection (PR #569 reimpl under
 * NoopApp). Covers the dense-gravity eligibility gate, the tri-state verdict (NAP / NONE / INCONCLUSIVE),
 * the longest-quiet-run detection, the resting-HR settle gate, the min/max length bounds, and the
 * confidence ordering. Fixtures are DB-free + clock-free so they run under testFullDebugUnitTest and are
 * byte-identical to verify cross-platform.
 */
class NapDetectorTest {

    private val dev = "test-device"
    private val cad = 30L  // ~30 s offload cadence — dense by the engine's median-gap gate

    /** A gravity sample at [sec] with x-delta [x] (y=0, z=1 — same shape as the sedentary tests). */
    private fun grav(sec: Long, x: Double) = GravitySample(deviceId = dev, ts = sec, x = x, y = 0.0, z = 1.0)

    /** A still window from [start]..[end] at cadence [cad]: alternating tiny 0.0/0.01 deltas → ~0 motion. */
    private fun stillWindow(start: Long, end: Long, jitter: Double = 0.01): List<GravitySample> {
        val out = ArrayList<GravitySample>()
        var t = start
        var i = 0
        while (t <= end) { out.add(grav(t, if (i % 2 == 0) 0.0 else jitter)); t += cad; i++ }
        return out
    }

    /** A moving window: alternating 0.0/0.5 deltas → well above the still threshold. */
    private fun movingWindow(start: Long, end: Long): List<GravitySample> {
        val out = ArrayList<GravitySample>()
        var t = start
        var i = 0
        while (t <= end) { out.add(grav(t, if (i % 2 == 0) 0.0 else 0.5)); t += cad; i++ }
        return out
    }

    /** Constant-HR rows over [start]..[end] at cadence [cad]. */
    private fun hrWindow(start: Long, end: Long, bpm: Int): List<HrRow> {
        val out = ArrayList<HrRow>()
        var t = start
        while (t <= end) { out.add(HrRow(ts = t, bpm = bpm)); t += cad }
        return out
    }

    private val on = NapConfig(enabled = true)

    // ── Eligibility gate: isWindowDense ───────────────────────────────────────

    @Test fun dense_emptyIsNotDense() {
        assertFalse(NapDetector.isWindowDense(emptyList()))
    }

    @Test fun dense_tooFewSamplesIsNotDense() {
        assertFalse(NapDetector.isWindowDense(stillWindow(0, 5 * cad))) // 6 rows < 20
    }

    @Test fun dense_enoughCloselySpacedSamplesIsDense() {
        assertTrue(NapDetector.isWindowDense(stillWindow(0, 40 * 60))) // many rows, 30 s gaps
    }

    @Test fun dense_sparseGapsAreNotDense() {
        // 25 rows but spaced 5 min apart → median gap 300 s > 90 s cap.
        val sparse = (0 until 25).map { grav(it * 300L, 0.0) }
        assertFalse(NapDetector.isWindowDense(sparse))
    }

    @Test fun dense_respectsCustomThresholds() {
        val rows = (0 until 10).map { grav(it * 30L, 0.0) }
        assertTrue(NapDetector.isWindowDense(rows, minSamples = 10, maxMedianGapS = 60))
        assertFalse(NapDetector.isWindowDense(rows, minSamples = 11, maxMedianGapS = 60))
    }

    // ── longestQuietRun ───────────────────────────────────────────────────────

    @Test fun quiet_emptyIsNull() {
        assertNull(NapDetector.longestQuietRun(emptyList()))
    }

    @Test fun quiet_allStillReturnsWholeSpan() {
        val run = NapDetector.longestQuietRun(stillWindow(0, 30 * 60))
        assertNotNull(run)
        assertEquals(0L, run!!.first)
        assertTrue(run.second >= 29 * 60L)
    }

    @Test fun quiet_movementEndsTheRun() {
        val g = stillWindow(0, 30 * 60) + movingWindow(30 * 60 + cad, 40 * 60)
        val run = NapDetector.longestQuietRun(g)
        assertNotNull(run)
        assertEquals(0L, run!!.first)
        assertTrue("quiet run should end near the motion boundary, got ${run.second / 60}", run.second in 27 * 60L..33 * 60L)
    }

    @Test fun quiet_picksTheLongestOfTwoRuns() {
        // 12 min still, 5 min moving, 30 min still → the second run is the longest.
        val g = stillWindow(0, 12 * 60) +
            movingWindow(12 * 60 + cad, 17 * 60) +
            stillWindow(17 * 60 + cad, 47 * 60)
        val run = NapDetector.longestQuietRun(g)
        assertNotNull(run)
        assertTrue("should pick the later, longer run", run!!.first >= 17 * 60L)
    }

    @Test fun quiet_dataGapBreaksTheRun() {
        // Still for 40 min, then a 20-min hole, then still again — the hole splits it.
        val g = stillWindow(0, 40 * 60) + stillWindow(60 * 60, 75 * 60)
        val run = NapDetector.longestQuietRun(g)
        assertNotNull(run)
        // The first (longer) run should win and end before the hole.
        assertEquals(0L, run!!.first)
        assertTrue(run.second <= 41 * 60L)
    }

    // ── meanHrIn ──────────────────────────────────────────────────────────────

    @Test fun meanHr_emptyIsNull() {
        assertNull(NapDetector.meanHrIn(emptyList(), 0, 100))
    }

    @Test fun meanHr_averagesInWindow() {
        val hr = listOf(HrRow(10, 50), HrRow(20, 60), HrRow(30, 70))
        assertEquals(60, NapDetector.meanHrIn(hr, 0, 100))
    }

    @Test fun meanHr_ignoresOutsideWindow() {
        val hr = listOf(HrRow(10, 50), HrRow(200, 120))
        assertEquals(50, NapDetector.meanHrIn(hr, 0, 100))
    }

    @Test fun meanHr_dropsImplausibleBpm() {
        val hr = listOf(HrRow(10, 50), HrRow(20, 0), HrRow(30, 300))
        assertEquals(50, NapDetector.meanHrIn(hr, 0, 100))
    }

    // ── evaluate: feature gate + eligibility ──────────────────────────────────

    @Test fun eval_disabledIsInconclusiveNoCandidate() {
        val g = stillWindow(0, 40 * 60)
        val d = NapDetector.evaluate(g, emptyList(), restingHr = 55, config = NapConfig(enabled = false))
        assertEquals(NapVerdict.INCONCLUSIVE, d.verdict)
        assertNull(d.candidate)
    }

    @Test fun eval_sparseWindowIsInconclusive() {
        val sparse = (0 until 25).map { grav(it * 300L, 0.0) } // dense-gate fails
        val d = NapDetector.evaluate(sparse, emptyList(), restingHr = 55, config = on)
        assertEquals(NapVerdict.INCONCLUSIVE, d.verdict)
        assertNull(d.candidate)
    }

    @Test fun eval_tooFewSamplesIsInconclusive() {
        val d = NapDetector.evaluate(stillWindow(0, 5 * cad), emptyList(), restingHr = 55, config = on)
        assertEquals(NapVerdict.INCONCLUSIVE, d.verdict)
    }

    // ── evaluate: NONE (dense data, clearly awake) ────────────────────────────

    @Test fun eval_denseButMovingIsNone() {
        val g = movingWindow(0, 40 * 60)
        val d = NapDetector.evaluate(g, emptyList(), restingHr = 55, config = on)
        assertEquals(NapVerdict.NONE, d.verdict)
        assertNull(d.candidate)
    }

    @Test fun eval_quietButTooShortIsNone() {
        // ~10 min still (< 20 min min nap), densely sampled at 15 s so it still clears the 20-sample gate.
        val dense = (0..40).map { grav(it * 15L, if (it % 2 == 0) 0.0 else 0.01) } // ~10 min, 41 rows
        val d = NapDetector.evaluate(dense, emptyList(), restingHr = 55, config = on)
        assertEquals(NapVerdict.NONE, d.verdict)
    }

    @Test fun eval_stillButHrElevatedIsNone() {
        // 30 min still, but mean HR 80 with resting 55 + margin 8 → not settled → awake-but-still.
        val g = stillWindow(0, 30 * 60)
        val hr = hrWindow(0, 30 * 60, bpm = 80)
        val d = NapDetector.evaluate(g, hr, restingHr = 55, config = on)
        assertEquals(NapVerdict.NONE, d.verdict)
        assertNull(d.candidate)
    }

    // ── evaluate: NAP (the confident case) ────────────────────────────────────

    @Test fun eval_stillAndSettledIsNap() {
        val g = stillWindow(0, 30 * 60)
        val hr = hrWindow(0, 30 * 60, bpm = 56) // <= 55 + 8
        val d = NapDetector.evaluate(g, hr, restingHr = 55, config = on)
        assertEquals(NapVerdict.NAP, d.verdict)
        assertNotNull(d.candidate)
        assertEquals(56, d.candidate!!.meanHr)
    }

    @Test fun eval_napCandidateHasPlausibleWindow() {
        val g = stillWindow(0, 30 * 60)
        val hr = hrWindow(0, 30 * 60, bpm = 56)
        val c = NapDetector.evaluate(g, hr, restingHr = 55, config = on).candidate!!
        assertEquals(0L, c.start)
        assertTrue(c.end >= 29 * 60L)
        assertTrue(c.durationS >= 20 * 60L)
    }

    @Test fun eval_settledExactlyAtMarginIsNap() {
        val g = stillWindow(0, 30 * 60)
        val hr = hrWindow(0, 30 * 60, bpm = 63) // 55 + 8 exactly → settled (<=)
        assertEquals(NapVerdict.NAP, NapDetector.evaluate(g, hr, restingHr = 55, config = on).verdict)
    }

    @Test fun eval_oneOverMarginIsNone() {
        val g = stillWindow(0, 30 * 60)
        val hr = hrWindow(0, 30 * 60, bpm = 64) // 55 + 8 + 1 → not settled
        assertEquals(NapVerdict.NONE, NapDetector.evaluate(g, hr, restingHr = 55, config = on).verdict)
    }

    @Test fun eval_unknownRestingHrStillAllowsNapOnMotion() {
        // No resting HR + no HR rows → lean on motion alone → NAP, but capped-confidence.
        val g = stillWindow(0, 30 * 60)
        val d = NapDetector.evaluate(g, emptyList(), restingHr = null, config = on)
        assertEquals(NapVerdict.NAP, d.verdict)
        assertNotNull(d.candidate)
        assertNull(d.candidate!!.meanHr)
        assertTrue("unknown-HR confidence is capped", d.candidate!!.confidence <= 0.7)
    }

    @Test fun eval_unknownRestingButHrPresentStillNaps() {
        // HR rows present but resting unknown → can't apply the settle gate → NAP on motion.
        val g = stillWindow(0, 30 * 60)
        val hr = hrWindow(0, 30 * 60, bpm = 90)
        val d = NapDetector.evaluate(g, hr, restingHr = null, config = on)
        assertEquals(NapVerdict.NAP, d.verdict)
        assertEquals(90, d.candidate!!.meanHr)
    }

    // ── evaluate: INCONCLUSIVE (too long = maybe main sleep) ──────────────────

    @Test fun eval_overMaxLengthIsInconclusive() {
        // 120 min still (> 90 min max nap) → could be main sleep → don't mislabel.
        val g = stillWindow(0, 120 * 60)
        val hr = hrWindow(0, 120 * 60, bpm = 50)
        val d = NapDetector.evaluate(g, hr, restingHr = 55, config = on)
        assertEquals(NapVerdict.INCONCLUSIVE, d.verdict)
        assertNull(d.candidate)
    }

    @Test fun eval_atMaxLengthIsStillNap() {
        // Exactly 90 min → within bounds → NAP (boundary inclusive).
        val g = stillWindow(0, 90 * 60)
        val hr = hrWindow(0, 90 * 60, bpm = 56)
        assertEquals(NapVerdict.NAP, NapDetector.evaluate(g, hr, restingHr = 55, config = on).verdict)
    }

    @Test fun eval_atMinLengthIsNap() {
        val g = stillWindow(0, 20 * 60) // exactly 20 min
        val hr = hrWindow(0, 20 * 60, bpm = 56)
        assertEquals(NapVerdict.NAP, NapDetector.evaluate(g, hr, restingHr = 55, config = on).verdict)
    }

    @Test fun eval_justUnderMinIsNone() {
        // ~19 min still → below the 20-min minimum.
        val dense = (0..76).map { grav(it * 15L, if (it % 2 == 0) 0.0 else 0.01) } // ~19 min, 77 rows
        val d = NapDetector.evaluate(dense, emptyList(), restingHr = null, config = on)
        assertEquals(NapVerdict.NONE, d.verdict)
    }

    // ── config knobs ──────────────────────────────────────────────────────────

    @Test fun eval_customStillThresholdTightensDetection() {
        // A jittery-still window (0.06 g) passes the default 0.08 threshold but fails a stricter 0.04.
        val g = stillWindow(0, 30 * 60, jitter = 0.06)
        val loose = NapDetector.evaluate(g, hrWindow(0, 30 * 60, 56), 55, on)
        assertEquals(NapVerdict.NAP, loose.verdict)
        val strict = NapDetector.evaluate(g, hrWindow(0, 30 * 60, 56), 55, on.copy(stillThresholdG = 0.04))
        assertEquals(NapVerdict.NONE, strict.verdict)
    }

    @Test fun eval_customMinNapMinutes() {
        val g = stillWindow(0, 25 * 60)
        val hr = hrWindow(0, 25 * 60, 56)
        // Raising the min above the run length flips NAP→NONE.
        assertEquals(NapVerdict.NAP, NapDetector.evaluate(g, hr, 55, on).verdict)
        assertEquals(NapVerdict.NONE, NapDetector.evaluate(g, hr, 55, on.copy(minNapMinutes = 30)).verdict)
    }

    @Test fun eval_customMaxNapMinutes() {
        val g = stillWindow(0, 50 * 60)
        val hr = hrWindow(0, 50 * 60, 56)
        assertEquals(NapVerdict.NAP, NapDetector.evaluate(g, hr, 55, on).verdict)
        // Lowering the max below the run length flips NAP→INCONCLUSIVE.
        assertEquals(NapVerdict.INCONCLUSIVE, NapDetector.evaluate(g, hr, 55, on.copy(maxNapMinutes = 40)).verdict)
    }

    @Test fun eval_customHrMargin() {
        val g = stillWindow(0, 30 * 60)
        val hr = hrWindow(0, 30 * 60, bpm = 70) // 55 + 15
        assertEquals(NapVerdict.NONE, NapDetector.evaluate(g, hr, 55, on).verdict) // default margin 8
        assertEquals(NapVerdict.NAP, NapDetector.evaluate(g, hr, 55, on.copy(hrSettleMarginBpm = 20)).verdict)
    }

    // ── confidenceFor ─────────────────────────────────────────────────────────

    @Test fun confidence_isBounded() {
        for (mins in listOf(20.0, 45.0, 90.0)) {
            val c = NapDetector.confidenceFor(mins, restingHr = 55, meanHr = 50, config = on)
            assertTrue(c in 0.0..1.0)
        }
    }

    @Test fun confidence_longerNapIsMoreConfident() {
        val short = NapDetector.confidenceFor(20.0, 55, 50, on)
        val long = NapDetector.confidenceFor(85.0, 55, 50, on)
        assertTrue("longer nap → higher confidence", long > short)
    }

    @Test fun confidence_unknownHrIsCapped() {
        val c = NapDetector.confidenceFor(90.0, restingHr = null, meanHr = null, config = on)
        assertTrue(c <= 0.7)
    }

    @Test fun confidence_settledHrAddsConfidence() {
        val barely = NapDetector.confidenceFor(45.0, restingHr = 55, meanHr = 63, config = on) // at margin
        val deeply = NapDetector.confidenceFor(45.0, restingHr = 55, meanHr = 45, config = on) // well below
        assertTrue("a more-settled HR is more confident", deeply >= barely)
    }

    @Test fun confidence_neverNegativeWhenHrAboveBand() {
        // meanHr above the band shouldn't drive confidence negative (the NONE path catches it, but the
        // helper must still be bounded if called directly).
        val c = NapDetector.confidenceFor(45.0, restingHr = 55, meanHr = 100, config = on)
        assertTrue(c in 0.0..1.0)
    }

    // ── candidate fields ──────────────────────────────────────────────────────

    @Test fun candidate_durationSMatchesWindow() {
        val c = NapCandidate(start = 1000, end = 1000 + 25 * 60, meanHr = 55, confidence = 0.5)
        assertEquals(25 * 60L, c.durationS)
    }

    // ── robustness ────────────────────────────────────────────────────────────

    @Test fun eval_unsortedGravityStillWorks() {
        val sorted = stillWindow(0, 30 * 60)
        val shuffled = sorted.shuffled(java.util.Random(7))
        val a = NapDetector.evaluate(sorted, hrWindow(0, 30 * 60, 56), 55, on)
        val b = NapDetector.evaluate(shuffled, hrWindow(0, 30 * 60, 56), 55, on)
        assertEquals(a.verdict, b.verdict)
        assertEquals(a.candidate?.start, b.candidate?.start)
        assertEquals(a.candidate?.end, b.candidate?.end)
    }

    @Test fun eval_noHrRowsLeavesMeanHrNull() {
        val g = stillWindow(0, 30 * 60)
        val d = NapDetector.evaluate(g, emptyList(), restingHr = 55, config = on)
        // restingHr known but no HR rows → settle gate can't apply (meanHr null) → NAP on motion.
        assertEquals(NapVerdict.NAP, d.verdict)
        assertNull(d.candidate!!.meanHr)
    }

    @Test fun eval_hrOnlyOutsideWindowLeavesMeanNull() {
        val g = stillWindow(0, 30 * 60)
        val hr = listOf(HrRow(ts = 60 * 60, bpm = 90)) // after the window
        val d = NapDetector.evaluate(g, hr, restingHr = 55, config = on)
        assertEquals(NapVerdict.NAP, d.verdict)
        assertNull(d.candidate!!.meanHr)
    }
}
