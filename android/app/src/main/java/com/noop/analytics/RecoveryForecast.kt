package com.noop.analytics

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/*
 * RecoveryForecast.kt — an evening estimate of TOMORROW-morning Charge.
 *
 * Faithful Kotlin mirror of StrandAnalytics/RecoveryForecast.swift. Keep the tunables,
 * the three signed adjustments, the band math, and the confidence tier byte-identical
 * to Swift — cross-platform parity is the contract.
 *
 * Pure, deterministic, DB-free. Given the recent Charge (recovery) history, the recent
 * Effort (strain) history, today's Effort, and how much sleep is planned / banked
 * tonight against the personal sleep need, this projects what tomorrow's Charge is
 * LIKELY to wake at — with an honest ± error band.
 *
 * This is an ESTIMATE, not a measurement. WHOOP's morning recovery is computed from
 * the NEXT night's HRV/RHR/respiration, none of which exist yet at the time this runs;
 * so this can only lean on the levers that ARE known tonight. It is a simple,
 * transparent weighting of three signed nudges around the recent Charge baseline —
 * NOT a learned model — so it stays explainable line by line.
 *
 * Model (all adjustments are signed points ADDED to the baseline mean Charge):
 *
 *   center = mean(recent Charge over the last ~baselineWindow days)
 *
 *   1. Strain debt  — today's Effort vs the recent average Effort. A harder-than-usual
 *      day suppresses tomorrow's Charge; an easier day lifts it a little.
 *      adj1 = -strainWeight * (todayEffort - meanEffort) / effortSpread   (clamped)
 *
 *   2. Sleep adequacy — planned/banked sleep tonight vs the personal sleep need.
 *      Falling short suppresses Charge; meeting or beating it is neutral-to-slightly-
 *      positive (sleeping far beyond need does not keep adding Charge).
 *      adj2 = sleepWeight * clamp(sleepHours/needHours - 1, -1, +0.25)
 *
 *   3. Mean reversion — if recent Charge has been trending, pull the projection a
 *      little back toward the baseline rather than extrapolating the streak.
 *      adj3 = -reversionWeight * recentSlopePerDay                          (clamped)
 *
 *   forecast = clamp(center + adj1 + adj2 + adj3, 0, 100)
 *
 * Error band: the recent day-to-day SD of Charge, floored at minBandPoints and
 * inflated when the baseline is thin (few nights).
 *
 * Gating: returns null unless there are at least minBaselineNights of recent Charge,
 * so a cold-start user never sees a fabricated number. The UI shows the card only when
 * this is non-null.
 */

/** An evening projection of tomorrow-morning Charge (recovery, 0–100). APPROXIMATE. */
data class RecoveryForecast(
    /** The point estimate of tomorrow-morning Charge, 0–100 (whole number). */
    val charge: Double,
    /** Symmetric ± error band on [charge], in Charge points (whole number). */
    val band: Double,
    /** Recent Charge baseline (mean) this projection is anchored to, 0–100. */
    val baseline: Double,
    /** Planned/banked sleep hours tonight that the projection assumed. */
    val plannedSleepHours: Double,
    /** Personal sleep need (hours) the adequacy term compared against. */
    val needHours: Double,
    /** Nights of recent Charge history backing the baseline (drives confidence). */
    val nights: Int,
    /** Per-score certainty tier (reuses the Charge/Effort/Rest confidence ladder). */
    val confidence: ScoreConfidence,
) {
    /** Low end of the band, clamped to [0, 100]. */
    val low: Double get() = max(0.0, charge - band)

    /** High end of the band, clamped to [0, 100]. */
    val high: Double get() = min(100.0, charge + band)
}

object RecoveryForecaster {

    // Tunables (documented, deterministic — NOT learned). Mirror Swift exactly.

    /** Trailing Charge nights used for the baseline mean / SD / slope. */
    const val baselineWindow: Int = 14

    /** Minimum recent Charge nights before a forecast is offered (else null). */
    const val minBaselineNights: Int = 5

    /** Trailing Effort nights used for the strain-debt reference average. */
    const val effortWindow: Int = 14

    /** Charge points a one-spread excess of today's Effort over average removes. */
    const val strainWeight: Double = 9.0

    /** Effort spread (points) defining "one unit" of strain excess. Fixed + explainable. */
    const val effortSpread: Double = 12.0

    /** Max |strain-debt| nudge (points). */
    const val strainAdjCap: Double = 12.0

    /** Charge points a full night short / over of sleep-need moves the estimate. */
    const val sleepWeight: Double = 14.0

    /** Sleep beyond need keeps helping only up to this fraction (diminishing returns). */
    const val sleepOverCap: Double = 0.25

    /** Charge points removed per point/day of recent up-slope (the reversion damping). */
    const val reversionWeight: Double = 1.0

    /** Max |mean-reversion| nudge (points). */
    const val reversionAdjCap: Double = 8.0

    /** Floor on the ± band (points). */
    const val minBandPoints: Double = 8.0

    /** Extra ± points while the baseline is below [trustedNights] (thin history). */
    const val thinBandPoints: Double = 6.0

    /** Recent Charge nights at/above which the band is no longer inflated for thinness. */
    const val trustedNights: Int = 10

    /** Nights informing the sleep need at/above which the need is "solid" (matches 7). */
    const val solidNeedNights: Int = 7

    /** Default personal sleep need (hours) when the caller has none to refine it. */
    const val defaultNeedHours: Double = RestScorer.defaultSleepNeedHours

    /**
     * Project tomorrow-morning Charge from tonight's known levers. APPROXIMATE; null
     * until there are at least [minBaselineNights] of recent Charge to anchor to.
     *
     * @param recentCharge recent daily Charge values, OLDEST→NEWEST (0–100). Only the
     *   trailing [baselineWindow] are used for the baseline mean/SD/slope.
     * @param recentEffort recent daily Effort values, OLDEST→NEWEST (0–100); the
     *   trailing [effortWindow] set the strain-debt reference average. May be empty —
     *   the strain term then drops.
     * @param todayEffort today's Effort (0–100), or null to drop the strain term.
     * @param plannedSleepHours sleep hours planned / already banked tonight. Negative
     *   is treated as 0.
     * @param needHours personal sleep need (hours); null → [defaultNeedHours].
     * @param needNights recent nights that informed [needHours] (0 = still the default);
     *   drives the Rest-style confidence tier.
     */
    fun forecast(
        recentCharge: List<Double>,
        recentEffort: List<Double> = emptyList(),
        todayEffort: Double?,
        plannedSleepHours: Double,
        needHours: Double? = null,
        needNights: Int = 0,
    ): RecoveryForecast? {
        val chargeWindow = recentCharge.takeLast(baselineWindow)
        val nights = chargeWindow.size
        if (nights < minBaselineNights) return null

        val center = mean(chargeWindow)
        val sd = sampleSD(chargeWindow)
        val slope = leastSquaresSlope(chargeWindow)

        // 1. Strain debt: today vs the recent average Effort (both 0–100).
        var strainAdj = 0.0
        if (todayEffort != null && recentEffort.isNotEmpty()) {
            val meanEffort = mean(recentEffort.takeLast(effortWindow))
            val excess = (todayEffort - meanEffort) / effortSpread
            strainAdj = clamp(-strainWeight * excess, -strainAdjCap, strainAdjCap)
        }

        // 2. Sleep adequacy: planned sleep vs personal need.
        val need = max(needHours ?: defaultNeedHours, 0.1)
        val sleep = max(plannedSleepHours, 0.0)
        val sleepRatio = clamp(sleep / need - 1.0, -1.0, sleepOverCap)
        val sleepAdj = sleepWeight * sleepRatio

        // 3. Mean reversion: dampen a recent streak back toward the baseline.
        val reversionAdj = clamp(-reversionWeight * slope, -reversionAdjCap, reversionAdjCap)

        val raw = center + strainAdj + sleepAdj + reversionAdj
        val charge = clamp(raw, 0.0, 100.0).roundToInt().toDouble()

        // ± band: recent SD, floored, inflated while the baseline is thin.
        var band = max(sd, minBandPoints)
        if (nights < trustedNights) band += thinBandPoints
        band = band.roundToInt().toDouble()

        // Confidence rides the SAME calibrating/building/solid ladder as the daily
        // scores. The forecast always clears minBaselineNights to reach here (so it is
        // never CALIBRATING), then it is BUILDING on a thin baseline OR an unrefined
        // sleep-need default, and SOLID only when both the baseline is full
        // (≥ trustedNights) and the personal need is informed.
        val confidence = if (nights >= trustedNights && needNights >= solidNeedNights) {
            ScoreConfidence.SOLID
        } else {
            ScoreConfidence.BUILDING
        }

        return RecoveryForecast(
            charge = charge,
            band = band,
            baseline = center,
            plannedSleepHours = sleep,
            needHours = need,
            nights = nights,
            confidence = confidence,
        )
    }

    // Stats (self-contained so the Swift mirror is line-for-line).

    internal fun mean(values: List<Double>): Double {
        if (values.isEmpty()) return 0.0
        return values.sum() / values.size
    }

    /** Sample standard deviation (ddof = 1); 0 for fewer than 2 values. */
    internal fun sampleSD(values: List<Double>): Double {
        val n = values.size
        if (n < 2) return 0.0
        val m = mean(values)
        var ss = 0.0
        for (v in values) {
            val d = v - m
            ss += d * d
        }
        return sqrt(ss / (n - 1))
    }

    /** OLS slope of value vs the 0-based index (per-day trend); 0 for < 2 points. */
    internal fun leastSquaresSlope(values: List<Double>): Double {
        val n = values.size
        if (n < 2) return 0.0
        val meanX = (n - 1) / 2.0
        val meanY = mean(values)
        var num = 0.0
        var den = 0.0
        values.forEachIndexed { i, v ->
            val dx = i - meanX
            num += dx * (v - meanY)
            den += dx * dx
        }
        return if (den == 0.0) 0.0 else num / den
    }

    internal fun clamp(x: Double, lo: Double, hi: Double): Double {
        // Inclusive-bound equality is already in range: return x itself so Swift
        // and Kotlin preserve the same IEEE signed-zero bit (#56).
        if (x < lo) return lo
        if (x > hi) return hi
        return x
    }
}
