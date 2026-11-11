package com.noop.ui.forge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate

/** The "What changed" rule, as iOS's `TrendsChangeSummary.row` reads it. */
class ChangeSummaryTest {
    private val today = LocalDate.parse("2026-11-11")
    private val hrv = ChangeSummary.measures.first { it.tile == com.noop.ui.KeyMetric.HRV }
    private val rhr = ChangeSummary.measures.first { it.tile == com.noop.ui.KeyMetric.RESTING_HR }
    private val effort = ChangeSummary.measures.first { it.tile == com.noop.ui.KeyMetric.EFFORT }

    /** Days 1…7 back carry [now], days 8…14 back [before]. */
    private fun weeks(before: Double, now: Double) =
        (1..14).associate { back -> today.minusDays(back.toLong() - 1).toString() to (if (back <= 7) now else before) }

    @Test fun aRiseOnAMeasureWhereHigherIsBetterIsBetter() {
        val row = ChangeSummary.row(hrv, weeks(60.0, 66.0), today, 7)!!
        assertEquals(0.1, row.change, 1e-9)
        assertEquals(ChangeSummary.Verdict.Better, row.verdict)
    }

    @Test fun aRiseInRestingHeartRateIsWorse() =
        assertEquals(ChangeSummary.Verdict.Worse, ChangeSummary.row(rhr, weeks(50.0, 55.0), today, 7)!!.verdict)

    @Test fun underTwoPercentHoldsSteady() =
        assertEquals(ChangeSummary.Verdict.Steady, ChangeSummary.row(hrv, weeks(100.0, 101.9), today, 7)!!.verdict)

    @Test fun aMeasureWithoutAGoodDirectionIsNeutral() =
        assertEquals(ChangeSummary.Verdict.Neutral, ChangeSummary.row(effort, weeks(10.0, 14.0), today, 7)!!.verdict)

    @Test fun eachSpanNeedsAThirdOfItsDays() {
        // One day in the recent span (a third of seven, at least two, is needed); the earlier span is full.
        val thin = weeks(60.0, 66.0).filterKeys { it <= today.minusDays(7).toString() || it == today.toString() }
        assertNull(ChangeSummary.row(hrv, thin, today, 7))
    }

    @Test fun headlineFollowsTheLargerSideAndNamesItsLargestMove() {
        val rows = ChangeSummary.rows(mapOf(hrv to weeks(60.0, 66.0), rhr to weeks(50.0, 49.0), effort to weeks(10.0, 10.0)), today, 7)
        val (head, top) = ChangeSummary.headline(rows)
        assertEquals(ChangeSummary.Head.Strong, head)
        assertEquals(hrv, top!!.measure)
    }
}
