package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM twin of Packages/OuraProtocol/Tests/OuraProtocolTests/OuraWearTests.swift — the pure wear/charge
 * state machine: a live pulse means WORN, a silence timeout downgrades WORN->OFF (but never overrides
 * CHARGING), and the charger STATE strings drive CHARGING/OFF.
 */
class OuraWearTest {

    private fun state(text: String?) = OuraState(ringTimestamp = 0L, stateCode = 0, text = text)

    @Test
    fun testChargerStartStopStringMatching() {
        // The ring's own words drive charging; matched case-insensitively on the decoded text.
        assertTrue(OuraWear.isChargerStart(state("chg. detected")))
        assertTrue(OuraWear.isChargerStart(state("Charger started")))
        assertFalse(OuraWear.isChargerStart(state("chg. stopped")))

        assertTrue(OuraWear.isChargerStop(state("chg. stopped")))
        assertTrue(OuraWear.isChargerStop(state("charger removed")))
        assertFalse(OuraWear.isChargerStop(state("chg. detected")))

        // Non-charger STATE strings (and null text) match neither — code 5 is both "hr enable"/"motion det".
        assertFalse(OuraWear.isChargerStart(state("hr enable")))
        assertFalse(OuraWear.isChargerStop(state("motion det")))
        assertFalse(OuraWear.isChargerStart(state(null)))
        assertFalse(OuraWear.isChargerStop(state(null)))
    }

    @Test
    fun testLiveTrackerPulseMeansWorn() {
        val t = OuraWearTracker()
        assertEquals(OuraWearState.UNKNOWN, t.current)
        t.notePulse()
        assertEquals(OuraWearState.WORN, t.current)
    }

    @Test
    fun testLivePulseTimeoutDowngradesWornToOff() {
        val t = OuraWearTracker()
        t.notePulse()
        assertEquals(OuraWearState.WORN, t.current)

        // Silent stream past the grace window -> removed.
        t.noteLivePulseTimeout()
        assertEquals(OuraWearState.OFF, t.current)

        // Charger STATE is authoritative: a pulse-timeout must NEVER override CHARGING.
        t.note(state("chg. detected"))
        assertEquals(OuraWearState.CHARGING, t.current)
        t.noteLivePulseTimeout()
        assertEquals(OuraWearState.CHARGING, t.current)

        // Charger stop -> off; a fresh pulse -> worn again.
        t.note(state("chg. stopped"))
        assertEquals(OuraWearState.OFF, t.current)
        t.notePulse()
        assertEquals(OuraWearState.WORN, t.current)

        t.reset()
        assertEquals(OuraWearState.UNKNOWN, t.current)
    }
}
