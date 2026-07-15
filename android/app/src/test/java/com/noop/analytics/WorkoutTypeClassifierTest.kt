package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.StepSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Synthetic-fixture tests for the coarse [WorkoutTypeClassifier] (and its [WorkoutClassFeatures]
 * scoring directly). Faithful Kotlin mirror of WorkoutTypeClassifierTests.swift (#414) — same
 * fixtures, same expected classes. Per the CLAUDE.md derived-signal validation rule, each class is
 * exercised with MULTIPLE distinct injected patterns rather than one lucky example, plus an ambiguous
 * window that must NOT get a confident specific label.
 *
 * Real-world validation against labeled workouts (Oura-import `workout.sport` ground truth) is an
 * explicit, separate follow-up — these fixtures only prove the heuristic recovers the shapes it was
 * designed around.
 */
class WorkoutTypeClassifierTest {

    /** Feature-vector builder (keeps test cases terse and readable). */
    private fun features(
        durationMin: Double = 30.0,
        meanHR: Double,
        peakHR: Int,
        meanHRRPct: Double?,
        hrCV: Double,
        stillFraction: Double = 0.0,
        walkFraction: Double = 0.0,
        runFraction: Double = 0.0,
        tickCoverage: Double = 0.0,
        motionVariance: Double,
        motionCV: Double = 0.5,
        kcalPerMin: Double?,
    ): WorkoutClassFeatures = WorkoutClassFeatures(
        durationSec = durationMin * 60, meanHR = meanHR, peakHR = peakHR, meanHRRPct = meanHRRPct,
        hrCV = hrCV, stillFraction = stillFraction, walkFraction = walkFraction,
        runFraction = runFraction, tickCoverage = tickCoverage,
        motionVariance = motionVariance, motionCV = motionCV, kcalPerMin = kcalPerMin,
    )

    // ── RUN: two distinct injected patterns ─────────────────────────────────────

    @Test
    fun runShapedWindowDominantRunTicksIsClassifiedRun() {
        // Dominant run-classified ticks, elevated %HRR, higher-impact motion, smooth (low-CV) HR.
        val f = features(
            meanHR = 155.0, peakHR = 168, meanHRRPct = 70.0, hrCV = 0.04,
            stillFraction = 0.05, walkFraction = 0.1, runFraction = 0.8, tickCoverage = 0.9,
            motionVariance = 0.20, kcalPerMin = 11.0,
        )
        val out = WorkoutTypeClassifier.classify(f)
        assertEquals("scores: ${out.scores}", CoarseWorkoutClass.RUN, out.predictedClass)
        assertTrue(out.confidence > 0.4)
    }

    @Test
    fun runShapedWindowNoTicksFallsBackToHRAndMotion() {
        // No activity-class ticks at all (e.g. a WHOOP 4.0 capture) — must still read RUN from the
        // HR+motion fallback alone (high %HRR, smooth HR, high-impact motion).
        val f = features(
            meanHR = 160.0, peakHR = 172, meanHRRPct = 72.0, hrCV = 0.03,
            tickCoverage = 0.0, motionVariance = 0.25, kcalPerMin = 12.0,
        )
        val out = WorkoutTypeClassifier.classify(f)
        assertEquals("scores: ${out.scores}", CoarseWorkoutClass.RUN, out.predictedClass)
    }

    // ── WALK: two distinct injected patterns, incl. the "low-HR walk" from the brief ──

    @Test
    fun lowHRWalkIsClassifiedWalk() {
        // The brief's canonical case: a low-HR walk. Dominant walk ticks, LOW %HRR, modest motion.
        val f = features(
            meanHR = 96.0, peakHR = 104, meanHRRPct = 22.0, hrCV = 0.05,
            stillFraction = 0.1, walkFraction = 0.85, runFraction = 0.05, tickCoverage = 0.9,
            motionVariance = 0.03, kcalPerMin = 3.5,
        )
        val out = WorkoutTypeClassifier.classify(f)
        assertEquals("scores: ${out.scores}", CoarseWorkoutClass.WALK, out.predictedClass)
        assertTrue(out.confidence > 0.4)
    }

    @Test
    fun briskWalkHigherHRStillClassifiedWalk() {
        // A brisker walk: higher (but not run-level) %HRR, still dominant walk ticks.
        val f = features(
            meanHR = 118.0, peakHR = 128, meanHRRPct = 38.0, hrCV = 0.04,
            stillFraction = 0.05, walkFraction = 0.9, runFraction = 0.05, tickCoverage = 0.85,
            motionVariance = 0.05, kcalPerMin = 5.0,
        )
        val out = WorkoutTypeClassifier.classify(f)
        assertEquals("scores: ${out.scores}", CoarseWorkoutClass.WALK, out.predictedClass)
    }

    // ── STRENGTH: two distinct injected patterns, incl. the "high-HR low-cadence" case ──

    @Test
    fun highHRLowCadenceWindowIsClassifiedStrength() {
        // The brief's canonical case: high HR, no walk/run gait ("low cadence"), bursty sets-then-rest
        // HR pattern, lower sustained burn rate than continuous cardio.
        val f = features(
            meanHR = 140.0, peakHR = 172, meanHRRPct = 65.0, hrCV = 0.18,
            stillFraction = 0.85, walkFraction = 0.05, runFraction = 0.05, tickCoverage = 0.9,
            motionVariance = 0.03, kcalPerMin = 5.0,
        )
        val out = WorkoutTypeClassifier.classify(f)
        assertEquals("scores: ${out.scores}", CoarseWorkoutClass.STRENGTH, out.predictedClass)
        assertTrue(out.confidence > 0.3)
    }

    @Test
    fun moderateHRBurstySetsIsClassifiedStrength() {
        // A gentler lifting session: moderate %HRR (not a cardio spike), still bursty HR, no gait ticks.
        val f = features(
            meanHR = 110.0, peakHR = 145, meanHRRPct = 42.0, hrCV = 0.14,
            stillFraction = 0.8, walkFraction = 0.1, runFraction = 0.1, tickCoverage = 0.7,
            motionVariance = 0.02, kcalPerMin = 4.0,
        )
        val out = WorkoutTypeClassifier.classify(f)
        assertEquals("scores: ${out.scores}", CoarseWorkoutClass.STRENGTH, out.predictedClass)
    }

    // ── CYCLE: two distinct injected patterns ───────────────────────────────────

    @Test
    fun steadyCycleIsClassifiedCycle() {
        // No gait ticks, smooth (low-CV) sustained elevated HR, low motion variance (stable torso).
        val f = features(
            meanHR = 145.0, peakHR = 158, meanHRRPct = 60.0, hrCV = 0.03,
            stillFraction = 0.9, walkFraction = 0.05, runFraction = 0.05, tickCoverage = 0.9,
            motionVariance = 0.015, kcalPerMin = 9.0,
        )
        val out = WorkoutTypeClassifier.classify(f)
        assertEquals("scores: ${out.scores}", CoarseWorkoutClass.CYCLE, out.predictedClass)
        assertTrue(out.confidence > 0.3)
    }

    @Test
    fun easySpinNoTicksAtAllIsClassifiedCycle() {
        // No activity-class data whatsoever (tickCoverage 0) — must not be penalized as if "no gait"
        // were disproven; HR+motion alone should still read CYCLE (smooth, stable, moderate HR).
        val f = features(
            meanHR = 120.0, peakHR = 132, meanHRRPct = 40.0, hrCV = 0.04,
            tickCoverage = 0.0, motionVariance = 0.01, kcalPerMin = 6.0,
        )
        val out = WorkoutTypeClassifier.classify(f)
        assertEquals("scores: ${out.scores}", CoarseWorkoutClass.CYCLE, out.predictedClass)
    }

    // ── SKI: two distinct injected patterns ─────────────────────────────────────

    @Test
    fun downhillSkiSessionIsClassifiedSki() {
        // No gait ticks, high posture/motion variance (turns/terrain), wide intermittent HR (runs
        // interspersed with lift-ride rest) — more variable than cycle's steady spin.
        val f = features(
            durationMin = 120.0, meanHR = 128.0, peakHR = 165, meanHRRPct = 55.0, hrCV = 0.16,
            stillFraction = 0.85, walkFraction = 0.1, runFraction = 0.05, tickCoverage = 0.6,
            motionVariance = 0.25, kcalPerMin = 7.0,
        )
        val out = WorkoutTypeClassifier.classify(f)
        assertEquals("scores: ${out.scores}", CoarseWorkoutClass.SKI, out.predictedClass)
    }

    @Test
    fun skiSessionLighterDayIsClassifiedSki() {
        // A gentler ski day: lower average HRR (more time on lifts / easy runs) but the same
        // high-variance, intermittent signature.
        val f = features(
            durationMin = 150.0, meanHR = 108.0, peakHR = 150, meanHRRPct = 38.0, hrCV = 0.14,
            stillFraction = 0.85, walkFraction = 0.1, runFraction = 0.05, tickCoverage = 0.5,
            motionVariance = 0.20, kcalPerMin = 5.0,
        )
        val out = WorkoutTypeClassifier.classify(f)
        assertEquals("scores: ${out.scores}", CoarseWorkoutClass.SKI, out.predictedClass)
    }

    // ── Ambiguous → low confidence / other ──────────────────────────────────────

    @Test
    fun ambiguousWindowIsOtherOrLowConfidence() {
        // Deliberately doesn't match any prototype well: moderate-elevated HR with essentially no
        // gait ticks, low motion variance, but ALSO not smooth enough to read as cycle and not bursty
        // enough to read as strength — sits in the crack between bands.
        val f = features(
            meanHR = 118.0, peakHR = 135, meanHRRPct = 45.0, hrCV = 0.08,
            tickCoverage = 0.0, motionVariance = 0.045, kcalPerMin = 5.2,
        )
        val out = WorkoutTypeClassifier.classify(f)
        assertTrue(
            "expected OTHER or low confidence, got ${out.predictedClass} @ ${out.confidence}, scores: ${out.scores}",
            out.predictedClass == CoarseWorkoutClass.OTHER || out.confidence < 0.4,
        )
    }

    @Test
    fun veryThinDataLowConfidence() {
        // Minimal window, no ticks, no resolvable %HRR (null) — whatever the guess, confidence must be
        // damped by the missing inputs, never reading as fully confident.
        val f = features(
            meanHR = 100.0, peakHR = 110, meanHRRPct = null, hrCV = 0.05,
            tickCoverage = 0.0, motionVariance = 0.02, kcalPerMin = null,
        )
        val out = WorkoutTypeClassifier.classify(f)
        assertTrue("confidence should be damped by missing HRR/tick data", out.confidence < 0.7)
    }

    // ── Confidence sanity: a clean signature should outrank an ambiguous one ────

    @Test
    fun cleanSignatureIsMoreConfidentThanAmbiguous() {
        val clean = features(
            meanHR = 96.0, peakHR = 104, meanHRRPct = 22.0, hrCV = 0.05,
            stillFraction = 0.1, walkFraction = 0.85, runFraction = 0.05, tickCoverage = 0.9,
            motionVariance = 0.03, kcalPerMin = 3.5,
        )
        val ambiguous = features(
            meanHR = 118.0, peakHR = 135, meanHRRPct = 45.0, hrCV = 0.08,
            tickCoverage = 0.0, motionVariance = 0.045, kcalPerMin = 5.2,
        )
        val cleanOut = WorkoutTypeClassifier.classify(clean)
        val ambiguousOut = WorkoutTypeClassifier.classify(ambiguous)
        assertTrue(cleanOut.confidence > ambiguousOut.confidence)
    }

    // ── `scores` always covers all five concrete classes, never OTHER ───────────

    @Test
    fun scoresCoverAllConcreteClassesNeverOther() {
        val f = features(
            meanHR = 120.0, peakHR = 140, meanHRRPct = 40.0, hrCV = 0.06,
            motionVariance = 0.05, kcalPerMin = 5.0,
        )
        val out = WorkoutTypeClassifier.classify(f)
        assertEquals(
            setOf(
                CoarseWorkoutClass.WALK, CoarseWorkoutClass.RUN, CoarseWorkoutClass.STRENGTH,
                CoarseWorkoutClass.CYCLE, CoarseWorkoutClass.SKI,
            ),
            out.scores.keys,
        )
        assertNull(out.scores[CoarseWorkoutClass.OTHER])
        for ((_, v) in out.scores) {
            assertTrue(v >= 0.0)
            assertTrue(v <= 1.0)
        }
    }

    // ── HeuristicWorkoutClassifier (interface seam) matches the object ──────────

    @Test
    fun heuristicWorkoutClassifierMatchesObjectClassify() {
        val f = features(
            meanHR = 96.0, peakHR = 104, meanHRRPct = 22.0, hrCV = 0.05,
            stillFraction = 0.1, walkFraction = 0.85, runFraction = 0.05, tickCoverage = 0.9,
            motionVariance = 0.03, kcalPerMin = 3.5,
        )
        val viaInterface: WorkoutTypeClassifying = HeuristicWorkoutClassifier()
        assertEquals(WorkoutTypeClassifier.classify(f), viaInterface.classify(f))
    }
}

/**
 * Tests for [WorkoutTypeFeatureExtractor] — building a [WorkoutClassFeatures] from raw decoded
 * streams ([HrSample], [GravitySample], [StepSample]), the same stores [WorkoutDetector] reads.
 * Mirrors WorkoutTypeFeatureExtractorTests.swift (#414).
 */
class WorkoutTypeFeatureExtractorTest {

    private val dev = "test"

    private fun hrBlock(start: Long, durS: Int, bpm: Int): List<HrSample> =
        (0 until durS).map { HrSample(deviceId = dev, ts = start + it, bpm = bpm) }

    private fun gravityBlock(start: Long, durS: Int, deltaMag: Double): List<GravitySample> =
        // Alternate x between 0 and deltaMag each second so activitySeries' L2 delta ≈ deltaMag per step.
        (0 until durS).map { i ->
            GravitySample(
                deviceId = dev, ts = start + i,
                x = if (i % 2 == 0) 0.0 else deltaMag, y = 0.0, z = 1.0,
            )
        }

    private fun stepBlock(start: Long, durS: Int, activityClass: Int): List<StepSample> =
        (0 until durS).map { StepSample(deviceId = dev, ts = start + it, counter = it, activityClass = activityClass) }

    @Test
    fun extractRunWindowRecoversRunDominantComposition() {
        val start = 1_000_000L
        val dur = 20 * 60
        val hr = hrBlock(start, dur, 160)
        val gravity = gravityBlock(start, dur, deltaMag = 0.4)
        val steps = stepBlock(start, dur, activityClass = 2) // 2 = run
        val f = WorkoutTypeFeatureExtractor.extract(
            hr = hr, gravity = gravity, steps = steps,
            start = start, end = start + dur,
            restingHR = 60.0, maxHR = 190.0, caloriesKcal = 240.0,
        )
        assertNotNull(f)
        f!!
        assertEquals(1.0, f.runFraction, 0.001)
        assertEquals(1.0, f.tickCoverage, 0.05)
        assertTrue((f.meanHRRPct ?: 0.0) > 50)
        assertTrue(f.motionVariance > 0)
        assertEquals(12.0, f.kcalPerMin ?: 0.0, 0.01)
        // Round-trips into a RUN classification end-to-end.
        val out = WorkoutTypeClassifier.classify(f)
        assertEquals("scores: ${out.scores}", CoarseWorkoutClass.RUN, out.predictedClass)
    }

    @Test
    fun extractWalkWindowRecoversWalkDominantComposition() {
        val start = 2_000_000L
        val dur = 30 * 60
        val hr = hrBlock(start, dur, 95)
        val gravity = gravityBlock(start, dur, deltaMag = 0.05)
        val steps = stepBlock(start, dur, activityClass = 1) // 1 = walk
        val f = WorkoutTypeFeatureExtractor.extract(
            hr = hr, gravity = gravity, steps = steps,
            start = start, end = start + dur,
            restingHR = 60.0, maxHR = 180.0, caloriesKcal = 105.0,
        )
        assertNotNull(f)
        f!!
        assertEquals(1.0, f.walkFraction, 0.001)
        val out = WorkoutTypeClassifier.classify(f)
        assertEquals("scores: ${out.scores}", CoarseWorkoutClass.WALK, out.predictedClass)
    }

    @Test
    fun extractWithNoStepDataTickCoverageIsZero() {
        // No StepSample rows at all in the window (pre-#316 firmware / WHOOP 4.0) — tickCoverage must
        // read 0, not crash or divide-by-zero, and the fractions must be 0 (not NaN).
        val start = 3_000_000L
        val dur = 15 * 60
        val hr = hrBlock(start, dur, 150)
        val gravity = gravityBlock(start, dur, deltaMag = 0.3)
        val f = WorkoutTypeFeatureExtractor.extract(
            hr = hr, gravity = gravity, steps = emptyList(),
            start = start, end = start + dur,
        )
        assertNotNull(f)
        f!!
        assertEquals(0.0, f.tickCoverage, 0.0)
        assertEquals(0.0, f.stillFraction, 0.0)
        assertEquals(0.0, f.walkFraction, 0.0)
        assertEquals(0.0, f.runFraction, 0.0)
        assertFalse(f.hrCV.isNaN())
        assertFalse(f.motionVariance.isNaN())
    }

    @Test
    fun extractWithNoHRInWindowReturnsNull() {
        val start = 4_000_000L
        assertNull(
            WorkoutTypeFeatureExtractor.extract(
                hr = emptyList(), gravity = emptyList(), steps = emptyList(),
                start = start, end = start + 600,
            ),
        )
    }

    @Test
    fun extractDegenerateWindowReturnsNull() {
        val hr = hrBlock(5_000_000L, 10, 100)
        assertNull(
            WorkoutTypeFeatureExtractor.extract(
                hr = hr, gravity = emptyList(), steps = emptyList(),
                start = 5_000_000L, end = 5_000_000L,
            ),
        )
        assertNull(
            WorkoutTypeFeatureExtractor.extract(
                hr = hr, gravity = emptyList(), steps = emptyList(),
                start = 5_000_100L, end = 5_000_000L,
            ),
        )
    }

    @Test
    fun extractWithNoCaloriesInputKcalPerMinIsNull() {
        val start = 6_000_000L
        val dur = 600
        val hr = hrBlock(start, dur, 130)
        val f = WorkoutTypeFeatureExtractor.extract(
            hr = hr, gravity = emptyList(), steps = emptyList(),
            start = start, end = start + dur,
        )
        assertNotNull(f)
        assertNull(f?.kcalPerMin)
    }
}
