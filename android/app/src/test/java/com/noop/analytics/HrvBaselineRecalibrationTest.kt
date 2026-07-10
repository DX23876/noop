package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.math.abs

/**
 * Parity mirror of the Swift BaselinesTests early-anchoring + recalibration cases (the HRV half of
 * the Reddit Charge report). Pins two behaviours:
 *
 *  1. Early-life anti-anchoring: artificially-high cold-start nights followed by genuine lower nights
 *     must converge toward reality in DAYS, not the ~2-3 weeks the old halfLifeB=14 EWMA took — and the
 *     genuine lower nights must NOT be rejected as hard outliers while the spread is still floor-tight.
 *     A settled baseline still rejects a wild one-off outlier (the gate is suspended only during early
 *     life, not disabled).
 *
 *  2. Manual recalibration: foldHistory(values, dayKeys, cfg, baselineEpoch) drops every night before
 *     the epoch (`noop.hrvBaselineEpoch`, epoch SECONDS) and re-seeds from the first on-or-after night.
 */
class HrvBaselineRecalibrationTest {

    private val hrvCfg = Baselines.metricCfg.getValue("hrv")

    // ── 1. Early-life anti-anchoring ────────────────────────────────────────────────────────────

    @Test
    fun earlyHighSeed_convergesQuickly() {
        // 3 high cold-start nights (~90ms) then the user's true ~54ms for a week.
        val vals: List<Double?> = listOf(90.0, 92.0, 88.0) + List(7) { 54.0 }
        val s = Baselines.foldHistory(vals, hrvCfg)
        assertTrue(
            "early-high seed should converge near the true value within ~1 week, got ${s.baseline}",
            s.baseline < 65.0,
        )
        val dev = Baselines.deviation(54.0, s)
        assertTrue(
            "a real night near the converged baseline shouldn't read as an extreme outlier, z=${dev.z}",
            abs(dev.z) < 2.0,
        )
    }

    @Test
    fun genuineLowerNights_notRejectedDuringSeed() {
        val seedHigh = Baselines.foldHistory(List(4) { 90.0 }, hrvCfg)
        val vals: List<Double?> = List(4) { 90.0 } + List(5) { 55.0 }
        val after = Baselines.foldHistory(vals, hrvCfg)
        assertTrue(
            "lower nights must be folded (baseline drops), not rejected as outliers",
            after.baseline < seedHigh.baseline - 15.0,
        )
    }

    @Test
    fun hardOutlier_stillRejectedOnceSettled() {
        // Enough varied nights to get past earlyAdaptNights AND lift spread off the floor.
        val vals = ArrayList<Double?>()
        for (i in 0 until 14) vals.add(50.0 + (i % 3).toDouble()) // 50/51/52 jitter
        val stable = Baselines.foldHistory(vals, hrvCfg)
        assertTrue(stable.nValid >= Baselines.earlyAdaptNights)
        vals.add(220.0) // wild outlier
        val after = Baselines.foldHistory(vals, hrvCfg)
        assertEquals(
            "a settled baseline should still reject a wild outlier",
            stable.baseline, after.baseline, 2.0,
        )
    }

    @Test
    fun earlyPath_noOpOnConstantSeries() {
        val s = Baselines.foldHistory(List(30) { 50.0 }, hrvCfg)
        assertEquals(50.0, s.baseline, 1e-6)
        assertEquals(hrvCfg.floorSpread, s.spread, 1e-9)
    }

    // ── 2. Manual recalibration epoch (noop.hrvBaselineEpoch) ───────────────────────────────────

    @Test
    fun recalibrateEpoch_reseedsFromEpoch() {
        val days = listOf(
            "2026-06-08", "2026-06-09", "2026-06-10", "2026-06-11", "2026-06-12", "2026-06-13",
            "2026-06-15", "2026-06-16", "2026-06-17", "2026-06-18", "2026-06-19", "2026-06-20",
        )
        val vals: List<Double?> = listOf(90.0, 91.0, 89.0, 90.0, 92.0, 88.0, 54.0, 55.0, 53.0, 54.0, 56.0, 54.0)
        val epoch = LocalDate.parse("2026-06-15").atStartOfDay(ZoneOffset.UTC).toEpochSecond().toDouble()

        val recalibrated = Baselines.foldHistory(vals, days, hrvCfg, epoch)
        assertEquals(6, recalibrated.nValid) // only the 6 post-epoch nights contribute
        assertEquals(54.0, recalibrated.baseline, 2.0)

        val notRecalibrated = Baselines.foldHistory(vals, days, hrvCfg, 0.0)
        assertTrue(notRecalibrated.baseline > recalibrated.baseline + 10.0)
    }

    @Test
    fun recalibrateEpoch_zeroIsNoOp() {
        val days = listOf("2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04")
        val vals: List<Double?> = listOf(60.0, 61.0, 59.0, 62.0)
        val withZero = Baselines.foldHistory(vals, days, hrvCfg, 0.0)
        val plain = Baselines.foldHistory(vals, hrvCfg)
        assertEquals(plain.baseline, withZero.baseline, 1e-9)
        assertEquals(plain.nValid, withZero.nValid)
    }

    @Test
    fun recalibrateEpoch_afterAllNights_resetsToColdStart() {
        val days = listOf("2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04")
        val vals: List<Double?> = listOf(60.0, 61.0, 59.0, 62.0)
        val s = Baselines.foldHistory(vals, days, hrvCfg, 4_000_000_000.0) // far-future epoch
        assertEquals(0, s.nValid)
        assertEquals(BaselineStatus.CALIBRATING, s.status)
    }

    // ── 2b. #201: HRV window switch re-folds instead of restarting calibration ───────────────────

    /**
     * #201: switching the HRV window re-scores the recent nights under the new window and folds the
     * baseline from them WITHOUT re-anchoring the epoch. An established user (≥ minNightsSeed valid
     * nights) keeps a usable baseline centered on the new (here lower, deep-window) values immediately —
     * not a multi-night calibrating reset. Contrast [recalibrateEpoch_afterAllNights_resetsToColdStart],
     * the old window-switch behaviour that dropped every night to cold-start and read as "the deep-sleep
     * setting is broken" (#195). Parity twin of the Swift
     * testWindowSwitchRefoldStaysUsableWithoutEpochReset.
     */
    @Test
    fun windowSwitchRefold_staysUsableWithoutEpochReset() {
        // 21 recent nights, all re-scored under the new deep window → the lower deep-only value.
        val days = (1..21).map { "2026-06-%02d".format(it) }
        val deepVals: List<Double?> = List(21) { 48.0 }

        // #201 path: fold with no recalibration epoch → usable, centered on the new deep value.
        val refolded = Baselines.foldHistory(deepVals, days, hrvCfg, 0.0)
        assertTrue("established user keeps a usable baseline after a window switch", refolded.usable)
        assertEquals(48.0, refolded.baseline, 2.0)

        // Old behaviour: re-anchoring the epoch to "now" drops every re-scored night → calibrating.
        val reset = Baselines.foldHistory(deepVals, days, hrvCfg, 4_000_000_000.0)
        assertTrue("epoch reset drops all nights back to calibrating", !reset.usable)
        assertEquals(BaselineStatus.CALIBRATING, reset.status)
    }

    // ── 3. "Recalibrate Charge baseline" reset helper (writes BOTH epoch keys) ───────────────────

    /**
     * Minimal in-memory [android.content.SharedPreferences.Editor] double so this stays a pure-JVM
     * unit test (no Robolectric / Android runtime). Only the Long path the helper uses is real;
     * everything else is a no-op that returns `this` for chaining.
     */
    private class FakeEditor : android.content.SharedPreferences.Editor {
        val longs = HashMap<String, Long>()
        override fun putLong(key: String, value: Long) = apply { longs[key] = value }
        override fun putString(key: String?, value: String?) = this
        override fun putStringSet(key: String?, values: MutableSet<String>?) = this
        override fun putInt(key: String?, value: Int) = this
        override fun putFloat(key: String?, value: Float) = this
        override fun putBoolean(key: String?, value: Boolean) = this
        override fun remove(key: String?) = this
        override fun clear() = this
        override fun commit() = true
        override fun apply() {}
    }

    /** The reset helper must write now-seconds to BOTH epoch keys — the whole Charge build-up restarts. */
    @Test
    fun recalibrateRecoveryBaselines_writesBothEpochs() {
        val editor = FakeEditor()
        val now = 1_750_000_000L
        Baselines.recalibrateRecoveryBaselines(editor, now)
        assertEquals(now, editor.longs[Baselines.hrvBaselineEpochKey])
        assertEquals(now, editor.longs[Baselines.recoveryBaselineEpochKey])
    }

    /** End-to-end: after the reset moves the epoch, the SAME history (nothing deleted) re-anchors to the
     *  recent reality when folded with the written epoch. */
    @Test
    fun recalibrateRecoveryBaselines_reAnchorsNextComputation() {
        val days = listOf(
            "2026-06-08", "2026-06-09", "2026-06-10", "2026-06-11", "2026-06-12", "2026-06-13",
            "2026-06-15", "2026-06-16", "2026-06-17", "2026-06-18", "2026-06-19", "2026-06-20",
        )
        val vals: List<Double?> = listOf(90.0, 91.0, 89.0, 90.0, 92.0, 88.0, 54.0, 55.0, 53.0, 54.0, 56.0, 54.0)

        // Bad first week anchors the baseline high before any reset.
        val before = Baselines.foldHistory(vals, days, hrvCfg, 0.0)
        assertTrue(before.baseline > 70.0)

        // Tap Recalibrate at the start of 2026-06-15; read the epoch back out of the editor double.
        val editor = FakeEditor()
        val resetInstant = LocalDate.parse("2026-06-15").atStartOfDay(ZoneOffset.UTC).toEpochSecond()
        Baselines.recalibrateRecoveryBaselines(editor, resetInstant)
        val epoch = editor.longs.getValue(Baselines.hrvBaselineEpochKey).toDouble()

        val after = Baselines.foldHistory(vals, days, hrvCfg, epoch)
        assertEquals(6, after.nValid)            // only the 6 post-reset nights contribute
        assertEquals(54.0, after.baseline, 2.0)  // re-anchored to the real value
        assertTrue(after.baseline < before.baseline - 10.0)
    }
}
