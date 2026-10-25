package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirror of the Swift PostBondTimeoutLoopDetectorTests — pins the #617 bond-loop detection. A WHOOP 4
 * strap bonds successfully, then the encrypted link drops ~1s later with a connection timeout
 * (GATT_CONN_TIMEOUT, the twin of iOS CBError.connectionTimeout), the auto-rescan reconnects, it bonds
 * again, and dies again — an endless bond->timeout loop. PostBondTimeoutLoopDetector watches for
 * CONSECUTIVE bond-then-quick-timeout cycles and, after the threshold, tells WhoopBleClient to surface the
 * existing re-pair guide instead of looping silently. Pure value type → no BLE seam needed.
 *
 * The Swift detector takes seconds; this Kotlin twin takes milliseconds, so each `secondsSinceBond: N`
 * maps to `msSinceBond = N * 1_000` and the 8s window maps to 8_000ms.
 */
class PostBondTimeoutLoopDetectorTest {

    // Two consecutive bond-then-quick-timeout cycles trip the loop; the trip is reported exactly once.
    @Test fun tripsAfterTwoConsecutiveBondTimeouts() {
        val d = PostBondTimeoutLoopDetector()   // default tripThreshold=2, window=8s
        assertFalse(
            "one bond-then-timeout is noise, not yet a trip",
            d.connectionEnded(wasBonded = true, msSinceBond = 1_000L, timedOut = true),
        )
        assertFalse(d.tripped)
        assertTrue(
            "second consecutive bond-then-timeout trips the loop",
            d.connectionEnded(wasBonded = true, msSinceBond = 1_200L, timedOut = true),
        )
        assertTrue(d.tripped)
        // Already tripped → no second "freshly tripped" signal (caller surfaces the guide only once).
        assertFalse(d.connectionEnded(wasBonded = true, msSinceBond = 900L, timedOut = true))
        assertTrue(d.tripped)
    }

    // A single quick post-bond drop must never trip — links die for benign reasons. Below threshold stays untripped.
    @Test fun singleDropDoesNotTrip() {
        val d = PostBondTimeoutLoopDetector()
        assertFalse(d.connectionEnded(wasBonded = true, msSinceBond = 1_000L, timedOut = true))
        assertFalse(d.tripped)
        assertEquals(1, d.consecutiveBondTimeouts)
    }

    // A drop that lands LONG after bonding is a healthy session that flapped later, not the bond loop.
    // It must break the streak rather than count toward a trip (don't mis-trip a healthy link).
    @Test fun timeoutOutsideWindowBreaksStreak() {
        val d = PostBondTimeoutLoopDetector(tripThreshold = 2, quickTimeoutWindowMs = 8_000L)
        assertFalse(d.connectionEnded(wasBonded = true, msSinceBond = 2_000L, timedOut = true))
        assertEquals(1, d.consecutiveBondTimeouts)
        // 90s after bonding: the link clearly survived the bond — this drop is unrelated to the loop.
        assertFalse(d.connectionEnded(wasBonded = true, msSinceBond = 90_000L, timedOut = true))
        assertEquals("a late drop resets the bond-timeout streak", 0, d.consecutiveBondTimeouts)
        assertFalse(d.tripped)
    }

    // A non-timeout close (timedOut=false — intentional disconnect, bond reset, clean close) must never
    // count toward the streak. The bond-loop's signature is specifically a CONNECTION TIMEOUT.
    @Test fun nonTimeoutCloseDoesNotCount() {
        val d = PostBondTimeoutLoopDetector()
        assertFalse(d.connectionEnded(wasBonded = true, msSinceBond = 1_000L, timedOut = true))
        assertFalse(d.connectionEnded(wasBonded = true, msSinceBond = 1_000L, timedOut = false))
        assertEquals("a clean (non-timeout) close resets suspicion", 0, d.consecutiveBondTimeouts)
        // ...and now it takes two fresh bond-timeouts again to trip.
        assertFalse(d.connectionEnded(wasBonded = true, msSinceBond = 1_000L, timedOut = true))
        assertTrue(d.connectionEnded(wasBonded = true, msSinceBond = 1_000L, timedOut = true))
        assertTrue(d.tripped)
    }

    // A drop where the link never bonded (wasBonded=false — e.g. it failed before the bond) can't be the
    // bond loop and must reset the streak.
    @Test fun unbondedDropResetsStreak() {
        val d = PostBondTimeoutLoopDetector()
        assertFalse(d.connectionEnded(wasBonded = true, msSinceBond = 1_000L, timedOut = true))
        assertEquals(1, d.consecutiveBondTimeouts)
        assertFalse(d.connectionEnded(wasBonded = false, msSinceBond = null, timedOut = true))
        assertEquals(0, d.consecutiveBondTimeouts)
    }

    // A timeout with no bond timestamp (msSinceBond == null) can't be classified as quick → no count.
    @Test fun nilSinceBondDoesNotCount() {
        val d = PostBondTimeoutLoopDetector()
        assertFalse(d.connectionEnded(wasBonded = true, msSinceBond = null, timedOut = true))
        assertEquals(0, d.consecutiveBondTimeouts)
        assertFalse(d.tripped)
    }

    // The boundary value (exactly at the window) still counts — a drop right at the edge is part of the loop.
    @Test fun timeoutAtWindowBoundaryCounts() {
        val d = PostBondTimeoutLoopDetector(tripThreshold = 2, quickTimeoutWindowMs = 8_000L)
        assertFalse(d.connectionEnded(wasBonded = true, msSinceBond = 8_000L, timedOut = true))
        assertEquals("exactly at the window boundary still counts", 1, d.consecutiveBondTimeouts)
    }

    // reset() clears everything — used on a clean user-initiated disconnect, so a transient bond hiccup
    // isn't a permanent flag.
    @Test fun resetClearsState() {
        val d = PostBondTimeoutLoopDetector()
        d.connectionEnded(wasBonded = true, msSinceBond = 1_000L, timedOut = true)
        d.connectionEnded(wasBonded = true, msSinceBond = 1_000L, timedOut = true)
        assertTrue(d.tripped)
        d.reset()
        assertFalse(d.tripped)
        assertEquals(0, d.consecutiveBondTimeouts)
        // After reset it takes the full threshold again to re-trip.
        assertFalse(d.connectionEnded(wasBonded = true, msSinceBond = 1_000L, timedOut = true))
        assertFalse(d.tripped)
    }

    // A custom higher threshold (e.g. 3) requires that many consecutive cycles.
    @Test fun customThreshold() {
        val d = PostBondTimeoutLoopDetector(tripThreshold = 3, quickTimeoutWindowMs = 8_000L)
        assertFalse(d.connectionEnded(wasBonded = true, msSinceBond = 1_000L, timedOut = true))
        assertFalse(d.connectionEnded(wasBonded = true, msSinceBond = 1_000L, timedOut = true))
        assertFalse(d.tripped)
        assertTrue(d.connectionEnded(wasBonded = true, msSinceBond = 1_000L, timedOut = true))
        assertTrue(d.tripped)
    }
}
