package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId
import java.time.ZonedDateTime

/**
 * "Last night" names only the night that woke on today's logical day (design critique 2026-11-28). Twin of
 * iOS `LastNightLabelTests`: the newest stored night is older while the strap has not synced, and the Sleep
 * tab called it "Last night" right under a banner waiting for last night.
 */
class LastNightTest {
    private val zone = ZoneId.of("Europe/Berlin")
    private fun at(d: Int, h: Int, m: Int = 0) = ZonedDateTime.of(2026, 11, d, h, m, 0, 0, zone)

    @Test
    fun aNightThatWokeThisMorningIsLastNight() {
        assertTrue(isLastNight(at(28, 7, 15).toEpochSecond(), now = at(28, 14)))
    }

    @Test
    fun theNightBeforeIsNotLastNight() {
        // Saturday afternoon, the newest stored night woke on Friday: the strap has not synced yet.
        assertFalse(isLastNight(at(27, 7, 37).toEpochSecond(), now = at(28, 14)))
    }

    @Test
    fun inTheSmallHoursYesterdaysNightIsStillLastNight() {
        // 01:30 on Sunday is still Saturday's logical day, so Saturday morning's night stays last night.
        assertTrue(isLastNight(at(28, 7, 15).toEpochSecond(), now = at(29, 1, 30)))
        assertFalse(isLastNight(at(28, 7, 15).toEpochSecond(), now = at(29, 4, 30)))
    }

    @Test
    fun aWakeBeforeTheRolloverCountsForItsCalendarDay() {
        assertTrue(isLastNight(at(28, 3).toEpochSecond(), now = at(28, 20)))
    }
}
