package com.noop.ui

import com.noop.analytics.Baselines
import com.noop.data.DailyMetric
import java.time.LocalDate
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for [recoveryCalibrationNights], the pure helper behind the Today recovery cold-start
 * "Calibrating — N of 4 nights" affordance. Recovery is null until the HRV baseline crosses the seed
 * gate (Baselines.minNightsSeed valid nights); this surfaces honest progress instead of "No Data". N
 * is the HRV baseline's real `nValid` from folding the SAME day-keyed, epoch-aware history the recovery
 * engine folds. Mirrors the Swift RecoveryCalibrationTests case-for-case.
 */
class RecoveryCalibrationTest {

    private val seed = Baselines.minNightsSeed // 4

    private fun day(d: String, hrv: Double?) = DailyMetric(deviceId = "my-whoop-noop", day = d, avgHrv = hrv)

    /** The UTC day-start epoch (seconds) for a "yyyy-MM-dd" key, computed exactly as
     *  [Baselines.foldHistory] does, so a test epoch lands on a real night boundary. */
    private fun epoch(dayKey: String): Double =
        LocalDate.parse(dayKey).atStartOfDay(ZoneOffset.UTC).toEpochSecond().toDouble()

    /** Call helper pinning `hrvBaselineEpoch = 0.0` (no recalibration → plain fold). */
    private fun nights(days: List<DailyMetric>, hasRecovery: Boolean): Int? =
        recoveryCalibrationNights(days, hasRecovery = hasRecovery, hrvBaselineEpoch = 0.0)

    @Test
    fun nullWhenRecoveryAlreadyExists() {
        val days = listOf(day("2026-01-01", 55.0), day("2026-01-02", 60.0))
        assertNull(nights(days, hasRecovery = true))
    }

    @Test
    fun zeroWhenNoNightHasHrvYet() {
        // Brand-new user (no valid HRV nights yet) → 0, so Charge reads "Calibrating — 0 of N"
        // rather than a bare "No data" (#335).
        val days = listOf(day("2026-01-01", null), day("2026-01-02", null))
        assertEquals(0, nights(days, hasRecovery = false))
    }

    @Test
    fun countsNightsCarryingHrvBelowSeed() {
        val days = listOf(day("2026-01-01", 55.0), day("2026-01-02", null), day("2026-01-03", 61.0))
        assertEquals(2, nights(days, hasRecovery = false))
    }

    @Test
    fun oneNightReportsOne() {
        assertEquals(1, nights(listOf(day("2026-01-01", 58.0)), hasRecovery = false))
    }

    @Test
    fun nullAtOrAboveSeed_doesNotClaimCalibrating() {
        // At/above the seed gate, the baseline should be usable; if recovery is still null it's some
        // other gap, so we must NOT show a misleading "calibrating 4 of 4".
        val days = (1..seed).map { day("2026-01-0$it", 55.0 + it) }
        assertNull(nights(days, hasRecovery = false))
    }

    @Test
    fun ignoresNullHrvNights() {
        val days = listOf(
            day("2026-01-01", 55.0), day("2026-01-02", null),
            day("2026-01-03", null), day("2026-01-04", 60.0),
        )
        assertEquals(2, nights(days, hasRecovery = false))
    }

    @Test
    fun ignoresOutOfRangeHrvNights() {
        // A physiologically implausible avgHrv (outside the HRV config bounds 5..250) does NOT advance
        // the recovery seed in Baselines.update, so it must not be counted here either — only the
        // in-range night does. Keeps the displayed N in step with the real nValid.
        val days = listOf(
            day("2026-01-01", 55.0),    // valid
            day("2026-01-02", 4.0),     // below minVal (5.0) → not a seed night
            day("2026-01-03", 999.0),   // above maxVal (250.0) → not a seed night
        )
        assertEquals(1, nights(days, hasRecovery = false))
    }

    // Bug B (#393 follow-up): recalibration must not strand a calibrating user on "Needs the strap".

    @Test
    fun recalibrationDropsPreEpochNights_soNTracksTheRealBaseline() {
        // Six in-range nights, then a manual "Recalibrate HRV baseline" epoch dated 2026-01-05: the
        // engine's fold DROPS the four pre-epoch nights, so the real nValid is the 2 post-epoch nights.
        // The old per-night bounds count was 6 (>= seed) and returned null, stranding the score side on
        // "Needs the strap"; N must now read 2 (a genuinely-calibrating baseline).
        val days = (1..6).map { day("2026-01-0$it", 55.0) }
        assertEquals(2, recoveryCalibrationNights(days, hasRecovery = false, hrvBaselineEpoch = epoch("2026-01-05")))
    }

    @Test
    fun recalibrationLeavingSeededBaseline_stillReturnsNull() {
        // If enough post-epoch nights remain to cross the seed gate, the baseline is usable again and a
        // null recovery is some OTHER gap — so we must not claim "calibrating". Epoch 2026-01-02 drops one
        // night; five post-epoch nights → nValid 5.
        val days = (1..6).map { day("2026-01-0$it", 55.0) }
        assertNull(recoveryCalibrationNights(days, hasRecovery = false, hrvBaselineEpoch = epoch("2026-01-02")))
    }
}
