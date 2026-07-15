package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-predicate tests for two BLE-lane changes that can't exercise a live GATT stack (no Robolectric —
 * see [GattCrashSafetyTest]):
 *
 *   - PR #568 (charging bolt): [WhoopBleClient.shouldApplyChargingFromBatteryEvent] — a LIVE BATTERY_LEVEL
 *     event drives the charging pill; a historical one replayed mid-backfill does not. The old 45 s
 *     event-timestamp freshness gate is gone.
 *   - H3 / #520 (device-remove release): [WhoopBleClient.releasedLiveState] — releasing a strap clears the
 *     live link + every stale readout so a removed band can't keep showing live HR / a bond / a charge.
 */
class ChargingAndReleaseTest {

    // --- PR #568: charging-from-battery-event gate -----------------------------------------------------

    @Test fun liveBatteryEvent_appliesCharging() {
        assertTrue(WhoopBleClient.shouldApplyChargingFromBatteryEvent(replayedOffload = false))
    }

    @Test fun replayedHistoricalBatteryEvent_doesNotApplyCharging() {
        assertFalse(WhoopBleClient.shouldApplyChargingFromBatteryEvent(replayedOffload = true))
    }

    // --- H3 / #520: released LiveState -----------------------------------------------------------------

    @Test fun releasedState_dropsTheLinkAndClearsLiveReadouts() {
        val live = LiveState(
            connected = true, bonded = true, encryptedBond = true,
            heartRate = 72, rr = listOf(800, 810), rrRecent = listOf(800, 810),
            charging = true, pairingHint = "still bonded to the official app",
            strapFirmware = "41.17.6.0", historyLayoutVersion = 25,
            scanning = true, statusNote = "Searching…",
        )
        val released = WhoopBleClient.releasedLiveState(live)
        assertFalse(released.connected)
        assertFalse(released.bonded)
        assertFalse(released.encryptedBond)
        assertNull(released.heartRate)
        assertTrue(released.rr.isEmpty())
        assertTrue(released.rrRecent.isEmpty())
        assertNull(released.charging)
        assertNull(released.strapFirmware)
        assertNull(released.historyLayoutVersion)
        assertNull(released.pairingHint)
        assertFalse(released.scanning)
        assertNull(released.statusNote)
    }

    @Test fun releasedState_isIdempotentFromAnAlreadyDownState() {
        val down = LiveState()
        val released = WhoopBleClient.releasedLiveState(down)
        assertFalse(released.connected)
        assertNull(released.heartRate)
        assertNull(released.charging)
    }
}
