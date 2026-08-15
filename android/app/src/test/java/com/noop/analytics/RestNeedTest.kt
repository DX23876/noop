package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Tests/StrandAnalyticsTests/RestNeedTests.swift (Wave 0 · T1, PR #456).
 *
 * `RestScorer.personalizedNeedHours` — population-anchored, age-floored sleep need. The load-bearing
 * property is the anti-self-referential guard: a chronic under-sleeper's need must NOT drift down
 * toward their own deficit (which a plain trailing mean would do, inverting the honesty philosophy
 * for exactly the users with the most sleep debt); it stays anchored at the age-appropriate
 * population floor. Same inputs and expected values as the Swift test.
 */
class RestNeedTest {

    @Test
    fun chronicUnderSleeperStaysAtFloor() {
        // 14 nights of ~5.5 h. A self-referential mean returns ~5.5; the anchor must hold >= 7.0.
        val nights = List(14) { 5.5 }
        assertTrue(RestScorer.personalizedNeedHours(nights, age = 30) >= 7.0)
    }

    @Test
    fun normalSleeperReflectsUnrestrictedNights() {
        val nights = listOf(7.2, 7.8, 8.1, 7.5, 8.4, 7.9, 8.0, 7.6, 8.2, 7.7)
        val need = RestScorer.personalizedNeedHours(nights, age = 35)
        assertTrue(need >= 7.0)
        assertTrue(need <= 9.5)
        // Upper-quartile, not the mean: reflects what they sleep on their longer nights.
        assertTrue(need >= 7.8)
    }

    @Test
    fun coldStartReturnsPopulationDefault() {
        // Fewer than minNeedNights → the population default (8.0), floored.
        assertEquals(
            RestScorer.defaultSleepNeedHours,
            RestScorer.personalizedNeedHours(listOf(7.0, 8.0, 6.5), age = 30),
            0.001,
        )
    }

    @Test
    fun capsLongSleeper() {
        val nights = List(10) { 11.0 }
        assertTrue(RestScorer.personalizedNeedHours(nights, age = 40) <= 9.5)
    }

    @Test
    fun minorHasHigherFloor() {
        val nights = List(10) { 6.0 }   // an under-sleeping teen
        assertTrue(RestScorer.personalizedNeedHours(nights, age = 15) >= 8.0)
    }

    @Test
    fun nilAgeUsesAdultFloor() {
        val nights = List(10) { 5.0 }
        assertTrue(RestScorer.personalizedNeedHours(nights, age = null) >= 7.0)
    }

    @Test
    fun zeroAndNegativeNightsIgnored() {
        // no-data days (0) must not drag the estimate down or count toward the minimum.
        val nights = listOf(0.0, -1.0, 7.5, 8.0, 7.8, 8.2, 7.6, 8.1, 7.9, 8.3, 0.0)
        assertTrue(RestScorer.personalizedNeedHours(nights, age = 30) >= 7.5)
    }
}
