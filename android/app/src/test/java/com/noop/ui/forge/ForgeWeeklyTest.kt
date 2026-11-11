package com.noop.ui.forge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.DayOfWeek
import java.time.LocalDate

/** The weekly report's weeks and figures, as iOS's `ForgeWeekly`. */
class ForgeWeeklyTest {
    @Test fun theWeekAndTheOneBeforeStartOnTheTrainingWeeksFirstDay() {
        val (now, before) = ForgeWeekly.weeks(LocalDate.parse("2026-11-11"), DayOfWeek.MONDAY) { ForgeWeekly.DayValues() }
        assertEquals("2026-11-09", now.days.first()); assertEquals("2026-11-15", now.days.last())
        assertEquals("2026-11-02", before.days.first())
    }

    @Test fun onTheFirstDayTheReportIsAboutTheWeekThatEnded() {
        val (now, _) = ForgeWeekly.weeks(LocalDate.parse("2026-11-09"), DayOfWeek.MONDAY) { ForgeWeekly.DayValues() }
        assertEquals("2026-11-02", now.days.first())
    }

    @Test fun meansSkipMissingDaysAndTheBestDayIsTheHighest() {
        val (now, _) = ForgeWeekly.weeks(LocalDate.parse("2026-11-11"), DayOfWeek.MONDAY) { d ->
            when (d) { "2026-11-09" -> ForgeWeekly.DayValues(charge = 40.0); "2026-11-10" -> ForgeWeekly.DayValues(charge = 80.0); else -> ForgeWeekly.DayValues() }
        }
        assertEquals(60.0, now.mean { it.charge }!!, 1e-9)
        assertEquals(1, now.bestIndex { it.charge })
        assertNull(now.mean { it.steps })
    }
}
