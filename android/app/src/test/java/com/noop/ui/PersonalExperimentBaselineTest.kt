package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Personal Experiment contrast, against the numbers the Swift suite pins
 * (`PersonalExperimentTests` in StrandAnalytics, the same cases): the baseline is the explicit NO days
 * before the start, never the silence next to them. The unanswered days sit AFTER the NO days here, so a
 * baseline that took "every day that is not a logged yes" would land on different days and a different
 * mean. (Refs #2923)
 */
class PersonalExperimentBaselineTest {
    private val outcomes = mapOf(
        "2026-11-01" to 60.0,   // answered NO
        "2026-11-02" to 80.0,   // answered NO
        "2026-11-03" to 10.0,   // never answered
        "2026-11-04" to 20.0,   // never answered
        "2026-11-05" to 90.0,   // start, logged YES
        "2026-11-06" to 100.0,  // logged YES
        "2026-11-07" to 30.0,   // inside the window, never answered
    )
    private val logged = setOf("2026-11-05", "2026-11-06")
    private val controls = setOf("2026-11-01", "2026-11-02")

    private fun mean(days: List<String>): Double? =
        days.mapNotNull { outcomes[it] }.takeIf { it.isNotEmpty() }?.average()

    @Test
    fun theBaselineIsExplicitNoDaysOnly() {
        val split = experimentDaySplit(
            outcomeDays = outcomes.keys,
            loggedDays = logged,
            controlDays = controls,
            startedDay = "2026-11-05",
            today = "2026-11-07",
            durationDays = 3,
            baselineDays = 2,
        )
        assertEquals(listOf("2026-11-01", "2026-11-02"), split.baseline)
        assertEquals(listOf("2026-11-05", "2026-11-06"), split.intervention)
        // The Swift suite's numbers, verbatim.
        assertEquals(70.0, mean(split.baseline)!!, 1e-9)
        assertEquals(95.0, mean(split.intervention)!!, 1e-9)
        assertEquals(25.0, mean(split.intervention)!! - mean(split.baseline)!!, 1e-9)
    }

    @Test
    fun noControlDaysMeansNoBaseline() {
        val split = experimentDaySplit(
            outcomeDays = outcomes.keys,
            loggedDays = logged,
            controlDays = emptySet(),
            startedDay = "2026-11-05",
            today = "2026-11-07",
            durationDays = 3,
            baselineDays = 2,
        )
        assertTrue(split.baseline.isEmpty())
        assertEquals(null, mean(split.baseline))
        assertEquals(95.0, mean(split.intervention)!!, 1e-9)
    }

    @Test
    fun theWindowFollowsTheDuration() {
        val sameDay = experimentDaySplit(
            outcomeDays = outcomes.keys,
            loggedDays = logged,
            controlDays = controls,
            startedDay = "2026-11-05",
            today = "2026-11-05",
            durationDays = 14,
            baselineDays = 7,
        )
        assertEquals(listOf("2026-11-05"), sameDay.intervention)
        assertEquals(listOf("2026-11-01", "2026-11-02"), sameDay.baseline)

        val capped = experimentDaySplit(
            outcomeDays = outcomes.keys,
            loggedDays = logged,
            controlDays = controls,
            startedDay = "2026-11-05",
            today = "2026-11-07",
            durationDays = 1,
            baselineDays = 7,
        )
        assertEquals(listOf("2026-11-05"), capped.intervention)
    }
}
