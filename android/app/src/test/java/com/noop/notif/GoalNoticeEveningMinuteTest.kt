package com.noop.notif

import org.junit.Assert.assertEquals
import org.junit.Test

/** The evening reminder's minute, as `GoalEventNotifier.eveningMinute` places it. */
class GoalNoticeEveningMinuteTest {
    @Test fun threeHoursBeforeBedtime() {
        // Wake 07:00, 8 h of sleep: bedtime 23:00, reminder 20:00.
        assertEquals(20 * 60, GoalNoticeNotifier.eveningMinuteFor(7 * 60, 8 * 60))
    }

    @Test fun anOddResultFallsBackToSevenPm() {
        // Wake 10:00, 8 h: bedtime 02:00, reminder 23:00, past the 20:45 limit.
        assertEquals(19 * 60, GoalNoticeNotifier.eveningMinuteFor(10 * 60, 8 * 60))
        // Wake 04:00, 8 h: bedtime 20:00, reminder 17:00 is fine.
        assertEquals(17 * 60, GoalNoticeNotifier.eveningMinuteFor(4 * 60, 8 * 60))
        // Wake 03:00, 9 h: bedtime 18:00, reminder 15:00, before 16:00.
        assertEquals(19 * 60, GoalNoticeNotifier.eveningMinuteFor(3 * 60, 9 * 60))
    }
}
