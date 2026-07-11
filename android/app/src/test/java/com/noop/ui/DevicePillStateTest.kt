package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the Devices card's state-pill priority (#221): "Connected · not paired" must beat "Active · Live"
 * but yield to a reboot's "Reconnecting…". Mirrors the Swift `DevicePillStateTests` exactly — a silent
 * reorder on either platform would otherwise only be caught by eyeballing a screenshot.
 */
class DevicePillStateTest {

    @Test
    fun bondRefused_beatsActiveLive_butYieldsToReconnecting() {
        assertEquals(
            "Connected · not paired",
            devicePillState(
                isArchived = false, isActive = true, isReconnecting = false,
                bondRefused = true, isLiveConnected = true,
            ).label,
        )
        assertEquals(
            "Reconnecting…",
            devicePillState(
                isArchived = false, isActive = true, isReconnecting = true,
                bondRefused = true, isLiveConnected = true,
            ).label,
        )
    }

    @Test
    fun normalConnect_isUnaffected() {
        assertEquals(
            "Active · Live",
            devicePillState(
                isArchived = false, isActive = true, isReconnecting = false,
                bondRefused = false, isLiveConnected = true,
            ).label,
        )
        assertEquals(
            "Active",
            devicePillState(
                isArchived = false, isActive = true, isReconnecting = false,
                bondRefused = false, isLiveConnected = false,
            ).label,
        )
    }

    @Test
    fun nonActiveAndArchived() {
        assertEquals(
            "Paired",
            devicePillState(
                isArchived = false, isActive = false, isReconnecting = false,
                bondRefused = false, isLiveConnected = false,
            ).label,
        )
        assertEquals(
            "Removed",
            devicePillState(
                isArchived = true, isActive = false, isReconnecting = false,
                bondRefused = false, isLiveConnected = false,
            ).label,
        )
    }
}
