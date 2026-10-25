package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirror of the Swift EmptySyncTrackerTests — pins the #126 false-alarm guard on the #77/#91/#120
 * "your strap's clock has lost sync" banner. A single console-only sync (common on a healthy strap under
 * heavy live-HR polling) must NOT warn; only CONSECUTIVE empty cycles do, and any banking cycle clears
 * the streak.
 */
class EmptySyncTrackerTest {

    @Test fun singleEmptyCycleDoesNotWarn() {
        val t = EmptySyncTracker()        // default threshold 3
        assertFalse(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
        assertEquals(1, t.consecutiveEmptySyncs)
    }

    @Test fun twoEmptyCyclesStillSilent() {
        val t = EmptySyncTracker()
        assertFalse(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
        assertFalse(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
        assertEquals(2, t.consecutiveEmptySyncs)
    }

    @Test fun threeConsecutiveEmptyCyclesWarn() {
        val t = EmptySyncTracker()
        assertFalse(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
        assertFalse(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
        assertTrue(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
        assertEquals(3, t.consecutiveEmptySyncs)
    }

    // NoahMcE's case: 2 empty cycles sprinkled among healthy ones never accumulate to a warning.
    @Test fun bankingCycleClearsStreak() {
        val t = EmptySyncTracker()
        assertFalse(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
        assertFalse(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
        assertFalse(t.recordCompletedSync(bankedSensorRecords = true, consoleOnly = false))
        assertEquals(0, t.consecutiveEmptySyncs)
        assertFalse(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
        assertFalse(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
        assertTrue(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
    }

    // A caught-up sync (nothing to offload) also clears the streak — it isn't a banking failure.
    @Test fun caughtUpCycleClearsStreak() {
        val t = EmptySyncTracker()
        assertFalse(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
        assertFalse(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = false))
        assertEquals(0, t.consecutiveEmptySyncs)
    }

    @Test fun sustainedEmptinessKeepsWarning() {
        val t = EmptySyncTracker()
        t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true)
        t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true)
        assertTrue(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
        assertTrue(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
    }

    @Test fun customThreshold() {
        val t = EmptySyncTracker(threshold = 2)
        assertFalse(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
        assertTrue(t.recordCompletedSync(bankedSensorRecords = false, consoleOnly = true))
    }
}
