package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #259: on WHOOP 4.0 a long low-motion pre-onset stretch was over-staged as sleep, so the detected
 * block spanned a much wider window than the user actually slept. After a bed edit (or onset trim) the
 * raw was too sparse to re-stage, leaving those pre-onset segments in the stored stagesJSON. The daily
 * aggregate then summed the FULL window, making "asleep" exceed "time-in-bed" (the impossible
 * "6h41m asleep / 4h33m in bed" card). [SleepStageTotals.dailyAggregateHonoringEdits] now trims each
 * selected block's stages to its effective onset before summing. Byte-parity twin of the Swift test.
 */
class Issue259PreOnsetClampTest {

    private fun stages(start: Long, end: Long, stage: String): String =
        AnalyticsEngine.encodeStages(listOf(StageSegment(start = start, end = end, stage = stage)))!!

    @Test
    fun preOnsetStagesAreClampedSoAsleepNeverExceedsTimeInBed() {
        // Detected block staged as one contiguous 8h49m "light" span [0, 31740]; the user's EFFECTIVE
        // onset is 15300 (they actually slept from there, 4h34m). Before the fix the aggregate summed the
        // full 8h49m; after, the pre-onset half is dropped and asleep == the post-onset window.
        val startTs = 0L
        val onset = 15_300L            // effective onset — 4h15m after the (over-detected) start
        val end = 31_740L              // wake — 8h49m after the detected start
        val json = stages(startTs, end, "light")

        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = listOf(startTs to json),
            edited = mapOf(startTs to json),          // an edit is present (onset moved); stages not re-staged
            onsetByStart = mapOf(startTs to onset),
            offsetSec = 0L,
        )
        assertNotNull(r)

        val inBedMin = (end - onset) / 60.0           // 274 min — time-in-bed the card shows
        assertEquals("asleep is clamped to the post-onset window", inBedMin, r!!.sleep.totalSleepMin, 1e-6)
        assertTrue("asleep must never exceed time-in-bed (#259)", r.sleep.totalSleepMin <= inBedMin + 1e-6)
        // Guard: without the clamp this would be the full 8h49m (529 min).
        assertNotEquals("must not sum the pre-onset stretch", (end - startTs) / 60.0, r.sleep.totalSleepMin, 1e-6)
    }

    @Test
    fun nonEditedNightIsUnchangedByTheClamp() {
        // A normally-detected night whose onset equals its start: clamping to its own onset is a no-op, so
        // the aggregate is identical to before the fix (no regression for the common case).
        val startTs = 1_000L
        val end = 1_000L + 27_000L     // 7h30m
        val json = stages(startTs, end, "light")

        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = listOf(startTs to json),
            edited = emptyMap(),
            onsetByStart = mapOf(startTs to startTs),  // onset == start → clamp is a no-op
            offsetSec = 0L,
        )
        assertNotNull(r)
        assertEquals(27_000.0 / 60.0, r!!.sleep.totalSleepMin, 1e-6)
    }
}
