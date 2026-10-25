package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Kotlin parity for StrandAnalytics/SleepDebtTests.swift — same vectors, same results. */
class SleepDebtTest {

    @Test
    fun onTarget_netsToZero() {
        val series = listOf(
            "2026-06-01" to 480.0, "2026-06-02" to 480.0, "2026-06-03" to 480.0,
        )
        val l = SleepDebt.ledger(series, needHours = 8.0)
        assertEquals(0.0, l.balanceMin, 1e-9)
        assertEquals(3, l.nightCount)
        assertFalse(l.isDebt)
        assertEquals(480.0, l.needMin, 1e-9)
    }

    @Test
    fun debtCarriesAtFiftyFivePercentAndSurplusDoesNotBank() {
        val series = listOf(
            "2026-06-01" to 360.0,   // −120
            "2026-06-02" to 540.0,   // +60
            "2026-06-03" to 420.0,   // −60
        )
        val l = SleepDebt.ledger(series, needHours = 8.0)
        // debt: 66 after night 1; the target-met second night clears it; night 3 leaves 33.
        assertEquals(-33.0, l.balanceMin, 1e-9)
        assertTrue(l.isDebt)
        assertEquals(33.0, l.magnitudeMin, 1e-9)
        assertEquals(listOf(-120.0, 60.0, -60.0), l.nights.map { it.deltaMin })
    }

    @Test
    fun skipsNoDataNights() {
        val series = listOf<Pair<String, Double?>>(
            "2026-06-01" to 480.0,
            "2026-06-02" to null,     // skipped
            "2026-06-03" to 0.0,      // skipped (non-positive)
            "2026-06-04" to 420.0,    // −60
        )
        val l = SleepDebt.ledger(series, needHours = 8.0)
        assertEquals(2, l.nightCount)
        assertEquals(-33.0, l.balanceMin, 1e-9)
        assertEquals(listOf("2026-06-01", "2026-06-04"), l.nights.map { it.day })
    }

    @Test
    fun windowCap_keepsMostRecent() {
        val series = (1..16).map { String.format("2026-06-%02d", it) to (420.0 as Double?) }
        val l = SleepDebt.ledger(series, needHours = 8.0, window = 14)
        assertEquals(14, l.nightCount)
        assertEquals(-73.3, l.balanceMin, 1e-9) // converges instead of stacking 14 × −60
        assertEquals("2026-06-03", l.nights.first().day)
        assertEquals("2026-06-16", l.nights.last().day)
    }

    @Test
    fun emptyLedger() {
        val l = SleepDebt.ledger(emptyList())
        assertEquals(0.0, l.balanceMin, 1e-9)
        assertEquals(0, l.nightCount)
        assertTrue(l.nights.isEmpty())

        val allNull = listOf<Pair<String, Double?>>("2026-06-01" to null)
        assertEquals(0, SleepDebt.ledger(allNull).nightCount)
    }

    @Test
    fun defaultNeed_isEightHours() {
        val l = SleepDebt.ledger(listOf("2026-06-01" to 420.0))
        assertEquals(RestScorer.defaultSleepNeedHours * 60.0, l.needMin, 1e-9)
        assertEquals(-33.0, l.balanceMin, 1e-9)
    }

    /** Main sleep stays canonical; separately-recorded nap sleep adds debt repayment credit. */
    @Test
    fun napMinutes_addDebtRepaymentCredit() {
        val credited = SleepDebt.creditedSleepMin(mainSleepMin = 392.0, napSleepMin = 48.0)
        assertEquals(440.0, credited!!, 1e-9)
        val l = SleepDebt.ledger(listOf("2026-06-01" to credited), needHours = 8.0)
        assertEquals(-22.0, l.balanceMin, 1e-9)
    }

    @Test
    fun calculatedDebtBelowTenMinutesClearsButExactlyTenRemains() {
        val below = SleepDebt.ledger(listOf("2026-06-01" to (480.0 - 9.9 / 0.55)), needHours = 8.0)
        val exact = SleepDebt.ledger(listOf("2026-06-01" to (480.0 - 10.0 / 0.55)), needHours = 8.0)
        assertEquals(0.0, below.balanceMin, 1e-9)
        assertEquals(-10.0, exact.balanceMin, 1e-9)
    }

    @Test
    fun meetingNeedIncludingCurrentDebtClearsItCompletely() {
        val l = SleepDebt.ledger(
            listOf("2026-06-01" to 360.0, "2026-06-02" to 546.0),
            needHours = 8.0,
        )
        assertEquals(0.0, l.balanceMin, 1e-9)
        assertFalse(l.isDebt)
    }

    @Test
    fun importedDebtIsVerbatimButDoesNotSeedFollowingFallback() {
        val values = SleepDebt.debtSeries(
            series = listOf("2026-06-01" to 420.0, "2026-06-02" to 480.0),
            needHours = 8.0,
            importedDebtMin = mapOf("2026-06-01" to 61.25),
        )
        assertEquals(61.25, values[0].second, 1e-9)
        assertEquals(18.2, SleepDebt.round1(values[1].second), 1e-9)
    }

    @Test
    fun debtSeriesRoundsLocalOutputsToTheLedgerSurfacePrecision() {
        val values = SleepDebt.debtSeries(
            series = listOf("2026-06-01" to 420.0, "2026-06-02" to 410.0),
            needHours = 8.0,
        )
        val ledger = SleepDebt.ledger(
            series = listOf("2026-06-01" to 420.0, "2026-06-02" to 410.0),
            needHours = 8.0,
        )
        assertEquals(56.7, values.last().second, 1e-9)
        assertEquals(ledger.magnitudeMin, values.last().second, 1e-9)
    }

    @Test
    fun importedOnlyGapDoesNotConsumeOneOfFourteenUsableNights() {
        val usable = (1..14).map { index ->
            String.format("2026-06-%02d", index) to (420.0 as Double?)
        }
        val series = usable.take(13) +
            listOf("2026-06-14-imported-only" to null) +
            usable.drop(13)
        val values = SleepDebt.debtSeries(
            series = series,
            needHours = 8.0,
            importedDebtMin = mapOf("2026-06-14-imported-only" to 91.25),
        )

        assertEquals(15, values.size)
        assertEquals(91.25, values[13].second, 1e-9)
        assertEquals(
            SleepDebt.ledger(usable, needHours = 8.0, window = 14).magnitudeMin,
            values.last().second,
            1e-9,
        )
    }

    @Test
    fun debtSeriesKeepsFullOutputHistoryAndRecomputesEachDayFromTrailingUsableWindow() {
        val series = (1..16).map { index ->
            String.format("2026-06-%02d", index) to ((390.0 + index) as Double?)
        }
        val values = SleepDebt.debtSeries(series, needHours = 8.0, window = 14)

        assertEquals(16, values.size)
        values.forEachIndexed { index, (day, debt) ->
            val expected = SleepDebt.ledger(
                series = series.take(index + 1),
                needHours = 8.0,
                window = 14,
            ).magnitudeMin
            assertEquals(day, series[index].first)
            assertEquals("per-day parity at $day", expected, debt, 1e-9)
        }
    }

    @Test
    fun napCredit_requiresMainSleepAndIgnoresNegativeNapMinutes() {
        assertNull(SleepDebt.creditedSleepMin(mainSleepMin = null, napSleepMin = 48.0))
        assertNull(SleepDebt.creditedSleepMin(mainSleepMin = 0.0, napSleepMin = 48.0))
        assertEquals(392.0, SleepDebt.creditedSleepMin(mainSleepMin = 392.0, napSleepMin = -10.0)!!, 1e-9)
    }

    /** round1 pinned directly (both signs + a non-tie + a larger tie), parity with Swift's
     *  testRound1HalfTiesAwayFromZero. */
    @Test
    fun round1_halfTiesAwayFromZero() {
        assertEquals(-0.1, SleepDebt.round1(-0.05), 1e-9)
        assertEquals(0.1, SleepDebt.round1(0.05), 1e-9)
        assertEquals(0.0, SleepDebt.round1(-0.04), 1e-9)
        assertEquals(-0.3, SleepDebt.round1(-0.25), 1e-9)
    }
}
