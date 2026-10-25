package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the pure caffeine half-life decay math + the honesty rules of the active estimate (#526) — the JVM
 * twin of StrandTests/CaffeineDecayTests.swift. The point of these is to hold the HONEST-DATA line: an
 * unknown dose stays unknown (never invented), a future-dated log can't amplify a dose, and the estimate
 * is a deterministic function of what was logged. Pure → no android.* needed.
 */
class CaffeineDecayTest {

    private val hl = CaffeineDecay.DEFAULT_HALF_LIFE_HOURS   // 5.5 h

    // MARK: - fractionRemaining

    @Test fun fractionAtZeroIsFull() {
        assertEquals(1.0, CaffeineDecay.fractionRemaining(0.0, hl), 1e-9)
    }

    @Test fun fractionAtOneHalfLifeIsHalf() {
        assertEquals(0.5, CaffeineDecay.fractionRemaining(hl, hl), 1e-9)
    }

    @Test fun fractionAtTwoHalfLivesIsQuarter() {
        assertEquals(0.25, CaffeineDecay.fractionRemaining(2 * hl, hl), 1e-9)
    }

    @Test fun negativeElapsedClampsToFull() {
        assertEquals(1.0, CaffeineDecay.fractionRemaining(-3.0, hl), 1e-9)
    }

    @Test fun zeroHalfLifeYieldsZero() {
        assertEquals(0.0, CaffeineDecay.fractionRemaining(1.0, 0.0), 1e-9)
    }

    // MARK: - remainingMg / totals

    @Test fun remainingMgHalvesEachHalfLife() {
        assertEquals(100.0, CaffeineDecay.remainingMg(200.0, hl, hl), 1e-6)
        assertEquals(50.0, CaffeineDecay.remainingMg(200.0, 2 * hl, hl), 1e-6)
    }

    @Test fun totalRemainingMgSumsDoses() {
        val total = CaffeineDecay.totalRemainingMg(listOf(100.0 to 0.0, 80.0 to hl), hl)
        assertEquals(100.0 + 40.0, total, 1e-6)
    }

    @Test fun hoursUntilQuarterIsTwoHalfLives() {
        assertEquals(2 * hl, CaffeineDecay.hoursUntilFraction(0.25, hl), 1e-6)
    }

    @Test fun isStillActiveThreshold() {
        assertTrue(CaffeineDecay.isStillActive(hl, halfLifeHours = hl))
        assertFalse(CaffeineDecay.isStillActive(3 * hl, halfLifeHours = hl))
    }

    // MARK: - CaffeineActiveEstimate (the honest summary)

    @Test fun estimateSumsOnlyKnownDoses() {
        val now = 1_000_000L
        val intakes = listOf(
            CaffeineIntake("a", now, mg = 120.0),                              // full
            CaffeineIntake("b", now - (hl * 3600).toLong(), mg = null),        // active, dose UNKNOWN
        )
        val est = CaffeineActiveEstimate.compute(intakes, now, hl)
        assertEquals(2, est.activeIntakeCount)
        assertEquals(120.0, est.totalRemainingMg!!, 1e-6)   // unknown dose never invented as a number
    }

    @Test fun estimateNoKnownDoseYieldsNullMg() {
        val now = 1_000_000L
        val est = CaffeineActiveEstimate.compute(listOf(CaffeineIntake("a", now, mg = null)), now, hl)
        assertTrue(est.hasActive)
        assertNull(est.totalRemainingMg)
    }

    @Test fun estimateExcludesClearedAndFutureIntakes() {
        val now = 1_000_000L
        val intakes = listOf(
            CaffeineIntake("old", now - (10 * hl * 3600).toLong(), mg = 200.0),  // long cleared
            CaffeineIntake("future", now + 2 * 3600, mg = 200.0),                // future-dated
            CaffeineIntake("active", now, mg = 200.0),                           // active
        )
        val est = CaffeineActiveEstimate.compute(intakes, now, hl)
        assertEquals(1, est.activeIntakeCount)
        assertEquals(200.0, est.totalRemainingMg!!, 1e-6)
    }

    @Test fun estimateEmptyIntakesIsInactive() {
        val est = CaffeineActiveEstimate.compute(emptyList(), 1_000_000L, hl)
        assertFalse(est.hasActive)
        assertEquals(0, est.activeIntakeCount)
        assertNull(est.totalRemainingMg)
    }

    @Test fun mostRecentActiveHoursPicksClosest() {
        val now = 1_000_000L
        val intakes = listOf(
            CaffeineIntake("a", now - 2 * 3600, mg = 100.0),
            CaffeineIntake("b", now - 1 * 3600, mg = 100.0),   // most recent
        )
        val est = CaffeineActiveEstimate.compute(intakes, now, hl)
        assertEquals(1.0, est.hoursSinceMostRecentActive!!, 1e-6)
    }
}
