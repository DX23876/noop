package com.noop.ui.forge

import com.noop.ble.WhoopBleClient
import com.noop.ble.WhoopModel
import com.noop.data.WhoopLiveCapabilities
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Forge pairing registers a WHOOP exactly as the classic wizard does, so the source coordinator treats it alike. */
class ForgePairingTest {
    private val strap = WhoopBleClient.DiscoveredWhoop(address = "AA:BB:CC:DD:EE:FF", name = "WHOOP 4C1234567", rssi = -60)

    @Test fun aFiveOrMgBecomesTheClassicRow() {
        val row = forgeWhoopRow(strap, WhoopModel.WHOOP5_MG, 1_800_000_000)
        assertEquals("whoop-AA:BB:CC:DD:EE:FF", row.id)
        assertEquals("WHOOP", row.brand)
        assertEquals("5.0 MG", row.model)
        assertEquals("AA:BB:CC:DD:EE:FF", row.peripheralId)
        assertEquals("liveBLE", row.sourceKind)
        assertEquals(WhoopLiveCapabilities.encoded("5.0 MG"), row.capabilities)
        assertEquals("paired", row.status)
        assertEquals(1_800_000_000, row.addedAt)
    }

    @Test fun aFourKeepsItsOwnModelAndANamelessStrapNoNickname() {
        val row = forgeWhoopRow(strap.copy(name = " "), WhoopModel.WHOOP4, 1)
        assertEquals("4.0", row.model)
        assertEquals(WhoopLiveCapabilities.encoded("4.0"), row.capabilities)
        assertNull(row.nickname)
    }

    @Test fun signalBarsStepEveryTenDecibels() {
        assertEquals(listOf(4, 4, 3, 2, 1), listOf(-40, -55, -65, -75, -90).map(::signalBars))
    }
}
