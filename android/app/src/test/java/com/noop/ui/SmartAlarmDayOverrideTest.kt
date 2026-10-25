package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

/**
 * Per-weekday wake-time OVERRIDES for the smart alarm (PR #554 reimpl, @MumiZed). The default "Wake at"
 * time applies to every firing day UNLESS that day has an override, in which case the override time is
 * used. Covers the date math in [nextSmartAlarmEpochSec]'s new [dayOverrides] arg. Mirrors the macOS
 * SmartAlarmDayOverrideTests. Empty override map must be byte-for-byte the pre-#554 behaviour.
 *
 * Calendar.DAY_OF_WEEK: 1 = Sun … 7 = Sat.
 */
class SmartAlarmDayOverrideTest {

    private val utc = TimeZone.getTimeZone("UTC")
    private fun utcCalendar(): Calendar = Calendar.getInstance(utc)

    private fun ms(year: Int, month1: Int, day: Int, hour: Int, minute: Int): Long =
        utcCalendar().apply { clear(); set(year, month1 - 1, day, hour, minute, 0) }.timeInMillis

    private fun weekday(epochSec: Long): Int =
        utcCalendar().apply { timeInMillis = epochSec * 1000L }.get(Calendar.DAY_OF_WEEK)

    // 2026-06-17 is a Wednesday (DAY_OF_WEEK 4).
    private fun wedAt(hour: Int, minute: Int) = ms(2026, 6, 17, hour, minute)

    private fun next(minuteOfDay: Int, weekdays: Set<Int>, nowMs: Long, overrides: Map<Int, Int>): Long? =
        nextSmartAlarmEpochSec(minuteOfDay, weekdays, nowMs, ::utcCalendar, overrides)

    @Test
    fun emptyOverrides_matchesDefaultBehaviour() {
        // now = Wed 06:00, wake 07:00, every day, no overrides → today 07:00 (unchanged from #539).
        val n = next(7 * 60, emptySet(), wedAt(6, 0), emptyMap())
        assertEquals(wedAt(7, 0) / 1000, n)
    }

    @Test
    fun overrideForToday_usesOverrideTime() {
        // now = Wed 06:00, default 07:00, but Wednesday overridden to 09:00 → today 09:00.
        val n = next(7 * 60, emptySet(), wedAt(6, 0), mapOf(4 to 9 * 60))
        assertEquals(wedAt(9, 0) / 1000, n)
    }

    @Test
    fun overrideMakesTodayStillPending() {
        // now = Wed 08:00, default 07:00 (already passed today), Wednesday override 09:00 → STILL today
        // 09:00 (the later override keeps today's occurrence in the future).
        val n = next(7 * 60, emptySet(), wedAt(8, 0), mapOf(4 to 9 * 60))
        assertEquals(wedAt(9, 0) / 1000, n)
        assertEquals(4, weekday(n!!))
    }

    @Test
    fun overrideEarlierThanNow_rollsToNextDayWithItsOwnTime() {
        // now = Wed 08:00, Wednesday overridden to 06:00 (already passed) → next day (Thu) at the DEFAULT.
        val n = next(7 * 60, emptySet(), wedAt(8, 0), mapOf(4 to 6 * 60))
        assertEquals(ms(2026, 6, 18, 7, 0) / 1000, n) // Thu 07:00 default
    }

    @Test
    fun overrideOnADifferentFiringDay() {
        // now = Wed 06:00, default 07:00, Thursday overridden to 06:30. Wednesday still fires first at the
        // default 07:00 today.
        val n = next(7 * 60, emptySet(), wedAt(6, 0), mapOf(5 to 6 * 60 + 30))
        assertEquals(wedAt(7, 0) / 1000, n)
    }

    @Test
    fun overrideOnlyAppliesToOverriddenDay() {
        // Weekdays only (Mon–Fri); now = Wed 08:00 (past 07:00), no override for Thu → Thu 07:00 default.
        val n = next(7 * 60, setOf(2, 3, 4, 5, 6), wedAt(8, 0), mapOf(2 to 5 * 60))
        assertEquals(ms(2026, 6, 18, 7, 0) / 1000, n)
    }

    @Test
    fun overrideRespectedAcrossTheWeek() {
        // Weekdays only; now = Sat 06:00 (2026-06-20). Monday (dow 2) overridden to 05:30 → Mon 05:30.
        val n = next(7 * 60, setOf(2, 3, 4, 5, 6), ms(2026, 6, 20, 6, 0), mapOf(2 to 5 * 60 + 30))
        assertEquals(2, weekday(n!!))
        assertEquals(ms(2026, 6, 22, 5, 30) / 1000, n)
    }

    @Test
    fun invalidOverridesAreIgnored() {
        // Out-of-range day / minute overrides are dropped → falls back to the default time.
        val n = next(7 * 60, emptySet(), wedAt(6, 0), mapOf(99 to 5 * 60, 4 to 9999))
        assertEquals(wedAt(7, 0) / 1000, n)
    }

    @Test
    fun overrideOnNonFiringDayHasNoEffect() {
        // Wednesdays only; an override on Friday (not a firing day) is irrelevant → next Wed at default.
        val n = next(7 * 60, setOf(4), wedAt(8, 0), mapOf(6 to 5 * 60))
        assertEquals(ms(2026, 6, 24, 7, 0) / 1000, n)
    }

    @Test
    fun stillStrictlyFutureWithOverride() {
        // now exactly at the override time → must skip to the next occurrence.
        val n = next(7 * 60, emptySet(), wedAt(9, 0), mapOf(4 to 9 * 60))
        assertTrue(n!! * 1000L > wedAt(9, 0))
    }

    @Test
    fun noValidFiringDay_returnsNull() {
        assertNull(next(7 * 60, setOf(0, 8), wedAt(6, 0), mapOf(4 to 9 * 60)))
    }
}
