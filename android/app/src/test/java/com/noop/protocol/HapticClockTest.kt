package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pure-logic tests for the Haptic Clock encoder (#460). These pin the EXACT pulse list for sample
 * times; the Apple `HapticClockTests.swift` asserts the same lists so the two platforms buzz
 * identically (e.g. 3:25 → the same list).
 */
class HapticClockTest {
    private fun lng(gap: Int) = HapticClock.Pulse(HapticClock.LONG_MS, gap)
    private fun shrt(gap: Int) = HapticClock.Pulse(HapticClock.SHORT_MS, gap)

    /** 3:25 in 24-hour form: hour 03 (no tens, 3 units) — block — minute 25 (2 tens, 5 units). */
    @Test
    fun pulses_0325_24h_exactList() {
        val g = HapticClock.INTRA_GAP_MS
        val expected = listOf(
            // hour-tens 0 → nothing; hour-units 3 → three short pulses, last carries the block gap.
            shrt(g), shrt(g), shrt(HapticClock.BLOCK_GAP_MS),
            // minute-tens 2 → two long pulses, last carries the group gap.
            lng(g), lng(HapticClock.GROUP_GAP_MS),
            // minute-units 5 → five short pulses; the very last pulse has no trailing gap.
            shrt(g), shrt(g), shrt(g), shrt(g), shrt(0),
        )
        assertEquals(expected, HapticClock.pulses(3, 25, is24h = true))
    }

    /** 12-hour mapping: 15:25 → dial reads 3:25, so it must equal the 24h 3:25 list exactly. */
    @Test
    fun pulses_1525_12h_mapsTo0325() {
        assertEquals(
            HapticClock.pulses(3, 25, is24h = true),
            HapticClock.pulses(15, 25, is24h = false),
        )
    }

    /**
     * 10:05 in 24-hour form: hour 10 (1 ten, 0 units) — block — minute 05 (0 tens, 5 units).
     * Exercises a 0 unit digit (hour) and a 0 tens digit (minute) — both emit no pulse.
     */
    @Test
    fun pulses_1005_24h_handlesZeroDigits() {
        val g = HapticClock.INTRA_GAP_MS
        val expected = listOf(
            // hour-tens 1 → one long; hour-units 0 → nothing, so this long carries the block gap.
            lng(HapticClock.BLOCK_GAP_MS),
            // minute-tens 0 → nothing; minute-units 5 → five short, last with no trailing gap.
            shrt(g), shrt(g), shrt(g), shrt(g), shrt(0),
        )
        assertEquals(expected, HapticClock.pulses(10, 5, is24h = true))
    }

    /** Midnight 0:00 in 24-hour form has no nonzero digits — there is nothing to buzz. */
    @Test
    fun pulses_midnight_24h_isEmpty() {
        assertEquals(emptyList<HapticClock.Pulse>(), HapticClock.pulses(0, 0, is24h = true))
    }

    /** Midnight 0:00 in 12-hour form reads "12:00" → one ten + two units of hour, no minute pulses. */
    @Test
    fun pulses_midnight_12h_readsTwelve() {
        val expected = listOf(
            lng(HapticClock.GROUP_GAP_MS),
            shrt(HapticClock.INTRA_GAP_MS), shrt(0),
        )
        assertEquals(expected, HapticClock.pulses(0, 0, is24h = false))
    }

    /** Noon stays 12 in 12-hour form (it does not collapse to 0). */
    @Test
    fun twelveHour_mapping() {
        assertEquals(12, HapticClock.twelveHour(12))
        assertEquals(12, HapticClock.twelveHour(0))
        assertEquals(1, HapticClock.twelveHour(13))
        assertEquals(11, HapticClock.twelveHour(23))
    }

    /** Out-of-range inputs are clamped, not crashed (the trigger can be driven from a stored pref). */
    @Test
    fun pulses_clampsOutOfRange() {
        assertEquals(
            HapticClock.pulses(23, 59, is24h = true),
            HapticClock.pulses(99, 99, is24h = true),
        )
        assertEquals(
            HapticClock.pulses(0, 0, is24h = true),
            HapticClock.pulses(-5, -5, is24h = true),
        )
    }
}
