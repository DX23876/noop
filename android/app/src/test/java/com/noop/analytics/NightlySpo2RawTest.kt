package com.noop.analytics

import com.noop.data.Spo2Sample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pure unit test for [AnalyticsEngine.nightlySpo2RawMeans] (WHOOP 4.0 raw SpO2 red/IR ADC means over
 * detected sleep, #93). Twin of the Swift `wornNightlySpo2Raw`. No wear gate: the strap streams SpO2
 * only on-wrist, so a sample counts purely by whether its timestamp lands inside a detected in-bed span.
 */
class NightlySpo2RawTest {

    private fun sleep(start: Long, end: Long) =
        DetectedSleep(start = start, end = end, efficiency = 0.9, stages = emptyList(),
            restingHR = 55, avgHRV = 60.0)

    private fun spo2(ts: Long, red: Int, ir: Int) =
        Spo2Sample(deviceId = "my-whoop", ts = ts, red = red, ir = ir)

    @Test
    fun emptyInputs_returnNull() {
        assertNull(AnalyticsEngine.nightlySpo2RawMeans(emptyList(), listOf(spo2(100, 1, 1))))
        assertNull(AnalyticsEngine.nightlySpo2RawMeans(listOf(sleep(0, 1000)), emptyList()))
    }

    @Test
    fun inWindowSamples_averageRedAndIrSeparately() {
        val sessions = listOf(sleep(1000, 2000))
        val samples = listOf(
            spo2(1100, red = 30000, ir = 20000),
            spo2(1500, red = 32000, ir = 24000),
        )
        val (red, ir) = AnalyticsEngine.nightlySpo2RawMeans(sessions, samples)!!
        assertEquals(31000, red)   // (30000 + 32000) / 2
        assertEquals(22000, ir)    // (20000 + 24000) / 2
    }

    @Test
    fun samplesOutsideEveryWindow_returnNull() {
        val sessions = listOf(sleep(1000, 2000))
        val samples = listOf(spo2(500, 1, 1), spo2(2500, 2, 2))  // both outside [1000, 2000]
        assertNull(AnalyticsEngine.nightlySpo2RawMeans(sessions, samples))
    }

    @Test
    fun onlyInWindowSamplesCount_boundariesInclusive() {
        val sessions = listOf(sleep(1000, 2000))
        val samples = listOf(
            spo2(999, red = 9, ir = 9),        // just before → dropped
            spo2(1000, red = 100, ir = 200),   // inclusive start → kept
            spo2(2000, red = 300, ir = 400),   // inclusive end → kept
            spo2(2001, red = 9, ir = 9),       // just after → dropped
        )
        val (red, ir) = AnalyticsEngine.nightlySpo2RawMeans(sessions, samples)!!
        assertEquals(200, red)   // (100 + 300) / 2
        assertEquals(300, ir)    // (200 + 400) / 2
    }

    @Test
    fun multipleSessions_unionOfWindows() {
        val sessions = listOf(sleep(1000, 1500), sleep(3000, 3500))
        val samples = listOf(
            spo2(1200, red = 10, ir = 20),   // in first
            spo2(2000, red = 99, ir = 99),   // gap → dropped
            spo2(3200, red = 30, ir = 40),   // in second
        )
        val (red, ir) = AnalyticsEngine.nightlySpo2RawMeans(sessions, samples)!!
        assertEquals(20, red)   // (10 + 30) / 2
        assertEquals(30, ir)    // (20 + 40) / 2
    }
}
