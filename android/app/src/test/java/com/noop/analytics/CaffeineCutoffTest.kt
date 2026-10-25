package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the PR#566 caffeine cutoff-window math added to [CaffeineDecay] — the latest caffeine time before
 * bed and the "this intake is past the cutoff" test. Pure (no android.*); the cross-platform contract is
 * that the Swift twin in CaffeineLog.swift returns the same numbers. The cutoff is just a reframing of the
 * existing half-life decay, so the honest framing ("a guide, not a rule") carries over from the model.
 */
class CaffeineCutoffTest {

    private val hl = CaffeineDecay.DEFAULT_HALF_LIFE_HOURS // 5.5 h

    // MARK: - cutoffLeadHours

    @Test fun leadIsTwoHalfLivesForQuarterResidual() {
        // Default residual is 0.25 → exactly two half-lives of lead.
        assertEquals(2 * hl, CaffeineDecay.cutoffLeadHours(), 1e-9)
    }

    @Test fun lowerResidualPushesCutoffEarlier() {
        // Wanting LESS on board by bed (1/8) needs a LONGER lead (three half-lives).
        assertEquals(3 * hl, CaffeineDecay.cutoffLeadHours(targetResidualFraction = 0.125), 1e-9)
    }

    // MARK: - cutoffMinutesSinceMidnight

    @Test fun cutoffIsBedtimeMinusLead() {
        // Bedtime 23:00 (1380), lead 11 h → cutoff 12:00 (720).
        val bed = 23 * 60
        val expected = bed - (2 * hl * 60).toInt() // 1380 - 660 = 720
        assertEquals(expected, CaffeineDecay.cutoffMinutesSinceMidnight(bed))
    }

    @Test fun earlyBedtimeWrapsToPreviousEvening() {
        // Bedtime 09:00 (540): cutoff at 540 - 660 = -120 → normalised to 22:00 (1320) the prior evening.
        val cutoff = CaffeineDecay.cutoffMinutesSinceMidnight(9 * 60)
        assertEquals(1320, cutoff)
        assertTrue(cutoff in 0 until 1440)
    }

    // MARK: - isPastCutoff

    @Test fun morningCoffeeIsNotLate() {
        // 08:00 intake, 23:00 bedtime, cutoff 12:00 → not past.
        assertFalse(CaffeineDecay.isPastCutoff(intakeMinutes = 8 * 60, bedtimeMinutes = 23 * 60))
    }

    @Test fun lateAfternoonCoffeeIsLate() {
        // 16:00 intake, 23:00 bedtime, cutoff 12:00 → past.
        assertTrue(CaffeineDecay.isPastCutoff(intakeMinutes = 16 * 60, bedtimeMinutes = 23 * 60))
    }

    @Test fun intakeExactlyAtCutoffIsNotLate() {
        // At the cutoff itself the dose decays to exactly the target by bed — not "more than", so not late.
        val bed = 23 * 60
        val cutoffRaw = bed - (2 * hl * 60).toInt() // 720
        assertFalse(CaffeineDecay.isPastCutoff(intakeMinutes = cutoffRaw, bedtimeMinutes = bed))
        assertTrue(CaffeineDecay.isPastCutoff(intakeMinutes = cutoffRaw + 1, bedtimeMinutes = bed))
    }

    @Test fun earlyBedtimeMakesAnySameDayIntakeLate() {
        // Bedtime 09:00 → raw cutoff is negative (prior evening), so any positive same-day intake is late.
        assertTrue(CaffeineDecay.isPastCutoff(intakeMinutes = 7 * 60, bedtimeMinutes = 9 * 60))
    }
}
