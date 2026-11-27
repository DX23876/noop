package com.noop.ble

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class NotifyDayStateCacheTest {

    private fun days(): List<DailyMetric> = (1..14).map { day ->
        DailyMetric(
            deviceId = "my-whoop",
            day = "2026-07-${day.toString().padStart(2, '0')}",
            recovery = day.toDouble(),
            strain = (day + 20).toDouble(),
        )
    }

    @Test
    fun emptyHistoryCannotProduceAnIllnessAlert() {
        var illnessCalls = 0
        val cache = NotifyDayStateCache {
            illnessCalls += 1
            "stale alert"
        }

        val state = cache.resolve(emptyList(), "2026-07-14", "2026-07-14", illnessEnabled = true)
        assertNull(state.illness)
        assertEquals(0, illnessCalls)
    }

    @Test
    fun liveTicksReuseDailyProjectionWhileInputsAreUnchanged() {
        var illnessCalls = 0
        val cache = NotifyDayStateCache {
            illnessCalls += 1
            "alert-$illnessCalls"
        }
        val days = days()

        val first = cache.resolve(days, "2026-07-14", "2026-07-14", illnessEnabled = true)
        repeat(1_000) {
            assertSame(first, cache.resolve(days, "2026-07-14", "2026-07-14", illnessEnabled = true))
        }

        assertEquals(1, illnessCalls)
        assertEquals(14.0, first.todayRecovery)
        assertEquals(14, first.widgetRecovery)
        assertEquals(34, first.widgetEffort)
    }

    @Test
    fun newRoomEmissionRefreshesEvenWhenRowsCompareEqual() {
        var illnessCalls = 0
        val cache = NotifyDayStateCache {
            illnessCalls += 1
            null
        }
        val firstDays = days()
        val secondDays = ArrayList(firstDays)

        val first = cache.resolve(firstDays, "2026-07-14", "2026-07-14", illnessEnabled = true)
        val second = cache.resolve(secondDays, "2026-07-14", "2026-07-14", illnessEnabled = true)

        assertNotSame(first, second)
        assertEquals(2, illnessCalls)
        assertSame(secondDays, second.days)
    }

    @Test
    fun preferenceChangeClearsIllnessWithoutWaitingForRoom() {
        var illnessCalls = 0
        val cache = NotifyDayStateCache {
            illnessCalls += 1
            "strained"
        }
        val days = days()

        val enabled = cache.resolve(days, "2026-07-14", "2026-07-14", illnessEnabled = true)
        val disabled = cache.resolve(days, "2026-07-14", "2026-07-14", illnessEnabled = false)

        assertEquals("strained", enabled.illness)
        assertNull(disabled.illness)
        assertEquals(1, illnessCalls)
    }

    @Test
    fun logicalDayRolloverRefreshesWithoutWaitingForRoom() {
        var illnessCalls = 0
        val cache = NotifyDayStateCache {
            illnessCalls += 1
            "alert-$illnessCalls"
        }
        val days = days()

        val before = cache.resolve(days, "2026-07-14", "2026-07-14", illnessEnabled = true)
        val after = cache.resolve(days, "2026-07-15", "2026-07-15", illnessEnabled = true)

        assertNotSame(before, after)
        assertEquals(14.0, before.todayRecovery)
        assertNull(after.todayRecovery)
        assertEquals("alert-1", before.illness)
        assertNull(after.illness)
        assertEquals(1, illnessCalls)
    }

    @Test
    fun unscoredToday_widgetRecoveryCarriesButEffortIsTodays() {
        val cache = NotifyDayStateCache { null }
        val days = listOf(
            DailyMetric(
                deviceId = "my-whoop", day = "2026-11-22", recovery = 80.57, strain = 44.08,
                totalSleepMin = 548.15, deepMin = 143.5, remMin = 109.1, lightMin = 295.55,
                efficiency = 0.9489, disturbances = 20,
            ),
            DailyMetric(
                deviceId = "my-whoop", day = "2026-11-23", recovery = null, strain = 0.0,
                totalSleepMin = 429.5, deepMin = 0.0, remMin = 6.5, lightMin = 423.0,
                efficiency = 0.9919, disturbances = 3,
            ),
        )

        val state = cache.resolve(days, "2026-11-23", "2026-11-23", illnessEnabled = false)

        assertNull(state.todayRecovery)
        assertEquals(81, state.widgetRecovery)   // carried Charge, labelled as last night by Today
        assertEquals(0, state.widgetEffort)      // TODAY's strain, not yesterday's 44
    }
}
