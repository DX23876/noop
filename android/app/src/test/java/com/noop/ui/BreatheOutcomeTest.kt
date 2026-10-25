package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins the Breathe end-of-session outcome line: the 2-minute floor, the honest "—"
 * when there is no usable baseline or no R-R data (never an invented number), and
 * the mean-vs-baseline percent + peak formatting. Mirrors the Swift
 * BreathingView.captureOutcome case-for-case.
 */
class BreatheOutcomeTest {

    @Test
    fun under2MinutesIsAbandonedNotReported() {
        assertNull(breatheOutcomeCore(baseline = 40.0, sum = 472.0, count = 10, peak = 64.0, seconds = 119))
    }

    @Test
    fun noBaselineShowsDash() {
        assertEquals("—", breatheOutcomeCore(baseline = null, sum = 472.0, count = 10, peak = 64.0, seconds = 180))
    }

    @Test
    fun zeroBaselineShowsDash() {
        // An RMSSD-0 baseline cannot anchor a percent delta.
        assertEquals("—", breatheOutcomeCore(baseline = 0.0, sum = 472.0, count = 10, peak = 64.0, seconds = 180))
    }

    @Test
    fun noSamplesShowsDash() {
        assertEquals("—", breatheOutcomeCore(baseline = 40.0, sum = 0.0, count = 0, peak = 0.0, seconds = 180))
    }

    @Test
    fun improvementFormatsMeanVsBaselineAndPeak() {
        // mean = 472 / 10 = 47.2 ms → +18% vs a 40 ms baseline.
        assertEquals(
            "+18% vs start · peak 64 ms",
            breatheOutcomeCore(baseline = 40.0, sum = 472.0, count = 10, peak = 64.0, seconds = 300),
        )
    }

    @Test
    fun declineKeepsExplicitSign() {
        // mean = 352 / 10 = 35.2 ms → -12% vs a 40 ms baseline.
        assertEquals(
            "-12% vs start · peak 41 ms",
            breatheOutcomeCore(baseline = 40.0, sum = 352.0, count = 10, peak = 41.0, seconds = 300),
        )
    }

    @Test
    fun flatSessionIsPlusZero() {
        assertEquals(
            "+0% vs start · peak 40 ms",
            breatheOutcomeCore(baseline = 40.0, sum = 400.0, count = 10, peak = 40.0, seconds = 120),
        )
    }
}
