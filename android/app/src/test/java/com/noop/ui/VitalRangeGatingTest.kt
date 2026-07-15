package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Range-chip gating for the Vital Signs detail (#943, ryanbr). filterVitalPoints windows off the
 * LATEST reading, so with short history every window returns the same full point set and all the
 * chips drew byte-identical charts. A range only shows something NEW once the data span EXCEEDS the
 * previous range's window, so the unlocked chips form a contiguous prefix with W always available
 * (a calibrating user is never stranded with zero ranges). These pin the unlock boundaries: n daily
 * points span n-1 days, so a range unlocks at span > 7 / 14 / 21 / 30 / 90 / 180; W and ALL are
 * never gated (Swift parity). The 1D/2D experiment was dropped — daily metrics hold at most one
 * point per day, so those windows could never draw a line.
 */
class VitalRangeGatingTest {

    private fun dailyPoints(count: Int, start: String = "2026-01-01"): List<Pair<String, Double>> {
        val first = java.time.LocalDate.parse(start)
        return (0 until count).map { first.plusDays(it.toLong()).toString() to 60.0 + it }
    }

    // ── span math ───────────────────────────────────────────────────────────────

    @Test fun spanIsLastMinusFirstInEpochDays() {
        assertEquals(9L, vitalHistorySpanDays(dailyPoints(10)))
        assertEquals(0L, vitalHistorySpanDays(dailyPoints(1)))
        assertEquals(0L, vitalHistorySpanDays(emptyList()))
    }

    @Test fun unparseableBoundsFallBackToZeroSpan() {
        assertEquals(0L, vitalHistorySpanDays(listOf("garbage" to 60.0, "2026-01-09" to 61.0)))
        assertEquals(0L, vitalHistorySpanDays(listOf("2026-01-01" to 60.0, "garbage" to 61.0)))
    }

    @Test fun gapsCountTowardTheSpan() {
        // Two points 60 days apart span 60 even though only 2 readings exist.
        val sparse = listOf("2026-01-01" to 60.0, "2026-03-02" to 61.0)
        assertEquals(60L, vitalHistorySpanDays(sparse))
    }

    // ── unlock boundaries (contiguous prefix, W unconditional) ──────────────────

    @Test fun weekIsAlwaysUnlocked() {
        assertEquals(listOf(VitalDetailRange.WEEK, VitalDetailRange.ALL), unlockedVitalRanges(0L))
    }

    @Test fun twoWeekUnlocksWhenSpanExceedsAWeek() {
        assertEquals(listOf(VitalDetailRange.WEEK, VitalDetailRange.ALL), unlockedVitalRanges(7L))
        assertEquals(
            listOf(VitalDetailRange.WEEK, VitalDetailRange.TWO_WEEK, VitalDetailRange.ALL),
            unlockedVitalRanges(8L),
        )
    }

    @Test fun threeWeekUnlocksWhenSpanExceedsTwoWeeks() {
        assertEquals(3, unlockedVitalRanges(14L).size)
        assertEquals(
            listOf(
                VitalDetailRange.WEEK, VitalDetailRange.TWO_WEEK, VitalDetailRange.THREE_WEEK,
                VitalDetailRange.ALL,
            ),
            unlockedVitalRanges(15L),
        )
    }

    @Test fun monthUnlocksWhenSpanExceedsThreeWeeks() {
        assertEquals(4, unlockedVitalRanges(21L).size)
        assertEquals(
            listOf(
                VitalDetailRange.WEEK, VitalDetailRange.TWO_WEEK, VitalDetailRange.THREE_WEEK,
                VitalDetailRange.MONTH, VitalDetailRange.ALL,
            ),
            unlockedVitalRanges(22L),
        )
    }

    @Test fun threeMonthUnlocksWhenSpanExceedsAMonth() {
        assertEquals(5, unlockedVitalRanges(30L).size)
        assertEquals(6, unlockedVitalRanges(31L).size)
    }

    @Test fun sixMonthUnlocksWhenSpanExceedsThreeMonths() {
        assertEquals(6, unlockedVitalRanges(90L).size)
        assertEquals(7, unlockedVitalRanges(91L).size)
    }

    @Test fun yearUnlocksWhenSpanExceedsSixMonths() {
        assertEquals(7, unlockedVitalRanges(180L).size)
        assertEquals(8, unlockedVitalRanges(181L).size)
    }

    @Test fun allUnlocksWhenSpanExceedsAYear() {
        assertEquals(VitalDetailRange.entries.toList(), unlockedVitalRanges(365L))
        assertEquals(VitalDetailRange.entries.toList(), unlockedVitalRanges(366L))
    }

    @Test fun largestUnlockedRangeIsTheCoercionTarget() {
        // A locked selection coerces DOWN to the largest unlocked range with a real finite window
        // that is <= the selection (never ALL), matching Swift's coercedSelection.
        val span3 = unlockedVitalRanges(3L)   // W + ALL only
        assertEquals(VitalDetailRange.WEEK, coercedVitalRange(VitalDetailRange.MONTH, span3))
        assertEquals(VitalDetailRange.WEEK, coercedVitalRange(VitalDetailRange.YEAR, span3))
        val span16 = unlockedVitalRanges(16L)  // W + 2W + 3W + ALL
        assertEquals(VitalDetailRange.THREE_WEEK, coercedVitalRange(VitalDetailRange.YEAR, span16))
        // An unlocked selection is kept verbatim; ALL is always selectable.
        assertEquals(VitalDetailRange.WEEK, coercedVitalRange(VitalDetailRange.WEEK, span3))
        assertEquals(VitalDetailRange.ALL, coercedVitalRange(VitalDetailRange.ALL, span3))
    }

    // ── the gating rule really is the identical-window dedup rule ───────────────

    @Test fun lockedRangeWouldHaveDrawnTheSamePointsAsItsPredecessor() {
        // 10 daily points, span 9: W (7 points) differs from 2W (all 10), so 2W is unlocked;
        // 3W returns the identical set as 2W, so 3W is locked.
        val points = dailyPoints(10)
        val unlocked = unlockedVitalRanges(vitalHistorySpanDays(points))
        assertEquals(
            listOf(VitalDetailRange.WEEK, VitalDetailRange.TWO_WEEK, VitalDetailRange.ALL),
            unlocked,
        )
        assertEquals(7, filterVitalPoints(points, VitalDetailRange.WEEK).size)
        assertEquals(10, filterVitalPoints(points, VitalDetailRange.TWO_WEEK).size)
        assertEquals(
            filterVitalPoints(points, VitalDetailRange.TWO_WEEK),
            filterVitalPoints(points, VitalDetailRange.THREE_WEEK),
        )
    }

    @Test fun filterWindowsOffTheLatestReadingInclusive() {
        // The WEEK window is latestDate-6..latestDate, so exactly the last 7 daily points survive.
        val points = dailyPoints(30)
        val week = filterVitalPoints(points, VitalDetailRange.WEEK)
        assertEquals(7, week.size)
        assertEquals(points.takeLast(7), week)
        // The new 3W window: the last 21 daily points.
        assertEquals(21, filterVitalPoints(points, VitalDetailRange.THREE_WEEK).size)
    }
}
