package com.noop.core

import com.noop.data.PairedDeviceRow
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** The core's union reads get the same registered WHOOP set the Room fallback reads, archived straps included. */
class CoreShadowDevicesTest {
    private fun row(id: String, brand: String, status: String) =
        PairedDeviceRow(id = id, brand = brand, model = "", nickname = null, sourceKind = "ble",
                        capabilities = "", status = status, addedAt = 0, lastSeenAt = 0)

    @Test fun everyRegisteredWhoopIsHandedOnInRegistryOrderIncludingArchived() {
        val rows = listOf(
            row("whoop-old", "WHOOP", "archived"),
            row("oura-1", "Oura", "paired"),
            row("whoop-new", "whoop", "active"),
        )
        assertEquals(listOf("whoop-old", "whoop-new"), CoreShadow.registeredWhoopIds(rows))
    }

    @Test fun theArgumentsCarryTheListOnlyWhenTheRegistryWasRead() {
        val full = JSONObject(CoreShadow.devicesArgs("whoop-new", listOf("whoop-old", "whoop-new")))
        assertEquals("whoop-new", full.getString("active"))
        assertEquals(2, full.getJSONArray("registered").length())
        // A strap switch on the Bluetooth thread moves only the active id; the list the core has stays.
        assertFalse(JSONObject(CoreShadow.devicesArgs("whoop-new", null)).has("registered"))
    }
}
