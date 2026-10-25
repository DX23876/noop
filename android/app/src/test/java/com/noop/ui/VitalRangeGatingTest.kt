package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Range-chip gating for the Vital Signs detail (#943, ryanbr). filterVitalReadings windows off the
 * LATEST reading, so with short history every window returns the same full point set and all the
 * chips drew byte-identical charts. A range only shows something NEW once the data span EXCEEDS the
 * previous range's window, so the unlocked chips form a contiguous prefix with W always available
 * (a calibrating user is never stranded with zero ranges). These pin the unlock boundaries: n daily
 * points span n-1 days, so a range unlocks at span > 7 / 14 / 21 / 30 / 90 / 180; W and ALL are
 * never gated (Swift parity). The 1D/2D experiment was dropped — daily metrics hold at most one
 * point per day, so those windows could never draw a line.
 */
class VitalRangeGatingTest {

    private fun dailyReadings(count: Int, start: String = "2026-01-01"): List<VitalReading> {
        val first = java.time.LocalDate.parse(start)
        return (0 until count).map { VitalReading(first.plusDays(it.toLong()).toString(), 60.0 + it, "source-$it") }
    }

    private fun historySpan(readings: List<VitalReading>): Long =
        vitalHistorySpanDays(readings.map { it.day to it.value })

    // ── span math ───────────────────────────────────────────────────────────────

    @Test fun spanIsLastMinusFirstInEpochDays() {
        assertEquals(9L, historySpan(dailyReadings(10)))
        assertEquals(0L, historySpan(dailyReadings(1)))
        assertEquals(0L, historySpan(emptyList()))
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
        val readings = dailyReadings(10)
        val unlocked = unlockedVitalRanges(historySpan(readings))
        assertEquals(
            listOf(VitalDetailRange.WEEK, VitalDetailRange.TWO_WEEK, VitalDetailRange.ALL),
            unlocked,
        )
        assertEquals(7, filterVitalReadings(readings, VitalDetailRange.WEEK).size)
        assertEquals(10, filterVitalReadings(readings, VitalDetailRange.TWO_WEEK).size)
        assertEquals(
            filterVitalReadings(readings, VitalDetailRange.TWO_WEEK),
            filterVitalReadings(readings, VitalDetailRange.THREE_WEEK),
        )
    }

    @Test fun filterWindowsOffTheLatestReadingInclusive() {
        // The WEEK window is latestDate-6..latestDate, so exactly the last 7 daily points survive.
        val readings = dailyReadings(30)
        val week = filterVitalReadings(readings, VitalDetailRange.WEEK)
        assertEquals(7, week.size)
        assertEquals(readings.takeLast(7), week)
        // The new 3W window: the last 21 daily points.
        assertEquals(readings.takeLast(21), filterVitalReadings(readings, VitalDetailRange.THREE_WEEK))
    }

    @Test fun everyRangeKeepsTheExpectedDailyReadings() {
        val readings = dailyReadings(400)
        VitalDetailRange.entries.forEach { range ->
            val expected = range.days?.let { readings.takeLast(it.toInt()) } ?: readings
            assertEquals(expected, filterVitalReadings(readings, range))
        }
    }

    @Test fun sparseWindowUsesCalendarDaysAndRetainsSourceAndValue() {
        val readings = listOf(
            VitalReading("2026-01-01", 55.0, "old"),
            VitalReading("2026-01-23", 56.0, "before-cutoff"),
            VitalReading("2026-01-24", 57.0, "at-cutoff"),
            VitalReading("2026-01-29", 58.0, "apple-health"),
            VitalReading("2026-01-30", 59.0, "my-whoop-noop"),
        )
        assertEquals(readings.takeLast(3), filterVitalReadings(readings, VitalDetailRange.WEEK))
        assertEquals(readings, filterVitalReadings(readings, VitalDetailRange.ALL))
    }

    @Test fun invalidInteriorDateIsExcludedWhenLatestDateParses() {
        val readings = listOf(
            VitalReading("bad-day", 55.0, "unknown"),
            VitalReading("2026-01-30", 59.0, "my-whoop"),
        )
        assertEquals(readings.takeLast(1), filterVitalReadings(readings, VitalDetailRange.WEEK))
    }

    @Test fun invalidLatestDateFallsBackToReadingCount() {
        val readings = dailyReadings(10) + VitalReading("bad-day", 70.0, "unknown")
        assertEquals(readings.takeLast(7), filterVitalReadings(readings, VitalDetailRange.WEEK))
        assertEquals(readings, filterVitalReadings(readings, VitalDetailRange.ALL))
    }

    @Test fun emptyHistoryStaysEmptyInEveryRange() {
        VitalDetailRange.entries.forEach { range ->
            assertEquals(emptyList<VitalReading>(), filterVitalReadings(emptyList(), range))
        }
    }
}
