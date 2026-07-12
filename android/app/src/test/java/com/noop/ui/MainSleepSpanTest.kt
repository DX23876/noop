package com.noop.ui

import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #294: the Coupled view's bed-wake span and Today's HR-graph sleep band each invented their own pick
 * for "last night" instead of using the canonical bridged main-night resolver ([mainSleepGroup]) the
 * Sleep tab hero and the daily total already agree on. A night recorded as two stored fragments (a
 * brief mid-night wake, gap < [com.noop.analytics.SleepStageTotals.GAP_BRIDGE_MAX_MIN]) then showed a
 * DIFFERENT span on each screen: Coupled's old "freshest-ending block" pick and Today's old "longest
 * single block" pick both landed on the SECOND fragment alone, silently dropping the first fragment
 * from the reported bedtime. [mainSleepSpan] is the shared fix.
 */
class MainSleepSpanTest {

    private val fragment1 = SleepSession(
        deviceId = "my-whoop",
        startTs = 1_800_000_000L,                                    // onset
        endTs = 1_800_000_000L + 2 * 3600 + 14 * 60,                 // 2h14m asleep, then a brief wake
    )

    // A 20-minute mid-night wake -- well under GAP_BRIDGE_MAX_MIN (60 min) -- so this is ONE
    // interrupted night, not a nap followed by a separate main sleep.
    private val fragment2 = SleepSession(
        deviceId = "my-whoop",
        startTs = fragment1.endTs + 20 * 60,
        endTs = fragment1.endTs + 20 * 60 + 4 * 3600 + 41 * 60,      // 4h41m asleep, then wake
    )

    @Test
    fun bridgesBothFragmentsIntoOneSpan() {
        val span = mainSleepSpan(listOf(fragment1, fragment2))
        assertEquals(fragment1.effectiveStartTs to fragment2.endTs, span)
    }

    @Test
    fun oldFreshestEndingPickWouldHaveTruncatedTheNight() {
        // The bug this guards: picking by "latest endTs" alone (Coupled view's old heuristic) names
        // only the second fragment, silently dropping the first fragment of the night.
        val freshestEndingPick = listOf(fragment1, fragment2).maxByOrNull { it.endTs }!!
        val span = mainSleepSpan(listOf(fragment1, fragment2))!!
        assertTrue(span.first < freshestEndingPick.effectiveStartTs)
    }

    @Test
    fun oldLongestSingleBlockPickWouldHaveTruncatedTheNight() {
        // Today's old heuristic (longest single overlapping block) also names only the second
        // fragment here, since it out-lasts the first alone.
        val longestSinglePick = listOf(fragment1, fragment2).maxByOrNull { it.endTs - it.startTs }!!
        val span = mainSleepSpan(listOf(fragment1, fragment2))!!
        assertTrue(span.first < longestSinglePick.effectiveStartTs)
    }
}
