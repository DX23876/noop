package com.noop.analytics

import com.noop.data.HrSample
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/*
 * RecoveryScorer.kt — resting HR during sleep + a transparent 0–100 recovery score
 * (NOOP "Charge").
 *
 * Faithful Kotlin port of StrandAnalytics/RecoveryScorer.swift (verified on macOS),
 * itself ported from server/ingest/app/analysis/recovery.py.
 *
 * recovery() is a z-score + logistic composite. It is APPROXIMATE — not
 * WHOOP-identical (WHOOP's model is proprietary). It is a transparent,
 * HRV-dominant, baseline-normalized proxy.
 *
 * Weighting (documented, grounded, explainable):
 *   higher HRV vs baseline        → higher recovery  (W_HRV   = 0.55, dominant)
 *   lower resting HR vs baseline   → higher recovery  (W_RHR   = 0.20)
 *   lower resp vs baseline         → higher recovery  (W_RESP  = 0.05)
 *   higher sleep performance       → higher recovery  (W_SLEEP = 0.15)
 *   skin temp NEAR baseline        → higher recovery  (W_SKIN_TEMP = 0.05)
 *
 * Skin temp is a SYMMETRIC penalty: further from the personal baseline in EITHER
 * direction (illness / overreach) lowers Charge. It enters as −|dev| / scale, like
 * the "lower is better" terms but on the absolute deviation. When skinTempDev is null
 * the term drops and the remaining weights renormalize, so the score is IDENTICAL to
 * the pre-skin-temp model (the no-skin-temp path is byte-for-byte unchanged).
 *
 * Two OPTIONAL Oura-Readiness-style terms (dormant until a caller supplies them):
 *   overnight resting-HR DECLINE slope ("Recovery Index")      → W_RECOVERY_INDEX    = 0.05
 *   previous-day Effort vs personal baseline ("Activity Balance" /
 *   "Previous Day Activity", collapsed into one term)          → W_ACTIVITY_BALANCE  = 0.05
 * Both are ADDITIVE and NON-BREAKING: each is null unless the caller supplies it, in which
 * case it folds in with its small weight above; when null the term drops and the weights
 * renormalize exactly like the skin-temp term, so the default score for every existing caller
 * is BYTE-IDENTICAL to before either term existed. Recovery Index needs no personal baseline
 * (a fixed, documented bpm/hour scale, same style as sleepPerf/skin-temp); Activity Balance
 * needs BOTH the previous-day Effort value AND its EWMA baseline ([Baselines.strainCfg]) —
 * supplying only one drops the term.
 *
 * Each metric is standardized to a robust z-score against the personal baseline
 * (mean + EWMA-abs-dev spread). Missing terms are dropped and the weights
 * renormalized. The composite z is squashed through a logistic anchored so that
 * Z = 0 → ~58% (WHOOP's published population-average recovery).
 *
 * Cold-start: if the HRV baseline (dominant driver) is not yet usable
 * (< MIN_NIGHTS_SEED valid nights), recovery() returns null. Callers may use
 * [populationMean] (58.0) as a fallback but should flag it.
 *
 * `start` / `end` are wall-clock unix SECONDS (Long), matching the com.noop.data
 * layer and HrSample.ts (the Swift source uses Int seconds).
 */

/** Resting-HR estimate + transparent recovery score. Mirrors Swift `RecoveryScorer`. */
object RecoveryScorer {

    // ─────────────────────────────────────────────────────────────────────────
    // Constants (recovery.py)
    // ─────────────────────────────────────────────────────────────────────────

    const val wHRV: Double = 0.55
    const val wRHR: Double = 0.20
    const val wResp: Double = 0.05
    const val wSleep: Double = 0.15

    /** Skin-temperature deviation weight (symmetric illness/overreach penalty). */
    const val wSkinTemp: Double = 0.05

    /**
     * Skin-temp deviation scale (°C per z-unit). The term is −|skinTempDevC| / scale,
     * so a 1.0 °C absolute deviation from the personal baseline costs ≈ 1 z-unit of
     * Charge. skinTempDevC is the raw ±°C delta (DailyMetric.skinTempDevC), not a z.
     *
     * Kept at 1.0 to match the Swift reference (RecoveryScorer.skinTempScaleC = 1.0).
     * A prior 0.5 here applied a 2× penalty Charge never intended — every user's
     * Charge diverged from macOS/iOS by the skin-temp term. (Cross-platform parity.)
     */
    const val skinTempDevScale: Double = 1.0

    /**
     * Recovery-Index weight (overnight resting-HR DECLINE slope — Oura's "Recovery Index"
     * contributor). Small and additive like [wSkinTemp]: folds in only when a slope is
     * supplied. Mirrors Swift `RecoveryScorer.wRecoveryIndex`.
     */
    const val wRecoveryIndex: Double = 0.05

    /**
     * Recovery-Index slope scale (bpm/hour): a slope this many bpm/hour steeper than flat (0)
     * costs/earns ≈ 1 z-unit before weighting. Resting HR falling through the night is the
     * physiologically expected, good pattern; flat or rising (illness, alcohol, a late
     * stimulant, restlessness) is not. The SIGN carries the meaning (negative = declining =
     * good), unlike skin-temp's symmetric |deviation| penalty. Mirrors Swift
     * `RecoveryScorer.recoveryIndexScaleBpmPerHr`.
     */
    const val recoveryIndexScaleBpmPerHr: Double = 2.0

    /**
     * Activity-Balance / previous-day-Effort weight (collapses Oura's "Previous Day Activity"
     * and "Activity Balance" readiness contributors into one term). Small and additive like
     * [wSkinTemp]: folds in only when BOTH a previous-day Effort value and its personal EWMA
     * baseline ([Baselines.strainCfg]) are supplied. Mirrors Swift
     * `RecoveryScorer.wActivityBalance`.
     */
    const val wActivityBalance: Double = 0.05

    /** Logistic spread: ±2 z-units ≈ full Red–Green band (15%–95%). */
    const val logisticK: Double = 1.6

    /** Logistic offset so Z=0 → 58%. */
    const val logisticZ0: Double = -0.20

    /** WHOOP-published population-average recovery (%). Cold-start fallback. */
    const val populationMean: Double = 58.0

    /** Recovery band thresholds (WHOOP color scheme). */
    const val bandRedMax: Double = 34.0
    const val bandYellowMax: Double = 67.0

    /** Sleep-performance center ("good night" at ~85% efficiency). */
    const val sleepPerfCenter: Double = 0.85

    /** Sleep-performance scale (±2 z spans the normal range). */
    const val sleepPerfScale: Double = 0.12

    /** Rolling-mean HR window (seconds) for the resting-HR estimate. */
    const val restingHRWindowS: Int = 5 * 60

    /**
     * Minimum HR samples a 5-min bin must hold before its mean is eligible to WIN the resting
     * floor (#686). A thinly-populated bin — at the limit a single lone beat — lets one artifact
     * (a dropout, a decode glitch) become the bin "mean" and win the night's minimum, dragging
     * resting HR implausibly low. Requiring a handful of samples means the floor is a genuine
     * sustained dip, not a one-sample fluke. Worn nights stream ~1 Hz HR so a real 5-min bin holds
     * hundreds of samples and clears this trivially; only sparse/edge bins fall below it. Does NOT
     * change the floor DEFINITION — still the min of 5-min bin means — only stops an under-sampled
     * artifact bin from being that min. Mirrors Swift `RecoveryScorer.restingHRMinBinSamples`.
     */
    const val restingHRMinBinSamples: Int = 5

    /**
     * Physiological resting-HR floor (bpm) below which a bin mean is rejected as a dropout artifact
     * (#686), never the resting floor. An adult's true sleeping resting HR essentially never sits
     * below this; a 5-min mean that does is a run of dropout/decode-zero beats, not a real cardiac
     * dip. 25 bpm clears even deeply-bradycardic trained athletes (resting HRs in the low 30s) with
     * margin while rejecting the implausible artifact range. Mirrors Swift
     * `RecoveryScorer.restingHRMinPlausibleBpm`.
     */
    const val restingHRMinPlausibleBpm: Double = 25.0

    // ─────────────────────────────────────────────────────────────────────────
    // Resting HR
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Lowest sustained HR during the in-bed window (bpm, rounded), or null.
     *
     * "Sustained" = the minimum of 5-minute non-overlapping bin means of the HR
     * samples whose ts ∈ [start, end]. Rejects single-beat dips while capturing
     * the night's true floor. Returns null when there are no HR samples in window.
     *
     * Artifact hardening (#686): a bin may only WIN the floor when it is BOTH well-populated
     * (≥ [restingHRMinBinSamples], so one lone artifact beat can't be a bin "mean") AND
     * physiologically plausible (mean ≥ [restingHRMinPlausibleBpm], rejecting dropout-driven
     * sub-physiological dips). The floor DEFINITION is unchanged — still the minimum of the 5-min
     * bin means — only artifact bins are barred from being that minimum. If no bin qualifies (a
     * wholly sparse/degenerate window), fall back to the lowest of ALL bin means, else the
     * all-sample mean, preserving the never-null-on-data behaviour. Mirrors Swift `restingHR`.
     *
     * @param start / @param end window bounds, unix SECONDS (Long).
     */
    fun restingHR(hr: List<HrSample>, start: Long, end: Long): Int? {
        val seg = hr.filter { it.ts in start..end }
        if (seg.isEmpty()) return null

        val means = ArrayList<Double>()      // every bin mean (legacy floor, the fallback)
        val qualified = ArrayList<Double>()  // bins eligible to WIN the floor (#686)
        var t = start
        while (t < end) {
            val binEnd = t + restingHRWindowS
            val win = seg.filter { it.ts >= t && it.ts < binEnd }
            if (win.isNotEmpty()) {
                val mean = win.sumOf { it.bpm }.toDouble() / win.size.toDouble()
                means.add(mean)
                // A bin wins the floor only if it is well-populated AND physiologically plausible —
                // a thin (single-artifact) or sub-physiological (dropout) bin can't be the minimum.
                if (win.size >= restingHRMinBinSamples && mean >= restingHRMinPlausibleBpm) {
                    qualified.add(mean)
                }
            }
            t += restingHRWindowS
        }
        val floor: Double = qualified.minOrNull()
            ?: means.minOrNull()
            ?: (seg.sumOf { it.bpm }.toDouble() / seg.size.toDouble())
        return floor.roundToInt()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Recovery Index (overnight HR-decline slope)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Minimum 5-minute bins ([restingHR]'s SAME binning) required before a slope is trusted —
     * below this, too little of the night has elapsed to fit a trend, and a 1-2-point
     * regression is noise, not a night-long pattern. 6 bins = 30 minutes of binned coverage,
     * a deliberately low floor so a short/partial night still gets a number rather than a
     * routine null. Mirrors Swift `RecoveryScorer.recoveryIndexMinBins`.
     */
    const val recoveryIndexMinBins: Int = 6

    /**
     * Overnight resting-HR DECLINE slope (bpm/hour) across the in-bed window — the "Recovery
     * Index" component of Oura's Readiness that Charge lacked (it previously only read the
     * overnight FLOOR via [restingHR] above, never the trend that reaches it).
     *
     * Computed as the least-squares slope of the SAME non-overlapping 5-minute HR bin means
     * [restingHR] uses ([restingHRWindowS]) against each bin's midpoint time (hours from
     * `start`). NEGATIVE = declining (HR falling through the night — the physiologically
     * expected, good pattern); POSITIVE = rising (restlessness, illness, alcohol, a late
     * stimulant). Returns null when fewer than [recoveryIndexMinBins] bins have data (too
     * little of the window to fit a trend) or there are no samples at all — it never
     * fabricates a slope from a sliver of the night. Mirrors Swift `recoveryIndexSlope`.
     *
     * @param start / @param end window bounds, unix SECONDS (Long).
     */
    fun recoveryIndexSlope(hr: List<HrSample>, start: Long, end: Long): Double? {
        val seg = hr.filter { it.ts in start..end }
        if (seg.isEmpty()) return null

        // Same non-overlapping 5-minute binning as restingHR: both read the identical
        // underlying series, one as a floor, one as a trend across it.
        val points = ArrayList<Pair<Double, Double>>() // (tHours, meanBpm)
        var t = start
        while (t < end) {
            val binEnd = t + restingHRWindowS
            val win = seg.filter { it.ts >= t && it.ts < binEnd }
            if (win.isNotEmpty()) {
                val mean = win.sumOf { it.bpm }.toDouble() / win.size.toDouble()
                val midpointS = (t - start).toDouble() + restingHRWindowS / 2.0
                points.add((midpointS / 3600.0) to mean)
            }
            t += restingHRWindowS
        }
        if (points.size < recoveryIndexMinBins) return null

        // Least-squares slope: Σ((t−t̄)(y−ȳ)) / Σ((t−t̄)²), bpm per hour.
        val n = points.size.toDouble()
        val tBar = points.sumOf { it.first } / n
        val yBar = points.sumOf { it.second } / n
        var num = 0.0
        var den = 0.0
        for ((tHours, meanBpm) in points) {
            val dt = tHours - tBar
            num += dt * (meanBpm - yBar)
            den += dt * dt
        }
        // Degenerate (all bins at the same instant): no time spread to fit against.
        if (den <= 1e-9) return 0.0
        return num / den
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Recovery band
    // ─────────────────────────────────────────────────────────────────────────

    /** WHOOP-style color band for a recovery score [0, 100]. */
    fun band(score: Double): String {
        if (score < bandRedMax) return "red"
        if (score < bandYellowMax) return "yellow"
        return "green"
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Recovery score
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * A baseline driver: mean + spread (internal abs-dev units, as in [BaselineState]).
     * Mirrors Swift `RecoveryScorer.DriverBaseline`.
     */
    data class DriverBaseline(val mean: Double, val spread: Double) {
        constructor(state: BaselineState) : this(mean = state.baseline, spread = state.spread)
    }

    /** Robust z-score using EWMA spread: (value − mean) / (1.253 × spread). */
    internal fun zScore(value: Double, mean: Double, spread: Double): Double {
        val sigma = max(1.253 * spread, 1e-9)
        return (value - mean) / sigma
    }

    /**
     * Z-score + logistic recovery score in [0, 100]. APPROXIMATE.
     *
     * Returns null when the HRV baseline (dominant driver) is not yet usable, or
     * no valid driver is available at all.
     *
     * @param hrv tonight's HRV (RMSSD, ms).
     * @param rhr tonight's resting HR (bpm).
     * @param resp tonight's respiration (raw or calibrated — z is scale-invariant);
     *   null drops the term.
     * @param hrvBaseline HRV baseline (required for a score).
     * @param rhrBaseline resting-HR baseline; null drops the RHR term.
     * @param respBaseline respiration baseline; null drops the resp term.
     * @param sleepPerf sleep-performance proxy (Rest composite 0..1, or efficiency
     *   0..1 for legacy callers); null drops the term.
     * @param skinTempDev tonight's skin-temperature deviation from the personal
     *   baseline (raw ±°C, DailyMetric.skinTempDevC); applied as a SYMMETRIC penalty
     *   −|dev| / skinTempDevScale. null drops the term and renormalizes (score then
     *   identical to the pre-skin-temp model).
     * @param hrvBaselineUsable whether the HRV baseline has enough nights
     *   (BaselineState.usable). When false, returns null (cold-start).
     * @param recoveryIndexSlope overnight resting-HR DECLINE slope (bpm/hour, from
     *   [recoveryIndexSlope]). Negative (declining) supports recovery; positive (rising)
     *   limits it, weight [wRecoveryIndex]. null (the default) drops the term and the
     *   weights renormalize, so the no-slope score is IDENTICAL to before this parameter
     *   existed.
     * @param effortBaseline personal EWMA baseline of daily Effort/strain
     *   ([Baselines.strainCfg]). Needs [priorDayEffort] too — supplying only one drops
     *   the term.
     * @param priorDayEffort yesterday's Effort/strain (0–100, StrainScorer.strain). Lower vs
     *   [effortBaseline] supports recovery, same "lower is better" direction as RHR/resp,
     *   weight [wActivityBalance]. null (the default, like effortBaseline) drops the term
     *   and the weights renormalize, so the no-effort score is IDENTICAL to before either
     *   parameter existed.
     */
    fun recovery(
        hrv: Double,
        rhr: Double,
        resp: Double?,
        hrvBaseline: DriverBaseline?,
        rhrBaseline: DriverBaseline?,
        respBaseline: DriverBaseline?,
        sleepPerf: Double?,
        skinTempDev: Double? = null,
        hrvBaselineUsable: Boolean = true,
        recoveryIndexSlope: Double? = null,
        effortBaseline: DriverBaseline? = null,
        priorDayEffort: Double? = null,
    ): Double? {
        // Cold-start gate: HRV is the dominant driver; if its baseline isn't
        // usable, refuse to score (more honest than a fabricated value).
        if (!hrvBaselineUsable) return null

        val terms = ArrayList<Pair<Double, Double>>() // (z, weight)

        // HRV term: higher is better.
        hrvBaseline?.let { b ->
            terms.add(zScore(hrv, b.mean, b.spread) to wHRV)
        }
        // RHR term: lower is better → (μ − x) / σ.
        rhrBaseline?.let { b ->
            terms.add(zScore(b.mean, rhr, b.spread) to wRHR)
        }
        // Resp term: lower is better, optional.
        if (resp != null && respBaseline != null) {
            terms.add(zScore(respBaseline.mean, resp, respBaseline.spread) to wResp)
        }
        // Sleep-performance term: no baseline needed; centered at SLEEP_PERF_CENTER.
        if (sleepPerf != null) {
            terms.add(((sleepPerf - sleepPerfCenter) / sleepPerfScale) to wSleep)
        }
        // Skin-temp term: SYMMETRIC penalty, no baseline arg (skinTempDev is already a
        // deviation). Further from baseline in either direction → more negative z.
        if (skinTempDev != null) {
            terms.add((-abs(skinTempDev) / skinTempDevScale) to wSkinTemp)
        }
        // Recovery-Index term: overnight HR-DECLINE slope (bpm/hour). No baseline needed (a
        // fixed, documented scale, same style as sleepPerf/skin-temp). Negative (declining)
        // supports recovery; positive (rising) limits it. Added only when supplied.
        if (recoveryIndexSlope != null) {
            terms.add((-recoveryIndexSlope / recoveryIndexScaleBpmPerHr) to wRecoveryIndex)
        }
        // Activity-Balance / previous-day-Effort term: lower vs personal baseline is better,
        // same "lower is better" direction as RHR/resp → (μ − x) / σ. Needs BOTH the value
        // and a baseline, matching resp's pattern; added only when both are supplied.
        if (priorDayEffort != null && effortBaseline != null) {
            terms.add(
                zScore(effortBaseline.mean, priorDayEffort, effortBaseline.spread) to wActivityBalance,
            )
        }

        if (terms.isEmpty()) return null
        val totalWeight = terms.sumOf { it.second }
        if (totalWeight <= 0.0) return null

        val z = terms.sumOf { it.first * it.second } / totalWeight
        val score = 100.0 / (1.0 + exp(-logisticK * (z - logisticZ0)))
        return max(0.0, min(100.0, score))
    }

    /**
     * Convenience overload taking [BaselineState] directly. Enforces the cold-start
     * gate using `hrvBaseline.usable`. Mirrors the Swift `recovery(...)` overload.
     */
    fun recovery(
        hrv: Double,
        rhr: Double,
        resp: Double?,
        hrvBaseline: BaselineState,
        rhrBaseline: BaselineState?,
        respBaseline: BaselineState?,
        sleepPerf: Double?,
        skinTempDev: Double? = null,
        recoveryIndexSlope: Double? = null,
        effortBaseline: BaselineState? = null,
        priorDayEffort: Double? = null,
    ): Double? = recovery(
        hrv = hrv,
        rhr = rhr,
        resp = resp,
        hrvBaseline = DriverBaseline(hrvBaseline),
        rhrBaseline = rhrBaseline?.let { DriverBaseline(it) },
        respBaseline = respBaseline?.let { DriverBaseline(it) },
        sleepPerf = sleepPerf,
        skinTempDev = skinTempDev,
        hrvBaselineUsable = hrvBaseline.usable,
        recoveryIndexSlope = recoveryIndexSlope,
        effortBaseline = effortBaseline?.let { DriverBaseline(it) },
        priorDayEffort = priorDayEffort,
    )
}
