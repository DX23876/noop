package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Tests/StrandAnalyticsTests/RecoveryForecastTests.swift.
 * Same fixtures, same assertions — cross-platform parity is the contract.
 */
class RecoveryForecastTest {

    private val steadyCharge = List(14) { 60.0 }
    private val steadyEffort = List(14) { 50.0 }

    // Gating

    @Test
    fun nilUntilEnoughBaseline() {
        val few = List(RecoveryForecaster.minBaselineNights - 1) { 60.0 }
        assertNull(
            RecoveryForecaster.forecast(recentCharge = few, todayEffort = 50.0, plannedSleepHours = 8.0),
        )
        val enough = List(RecoveryForecaster.minBaselineNights) { 60.0 }
        assertNotNull(
            RecoveryForecaster.forecast(recentCharge = enough, todayEffort = null, plannedSleepHours = 8.0),
        )
    }

    @Test
    fun emptyChargeIsNull() {
        assertNull(
            RecoveryForecaster.forecast(recentCharge = emptyList(), todayEffort = 50.0, plannedSleepHours = 8.0),
        )
    }

    // Neutral case anchors to the baseline

    @Test
    fun neutralDayLandsNearBaseline() {
        val f = RecoveryForecaster.forecast(
            recentCharge = steadyCharge,
            recentEffort = steadyEffort,
            todayEffort = 50.0,
            plannedSleepHours = RecoveryForecaster.defaultNeedHours,
        )!!
        assertEquals(60.0, f.baseline, 1e-9)
        assertEquals(60.0, f.charge, 1e-9)
        assertEquals(14, f.nights)
    }

    // Strain debt

    @Test
    fun harderDayLowersForecast() {
        val f = RecoveryForecaster.forecast(
            recentCharge = steadyCharge, recentEffort = steadyEffort,
            todayEffort = 80.0, plannedSleepHours = RecoveryForecaster.defaultNeedHours,
        )!!
        assertTrue(f.charge < 60.0)
    }

    @Test
    fun easierDayRaisesForecast() {
        val f = RecoveryForecaster.forecast(
            recentCharge = steadyCharge, recentEffort = steadyEffort,
            todayEffort = 20.0, plannedSleepHours = RecoveryForecaster.defaultNeedHours,
        )!!
        assertTrue(f.charge > 60.0)
    }

    @Test
    fun strainAdjIsCapped() {
        val f = RecoveryForecaster.forecast(
            recentCharge = steadyCharge, recentEffort = steadyEffort,
            todayEffort = 100.0, plannedSleepHours = RecoveryForecaster.defaultNeedHours,
        )!!
        assertTrue(f.charge >= 60.0 - RecoveryForecaster.strainAdjCap)
    }

    @Test
    fun strainTermDropsWithoutEffortHistory() {
        val f = RecoveryForecaster.forecast(
            recentCharge = steadyCharge, recentEffort = emptyList(),
            todayEffort = 100.0, plannedSleepHours = RecoveryForecaster.defaultNeedHours,
        )!!
        assertEquals(60.0, f.charge, 1e-9)
    }

    // Sleep adequacy

    @Test
    fun shortSleepLowersForecast() {
        val f = RecoveryForecaster.forecast(
            recentCharge = steadyCharge, recentEffort = steadyEffort,
            todayEffort = 50.0, plannedSleepHours = 4.0,
        )!!
        assertTrue(f.charge < 60.0)
    }

    @Test
    fun oversleepHelpIsCapped() {
        val plenty = RecoveryForecaster.forecast(
            recentCharge = steadyCharge, recentEffort = steadyEffort,
            todayEffort = 50.0, plannedSleepHours = 12.0,
        )!!
        val justOver = RecoveryForecaster.forecast(
            recentCharge = steadyCharge, recentEffort = steadyEffort,
            todayEffort = 50.0, plannedSleepHours = 10.0,
        )!!
        assertEquals(plenty.charge, justOver.charge, 1e-9)
    }

    @Test
    fun negativeSleepTreatedAsZero() {
        val f = RecoveryForecaster.forecast(
            recentCharge = steadyCharge, recentEffort = steadyEffort,
            todayEffort = 50.0, plannedSleepHours = -3.0,
        )!!
        assertEquals(0.0, f.plannedSleepHours, 1e-9)
    }

    // Output bounds

    @Test
    fun chargeAndBandStayInRange() {
        val low = List(14) { 8.0 }
        val f = RecoveryForecaster.forecast(
            recentCharge = low, recentEffort = steadyEffort,
            todayEffort = 100.0, plannedSleepHours = 0.0,
        )!!
        assertTrue(f.charge in 0.0..100.0)
        assertTrue(f.low >= 0.0)
        assertTrue(f.high <= 100.0)
    }

    // Band + confidence

    @Test
    fun thinBaselineWidensBandAndIsBuilding() {
        val thin = List(6) { 60.0 }
        val f = RecoveryForecaster.forecast(
            recentCharge = thin, recentEffort = steadyEffort,
            todayEffort = 50.0, plannedSleepHours = 8.0,
        )!!
        assertEquals(
            RecoveryForecaster.minBandPoints + RecoveryForecaster.thinBandPoints, f.band, 1e-9,
        )
        assertEquals(ScoreConfidence.BUILDING, f.confidence)
    }

    @Test
    fun fullBaselineWithInformedNeedIsSolid() {
        val f = RecoveryForecaster.forecast(
            recentCharge = steadyCharge, recentEffort = steadyEffort,
            todayEffort = 50.0, plannedSleepHours = 8.0,
            needNights = RecoveryForecaster.solidNeedNights,
        )!!
        assertEquals(ScoreConfidence.SOLID, f.confidence)
        assertEquals(RecoveryForecaster.minBandPoints, f.band, 1e-9)
    }

    @Test
    fun fullBaselineButDefaultNeedIsBuilding() {
        val f = RecoveryForecaster.forecast(
            recentCharge = steadyCharge, recentEffort = steadyEffort,
            todayEffort = 50.0, plannedSleepHours = 8.0, needNights = 0,
        )!!
        assertEquals(ScoreConfidence.BUILDING, f.confidence)
    }

    // Mean reversion

    @Test
    fun downswingIsDamped() {
        val falling = (0 until 14).map { 80.0 - 2.0 * it }  // 80 → 54, mean 67
        val f = RecoveryForecaster.forecast(
            recentCharge = falling, recentEffort = steadyEffort,
            todayEffort = 50.0, plannedSleepHours = 8.0,
        )!!
        assertTrue(f.charge > falling.last())
    }

    // Stat helpers

    @Test
    fun statHelpers() {
        assertEquals(4.0, RecoveryForecaster.mean(listOf(2.0, 4.0, 6.0)), 1e-9)
        assertEquals(0.0, RecoveryForecaster.mean(emptyList()), 1e-9)
        assertEquals(0.0, RecoveryForecaster.sampleSD(listOf(10.0)), 1e-9)
        assertEquals(2.0, RecoveryForecaster.sampleSD(listOf(2.0, 4.0, 6.0)), 1e-9)
        assertEquals(1.0, RecoveryForecaster.leastSquaresSlope(listOf(1.0, 2.0, 3.0, 4.0)), 1e-9)
        assertEquals(0.0, RecoveryForecaster.leastSquaresSlope(listOf(5.0)), 1e-9)
    }

    @Test
    fun clampPreservesInputSignedZeroAtInclusiveBounds() {
        // Cross-platform contract (#56): a value numerically equal to either bound is
        // already in range, so clamp returns x itself and preserves x's IEEE sign bit.
        val cases = listOf(
            Triple(+0.0, -0.0, 1.0),
            Triple(-0.0, +0.0, 1.0),
            Triple(+0.0, -1.0, -0.0),
            Triple(-0.0, -1.0, +0.0),
        )
        cases.forEach { (x, lo, hi) ->
            assertEquals(x.toRawBits(), RecoveryForecaster.clamp(x, lo, hi).toRawBits())
        }

        assertEquals(-1.0, RecoveryForecaster.clamp(-1.01, -1.0, 1.0), 0.0)
        assertEquals(0.25, RecoveryForecaster.clamp(0.25, -1.0, 1.0), 0.0)
        assertEquals(1.0, RecoveryForecaster.clamp(1.01, -1.0, 1.0), 0.0)
    }
}
