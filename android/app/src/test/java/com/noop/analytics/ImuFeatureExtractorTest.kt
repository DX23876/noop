package com.noop.analytics

import com.noop.protocol.RawImuSample
import com.noop.protocol.Whoop5ImuFrame
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [ImuFeatureExtractor] — activity features from decoded 5/MG raw IMU (#423). Kotlin twin of the
 * Swift ImuFeatureExtractorTests. Per the repo's derived-signal rule, cadence is validated to recover
 * MULTIPLE distinct injected rates (not one lucky match); still/energy/gyro checked independently.
 */
class ImuFeatureExtractorTest {

    /** 100 Hz samples: gravity on Z + a sinusoidal wobble of amplitude [amp] g at [cadence] Hz on Z,
     *  and an optional constant gyro rotation [gyroDps] on gx. */
    private fun gaitSamples(
        cadence: Double,
        amp: Double = 0.2,
        seconds: Double = 6.0,
        gyroDps: Double = 0.0,
    ): List<RawImuSample> {
        val rate = 100.0
        val n = (seconds * rate).toInt()
        return (0 until n).map { i ->
            val az = 1.0 + amp * sin(2 * Math.PI * cadence * i.toDouble() / rate)
            RawImuSample(ax = 0.0, ay = 0.0, az = az, gx = gyroDps, gy = 0.0, gz = 0.0)
        }
    }

    @Test
    fun recoversMultipleDistinctCadences() {
        // The load-bearing test: the extractor must track a VARYING input, not manufacture one rate.
        for (target in listOf(1.4, 1.8, 2.4, 3.0)) {
            val f = ImuFeatureExtractor.extract(gaitSamples(cadence = target), sampleRateHz = 100)
            assertNotNull("cadence $target Hz should be detected", f.cadenceHz)
            assertEquals("recovered cadence should match the injected $target Hz", target, f.cadenceHz!!, 0.15)
            assertTrue("a clean sinusoid should read as strongly rhythmic", f.cadenceStrength > 0.4)
        }
    }

    @Test
    fun stillHasNoCadenceAndLowEnergy() {
        val still = (0 until 600).map { RawImuSample(ax = 0.0, ay = 0.0, az = 1.0, gx = 0.0, gy = 0.0, gz = 0.0) }
        val f = ImuFeatureExtractor.extract(still, sampleRateHz = 100)
        assertNull("a still wrist has no gait cadence", f.cadenceHz)
        assertTrue(f.accelEnergyG < 0.01)
        assertTrue(f.gyroEnergyDps < 0.01)
    }

    @Test
    fun energyAndJerkRiseWithMotion() {
        val still = ImuFeatureExtractor.extract(gaitSamples(cadence = 2.0, amp = 0.0), sampleRateHz = 100)
        val moving = ImuFeatureExtractor.extract(gaitSamples(cadence = 2.0, amp = 0.3), sampleRateHz = 100)
        assertTrue(moving.accelEnergyG > still.accelEnergyG + 0.05)
        assertTrue(moving.jerkRms > still.jerkRms)
    }

    @Test
    fun gyroEnergyReflectsRotation() {
        val f = ImuFeatureExtractor.extract(gaitSamples(cadence = 2.0, gyroDps = 45.0), sampleRateHz = 100)
        assertEquals("constant 45 dps rotation should read back", 45.0, f.gyroEnergyDps, 1.0)
    }

    @Test
    fun extractFromDecodedFrames() {
        // End-to-end from the decoder shape: two frames concatenate into one feature window.
        val frame = Whoop5ImuFrame(baseTs = 0, sampleRateHz = 100, samples = gaitSamples(cadence = 2.2))
        val f = ImuFeatureExtractor.extract(listOf(frame, frame))
        assertEquals(frame.samples.size * 2, f.sampleCount)
        assertNotNull(f.cadenceHz)
        assertEquals(2.2, f.cadenceHz!!, 0.15)
    }
}
