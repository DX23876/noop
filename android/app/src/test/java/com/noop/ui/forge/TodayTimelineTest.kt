package com.noop.ui.forge

import com.noop.core.CoreRead
import com.noop.data.WorkoutRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

class TodayTimelineTest {
    private val zone = ZoneId.of("Europe/Berlin")
    private fun ts(day: Int, hour: Int, minute: Int = 0): Long =
        LocalDateTime.of(2026, 11, day, hour, minute).atZone(zone).toEpochSecond()

    private fun workout(start: Long, end: Long) = WorkoutRow(deviceId = "d", startTs = start, endTs = end,
                                                             sport = "Running", source = "strap")

    private fun night(start: Long, end: Long, minutes: Map<String, Double>? = null) =
        CoreRead.Night(start, end, null, null, null, false, emptyList(), minutes)

    @Test fun keepsTodayAndYesterdayNewestFirst() {
        val now = ts(9, 21)
        val entries = TodayTimeline.entries(
            workouts = listOf(workout(ts(9, 18), ts(9, 19)), workout(ts(8, 7), ts(8, 8)), workout(ts(7, 7), ts(7, 8))),
            nights = listOf(night(ts(8, 23), ts(9, 7), mapOf("deep" to 90.0, "rem" to 100.0, "light" to 250.0, "wake" to 20.0))),
            naps = emptyList(), now = now, zone = zone)
        assertEquals(listOf(ts(9, 19), ts(9, 7), ts(8, 8)), entries.map { it.endTs })
        val wake = entries[1] as TodayTimeline.Entry.Wake
        assertEquals(440.0, wake.asleepMinutes, 0.001)
        assertTrue(!wake.nap)
    }

    @Test fun leavesOutWhatEndsLaterAndTakesNapsFromTheCore() {
        val now = ts(9, 15)
        val entries = TodayTimeline.entries(
            workouts = listOf(workout(ts(9, 14), ts(9, 16))),
            nights = emptyList(),
            naps = listOf(CoreRead.Nap(ts(9, 13), ts(9, 14), 55.0), CoreRead.Nap(ts(9, 15, 30), ts(9, 16), 25.0)),
            now = now, zone = zone)
        assertEquals(1, entries.size)
        val nap = entries.single() as TodayTimeline.Entry.Wake
        assertTrue(nap.nap)
        assertEquals(55.0, nap.asleepMinutes, 0.001)
    }

    @Test fun aShortMainNightStaysTheNight() {
        // Two hours of sleep is a bad night, not a nap: only the core's pick decides (SleepNight.naps).
        val entries = TodayTimeline.entries(
            workouts = emptyList(),
            nights = listOf(night(ts(9, 4), ts(9, 6), mapOf("light" to 110.0))),
            naps = emptyList(), now = ts(9, 12), zone = zone)
        val wake = entries.single() as TodayTimeline.Entry.Wake
        assertTrue(!wake.nap)
        assertEquals(110.0, wake.asleepMinutes, 0.001)
    }

    @Test fun writesHoursAndMinutes() {
        assertEquals("7:26", TodayTimeline.hoursMinutes(446.0))
        assertEquals("0:05", TodayTimeline.hoursMinutes(4.6))
    }
}
