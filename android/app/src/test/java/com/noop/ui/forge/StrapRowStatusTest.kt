package com.noop.ui.forge

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * What a strap row may say about the link. The case that brought this rule into being is the first one:
 * the published registry name lags a pairing takeover, and a row that asked the name first then told a
 * tester there was no wearable while his WHOOP 4 was streaming.
 */
class StrapRowStatusTest {

    @Test
    fun `a connected strap is connected even while its name lags`() {
        assertEquals(
            StrapRow.Connected,
            StrapRowStatus.of(named = false, onAir = true, syncing = false, charging = null, batteryPct = null),
        )
        assertEquals(
            StrapRow.Battery,
            StrapRowStatus.of(named = false, onAir = true, syncing = false, charging = null, batteryPct = 42.0),
        )
    }

    @Test
    fun `nothing paired and nothing on the air is the only empty state`() {
        assertEquals(
            StrapRow.None,
            StrapRowStatus.of(named = false, onAir = false, syncing = false, charging = null, batteryPct = null),
        )
        // A battery reading left over from an earlier link does not make an absent strap present.
        assertEquals(
            StrapRow.None,
            StrapRowStatus.of(named = false, onAir = false, syncing = false, charging = null, batteryPct = 42.0),
        )
    }

    @Test
    fun `a named strap that is off the air reads disconnected, not absent`() {
        assertEquals(
            StrapRow.Disconnected,
            StrapRowStatus.of(named = true, onAir = false, syncing = false, charging = null, batteryPct = 42.0),
        )
    }

    @Test
    fun `syncing comes before charging and the battery`() {
        assertEquals(
            StrapRow.Syncing,
            StrapRowStatus.of(named = true, onAir = true, syncing = true, charging = true, batteryPct = 42.0),
        )
        assertEquals(
            StrapRow.Charging,
            StrapRowStatus.of(named = true, onAir = true, syncing = false, charging = true, batteryPct = 42.0),
        )
    }

    /** A surface that does not name charging passes null for it and never gets that state back. */
    @Test
    fun `a surface that ignores charging gets the battery instead`() {
        assertEquals(
            StrapRow.Battery,
            StrapRowStatus.of(named = true, onAir = true, syncing = false, charging = null, batteryPct = 42.0),
        )
    }
}
