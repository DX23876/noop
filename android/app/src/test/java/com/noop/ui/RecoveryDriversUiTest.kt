package com.noop.ui

import com.noop.analytics.ChargeBaselines
import com.noop.analytics.ScoreConfidence
import com.noop.analytics.ChargeDriverLabel
import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the Today "What shaped it" wiring: [recoveryChargeDrivers] (scores against the Charge
 * baselines [ChargeBaselines.resolve] builds with the engine's rule, #2525, then defers to
 * RecoveryDrivers.chargeDrivers) and [chargeConfidenceTier] (surfaces the existing ScoreConfidence). Pure
 * JVM, no Robolectric. Mirrors the iOS chargeDrivers wiring tests.
 */
class RecoveryDriversUiTest {

    private fun day(
        d: String,
        hrv: Double? = 55.0,
        rhr: Int? = 55,
        resp: Double? = 15.0,
        recovery: Double? = null,
        efficiency: Double? = 0.9,
        sleepMin: Double? = 450.0,
        skinTempDevC: Double? = null,
    ) = DailyMetric(
        deviceId = "my-whoop-noop", day = d, avgHrv = hrv, restingHr = rhr, respRateBpm = resp,
        recovery = recovery, efficiency = efficiency, totalSleepMin = sleepMin, skinTempDevC = skinTempDevC,
    )

    /** The Charge baselines for own nights [days] (plus [imported]), anchored on [anchor]. */
    private fun resolved(
        days: List<DailyMetric>,
        anchor: String,
        imported: List<DailyMetric> = emptyList(),
        hrvEpoch: Double = 0.0,
    ) = ChargeBaselines.resolve(imported, days, anchor, hrvEpoch = hrvEpoch, recoveryEpoch = 0.0)

    private fun drivers(days: List<DailyMetric>, day: DailyMetric?, hrvEpoch: Double = 0.0) =
        recoveryChargeDrivers(resolved(days, day?.day ?: days.last().day, hrvEpoch = hrvEpoch), day)

    private fun tier(days: List<DailyMetric>, day: DailyMetric?, hrvEpoch: Double = 0.0) =
        chargeConfidenceTier(resolved(days, day?.day ?: days.last().day, hrvEpoch = hrvEpoch), day)

    /** A history long enough to make the HRV baseline usable, plus a scored "today". */
    private fun scoredHistory(): List<DailyMetric> {
        val past = (1..10).map { day("2026-01-%02d".format(it), hrv = 50.0 + (it % 3)) }
        val today = day("2026-01-20", hrv = 62.0, rhr = 51, resp = 15.0, recovery = 64.0, skinTempDevC = 0.2)
        return past + today
    }

    @Test fun scoredDayProducesDriverRows() {
        val days = scoredHistory()
        val rows = drivers(days, days.last())
        assertTrue("a usable baseline should yield driver rows", rows.isNotEmpty())
        val labels = rows.map { it.label }
        assertTrue(labels.contains(ChargeDriverLabel.HEART_RATE_VARIABILITY))
        assertTrue(labels.contains(ChargeDriverLabel.RESTING_HEART_RATE))
        // Skin-temp was supplied on the scored day, so its row is present.
        assertTrue(labels.contains(ChargeDriverLabel.SKIN_TEMPERATURE))
    }

    @Test fun coldStartHistoryProducesNoRows() {
        // Two nights only: the HRV baseline is not usable yet, so there are no honest drivers.
        val days = listOf(
            day("2026-01-01", hrv = 55.0),
            day("2026-01-02", hrv = 58.0, recovery = null),
        )
        assertTrue(drivers(days, days.last()).isEmpty())
    }

    @Test fun confidenceTierIsSurfaced() {
        val days = scoredHistory()
        // A scored day on a now-usable baseline surfaces a non-calibrating tier.
        val t = tier(days, days.last())
        assertTrue(t == ScoreConfidence.BUILDING || t == ScoreConfidence.SOLID)
        // A day with no recovery number surfaces CALIBRATING.
        assertEquals(ScoreConfidence.CALIBRATING, tier(days, day("2026-01-21", recovery = null)))
    }

    @Test fun nullDayProducesNoRows() {
        assertTrue(drivers(scoredHistory(), null).isEmpty())
        assertTrue("no baselines resolved yet means no rows", recoveryChargeDrivers(null, scoredHistory().last()).isEmpty())
    }

    // ---- #1988: the RHR row needs a USABLE resting-HR baseline ----------------------------------

    /**
     * A history with no banked resting HR folds to `foldHistory`'s synthetic midpoint (about 75 bpm),
     * which is nobody's resting HR. Scoring the RHR row against it moves a bar on a baseline the user
     * has never had, so the row must be absent. The HRV row still stands, since that baseline is real.
     *
     * The display day itself carries a reading, so this is specifically the BASELINE being unusable,
     * not the reading being missing.
     *
     * The gate is NOT in this file: `recoveryChargeDrivers` passes its fold on ungated and
     * `RecoveryDrivers.chargeDrivers` applies it (#1990). This pins the end of that path, the surface a
     * user actually sees, which nothing else covers. `scoredDayProducesDriverRows` above is the usable
     * -baseline half of the pair: it asserts the row IS present on a history that banks resting HR, so
     * the two together show the gate is not a blanket off. Deliberately not restated here.
     */
    @Test fun rhrRowIsAbsentWhenTheRestingHrBaselineIsNotUsable() {
        val history = (1..6).map { day("2026-01-0$it", rhr = null) }
        val today = day("2026-01-07", rhr = 55)
        val rows = drivers(history + today, today)
        val labels = rows.map { it.label }
        assertTrue("the HRV baseline is real, so its row must still be there",
            labels.contains(ChargeDriverLabel.HEART_RATE_VARIABILITY))
        assertFalse("no usable resting-HR baseline, so no RHR row: got $labels",
            labels.contains(ChargeDriverLabel.RESTING_HEART_RATE))
    }

    /** Epoch for a `yyyy-MM-dd` day key, UTC midnight, matching what Recalibrate writes. */
    private fun epochOf(day: String): Double =
        java.time.LocalDate.parse(day).atStartOfDay(java.time.ZoneOffset.UTC).toEpochSecond().toDouble()

    @Test fun driverBaselineHonoursTheRecalibrationEpoch() {
        // #2315: the reported shape. A history of low-HRV nights, then Recalibrate, then higher nights.
        // Folding the WHOLE history gives one baseline and folding from the epoch gives another, and the
        // headline uses the second. These rows must agree with the headline rather than with history.
        val old = (1..10).map { day("2026-01-%02d".format(it), hrv = 40.0) }
        val since = (11..20).map { day("2026-01-%02d".format(it), hrv = 70.0) }
        val today = day("2026-01-21", hrv = 72.0, recovery = 70.0)
        val days = old + since + today

        val wholeHistory = drivers(days, today, hrvEpoch = 0.0)
        val fromEpoch = drivers(days, today, hrvEpoch = epochOf("2026-01-11"))

        val hrvOf = { rows: List<com.noop.analytics.ChargeDriver> ->
            rows.first { it.label == ChargeDriverLabel.HEART_RATE_VARIABILITY }.baseline
        }
        val whole = hrvOf(wholeHistory)
        val recent = hrvOf(fromEpoch)
        assertTrue("both folds must produce an HRV row", whole != null && recent != null)
        assertTrue(
            "the epoch fold must discard the pre-recalibration nights, so its baseline sits higher " +
                "(whole=$whole, fromEpoch=$recent)",
            recent!! > whole!!,
        )
    }

    /** #2525: once the own nights are trusted on their own, the import no longer takes part in the baseline
     *  the headline is scored against, so the rows must not move with it either. Before #2525 the rows folded
     *  every imported night and could read a baseline the score never used. */
    @Test fun anImportTheHeadlineNoLongerUsesDoesNotMoveTheRows() {
        val own = (1..20).map { day("2026-01-%02d".format(it), hrv = 70.0 + (it % 3)) }
        val today = day("2026-01-21", hrv = 72.0, recovery = 70.0)
        // Inside the window and on the same days: only the handoff can keep it out of the baseline.
        val lowImport = (1..20).map { day("2026-01-%02d".format(it), hrv = 40.0).copy(deviceId = "my-whoop") }
        val alone = recoveryChargeDrivers(resolved(own + today, today.day), today)
        val withImport = recoveryChargeDrivers(resolved(own + today, today.day, imported = lowImport), today)
        assertEquals(alone.map { it.baseline }, withImport.map { it.baseline })
        assertEquals(alone.map { it.deltaPoints }, withImport.map { it.deltaPoints })
    }

    @Test fun theConfidenceTierUsesTheSameEpochAsTheDrivers() {
        // The tier is read off the baseline the ring rides. A post-Recalibrate history that is still
        // seeding must not be badged from a whole-history fold that looks fully trusted.
        // Two nights since Recalibrate plus today is three, under the four-night seed gate, so the
        // post-epoch baseline is not yet usable while the whole-history one looks fully trusted.
        val old = (1..20).map { day("2026-01-%02d".format(it), hrv = 45.0) }
        val since = (21..22).map { day("2026-01-%02d".format(it), hrv = 60.0) }
        val today = day("2026-01-23", hrv = 61.0, recovery = 66.0)
        val days = old + since + today
        val whole = tier(days, today, hrvEpoch = 0.0)
        val fromEpoch = tier(days, today, hrvEpoch = epochOf("2026-01-21"))
        assertEquals(ScoreConfidence.CALIBRATING, fromEpoch)
        assertFalse("the whole-history fold is what made these disagree", whole == fromEpoch)
    }
}
