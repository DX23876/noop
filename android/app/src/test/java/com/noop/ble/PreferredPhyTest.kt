package com.noop.ble

import android.bluetooth.BluetoothDevice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [WhoopBleClient.preferredPhyMask] / [WhoopBleClient.phyLabel] — the pure LE 2M PHY decision (#533),
 * unit-testable without a BLE stack (the [ConnectionPriorityTest] idiom).
 *
 * NOOP has never called `setPreferredPhy`, so every historical offload has run on the 1M PHY. LE 2M doubles
 * the symbol rate: the same bytes spend HALF the air-time, which should cost LESS radio energy per byte —
 * the opposite of the connection-interval lever, which buys speed with extra wakeups.
 */
class PreferredPhyTest {

    @Test fun offIsPlain1M_todaysLink() {
        // Default path must be byte-for-byte today: 1M only, no 2M preference expressed.
        assertEquals(BluetoothDevice.PHY_LE_1M_MASK, WhoopBleClient.preferredPhyMask(fastLinkEnabled = false))
    }

    /**
     * The request must ALWAYS keep 1M in the mask, never ask for 2M alone. It is only a preference, and
     * leaving 1M in lets the controller fall back rather than cling to a 2M link gone marginal — 2M trades
     * range for speed, and the strap may decline it outright.
     */
    @Test fun onAllowsBoth2MAnd1MFallback() {
        val mask = WhoopBleClient.preferredPhyMask(fastLinkEnabled = true)
        assertTrue("2M must be offered", mask and BluetoothDevice.PHY_LE_2M_MASK != 0)
        assertTrue("1M must stay in the mask so the controller can fall back", mask and BluetoothDevice.PHY_LE_1M_MASK != 0)
    }

    /**
     * Turning the experiment OFF must hand the link BACK to 1M, not merely stop future offloads asking for
     * 2M: a PHY persists once negotiated, so an already-2M link would otherwise stay 2M until the next
     * reconnect — and the toggle's copy tells the user to switch it off when syncing goes flaky at range,
     * which is exactly when 2M is the suspect. The release requests the same mask the OFF state describes.
     */
    @Test fun theReleaseMaskIsTheOffMaskAndDropsThe2MOffer() {
        val off = WhoopBleClient.preferredPhyMask(fastLinkEnabled = false)
        assertEquals(BluetoothDevice.PHY_LE_1M_MASK, off)
        assertEquals("off must not still offer 2M, or it wouldn't undo the escalation", 0, off and BluetoothDevice.PHY_LE_2M_MASK)
    }

    /** The on→off edge rule is shared with the connection-priority lever (#536): only a real on→off
     *  transition releases, so the default launch path (re-applying false while already off) is a no-op. */
    @Test fun onlyTheOnToOffEdgeReleasesThePhy() {
        assertTrue(WhoopBleClient.releasesOnDisable(wasEnabled = true, nowEnabled = false))
        assertEquals(false, WhoopBleClient.releasesOnDisable(wasEnabled = false, nowEnabled = false))
        assertEquals(false, WhoopBleClient.releasesOnDisable(wasEnabled = false, nowEnabled = true))
        assertEquals(false, WhoopBleClient.releasesOnDisable(wasEnabled = true, nowEnabled = true))
    }

    /**
     * `onPhyUpdate` reports a PHY_LE_* VALUE (1/2/3), NOT the *_MASK constants used to request one — the
     * two numbering schemes overlap, so a label that compared against masks would misreport the link.
     */
    @Test fun labelsTheNegotiatedPhyValueNotTheMask() {
        assertEquals("1M", WhoopBleClient.phyLabel(BluetoothDevice.PHY_LE_1M))
        assertEquals("2M", WhoopBleClient.phyLabel(BluetoothDevice.PHY_LE_2M))
        assertEquals("coded", WhoopBleClient.phyLabel(BluetoothDevice.PHY_LE_CODED))
    }

    @Test fun labelsAnUnexpectedPhyRatherThanHidingIt() {
        assertEquals("unknown(9)", WhoopBleClient.phyLabel(9))
    }
}
