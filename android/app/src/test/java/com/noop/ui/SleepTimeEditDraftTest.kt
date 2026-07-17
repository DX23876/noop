package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

class SleepTimeEditDraftTest {
    private val zone = ZoneId.of("UTC")

    private fun ts(y: Int, mo: Int, d: Int, h: Int, mi: Int): Long =
        LocalDateTime.of(y, mo, d, h, mi).atZone(zone).toEpochSecond()

    @Test
    fun splitNightCorrectionSavesOneFinalWindow() {
        val original = SleepTimeEditDraft(
            startTs = ts(2026, 7, 16, 0, 3),
            endTs = ts(2026, 7, 16, 1, 30),
        )

        val finalDraft = original
            .withBedCandidate(
                candidateBedTs = ts(2026, 7, 16, 0, 0),
                nowTs = ts(2026, 7, 16, 8, 0),
                zone = zone,
            )
            .withWakeTime(hour = 7, minute = 0, zone = zone)

        assertEquals(
            ts(2026, 7, 16, 0, 0) to ts(2026, 7, 16, 7, 0),
            finalDraft.validatedWindow(nowTs = ts(2026, 7, 16, 8, 0)),
        )
    }

    @Test
    fun crossMidnightBedAndWakeResolveAsOneNight() {
        val original = SleepTimeEditDraft(
            startTs = ts(2026, 7, 16, 1, 6),
            endTs = ts(2026, 7, 16, 5, 0),
        )

        val finalDraft = original
            .withBedCandidate(
                candidateBedTs = ts(2026, 7, 16, 23, 0),
                nowTs = ts(2026, 7, 16, 8, 0),
                zone = zone,
            )
            .withWakeTime(hour = 7, minute = 0, zone = zone)

        assertEquals(
            ts(2026, 7, 15, 23, 0) to ts(2026, 7, 16, 7, 0),
            finalDraft.validatedWindow(nowTs = ts(2026, 7, 16, 8, 0)),
        )
    }

    @Test
    fun wakeAtOrBeforeBedRollsToFollowingDay() {
        val draft = SleepTimeEditDraft(
            startTs = ts(2026, 7, 15, 23, 0),
            endTs = ts(2026, 7, 16, 5, 0),
        ).withWakeTime(hour = 22, minute = 30, zone = zone)

        assertEquals(ts(2026, 7, 16, 22, 30), draft.endTs)
    }

    @Test
    fun invalidIntermediateWindowCannotBeSaved() {
        val draft = SleepTimeEditDraft(
            startTs = ts(2026, 7, 16, 6, 0),
            endTs = ts(2026, 7, 16, 5, 0),
        )

        assertNull(draft.validatedWindow(nowTs = ts(2026, 7, 16, 8, 0)))
    }
}
