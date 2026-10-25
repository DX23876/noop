package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.StepSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [WakeMotionRefinement] (#364 "Proposal 2" follow-up; density-gate precedent #345) against
 * SYNTHETIC fixtures only — no real user data. Every fixture is built from [buildNight], which lays down
 * a dense, still, non-ambulatory baseline (4 gravity samples/min at one fixed orientation, 1 step record/
 * min with a flat counter and `activityClass = 0`) and overrides specific minutes to inject either a
 * posture "burst" (a turn-over) or real walking cadence. Android twin of the Swift
 * `WakeMotionRefinementTests`.
 */
class WakeMotionRefinementTest {

    private val dev = "d"

    /** Minute-aligned so every assertion below can reason in whole minutes. */
    private val start = 1_700_000_000L / 60 * 60

    // ── Fixture builder ──────────────────────────────────────────────────────────────────────────────

    /**
     * One night's gravity + step streams over minutes `[0, totalMinutes)` relative to [start].
     * - [burstMinutes]: these minutes get a gravity vector that swings between two orientations within
     *   the minute (posture variance well above [WakeMotionRefinement.STABLE_POSTURE_VARIANCE_G2]); every
     *   other minute is a fixed, motionless orientation (variance 0).
     * - [walkMinutes]: these minutes accrue [ticksPerWalkMinute] walk-class (`activityClass = 1`)
     *   step-counter ticks; every other minute accrues 0 ticks at `activityClass = 0` (still).
     * - [sparse]: when true, mimics a WHOOP 4.0 night instead — gravity only every 5th minute, no step
     *   samples at all — so the density self-gate declines regardless of the burst/walk pattern.
     */
    private fun buildNight(
        totalMinutes: Int,
        burstMinutes: Set<Int> = emptySet(),
        walkMinutes: Set<Int> = emptySet(),
        ticksPerWalkMinute: Int = 25,
        sparse: Boolean = false,
    ): Pair<List<GravitySample>, List<StepSample>> {
        val grav = mutableListOf<GravitySample>()
        val steps = mutableListOf<StepSample>()
        var counter = 0
        for (m in 0 until totalMinutes) {
            val minuteStart = start + m * 60L
            if (sparse) {
                if (m % 5 == 0) grav.add(GravitySample(deviceId = dev, ts = minuteStart, x = 0.0, y = 0.0, z = 1.0))
                continue // no step samples at all on the sparse fixture
            }
            if (m in burstMinutes) {
                for (k in 0 until 4) {
                    val swing = k % 2 == 0
                    grav.add(
                        GravitySample(
                            deviceId = dev, ts = minuteStart + k * 15L,
                            x = if (swing) 0.0 else 1.0, y = 0.0, z = if (swing) 1.0 else 0.0,
                        ),
                    )
                }
            } else {
                for (k in 0 until 4) {
                    grav.add(GravitySample(deviceId = dev, ts = minuteStart + k * 15L, x = 0.0, y = 0.0, z = 1.0))
                }
            }
            val walking = m in walkMinutes
            counter += if (walking) ticksPerWalkMinute else 0
            steps.add(
                StepSample(
                    deviceId = dev, ts = minuteStart, counter = counter and 0xFFFF,
                    activityClass = if (walking) 1 else 0,
                ),
            )
        }
        return grav to steps
    }

    private fun wakeSegment(minutes: Int) = StageSegment(start = start, end = start + minutes * 60L, stage = "wake")

    // ── (a) hot-but-still night, one turn-over burst every 90 min -> the still spans are reclaimed ────

    @Test
    fun hotButStillNightReclaimsTheStillSpansAroundIsolatedBursts() {
        val seg = wakeSegment(180)
        val (grav, steps) = buildNight(totalMinutes = 180, burstMinutes = setOf(45, 135))

        val result = WakeMotionRefinement.refine(listOf(seg), grav, steps)

        val expected = listOf(
            StageSegment(start, start + 44 * 60L, "light"),
            StageSegment(start + 44 * 60L, start + 47 * 60L, "wake"),
            StageSegment(start + 47 * 60L, start + 134 * 60L, "light"),
            StageSegment(start + 134 * 60L, start + 137 * 60L, "wake"),
            StageSegment(start + 137 * 60L, start + 180 * 60L, "light"),
        )
        assertEquals(
            "only the two burst minutes (+/-1 min pad) should survive as wake; the motionless stretches " +
                "between them (the hot-but-atonic REM misread) should reclaim to light",
            expected, result,
        )

        val totalDuration = result.sumOf { it.end - it.start }
        assertEquals("the refinement must never change total session duration", 180 * 60L, totalDuration)
        val wakeDuration = result.filter { it.stage == "wake" }.sumOf { it.end - it.start }
        assertEquals("wake should shrink from 180 min to the 2 burst blocks (3 min each)", 6 * 60L, wakeDuration)
    }

    // ── (b) a real get-up (3 consecutive minutes of 25 ticks/min) stays wake ───────────────────────────

    @Test
    fun realGetUpStaysWake() {
        val seg = wakeSegment(30)
        val (grav, steps) = buildNight(totalMinutes = 30, walkMinutes = setOf(10, 11, 12), ticksPerWalkMinute = 25)

        val result = WakeMotionRefinement.refine(listOf(seg), grav, steps)

        assertEquals(
            "3 consecutive minutes at 25 ticks/min clears the sustained-walk locomotion gate (>=2 " +
                "consecutive minutes >=10 ticks), so the whole segment must be left untouched",
            listOf(seg), result,
        )
    }

    // ── (c) sparse-motion night -> the density self-gate declines to act ──────────────────────────────

    @Test
    fun sparseMotionNightDeclinesToAct() {
        val seg = wakeSegment(180)
        // Same burst pattern as the dense test above (which DOES reclassify) so the only variable here
        // is density -- proving the decline is the gate, not the burst pattern being ineligible.
        val (grav, steps) = buildNight(totalMinutes = 180, burstMinutes = setOf(45, 135), sparse = true)

        val result = WakeMotionRefinement.refine(listOf(seg), grav, steps)

        assertEquals(
            "a WHOOP-4.0-shaped stream (sparse gravity, no step samples) must fail the density self-gate " +
                "and leave the incumbent wake call untouched, per #345",
            listOf(seg), result,
        )
    }

    // ── (d) toggle off -> byte-identical output ────────────────────────────────────────────────────────

    @Test
    fun toggleOffIsByteIdenticalPassthrough() {
        val seg = wakeSegment(180)
        val (grav, steps) = buildNight(totalMinutes = 180, burstMinutes = setOf(45, 135))

        val off = WakeMotionRefinement.apply(listOf(seg), grav, steps, enabled = false)
        assertEquals("enabled=false must be a guaranteed byte-identical passthrough", listOf(seg), off)

        // Sanity: the SAME fixture actually changes when enabled, so the assertion above isn't vacuous.
        val on = WakeMotionRefinement.apply(listOf(seg), grav, steps, enabled = true)
        assertNotEquals("fixture sanity check: this fixture must be live when enabled", listOf(seg), on)
    }

    // ── (e) tracks VARYING inputs -- multiple patterns, each with a different injected reclaim amount,
    // each recovered (repo hard rule for a derived physiological signal: prove the method tracks varying
    // input, not a single lucky match). ────────────────────────────────────────────────────────────────

    @Test
    fun recoversDifferentInjectedReclaimAmountsAcrossPatterns() {
        data class Scenario(val name: String, val totalMinutes: Int, val burstMinutes: Set<Int>)
        val scenarios = listOf(
            Scenario("single burst", 40, setOf(20)),
            Scenario("two well-separated bursts", 120, setOf(20, 80)),
            Scenario("three well-separated bursts", 90, setOf(10, 40, 70)),
            Scenario("two adjacent bursts (padding overlaps)", 60, setOf(5, 6)),
            Scenario("burst at the segment's own edge (padding clamps)", 50, setOf(0, 49)),
        )

        val reclaimedAmounts = mutableSetOf<Int>()
        for (s in scenarios) {
            val seg = wakeSegment(s.totalMinutes)
            val (grav, steps) = buildNight(totalMinutes = s.totalMinutes, burstMinutes = s.burstMinutes)
            val result = WakeMotionRefinement.refine(listOf(seg), grav, steps)

            // Expected kept-as-wake minutes = union of each burst minute +/-1, clamped to the segment.
            val expectedKept = mutableSetOf<Int>()
            for (m in s.burstMinutes) {
                val lo = maxOf(0, m - 1)
                val hi = minOf(s.totalMinutes - 1, m + 1)
                if (lo <= hi) expectedKept.addAll(lo..hi)
            }
            val expectedReclaimedMin = s.totalMinutes - expectedKept.size

            val totalDuration = result.sumOf { it.end - it.start }
            assertEquals("[${s.name}] duration must be conserved", s.totalMinutes * 60L, totalDuration)

            val actualWakeMin = (result.filter { it.stage == "wake" }.sumOf { it.end - it.start } / 60L).toInt()
            val actualReclaimedMin = s.totalMinutes - actualWakeMin
            assertEquals(
                "[${s.name}] expected $expectedReclaimedMin min reclaimed to light, got $actualReclaimedMin",
                expectedReclaimedMin, actualReclaimedMin,
            )
            reclaimedAmounts.add(actualReclaimedMin)
        }

        // Belt-and-suspenders on the point of the test: the scenarios really do inject different amounts.
        assertTrue(
            "fixture sanity: scenarios must inject genuinely different reclaim amounts",
            reclaimedAmounts.size > 1,
        )
    }

    // ── Session-level convenience (efficiency recompute) ───────────────────────────────────────────────

    @Test
    fun sessionLevelRefineRecomputesEfficiency() {
        val session = DetectedSleep(
            start = start, end = start + 180 * 60L, efficiency = 0.0,
            stages = listOf(wakeSegment(180)), restingHR = 52, avgHRV = 40.0,
        )
        val (grav, steps) = buildNight(totalMinutes = 180, burstMinutes = setOf(45, 135))

        val refined = WakeMotionRefinement.refine(session, grav, steps)

        assertTrue(
            "reclassifying 174 of 180 wake minutes to light must raise efficiency",
            refined.efficiency > session.efficiency,
        )
        assertEquals(
            SleepStager.efficiency(session.start, session.end, refined.stages),
            refined.efficiency,
            1e-9,
        )
        assertEquals(session.restingHR, refined.restingHR)
        assertEquals(session.avgHRV, refined.avgHRV)
    }
}
