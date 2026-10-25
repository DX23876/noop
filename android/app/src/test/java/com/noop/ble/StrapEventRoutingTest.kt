package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins PR #577: the STRAP_DRIVEN_ALARM_EXECUTED (event 57) routing. The bug being fixed: a half-port placed
 * the smart-alarm case inside the GESTURE `when` branch — but event 57 is NOT a gesture, so [isGestureEvent]
 * returns false for it and control never reaches the gesture `when`; the alarm re-arm was swallowed and
 * never fired. The fix routes it from the NON-gesture branch via [smartAlarmFiredForEvent].
 *
 * Event strings are "NAME(rawValue)" (Schema.enumName), so the real on-wire form is
 * "STRAP_DRIVEN_ALARM_EXECUTED(57)".
 */
class StrapEventRoutingTest {

    // The crux of the bug: event 57 is NOT a gesture, so it MUST take the non-gesture branch (where the
    // alarm dispatch now lives). If this were ever true, the case would land in the gesture `when` and be
    // swallowed again.
    @Test fun event57IsNotAGesture() {
        assertFalse(WhoopBleClient.isGestureEvent("STRAP_DRIVEN_ALARM_EXECUTED(57)"))
    }

    // A LIVE event 57 fires the smart-alarm re-arm.
    @Test fun liveEvent57FiresSmartAlarm() {
        assertTrue(
            WhoopBleClient.smartAlarmFiredForEvent("STRAP_DRIVEN_ALARM_EXECUTED(57)", replayedOffload = false),
        )
    }

    // A HISTORICAL event 57 replayed mid-backfill must NOT re-arm (old ts — not a real wake just now).
    @Test fun replayedEvent57DoesNotFire() {
        assertFalse(
            WhoopBleClient.smartAlarmFiredForEvent("STRAP_DRIVEN_ALARM_EXECUTED(57)", replayedOffload = true),
        )
    }

    // The genuine gestures stay gestures (freshness-gated path) and never trip the smart-alarm dispatch.
    @Test fun gesturesAreGesturesAndNeverFireSmartAlarm() {
        for (g in listOf("DOUBLE_TAP(14)", "WRIST_ON(9)", "WRIST_OFF(10)")) {
            assertTrue("$g should be a gesture", WhoopBleClient.isGestureEvent(g))
            assertFalse("$g must not fire smart alarm",
                WhoopBleClient.smartAlarmFiredForEvent(g, replayedOffload = false))
        }
    }

    // Other non-gesture events (BLE_BONDED, BATTERY_LEVEL) take the non-gesture branch but must not fire the
    // smart-alarm dispatch — only event 57 does.
    @Test fun otherNonGestureEventsDoNotFireSmartAlarm() {
        for (e in listOf("BLE_BONDED(1)", "BATTERY_LEVEL(26)")) {
            assertFalse(WhoopBleClient.isGestureEvent(e))
            assertFalse(WhoopBleClient.smartAlarmFiredForEvent(e, replayedOffload = false))
        }
    }
}
