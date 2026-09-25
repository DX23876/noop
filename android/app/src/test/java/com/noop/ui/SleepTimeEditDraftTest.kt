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
            .withWakeCandidate(ts(2026, 7, 16, 7, 0))

        assertEquals(
            ts(2026, 7, 16, 0, 0) to ts(2026, 7, 16, 7, 0),
            finalDraft.validatedWindow(nowTs = ts(2026, 7, 16, 8, 0)),
        )
    }

    /** #2470: an evening bedtime corrected forward across midnight must keep the explicitly selected
     *  next-day date. Retaining the detected start's date would create a 28-hour window and disable Save. */
    @Test
    fun eveningBedtimeCanMoveForwardToWakeDay() {
        val original = SleepTimeEditDraft(
            startTs = ts(2026, 9, 24, 23, 0),
            endTs = ts(2026, 9, 25, 8, 0),
        )

        val corrected = original.withBedCandidate(
            candidateBedTs = ts(2026, 9, 25, 4, 0),
            nowTs = ts(2026, 9, 25, 12, 0),
            zone = zone,
        )

        assertEquals(ts(2026, 9, 25, 4, 0), corrected.startTs)
        assertEquals(
            ts(2026, 9, 25, 4, 0) to ts(2026, 9, 25, 8, 0),
            corrected.validatedWindow(nowTs = ts(2026, 9, 25, 12, 0)),
        )
    }

    @Test
    fun explicitWakeDateIsPreservedAfterBedCorrection() {
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
            .withWakeCandidate(ts(2026, 7, 18, 7, 0))

        assertEquals(ts(2026, 7, 15, 23, 0), finalDraft.startTs)
        assertEquals(ts(2026, 7, 18, 7, 0), finalDraft.endTs)
        assertNull(finalDraft.validatedWindow(nowTs = ts(2026, 7, 18, 8, 0)))
    }

    @Test
    fun explicitWakeBeforeBedRemainsInvalid() {
        val draft = SleepTimeEditDraft(
            startTs = ts(2026, 7, 16, 23, 0),
            endTs = ts(2026, 7, 17, 5, 0),
        ).withWakeCandidate(ts(2026, 7, 16, 22, 30))

        assertEquals(ts(2026, 7, 16, 22, 30), draft.endTs)
        assertNull(draft.validatedWindow(nowTs = ts(2026, 7, 17, 8, 0)))
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
