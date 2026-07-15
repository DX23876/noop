package com.noop.ble

import android.bluetooth.BluetoothGatt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [WhoopBleClient.connectionPriorityFor] — the pure GATT connection-priority decision (#477),
 * unit-testable without a BLE stack (the [ScanPowerBackoffTest] idiom).
 *
 * SAFE half: HIGH during an offload burst OR a live-HR session — a SHORTER interval than BALANCED, so
 * it can't cause a supervision-timeout drop and it shortens the radio-on window. RISKY half
 * ([idleThrottleEnabled], default off): LOW_POWER when idle. Off → BALANCED, today's default.
 */
class ConnectionPriorityTest {

    @Test fun activeWorkIsAlwaysHigh() {
        // offload OR live-HR → HIGH, and the idle throttle can't override active work
        assertEquals(
            BluetoothGatt.CONNECTION_PRIORITY_HIGH,
            WhoopBleClient.connectionPriorityFor(offloadActive = true, liveHrActive = false, idleThrottleEnabled = false),
        )
        assertEquals(
            BluetoothGatt.CONNECTION_PRIORITY_HIGH,
            WhoopBleClient.connectionPriorityFor(offloadActive = false, liveHrActive = true, idleThrottleEnabled = false),
        )
        assertEquals(
            BluetoothGatt.CONNECTION_PRIORITY_HIGH,
            WhoopBleClient.connectionPriorityFor(offloadActive = true, liveHrActive = false, idleThrottleEnabled = true),
        )
    }

    @Test fun idleWithThrottleOffStaysBalanced() {
        // The whole point of the safe half shipping default-on: idle == today's behaviour when the
        // risky throttle is off.
        assertEquals(
            BluetoothGatt.CONNECTION_PRIORITY_BALANCED,
            WhoopBleClient.connectionPriorityFor(offloadActive = false, liveHrActive = false, idleThrottleEnabled = false),
        )
    }

    @Test fun idleWithThrottleOnDropsToLowPower() {
        assertEquals(
            BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER,
            WhoopBleClient.connectionPriorityFor(offloadActive = false, liveHrActive = false, idleThrottleEnabled = true),
        )
    }

    // --- battery-adaptive gate, keyed on STRAP battery only (#477) ---

    @Test fun idleThrottleEngagesOnlyWhenDischargingAtOrBelowThreshold() {
        // strap at/below threshold, discharging → engage
        assertTrue(WhoopBleClient.idleThrottleActive(batteryPct = 20, charging = false, thresholdPct = 20))
        assertTrue(WhoopBleClient.idleThrottleActive(batteryPct = 12, charging = false, thresholdPct = 20))
        // above threshold → do not engage
        assertFalse(WhoopBleClient.idleThrottleActive(batteryPct = 21, charging = false, thresholdPct = 20))
        // well above → do not engage (the phone's own Battery Saver is NOT a trigger)
        assertFalse(WhoopBleClient.idleThrottleActive(batteryPct = 80, charging = false, thresholdPct = 20))
    }

    @Test fun idleThrottleNeverEngagesWhenChargingOrDisabled() {
        // strap charging → never (its battery isn't the concern)
        assertFalse(WhoopBleClient.idleThrottleActive(batteryPct = 5, charging = true, thresholdPct = 30))
        // threshold 0 → disabled
        assertFalse(WhoopBleClient.idleThrottleActive(batteryPct = 1, charging = false, thresholdPct = 0))
    }

    // --- battery-adaptive offload cadence (#477) ---

    private val base = 900_000L      // 15 min
    private val low = 2_700_000L     // 45 min

    @Test fun offloadStretchesOnlyWhenDischargingAtOrBelowThreshold() {
        // strap discharging, at/below → stretched
        assertEquals(low, WhoopBleClient.offloadIntervalMsFor(base, low, batteryPct = 18, charging = false, thresholdPct = 20))
        // above threshold → normal cadence (no phone-Battery-Saver override)
        assertEquals(base, WhoopBleClient.offloadIntervalMsFor(base, low, batteryPct = 40, charging = false, thresholdPct = 20))
        assertEquals(base, WhoopBleClient.offloadIntervalMsFor(base, low, batteryPct = 70, charging = false, thresholdPct = 20))
    }

    @Test fun offloadNeverStretchesWhenChargingOrDisabled() {
        // strap charging → normal even at low battery
        assertEquals(base, WhoopBleClient.offloadIntervalMsFor(base, low, batteryPct = 8, charging = true, thresholdPct = 30))
        // threshold 0 → normal cadence always
        assertEquals(base, WhoopBleClient.offloadIntervalMsFor(base, low, batteryPct = 3, charging = false, thresholdPct = 0))
    }
}
