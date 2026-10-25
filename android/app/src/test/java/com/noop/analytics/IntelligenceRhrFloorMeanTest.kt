package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the RHR floor-vs-mean strap-log line (#691). The recurring "NOOP's resting HR reads LOWER than
 * my sleeping-HR app" reports are NOT a bug: NOOP's restingHr is the WHOOP-style FLOOR (the lowest
 * sustained 5-min in-bed level), whereas a "sleeping HR" app reports the night MEAN over the whole
 * asleep span. The mean always sits at-or-above the floor, so NOOP looking lower is by design. The
 * engine now logs BOTH per scored night so a report carries the proof. `rhrFloorMeanLogLine` is the
 * pure formatter the loop calls; it's tested directly. Mirrors the Swift `IntelligenceRhrFloorMeanTests`
 * so the two platforms log byte-identical lines.
 */
class IntelligenceRhrFloorMeanTest {

    @Test
    fun floorBelowMean_theReportedDiscrepancy() {
        // The exact shape of the reports: an in-bed stretch that dips to a 48 bpm floor but averages 55.
        val bpms = listOf(48, 50, 52, 55, 58, 60, 62) // mean = 55.0 → "55"
        val line = IntelligenceEngine.rhrFloorMeanLogLine("2026-06-12", 48, bpms)
        assertEquals(
            "rhr day=2026-06-12 floor=48 nightMean=55 inBedSamples=7 " +
                "(floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)",
            line,
        )
    }

    @Test
    fun meanRoundsToNearest() {
        // 50,51,52,54 → 207/4 = 51.75 → rounds to 52, matching Swift .rounded().
        val line = IntelligenceEngine.rhrFloorMeanLogLine("2026-06-13", 50, listOf(50, 51, 52, 54))
        assertTrue(line, line.contains("floor=50 nightMean=52 inBedSamples=4"))
    }

    @Test
    fun emptyInBed_meanIsNil() {
        // A banked floor but no HR sample fell inside a matched session: mean reads "nil", not 0, and
        // the line is still emitted so the night stays visible in the log.
        val line = IntelligenceEngine.rhrFloorMeanLogLine("2026-06-12", 47, emptyList())
        assertEquals(
            "rhr day=2026-06-12 floor=47 nightMean=nil inBedSamples=0 " +
                "(floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)",
            line,
        )
    }

    @Test
    fun floorNeverExceedsMean_byConstruction() {
        // Sanity on the framing: across any in-bed set the floor (a min over the same span) is <= the
        // mean, so NOOP's RHR can only read at-or-below a sleeping-HR-app's night mean.
        val bpms = listOf(44, 46, 49, 53, 57, 61)
        val mean = bpms.sum().toDouble() / bpms.size
        assertTrue(bpms.min().toDouble() <= mean)
    }

    @Test
    fun lineCarriesNoEmDash() {
        // House style: never an em-dash in shared text.
        val line = IntelligenceEngine.rhrFloorMeanLogLine("2026-06-12", 48, listOf(48, 60))
        assertFalse(line.contains("—"))
    }
}
