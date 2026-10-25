package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrored regression coverage for same-sum gravity-axis cache collisions. */
class SleepStagerCacheFingerprintTest {
    private val dev = "cache-fingerprint-test"
    private val base = 1_749_513_600L

    private fun gravity(start: Long, duration: Int, flippingAxes: Boolean): List<GravitySample> =
        (0 until duration).map { i ->
            if (flippingAxes && i % 2 == 0) {
                GravitySample(deviceId = dev, ts = start + i, x = 1.0, y = 0.0, z = 0.0)
            } else {
                GravitySample(deviceId = dev, ts = start + i, x = 0.0, y = 0.0, z = 1.0)
            }
        }

    private fun heartRate(start: Long, duration: Int): List<HrSample> =
        (0 until duration).map { HrSample(deviceId = dev, ts = start + it, bpm = 50 + (it / 60) % 3) }

    private fun rr(start: Long, duration: Int): List<RrInterval> {
        val wave = listOf(0, 40, 0, -40)
        return (0 until duration).map {
            RrInterval(deviceId = dev, ts = start + it, rrMs = 1_000 + wave[it % wave.size])
        }
    }

    private fun shiftedGravity(rows: List<GravitySample>, delta: Long): List<GravitySample> =
        rows.map { it.copy(ts = it.ts + delta) }
    private fun shiftedHeartRate(rows: List<HrSample>, delta: Long): List<HrSample> =
        rows.map { it.copy(ts = it.ts + delta) }
    private fun shape(segments: List<StageSegment>, start: Long): List<String> =
        segments.map { "${it.start - start}:${it.end - start}:${it.stage}" }

    @Test
    fun detectSleepSameSumAxesDoNotAliasMemo() {
        val start = base + 2 * 3_600L
        val duration = 90 * 60
        val still = gravity(start, duration, flippingAxes = false)
        val moving = gravity(start, duration, flippingAxes = true)
        val hr = heartRate(start, duration)

        val controlA = SleepStager.detectSleep(hr = hr, gravity = still, traceSink = { })
        val controlB = SleepStager.detectSleep(hr = hr, gravity = moving, traceSink = { })
        assertFalse("control A must be a detected still night", controlA.isEmpty())
        assertTrue("control B must be motion, not sleep", controlB.isEmpty())

        val cachedA = SleepStager.detectSleep(hr = hr, gravity = still)
        val cachedB = SleepStager.detectSleep(hr = hr, gravity = moving)
        val cachedAAgain = SleepStager.detectSleep(hr = hr, gravity = still)
        assertEquals(controlA, cachedA)
        assertEquals("same-sum axis changes must invalidate the detect memo", controlB, cachedB)
        assertEquals("A→B→A must not poison the original cache entry", controlA, cachedAAgain)
    }

    @Test
    fun v1StageSameSumAxesDoNotAliasMemo() {
        val start = base + 100_000L
        val duration = 20 * 60
        val still = gravity(start, duration, flippingAxes = false)
        val moving = gravity(start, duration, flippingAxes = true)
        val hr = heartRate(start, duration)
        val controlShift = 200_000L

        val controlA = SleepStager.stageSession(
            start + controlShift, start + controlShift + duration,
            shiftedGravity(still, controlShift), shiftedHeartRate(hr, controlShift), emptyList(), emptyList())
        val controlB = SleepStager.stageSession(
            start + 2 * controlShift, start + 2 * controlShift + duration,
            shiftedGravity(moving, 2 * controlShift), shiftedHeartRate(hr, 2 * controlShift),
            emptyList(), emptyList())
        assertNotEquals("controls must exercise observably different staging",
            shape(controlA, start + controlShift), shape(controlB, start + 2 * controlShift))

        val a = SleepStager.stageSession(start, start + duration, still, hr, emptyList(), emptyList())
        val b = SleepStager.stageSession(start, start + duration, moving, hr, emptyList(), emptyList())
        val aAgain = SleepStager.stageSession(start, start + duration, still, hr, emptyList(), emptyList())
        assertEquals(shape(controlA, start + controlShift), shape(a, start))
        assertEquals("same-sum axis changes must invalidate the V1 stage memo",
            shape(controlB, start + 2 * controlShift), shape(b, start))
        assertEquals(shape(controlA, start + controlShift), shape(aAgain, start))
    }

    @Test
    fun v2StageSameSumAxesDoNotAliasMemo() {
        val start = base + 1_000_000L
        val duration = 30 * 60
        val still = gravity(start, duration, flippingAxes = false)
        val moving = (0 until duration).map { i ->
            if (i % 30 == 15) {
                GravitySample(deviceId = dev, ts = start + i, x = 1.0, y = 1.0, z = -1.0)
            } else {
                GravitySample(deviceId = dev, ts = start + i, x = 0.0, y = 0.0, z = 1.0)
            }
        }
        val hr = heartRate(start, duration)
        val beats = rr(start, duration)
        val stillControl = still.toMutableList().apply { add(1, still[0]) }
        val movingControl = moving.toMutableList().apply {
            add(1, moving[0])
            add(2, moving[0])
        }

        val controlA = SleepStagerV2.stageSession(
            start, start + duration, stillControl, hr, beats, emptyList())
        val controlB = SleepStagerV2.stageSession(
            start, start + duration, movingControl, hr, beats, emptyList())
        assertNotEquals("controls must exercise observably different staging",
            shape(controlA, start), shape(controlB, start))

        val a = SleepStagerV2.stageSession(start, start + duration, still, hr, beats, emptyList())
        val b = SleepStagerV2.stageSession(start, start + duration, moving, hr, beats, emptyList())
        val aAgain = SleepStagerV2.stageSession(start, start + duration, still, hr, beats, emptyList())
        assertEquals(shape(controlA, start), shape(a, start))
        assertEquals("same-sum axis changes must invalidate the V2 stage memo",
            shape(controlB, start), shape(b, start))
        assertEquals(shape(controlA, start), shape(aAgain, start))
    }
}
