package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Kotlin twin of Swift's OuraSleepWindowPairingTests. Regression for the 2026-07-17 capture: an overnight
 * hypnogram burst and a ~3PM nap burst finalized in the SAME history drain. The old single-slot window
 * let the nap's 0x49 overwrite the overnight's before the overnight burst persisted, so the overnight fell
 * back to its SleepNet WRITE time (10:58, ~4 h after the true 07:00 sleep end). The fix keeps a COLLECTION
 * and pairs each burst with the CLOSEST window by ring-time — these tests pin that picker.
 */
class OuraSleepWindowPairingTest {

    // (ringTimestamp deciseconds, startOffMin, endOffMin). 6000 ticks = 10 min pairing tolerance.
    private val overnight = Triple(8_400_000L, 778, 238)
    private val nap = Triple(8_512_000L, 44, 34)

    @Test fun overnightBurstPicksOvernightWindowDespiteLaterNap() {
        val windows = listOf(overnight, nap)   // nap appended LAST (the old code grabbed it)
        val picked = OuraLiveSource.closestSleepWindow049(windows, overnight.first + 50L, 6_000L)
        assertEquals(overnight.first, picked?.first)
        assertEquals(238, picked?.third)
    }

    @Test fun napBurstPicksNapWindow() {
        val windows = listOf(overnight, nap)
        val picked = OuraLiveSource.closestSleepWindow049(windows, nap.first + 30L, 6_000L)
        assertEquals(nap.first, picked?.first)
        assertEquals(34, picked?.third)
    }

    @Test fun noWindowInRangeReturnsNull() {
        // Only the nap stashed; an overnight burst is ~3 h away → nil (caller keeps write-time fallback).
        assertNull(OuraLiveSource.closestSleepWindow049(listOf(nap), overnight.first + 50L, 6_000L))
    }

    @Test fun closestOfTwoInRangeWins() {
        val near = Triple(10_000L, 600, 10)
        val far = Triple(13_000L, 600, 20)
        val picked = OuraLiveSource.closestSleepWindow049(listOf(far, near), 10_500L, 6_000L)
        assertEquals(10, picked?.third)   // near (gap 500) beats far (gap 2500)
    }

    @Test fun toleranceBoundaryInclusive() {
        val w = Triple(100_000L, 600, 10)
        assertEquals(w, OuraLiveSource.closestSleepWindow049(listOf(w), 100_000L - 6_000L, 6_000L))
        assertNull(OuraLiveSource.closestSleepWindow049(listOf(w), 100_000L - 6_001L, 6_000L))
    }

    @Test fun emptyReturnsNull() {
        assertNull(OuraLiveSource.closestSleepWindow049(emptyList(), 8_400_000L, 6_000L))
    }
}
