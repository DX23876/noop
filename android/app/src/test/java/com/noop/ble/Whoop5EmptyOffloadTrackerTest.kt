package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirror of the Swift Whoop5EmptyOffloadTrackerTests — pins the #580 fix. A connected WHOOP 5/MG whose
 * firmware acks SEND_HISTORICAL_DATA but emits ZERO type-0x2F offload frames streams live HR fine but every
 * offload times out; the old code surfaced the WHOOP-4 "strap went quiet" sync error and let the 120s
 * watchdog bounce the (healthy) link every ~2 min. The tracker counts CONSECUTIVE empty offloads so a
 * sustained empty streak reads as "history sync experimental" (not a sync error) + backs off the bounce;
 * any banking offload clears the streak.
 */
class Whoop5EmptyOffloadTrackerTest {

    @Test fun singleEmptyOffloadStaysQuiet() {
        val t = Whoop5EmptyOffloadTracker()        // default threshold 2
        assertFalse(t.recordOffload(bankedRecords = false))
        assertFalse(t.historyEmpty)
        assertEquals(1, t.consecutiveEmpty)
    }

    @Test fun twoConsecutiveEmptyOffloadsGoExperimental() {
        val t = Whoop5EmptyOffloadTracker()
        assertFalse(t.recordOffload(bankedRecords = false))
        assertTrue(t.recordOffload(bankedRecords = false))   // crossing call reports true once
        assertTrue(t.historyEmpty)
        assertEquals(2, t.consecutiveEmpty)
    }

    @Test fun staysExperimentalWithoutRecrossing() {
        val t = Whoop5EmptyOffloadTracker()
        t.recordOffload(bankedRecords = false)
        assertTrue(t.recordOffload(bankedRecords = false))
        assertFalse(t.recordOffload(bankedRecords = false))  // already experimental — don't re-cross
        assertTrue(t.historyEmpty)
        assertEquals(3, t.consecutiveEmpty)
    }

    @Test fun bankingOffloadClearsExperimental() {
        val t = Whoop5EmptyOffloadTracker()
        t.recordOffload(bankedRecords = false)
        assertTrue(t.recordOffload(bankedRecords = false))
        assertTrue(t.historyEmpty)
        assertFalse(t.recordOffload(bankedRecords = true))   // banking offload is never a crossing
        assertFalse(t.historyEmpty)
        assertEquals(0, t.consecutiveEmpty)
    }

    @Test fun recoveryThenRequiresFullStreakAgain() {
        val t = Whoop5EmptyOffloadTracker()
        t.recordOffload(bankedRecords = false)
        t.recordOffload(bankedRecords = false)               // experimental
        t.recordOffload(bankedRecords = true)                // recovered
        assertFalse(t.recordOffload(bankedRecords = false))
        assertFalse(t.historyEmpty)                          // one empty after recovery isn't enough
        assertTrue(t.recordOffload(bankedRecords = false))
        assertTrue(t.historyEmpty)
    }

    @Test fun resetClearsState() {
        val t = Whoop5EmptyOffloadTracker()
        t.recordOffload(bankedRecords = false)
        t.recordOffload(bankedRecords = false)
        assertTrue(t.historyEmpty)
        t.reset()
        assertFalse(t.historyEmpty)
        assertEquals(0, t.consecutiveEmpty)
    }

    @Test fun customThreshold() {
        val t = Whoop5EmptyOffloadTracker(quietThreshold = 3)
        assertFalse(t.recordOffload(bankedRecords = false))
        assertFalse(t.recordOffload(bankedRecords = false))
        assertTrue(t.recordOffload(bankedRecords = false))
    }
}
