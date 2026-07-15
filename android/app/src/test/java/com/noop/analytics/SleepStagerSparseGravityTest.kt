package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests SleepStager's sparse-gravity robustness (#308). On an un-unlocked WHOOP 5.0 the strap
 * backfills mostly v18/v26 records where gravity is sparse/clumped (~25% coverage), so the
 * gravity-only Stage-0 spine fragments the night at every >maxGapMin gravity gap and detectSleep
 * drops every <minSleepMin fragment — collapsing a ~6 h night to ~1 h. The fix, GATED ENTIRELY
 * behind a "gravity is sparse" condition, re-stitches the night so dense WHOOP-4.0 nights stay
 * BYTE-IDENTICAL.
 *
 * Faithful Kotlin mirror of the sparse-gravity cases in SleepStagerTests.swift; same reference
 * midnight, same thresholds, same scenarios.
 */
class SleepStagerSparseGravityTest {

    private val dev = "test"

    /** 2025-06-10 00:00:00 UTC — an arbitrary fixed midnight (ref % 86400 == 0). */
    private val refMidnight = 1_749_513_600L

    /** Unix start at `hourUTC:00:00` on the reference day (tzOffset=0 → local == UTC hour). */
    private fun startAtHour(hourUTC: Int): Long = refMidnight + hourUTC * 3_600L

    /** Dense still gravity (constant orientation) at 1 Hz. */
    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }

    /**
     * Still gravity sampled sparsely — one sample every [everyS] seconds (constant orientation, so
     * every inter-sample delta is 0 → "still"). Reproduces the WHOOP 5.0 v18/v26 backfill where
     * gravity is clumped/sparse, leaving multiple >maxGapMin gaps across the night.
     */
    private fun sparseStillGravity(start: Long, durationS: Int, everyS: Int): List<GravitySample> {
        val out = ArrayList<GravitySample>()
        var t = 0
        while (t < durationS) {
            out.add(GravitySample(deviceId = dev, ts = start + t, x = 0.0, y = 0.0, z = 1.0))
            t += everyS
        }
        return out
    }

    private fun hrStream(start: Long, durationS: Int, bpm: Int): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = start + it, bpm = bpm) }

    @Test
    fun sparseGravityNightNotShredded() {
        // A ~6 h overnight window: DENSE 1 Hz sleep-band HR (50 bpm) but SPARSE gravity — one still
        // sample every 25 min, so every inter-sample gap (1500 s) exceeds maxGapMin (1200 s). Before
        // #308 buildRuns broke the run at every gap and detectSleep dropped every <60-min fragment,
        // collapsing the night to ~0. Now the sparse path keeps it as ONE continuous ~6 h session.
        val start = startAtHour(1) // 01:00, center stays overnight
        val dur = 6 * 60 * 60 // 6 h
        val grav = sparseStillGravity(start, dur, 25 * 60)
        val hr = hrStream(start, dur, 50)

        assertTrue("clumped gravity must read as sparse", SleepStager.isGravitySparse(grav, hr))

        val sessions = SleepStager.detectSleep(hr = hr, gravity = grav)
        assertEquals("a sparse-gravity night must be ONE session, not shredded", 1, sessions.size)
        val s = sessions[0]
        // One ~6 h span (bounded by first/last gravity sample), not a sub-60-min fragment.
        assertTrue("the bridged session must be ~6 h, not a sub-hour fragment",
            (s.end - s.start).toDouble() > 5.0 * 60 * 60)
        assertEquals(50, s.restingHR)
    }

    @Test
    fun denseGravityNightUnchangedBySparsePath() {
        // Snapshot/regression guard for the 4.0 path: a DENSE 1 Hz still gravity night must NOT be
        // classified sparse, and must produce the SAME single stable session it did before #308 —
        // identical start, end and resting HR. Proves the sparse branches never touch the dense path.
        val start = startAtHour(2)
        val dur = 6 * 60 * 60
        val grav = stillGravity(start, dur) // dense 1 Hz
        val hr = hrStream(start, dur, 50)

        assertFalse("dense 1 Hz gravity must NOT read as sparse", SleepStager.isGravitySparse(grav, hr))

        val sessions = SleepStager.detectSleep(hr = hr, gravity = grav)
        assertEquals(1, sessions.size)
        val s = sessions[0]
        // Stable bounds: dense gravity tiles the whole window, so the session is [start, last sample].
        assertEquals(start, s.start)
        assertEquals(start + dur - 1, s.end) // last 1 Hz sample is at start+dur-1
        assertEquals(50, s.restingHR)
    }

    @Test
    fun buildRunsDenseGravityByteIdenticalToLegacy() {
        // Direct byte-identity proof: buildRuns with the sparse override OFF (the default) returns
        // exactly the same runs as passing sparse=false, on a gravity stream with a real >maxGapMin
        // gap. The legacy two-arg call and the sparse=false call must be indistinguishable.
        val start = 5_000_000L
        // Two still blocks separated by a 30-min (>20 min) gap → legacy buildRuns splits them.
        val blockA = stillGravity(start, 40 * 60)
        val gapStart = start + (40 * 60 + 30 * 60).toLong()
        val blockB = stillGravity(gapStart, 40 * 60)
        val grav = blockA + blockB
        val deltas = SleepStager.gravityDeltas(grav)
        val flags = SleepStager.classifyStill(grav, deltas)

        val legacy = SleepStager.buildRuns(grav, flags) // default sparse=false
        val explicit = SleepStager.buildRuns(grav, flags, sparse = false)
        assertEquals(legacy, explicit)
        // The dense >20-min gap still splits the night (a real wake), so there are ≥2 runs.
        assertTrue("a real >20-min gap must still split the dense path", legacy.size >= 2)
    }

    @Test
    fun gravitySparseGateConditions() {
        // The gate trips on EITHER a short gravity span vs HR span OR any inter-sample gravity gap > maxGapMin.
        val start = 6_000_000L
        val hr = hrStream(start, 6 * 60 * 60, 50)

        // (a) Span test: gravity confined to the first 30 min of a 6 h HR window (< 0.5 frac).
        val clumped = stillGravity(start, 30 * 60)
        assertTrue("short gravity span → sparse", SleepStager.isGravitySparse(clumped, hr))

        // (b) Large-gap test: gravity spans the night but every gap is 25 min (> maxGapMin).
        val bigGaps = sparseStillGravity(start, 6 * 60 * 60, 25 * 60)
        assertTrue("a large inter-sample gap → sparse", SleepStager.isGravitySparse(bigGaps, hr))

        // (c) Dense gravity over the same span is NOT sparse.
        val dense = stillGravity(start, 6 * 60 * 60)
        assertFalse("dense gravity → not sparse", SleepStager.isGravitySparse(dense, hr))

        // (d) Degenerate HR (<2 samples) keeps the dense path regardless of gravity.
        assertFalse("no HR span → keep dense path", SleepStager.isGravitySparse(bigGaps, emptyList()))

        // (e) #28: gravity SPANS the night (span gate stays dense) with a ~1 s MEDIAN gap (dense
        // bursts) but a single >maxGapMin dropout — the median test misses it, the max-gap test
        // catches it. Two 160-min blocks split by a 40-min dropout cover the whole 6 h HR window.
        val clumpedBigGap = stillGravity(start, 160 * 60) +
            stillGravity(start + (160 + 40) * 60L, 160 * 60)
        assertTrue("clumped gravity + one long dropout (small median, large max) → sparse",
            SleepStager.isGravitySparse(clumpedBigGap, hr))
    }

    @Test
    fun clumpedGravityWithLongDropoutBridged() {
        // #28: WHOOP 4.0 motion arrives CLUMPED — two dense 40-min still blocks split by a 30-min
        // dropout, the gravity spanning the whole HR window. The block-internal gaps are ~1 s so the
        // MEDIAN gate stays dense and the span gate doesn't fire; only the new max-gap arm catches the
        // dropout. With sleep-band HR across the gap the night is bridged into ONE session instead of
        // two dropped sub-minSleepMin fragments (~0 sleep) under the old median-only gate.
        val start = startAtHour(2)
        val block = 40 * 60
        val gap = 30 * 60
        val grav = stillGravity(start, block) + stillGravity(start + (block + gap).toLong(), block)
        val dur = 2 * block + gap // HR spans the whole window
        val hr = hrStream(start, dur, 50)

        assertTrue("clumped motion with a long dropout (small median, large max gap) must read as sparse",
            SleepStager.isGravitySparse(grav, hr))
        val sessions = SleepStager.detectSleep(hr = hr, gravity = grav)
        assertEquals("the dropout must be bridged into ONE session, not dropped sub-60-min fragments",
            1, sessions.size)
        assertTrue("the bridged session must span both blocks across the dropout",
            (sessions[0].end - sessions[0].start).toDouble() > (2 * block).toDouble())
    }

    // #345 END-TO-END: a locked synthetic WHOOP-4.0 OFFLOAD night — dense sleep-band HR but clumped/sparse
    // motion (the ~20% coverage the reporter's log showed) — must flow REAL isGravitySparse → REAL forRest
    // → BUILDING, EVEN when the night ALSO looks healthy (high efficiency + ~45% restorative). That healthy-
    // looking case is exactly what H9 misses (H9 only fires on LOW restorative), so without the sparse guard
    // it would read a confident SOLID 85–100 — the #319 signature. This is the guard validated against a
    // realistic synthetic offload night, in the shipping code, since no real offload capture exists yet.
    @Test
    fun sparseOffloadNightForcesRestBuildingEndToEnd() {
        val start = startAtHour(1)
        val dur = 6 * 60 * 60
        val grav = sparseStillGravity(start, dur, 25 * 60) // clumped, each gap > maxGapMin
        val hr = hrStream(start, dur, 50)
        val sparse = SleepStager.isGravitySparse(grav, hr)
        assertTrue("the locked synthetic 4.0-offload night must read sparse", sparse)
        val asleep = 8.0 * 3600.0
        assertEquals(
            "a sparse-motion night — even high-efficiency AND healthy restorative (the #319 case H9 misses)" +
                " — must NOT earn a confident SOLID Rest",
            ScoreConfidence.BUILDING,
            ScoreConfidence.forRest(hasSession = true, hasStagedSleep = true,
                asleepSeconds = asleep, restorativeSeconds = asleep * 0.45, efficiency = 0.95,
                gravitySparse = sparse))
    }

    @Test
    fun denseNightKeepsRestSolidEndToEnd() {
        // The dense counterpart: same healthy night on DENSE 1 Hz motion → not sparse → SOLID stands. Proves
        // the guard is a strict no-op on dense (5.0-live / 4.0-live) nights — no regression there.
        val start = startAtHour(2)
        val dur = 6 * 60 * 60
        val grav = stillGravity(start, dur)
        val hr = hrStream(start, dur, 50)
        val sparse = SleepStager.isGravitySparse(grav, hr)
        assertFalse("the dense night must NOT read sparse", sparse)
        val asleep = 8.0 * 3600.0
        assertEquals(
            "a dense healthy night keeps SOLID — the sparse guard never touches it",
            ScoreConfidence.SOLID,
            ScoreConfidence.forRest(hasSession = true, hasStagedSleep = true,
                asleepSeconds = asleep, restorativeSeconds = asleep * 0.45, efficiency = 0.95,
                gravitySparse = sparse))
    }
}
