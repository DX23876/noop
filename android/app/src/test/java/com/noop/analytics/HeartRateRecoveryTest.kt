package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HeartRateRecoveryTest {
    private val end = 10_000L

    private fun denseEligible(endHr: Int = 170): List<HrSample> =
        (end - 300..end).map { ts -> HrSample("strap", ts, if (ts >= end - 30) endHr else 145) }

    private fun window(minutes: Int, values: List<Int>): List<HrSample> {
        val target = end + minutes * 60L
        return values.mapIndexed { i, bpm -> HrSample("strap", target - values.size / 2 + i, bpm) }
    }

    @Test
    fun calculatesOneTwoAndFiveMinuteDropsFromRobustReadings() {
        val samples = denseEligible() +
            window(1, listOf(146, 146, 220, 146, 146)) +
            window(2, listOf(132, 132, 132)) +
            window(5, listOf(112, 112, 112))

        assertEquals(
            HeartRateRecovery.Result(170, 24, 38, 58),
            HeartRateRecovery.calculate(samples.shuffled(), end - 300, end, 200.0),
        )
    }

    @Test
    fun requiresSustainedHighIntensityRatherThanOnePeak() {
        val samples = (end - 300..end).map { HrSample("strap", it, 120) } +
            HrSample("strap", end, 190) + window(1, listOf(140, 140, 140))
        assertNull(HeartRateRecovery.calculate(samples, end - 300, end, 200.0))
    }

    @Test
    fun rejectsDisconnectedHighIntensityFragments() {
        val sparse = (end - 300..end step 15).map { HrSample("strap", it, 170) }
        assertNull(HeartRateRecovery.calculate(sparse + window(1, listOf(140, 140, 140)), end - 300, end, 200.0))
    }

    @Test
    fun doesNotCreditPreWorkoutHeartRateTowardEligibility() {
        val samples = denseEligible() + window(1, listOf(140, 140, 140))
        assertNull(HeartRateRecovery.calculate(samples, end - 60, end, 200.0))
    }

    @Test
    fun returnsOnlyMeasurementsWithRealCoverage() {
        val samples = denseEligible() + window(1, listOf(150, 150, 150)) + window(5, listOf(110, 110))
        assertEquals(
            HeartRateRecovery.Result(170, 20, null, null),
            HeartRateRecovery.calculate(samples, end - 300, end, 200.0),
        )
    }

    @Test
    fun noPostWorkoutCoverageReturnsNull() {
        assertNull(HeartRateRecovery.calculate(denseEligible(), end - 300, end, 200.0))
    }

    @Test
    fun aHeartRateRiseRemainsSignedInsteadOfBeingClamped() {
        val result = HeartRateRecovery.calculate(
            denseEligible(160) + window(1, listOf(165, 165, 165)), end - 300, end, 200.0,
        )
        assertEquals(-5, result?.after1Minute)
    }
}
