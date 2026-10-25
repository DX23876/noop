package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId

/**
 * Unit tests for [logicalDay], the pure helper behind the "Today must not blank at midnight" fix
 * (#144). The logical day rolls at 04:00 LOCAL, so between midnight and 4am the dashboard still
 * resolves to the prior calendar day's banked row instead of an empty new-calendar-day row.
 *
 * The three boundary cases the fix is judged on:
 *  - 23:59 → SAME calendar day (still the evening's logical day)
 *  - 01:00 → PREVIOUS calendar day (the small hours still belong to yesterday)
 *  - 04:01 → the NEW calendar day (a fresh logical day has begun)
 */
class LogicalDayTest {

    private val zone = ZoneId.of("UTC")

    /** Build a [ZonedDateTime] at the given wall-clock on 2026-06-12 in the test zone. */
    private fun at(hour: Int, minute: Int) =
        LocalDateTime.of(LocalDate.of(2026, 6, 12), LocalTime.of(hour, minute))
            .atZone(zone)

    @Test
    fun lateEveningStaysOnTheSameDay() {
        // 23:59 → 2026-06-12 (4h before is 19:59 same day).
        assertEquals(LocalDate.of(2026, 6, 12), logicalDay(at(23, 59)))
    }

    @Test
    fun afterMidnightBeforeRolloverIsThePreviousDay() {
        // 01:00 → 2026-06-11 (4h before is 21:00 the previous day).
        assertEquals(LocalDate.of(2026, 6, 11), logicalDay(at(1, 0)))
    }

    @Test
    fun justAfterRolloverIsTheNewDay() {
        // 04:01 → 2026-06-12 (4h before is 00:01, still the new calendar day).
        assertEquals(LocalDate.of(2026, 6, 12), logicalDay(at(4, 1)))
    }

    @Test
    fun exactlyAtRolloverIsTheNewDay() {
        // 04:00 → 2026-06-12 (4h before is exactly 00:00 — the boundary belongs to the new day).
        assertEquals(LocalDate.of(2026, 6, 12), logicalDay(at(4, 0)))
    }

    @Test
    fun justBeforeRolloverIsStillThePreviousDay() {
        // 03:59 → 2026-06-11 (4h before is 23:59 the previous day).
        assertEquals(LocalDate.of(2026, 6, 11), logicalDay(at(3, 59)))
    }

    @Test
    fun middayIsTheCurrentDay() {
        assertEquals(LocalDate.of(2026, 6, 12), logicalDay(at(12, 0)))
    }

    @Test
    fun midnightIsThePreviousDay() {
        // 00:00 → 2026-06-11: the instant the calendar rolls, the logical day must hold yesterday.
        assertEquals(LocalDate.of(2026, 6, 11), logicalDay(at(0, 0)))
    }

    @Test
    fun rolloverHourIsInjectable() {
        // With a 0-hour rollover the logical day is just the calendar day (no remap).
        val t = at(1, 0)
        assertEquals(LocalDate.of(2026, 6, 12), logicalDay(t, rolloverHour = 0))
    }

    @Test
    fun startOfLogicalDayAnchorsToThePriorMidnightInSmallHours() {
        // At 01:00 on the 12th the HR window must start at the 11th's 00:00, not the 12th's.
        val expected = LocalDate.of(2026, 6, 11).atStartOfDay(zone).toEpochSecond()
        assertEquals(expected, logicalDayStartEpochSecond(at(1, 0), zone))
    }

    @Test
    fun startOfLogicalDayAnchorsToTodayMidnightAfterRollover() {
        val expected = LocalDate.of(2026, 6, 12).atStartOfDay(zone).toEpochSecond()
        assertEquals(expected, logicalDayStartEpochSecond(at(9, 0), zone))
    }
}
