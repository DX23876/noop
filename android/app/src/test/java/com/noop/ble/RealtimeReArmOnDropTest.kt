package com.noop.ble

import com.noop.protocol.CommandNumber
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #312: when the GATT write queue drops a frame after MAX_WRITE_RETRIES busy-retries, only a dropped
 * TOGGLE_REALTIME_HR should clear the realtime latch so the keep-alive re-arms live R-R (→ HRV / Autonomic).
 * A 5/MG whose toggle lost a write race would otherwise stream plain HR forever while HRV stayed dark.
 *
 * Pins the pure decision [WhoopBleClient.shouldReArmRealtimeAfterDrop] — the full drop→re-arm behaviour
 * needs a live GATT stack the unit harness can't fake (no Robolectric; see GattCrashSafetyTest's INFRA NOTE),
 * so, matching that file's pattern, this pins the predicate the drop path is built on.
 */
class RealtimeReArmOnDropTest {

    @Test
    fun `dropped realtime toggle re-arms`() {
        assertTrue(WhoopBleClient.shouldReArmRealtimeAfterDrop(CommandNumber.TOGGLE_REALTIME_HR))
    }

    @Test
    fun `other dropped commands never poke the realtime latch`() {
        // Each has its own recovery; clearing realtimeArmed for them would spuriously re-send the toggle.
        for (cmd in listOf(
            CommandNumber.RUN_HAPTICS_PATTERN,
            CommandNumber.SEND_HISTORICAL_DATA,
            CommandNumber.HISTORICAL_DATA_RESULT,
            CommandNumber.SET_CLOCK,
            CommandNumber.SET_ALARM_TIME,
            CommandNumber.GET_BATTERY_LEVEL,
        )) {
            assertFalse("$cmd must not re-arm realtime", WhoopBleClient.shouldReArmRealtimeAfterDrop(cmd))
        }
    }

    @Test
    fun `an untagged (null-command) dropped frame does not re-arm`() {
        assertFalse(WhoopBleClient.shouldReArmRealtimeAfterDrop(null))
    }
}
