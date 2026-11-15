package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The asymmetry between the two directions of the sharing switch, pinned.
 *
 * The cases below are the ones that were wrong in the field: an OFF that also took the standard
 * heart-rate service down with it, a remembered wish fired at the wrong strap, and a readout that
 * reported a strap nobody had asked as "off". Twin of `StrapSharingTests` on the Swift side; the
 * expected strings are the same literals so a shared strap log reads identically either side.
 */
class StrapSharingTest {

    @Test
    fun `on writes both settings`() {
        val plan = StrapSharing.plan(true)
        assertTrue(plan.writesService)
        assertTrue(plan.writesAdvertising)
    }

    @Test
    fun `off never touches the service`() {
        val plan = StrapSharing.plan(false)
        assertFalse(
            "stopping the broadcast must not switch off the service NOOP reads",
            plan.writesService,
        )
        assertTrue(plan.writesAdvertising)
    }

    @Test
    fun `a pending wish applies only to the strap it was made for`() {
        assertTrue(StrapSharing.pendingApplies("my-whoop", "my-whoop"))
        assertFalse(StrapSharing.pendingApplies("my-whoop", "spare-whoop"))
    }

    @Test
    fun `a pending wish needs both ids`() {
        assertFalse(StrapSharing.pendingApplies(null, "my-whoop"))
        assertFalse(StrapSharing.pendingApplies("my-whoop", null))
        assertFalse(StrapSharing.pendingApplies("", "my-whoop"))
        assertFalse(StrapSharing.pendingApplies("my-whoop", ""))
        assertFalse(StrapSharing.pendingApplies(null, null))
    }

    @Test
    fun `the header line keeps unknown apart from off`() {
        assertEquals(
            "Sharing:     unknown (never read from this strap)",
            StrapSharing.headerLine(null, null),
        )
        assertEquals(
            "Sharing:     unknown (never read from this strap)",
            StrapSharing.headerLine(null, "5m ago"),
        )
    }

    @Test
    fun `the header line reports what was read`() {
        assertEquals(
            "Sharing:     ON — the strap broadcasts its heart rate continuously · read 5m ago",
            StrapSharing.headerLine(true, "5m ago"),
        )
        assertEquals("Sharing:     off · read 5m ago", StrapSharing.headerLine(false, "5m ago"))
        assertEquals("Sharing:     off", StrapSharing.headerLine(false, null))
    }

    @Test
    fun `the label matches the width of its neighbours`() {
        for (state in listOf(null, true, false)) {
            assertEquals("Sharing:     ", StrapSharing.headerLine(state, null).take(13))
        }
        assertEquals(13, "Model:       ".length)
    }
}
