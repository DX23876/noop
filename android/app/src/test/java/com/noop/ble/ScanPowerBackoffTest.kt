package com.noop.ble

import android.bluetooth.le.ScanSettings
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins PR #588: an INVOLUNTARY reconnect scan stays on the snappy LOW_LATENCY mode for the first few
 * attempts (the common quick-blip drop), then drops to the lower-power BALANCED mode once the streak
 * crosses [WhoopBleClient.SCAN_POWER_BACKOFF_THRESHOLD] — so an out-of-range strap (left at home / dead
 * battery) stops pinning the radio at full power while [ReconnectBackoff] still fires a scan up to every
 * 60s. A user-driven Connect resets the streak to 0 (resetReconnectBackoff), so a manual reconnect / the
 * Add-a-WHOOP wizard always scans at LOW_LATENCY.
 */
class ScanPowerBackoffTest {

    @Test fun zeroAttemptsIsLowLatency() {
        // attempts == 0 is the user-initiated connect / first scan — must be eager.
        assertEquals(
            ScanSettings.SCAN_MODE_LOW_LATENCY,
            WhoopBleClient.scanModeForReconnectAttempts(0),
        )
    }

    @Test fun belowThresholdStaysLowLatency() {
        for (n in 1 until WhoopBleClient.SCAN_POWER_BACKOFF_THRESHOLD) {
            assertEquals(
                "attempt $n should still be LOW_LATENCY",
                ScanSettings.SCAN_MODE_LOW_LATENCY,
                WhoopBleClient.scanModeForReconnectAttempts(n),
            )
        }
    }

    @Test fun atThresholdBacksOffToBalanced() {
        assertEquals(
            ScanSettings.SCAN_MODE_BALANCED,
            WhoopBleClient.scanModeForReconnectAttempts(WhoopBleClient.SCAN_POWER_BACKOFF_THRESHOLD),
        )
    }

    @Test fun pastThresholdStaysBalanced() {
        assertEquals(
            ScanSettings.SCAN_MODE_BALANCED,
            WhoopBleClient.scanModeForReconnectAttempts(WhoopBleClient.SCAN_POWER_BACKOFF_THRESHOLD + 20),
        )
    }
}
