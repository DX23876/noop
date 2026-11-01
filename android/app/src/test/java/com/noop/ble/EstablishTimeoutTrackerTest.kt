package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the status-147 establishment-timeout detector: a strap that advertises but never answers
 * `connectGatt` (two consecutive ~30s establishment timeouts) must surface the charge-kick/radio
 * recovery guidance, while a single edge-of-range timeout — or a mixed streak broken by a different
 * failure — must stay quiet. Pure value type -> no BLE seam needed, same shape as [EmptySyncTrackerTest].
 */
class EstablishTimeoutTrackerTest {

    // One lost connect request is edge-of-range noise, not a wedged radio: stay quiet.
    @Test fun singleTimeoutStaysQuiet() {
        val t = EstablishTimeoutTracker()
        assertFalse("first 147 is noise", t.recordFailedConnect(establishTimedOut = true))
        assertEquals(1, t.consecutiveTimeouts)
    }

    // Two in a row is the wedged-radio signature; and (like the #78 pairing hint) the signal REPEATS on
    // every further over-threshold timeout so the caller can re-assert the hint after the UI cleared it
    // (a user Connect overwrites statusNote with "Searching…").
    @Test fun warnsOnSecondConsecutiveTimeoutAndKeepsReasserting() {
        val t = EstablishTimeoutTracker()
        assertFalse(t.recordFailedConnect(establishTimedOut = true))
        assertTrue("second consecutive 147 warns", t.recordFailedConnect(establishTimedOut = true))
        assertTrue("third keeps re-asserting", t.recordFailedConnect(establishTimedOut = true))
        assertEquals(3, t.consecutiveTimeouts)
    }

    // A failed connect with a DIFFERENT status means the strap is at least answering — that breaks the
    // streak, so suspicion never accumulates across unrelated failures.
    @Test fun differentFailureBreaksTheStreak() {
        val t = EstablishTimeoutTracker()
        assertFalse(t.recordFailedConnect(establishTimedOut = true))
        assertFalse("non-147 failure clears the streak", t.recordFailedConnect(establishTimedOut = false))
        assertEquals(0, t.consecutiveTimeouts)
        assertFalse("streak restarts from scratch", t.recordFailedConnect(establishTimedOut = true))
        assertTrue(t.recordFailedConnect(establishTimedOut = true))
    }

    // reset() (STATE_CONNECTED / user teardown / releaseStrap) clears the streak: the next suspicion
    // must accumulate afresh.
    @Test fun resetClearsTheStreak() {
        val t = EstablishTimeoutTracker()
        t.recordFailedConnect(establishTimedOut = true)
        t.recordFailedConnect(establishTimedOut = true)
        t.reset()
        assertEquals(0, t.consecutiveTimeouts)
        assertFalse("post-reset first 147 is noise again", t.recordFailedConnect(establishTimedOut = true))
    }

    // A custom threshold is honoured (defensive: the default is 2, but the knob must work).
    @Test fun customThresholdHonoured() {
        val t = EstablishTimeoutTracker(warnThreshold = 3)
        assertFalse(t.recordFailedConnect(establishTimedOut = true))
        assertFalse(t.recordFailedConnect(establishTimedOut = true))
        assertTrue(t.recordFailedConnect(establishTimedOut = true))
    }
}
