package com.noop.ui

import com.noop.analytics.StagePercentages
import com.noop.ui.forge.SleepSummary
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The Forge sleep lanes take their percentage from ONE apportionment over the four stages, in the input
 * order every surface uses, so they sum to 100 and read the same number as the figures beside them.
 * Rounding each lane on its own (`minutes * 100 / inBed`) lost a point on a night like the second case
 * here. Twin of the Apple `StageSharePercentTests`. (Refs ryanbr/noop#2927)
 */
class ForgeStageLaneSharesTest {
    private fun shares(minutes: Map<String, Int>): List<Int> {
        val p = StagePercentages.wholePercentages(
            SleepSummary.stages.map { (minutes[it] ?: 0).toDouble() },
        )!!
        return SleepSummary.stages.map { p[SleepSummary.stages.indexOf(it)] }
    }

    @Test
    fun theLanesComeFromOneApportionmentAndSumTo100() {
        val minutes = mapOf("wake" to 25, "light" to 210, "deep" to 78, "rem" to 107)
        val s = shares(minutes)
        assertEquals(listOf(6, 50, 19, 25), s)
        assertEquals(100, s.sum())
    }

    @Test
    fun whereRoundingEachLaneOnItsOwnDisagrees() {
        val minutes = mapOf("wake" to 5, "light" to 5, "deep" to 5, "rem" to 2)
        assertEquals(listOf(30, 29, 29, 12), shares(minutes))
        val inBed = 17
        val alone = SleepSummary.stages.map { Math.round((minutes[it] ?: 0) * 100f / inBed) }
        assertEquals(listOf(29, 29, 29, 12), alone)
        assertEquals(99, alone.sum())
    }

    @Test
    fun theInputOrderMatchesApple() {
        assertEquals(listOf("wake", "light", "deep", "rem"), SleepSummary.stages)
    }
}
