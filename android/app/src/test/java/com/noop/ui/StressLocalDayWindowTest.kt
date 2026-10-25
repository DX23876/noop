package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

class StressLocalDayWindowTest {
    private val berlin = ZoneId.of("Europe/Berlin")

    @Test
    fun springForwardDayEndsAtNextLocalMidnight() {
        val window = stressLocalDayWindow(LocalDate.of(2026, 3, 29), berlin)

        assertEquals(Instant.parse("2026-03-28T23:00:00Z").epochSecond, window.fromEpochSecond)
        assertEquals(Instant.parse("2026-03-29T21:59:59Z").epochSecond, window.toEpochSecondInclusive)
        assertEquals(23 * 60 * 60L, window.durationSeconds)
        assertEquals(60 * 60, window.offsetSeconds)
    }

    @Test
    fun fallBackDayEndsAtNextLocalMidnight() {
        val window = stressLocalDayWindow(LocalDate.of(2026, 10, 25), berlin)

        assertEquals(Instant.parse("2026-10-24T22:00:00Z").epochSecond, window.fromEpochSecond)
        assertEquals(Instant.parse("2026-10-25T22:59:59Z").epochSecond, window.toEpochSecondInclusive)
        assertEquals(25 * 60 * 60L, window.durationSeconds)
        assertEquals(2 * 60 * 60, window.offsetSeconds)
    }

    @Test
    fun ordinaryDayRemainsTwentyFourHours() {
        val window = stressLocalDayWindow(LocalDate.of(2026, 2, 10), berlin)

        assertEquals(24 * 60 * 60L, window.durationSeconds)
    }

    @Test
    fun containingWindowUsesTheSuppliedDeviceZone() {
        val instant = Instant.parse("2026-03-29T22:30:00Z")

        val window = stressLocalDayWindowContaining(instant.epochSecond, berlin)

        assertEquals(LocalDate.of(2026, 3, 30), window.day)
        assertEquals(Instant.parse("2026-03-29T22:00:00Z").epochSecond, window.fromEpochSecond)
    }
}
