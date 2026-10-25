package com.noop.ui

import com.noop.analytics.CaffeineIntake
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.TimeZone

/**
 * Pins the local-time mapping the caffeine cutoff UI does on top of the pure [com.noop.analytics.CaffeineDecay]
 * math (PR#566, mvanhorn): an intake's epoch-seconds → minutes-since-LOCAL-midnight, and the "is this intake
 * past the cutoff" wrapper. Timezone is pinned to UTC so the wall-clock mapping is deterministic on any host.
 */
class CaffeineCutoffHelpersTest {

    private val saved = TimeZone.getDefault()

    @Before fun pinUtc() { TimeZone.setDefault(TimeZone.getTimeZone("UTC")) }
    @After fun restore() { TimeZone.setDefault(saved) }

    /** Epoch-seconds for a given UTC wall-clock minutes-of-day on 2026-06-21 (an arbitrary fixed date). */
    private fun atMinuteOfDay(minutes: Int): Long {
        // 2026-06-21T00:00:00Z = 1782777600 (days since epoch * 86400). Compute generically to avoid a
        // magic constant being wrong: build via Calendar in the pinned UTC zone.
        val cal = java.util.Calendar.getInstance().apply {
            clear()
            set(2026, java.util.Calendar.JUNE, 21, minutes / 60, minutes % 60, 0)
        }
        return cal.timeInMillis / 1000L
    }

    @Test fun localMinutesOfDayRoundTrips() {
        assertEquals(8 * 60, localMinutesOfDay(atMinuteOfDay(8 * 60)))
        assertEquals(16 * 60 + 30, localMinutesOfDay(atMinuteOfDay(16 * 60 + 30)))
        assertEquals(0, localMinutesOfDay(atMinuteOfDay(0)))
    }

    @Test fun morningIntakeIsNotPastCutoff() {
        val intake = CaffeineIntake(id = "a", atEpochSec = atMinuteOfDay(8 * 60), mg = null)
        assertFalse(isIntakePastCutoff(intake, bedtimeMinutes = 23 * 60))
    }

    @Test fun lateAfternoonIntakeIsPastCutoff() {
        val intake = CaffeineIntake(id = "b", atEpochSec = atMinuteOfDay(16 * 60), mg = 80.0)
        assertTrue(isIntakePastCutoff(intake, bedtimeMinutes = 23 * 60))
    }
}
