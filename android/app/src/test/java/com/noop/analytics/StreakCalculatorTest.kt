package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/** Mirrors StrandAnalyticsTests/StreakCalculatorTests.swift - same fixtures, same expected outputs. */
class StreakCalculatorTest {

    private val today = "2026-07-24"

    private fun expect(
        dayKeys: List<String>, qualified: List<Boolean>, current: Int, longest: Int,
        today: String = this.today,
    ) {
        assertEquals(
            StreakCalculator.Streaks(current, longest),
            StreakCalculator.streaks(dayKeys, qualified, today),
        )
    }

    @Test fun emptyHistory() = expect(emptyList(), emptyList(), 0, 0)

    @Test fun singleDayToday() = expect(listOf("2026-07-24"), listOf(true), 1, 1)

    @Test fun unbrokenRunEndingToday() = expect(
        listOf("2026-07-20", "2026-07-21", "2026-07-22", "2026-07-23", "2026-07-24"),
        List(5) { true }, 5, 5,
    )

    @Test fun gapResetsCurrentButKeepsLongest() = expect(
        listOf("2026-07-10", "2026-07-11", "2026-07-12", "2026-07-23", "2026-07-24"),
        List(5) { true }, 2, 3,
    )

    @Test fun todayNotYetScoredGrace() = expect(
        listOf("2026-07-21", "2026-07-22", "2026-07-23"), List(3) { true }, 3, 3,
    )

    @Test fun missedYesterdayAndTodayBreaksCurrent() = expect(
        listOf("2026-07-20", "2026-07-21", "2026-07-22"), List(3) { true }, 0, 3,
    )

    @Test fun duplicateDayKeysDeduped() =
        expect(listOf("2026-07-24", "2026-07-24"), listOf(true, true), 1, 1)

    @Test fun longestRunInTheMiddleOfHistory() = expect(
        listOf("2026-07-01", "2026-07-02", "2026-07-03", "2026-07-04", "2026-07-05",
            "2026-07-23", "2026-07-24"), List(7) { true }, 2, 5,
    )

    @Test fun unqualifiedDayBreaksTheRun() =
        expect(listOf("2026-07-22", "2026-07-23", "2026-07-24"), listOf(true, false, true), 1, 1)

    @Test fun mismatchedListLengthsUseThePairedPrefix() =
        expect(listOf("2026-07-24", "2026-07-23"), listOf(true), 1, 1)

    @Test fun unparseableTodayYieldsNoCurrentButKeepsLongest() =
        expect(listOf("2026-07-23", "2026-07-24"), listOf(true, true), 0, 2, today = "not-a-date")
}
