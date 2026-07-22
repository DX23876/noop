package com.noop.ui

import com.noop.data.SleepSession
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

/**
 * #699: [SleepConsistencyCard] iterated raw sessions directly, so a bridged night-tail fragment — already
 * folded into ONE night by the hero via [mainSleepGroup]/[mainSleepSpan] — still drew as its own low bar,
 * got counted as an extra "night", and skewed the bed/wake SD and consistency score. [consistencyNightSpans]
 * is the fix: group by local wake-day (the same key [navDays] uses), then resolve each day through the SAME
 * bridged selector the hero uses, so naps and night-tail fragments are handled identically everywhere.
 */
class ConsistencyNightSpansTest {

    private val saved: TimeZone = TimeZone.getDefault()

    @Before fun setUtc() { TimeZone.setDefault(TimeZone.getTimeZone("UTC")) }

    @After fun restore() { TimeZone.setDefault(saved) }

    private fun utc(y: Int, mo: Int, d: Int, h: Int, mi: Int): Long {
        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        cal.clear()
        cal.set(y, mo - 1, d, h, mi, 0)
        return cal.timeInMillis / 1000L
    }

    @Test
    fun nightTailFragmentFoldsIntoOneNightNotTwo() {
        // The #699 report: main night 23:43 -> 07:58, then a 68-min-gap morning fragment 09:06 -> 10:09,
        // both nap=false. The gap sits inside [GAP_BRIDGE_MAX_MIN, NIGHT_TAIL_BRIDGE_MAX_MIN) and the
        // fragment's onset is inside the overnight band, so the hero bridges them into one night.
        val main = SleepSession(deviceId = "my-whoop", startTs = utc(2026, 1, 9, 23, 43), endTs = utc(2026, 1, 10, 7, 58))
        val fragment = SleepSession(deviceId = "my-whoop", startTs = utc(2026, 1, 10, 9, 6), endTs = utc(2026, 1, 10, 10, 9))

        val spans = consistencyNightSpans(listOf(main, fragment))

        assertEquals("the fragment must fold into the main night, not stand as its own bar", 1, spans.size)
        assertEquals(main.effectiveStartTs to fragment.endTs, spans.single())
    }

    @Test
    fun aRealAfternoonNapIsDroppedNotCountedAsANight() {
        // Same main night, but the second block is a genuine afternoon nap hours later -- must NOT be
        // folded in, and must NOT count as a second "night" either.
        val main = SleepSession(deviceId = "my-whoop", startTs = utc(2026, 1, 9, 23, 30), endTs = utc(2026, 1, 10, 6, 30))
        val nap = SleepSession(deviceId = "my-whoop", startTs = utc(2026, 1, 10, 14, 0), endTs = utc(2026, 1, 10, 14, 45))

        val spans = consistencyNightSpans(listOf(main, nap))

        assertEquals("a genuine nap must not inflate the night count", 1, spans.size)
        assertEquals(main.effectiveStartTs to main.endTs, spans.single())
    }

    @Test
    fun takesOnlyTheTrailingLimitNights() {
        val nights = (0 until 20).map { i ->
            SleepSession(
                deviceId = "my-whoop",
                startTs = utc(2026, 1, 1, 23, 0) + i * 86_400L,
                endTs = utc(2026, 1, 2, 7, 0) + i * 86_400L,
            )
        }

        val spans = consistencyNightSpans(nights, limit = 14)

        assertEquals(14, spans.size)
        // Ascending by day (oldest first), so the LAST entry must be the most recent night.
        assertEquals(nights.last().endTs, spans.last().second)
    }
}
