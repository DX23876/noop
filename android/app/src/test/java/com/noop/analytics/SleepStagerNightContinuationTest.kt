package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests SleepStager's night-continuation exemption to the daytime false-sleep guard (#90).
 * A real overnight sleep that runs PAST the daytime-band start (~11:00) — a late wake, or a
 * brief morning stir then back to sleep that leaves the tail as its own daytime-centered run —
 * must keep its LATE wake time. The tail directly continues a chain that began overnight
 * (gap ≤ nightContinuationGapMin = 90 min), so it skips the nap guard; isolated daytime
 * stillness still faces the full guard.
 *
 * Faithful Kotlin mirror of testOvernightSleepTailPastNoonKeepsLateWake in SleepStagerTests.swift.
 * Reimplemented from @vulnix0x4's PR #353.
 */
class SleepStagerNightContinuationTest {

    private val dev = "test"

    /** 2025-06-10 00:00:00 UTC — an arbitrary fixed midnight (ref % 86400 == 0). */
    private val refMidnight = 1_749_513_600L

    /** Unix start at `hourUTC:00:00` on the reference day. With the detector's default
     *  tzOffset=0, local hour == UTC hour. */
    private fun startAtHour(hourUTC: Int): Long = refMidnight + hourUTC * 3_600L

    /** Still gravity (constant orientation) at 1 Hz. */
    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }

    /** Active gravity (0.5 g oscillation per sample → clearly moving) at 1 Hz. */
    private fun activeGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { i ->
            val phase = (i % 2) * 0.5
            GravitySample(deviceId = dev, ts = start + i, x = phase, y = 0.0, z = 1.0)
        }

    private fun hrStream(start: Long, durationS: Int, bpm: Int): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = start + it, bpm = bpm) }

    @Test
    fun overnightSleepTailPastNoonKeepsLateWake() {
        // REGRESSION (late wake): a real overnight sleep whose TAIL runs past the daytime-band
        // start — here a brief 40-min morning stir then back to sleep until ~12:40 — must keep
        // the LATE wake time. The tail is daytime-centered and, on its own, FAILS the daytime
        // guard's resting-HR bar (its HR sits at baseline, not below it), so before the
        // continuation exemption it was rejected and the wake was truncated to ~10:00.
        val nStart = startAtHour(2)            // 02:00 overnight onset
        val nDur = 8 * 60 * 60                 // → 10:00
        val wStart = nStart + nDur             // 10:00 brief morning wake
        val wDur = 40 * 60                     // 40 min: > mergeMin (15), ≤ continuation (90)
        val tStart = wStart + wDur             // 10:40 back to sleep
        val tDur = 2 * 60 * 60                 // → 12:40; center ~11:40 in the daytime band

        // Tail HR == night HR == baseline (50): passes the basic HR confirmation (≤ baseline×1.05)
        // but FAILS the stricter daytime resting bar (> baseline×0.95), so only the overnight
        // continuation exemption can keep it.
        val grav = stillGravity(nStart, nDur) +
            activeGravity(wStart, wDur) +
            stillGravity(tStart, tDur)
        val hr = hrStream(nStart, nDur, 50) +
            hrStream(wStart, wDur, 70) +
            hrStream(tStart, tDur, 50)

        val sessions = SleepStager.detectSleep(hr = hr, gravity = grav)
        val latestWake = sessions.maxOfOrNull { it.end } ?: 0L
        assertTrue(
            "overnight sleep's post-11:00 tail must be kept — wake not truncated to late morning",
            latestWake >= tStart + tDur - 10 * 60,
        )
    }
}
