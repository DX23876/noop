package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the raised step-calibration ceiling and the variable-increment stepper (#132). A WHOOP 5/MG
 * motion counter can overcount by ~24×, so the divisor must reach into the mid-20s while keeping the
 * 0.5 floor — and a flat 0.1 step from 0.5→30 (≈295 taps) would make that unreachable, so the
 * stepper widens its increment as the value climbs. Mirrors macOS `ProfileStore.steppedStepScale`.
 */
class StepCalibrationTest {

    private val EPS = 1e-9

    // --- the clamp the SharedPreferences getter/setter applies (STEP_SCALE_MIN..STEP_SCALE_MAX) ---

    private fun clamp(v: Double) = v.coerceIn(0.5, 30.0)

    @Test
    fun clampAllowsTheRealisticOvercount() {
        // The whole point of #132: ~24× must now be selectable (the old 4.0 ceiling clipped it).
        assertEquals(24.0, clamp(24.0), EPS)
    }

    @Test
    fun clampStillRejectsOutOfRange() {
        assertEquals("above ceiling clamps to 30", 30.0, clamp(31.0), EPS)
        assertEquals("below floor clamps to 0.5", 0.5, clamp(0.4), EPS)
        assertEquals("ceiling is exactly 30", 30.0, clamp(30.0), EPS)
        assertEquals("floor is exactly 0.5", 0.5, clamp(0.5), EPS)
    }

    // --- variable increment bands ---

    @Test
    fun incrementIsFineNearDefaultAndCoarseUpTop() {
        assertEquals(0.1, ProfileStore.stepScaleIncrement(1.0), EPS)
        assertEquals(0.1, ProfileStore.stepScaleIncrement(1.9), EPS)
        assertEquals(0.5, ProfileStore.stepScaleIncrement(2.0), EPS)
        assertEquals(0.5, ProfileStore.stepScaleIncrement(4.5), EPS)
        assertEquals(1.0, ProfileStore.stepScaleIncrement(5.0), EPS)
        assertEquals(1.0, ProfileStore.stepScaleIncrement(24.0), EPS)
    }

    // --- stepping behaviour ---

    @Test
    fun steppingUpClampsAtCeilingAndDownAtFloor() {
        assertEquals(30.0, ProfileStore.steppedStepScale(30.0, up = true), EPS)
        assertEquals(0.5, ProfileStore.steppedStepScale(0.5, up = false), EPS)
    }

    @Test
    fun fineGrainAroundTheOnePointZeroDefault() {
        assertEquals(1.1, ProfileStore.steppedStepScale(1.0, up = true), EPS)
        assertEquals(0.9, ProfileStore.steppedStepScale(1.0, up = false), EPS)
    }

    @Test
    fun coarseGrainInTheTwentyFourRegion() {
        assertEquals(25.0, ProfileStore.steppedStepScale(24.0, up = true), EPS)
        assertEquals(23.0, ProfileStore.steppedStepScale(24.0, up = false), EPS)
    }

    @Test
    fun aReasonableNumberOfTapsReaches24() {
        // The regression we're guarding against: with a flat 0.1 step this loop would take ~230
        // taps. The variable increment must get there in a usable handful of dozens.
        var v = 1.0
        var taps = 0
        while (v < 24.0 && taps < 1000) {
            v = ProfileStore.steppedStepScale(v, up = true)
            taps++
        }
        assertTrue("should reach 24 from 1.0", v >= 24.0)
        assertTrue("should take well under 60 taps (was $taps)", taps < 60)
    }

    @Test
    fun steppingNeverEscapesTheRange() {
        // Walk the whole ladder up from the floor and back down; every intermediate value stays in range.
        var v = 0.5
        repeat(100) {
            v = ProfileStore.steppedStepScale(v, up = true)
            assertTrue("$v within range", v in 0.5..30.0)
        }
        repeat(100) {
            v = ProfileStore.steppedStepScale(v, up = false)
            assertTrue("$v within range", v in 0.5..30.0)
        }
    }
}
