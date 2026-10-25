package com.noop.analytics

import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max

/*
 * HRVReadiness.kt — OPT-IN experimental "HRV readiness (Plews/Altini)" tier readout.
 *
 * Faithful Kotlin twin of StrandAnalytics/HRVReadiness.swift. Cross-platform parity is the contract:
 * every constant, gate, and formula here must stay byte-identical to the Swift source.
 *
 * This is a PURE, deterministic, DB-free engine and it does NOT change the default Charge/ring in any
 * way — it is only surfaced (read-only) behind the [com.noop.ble.PuffinExperiment] `noopHrvReadiness`
 * flag (off by default) and feeds NO downstream gate. It reimplements the endurance-science "smallest
 * worthwhile change" (SWC) reading of nightly HRV popularised by Plews et al. and Marco Altini: work in
 * the LOG domain (ln RMSSD is closer to normal and stabilises variance), compare a short 7-night rolling
 * baseline against a longer personal normal band (±0.5 SD), and read the tier off where the short baseline
 * sits relative to that band. A single bad night barely moves the 7-night baseline, so the reading is far
 * more robust than a raw single-night z.
 *
 * INPUT: the SAME nightly RMSSD series RecoveryScorer / ReadinessEngine consume — DailyMetric.avgHrv[]
 * in ms, oldest -> newest (nulls allowed for missing nights). Physiologically implausible nights are
 * dropped through the shared [Baselines.hrvCfg] bounds (5..250 ms) so one decode glitch can't skew it.
 *
 * OUTPUT ([HRVReadinessResult]): the tier (primed / normal / suppressed), the 7-night baseline and the
 * personal normal band (all back in ms via exp), and an informational overreaching-watch flag. Returns
 * null (the honest ".calibrating" edge) below [MIN_NIGHTS] valid nights: never a fabricated number.
 * Mirrors the WatchRecovery nil+.calibrating honesty pattern.
 *
 * This is a rough / early experiment: it is NOT yet validated against varying real data (n=1). Outputs
 * are APPROXIMATE wellness estimates, not medical advice.
 */

/** Where tonight's 7-night HRV baseline sits vs the personal normal band. Mirrors Swift `ReadinessTier`. */
enum class ReadinessTier { PRIMED, NORMAL, SUPPRESSED }

/** Result of an [HRVReadiness.evaluate] pass. All *Ms fields are back in milliseconds (exp of the log
 *  domain the engine works in). Mirrors Swift `HRVReadinessResult`. */
data class HRVReadinessResult(
    /** Tier from the SWC comparison of the 7-night baseline against the personal normal band. */
    val tier: ReadinessTier,
    /** 7-night rolling HRV baseline (ms) = exp(mean of ln RMSSD over the trailing ROLL_WINDOW nights). */
    val baseline7Ms: Double,
    /** Lower edge of the personal normal band (ms) = exp(longMean − 0.5·longSD). */
    val normalLowMs: Double,
    /** Upper edge of the personal normal band (ms) = exp(longMean + 0.5·longSD). */
    val normalHighMs: Double,
    /** Informational only (does NOT change the tier): a sustained falling CV trend while the 7-night
     *  baseline sits below the long mean — the classic parasympathetic-overreaching signature. */
    val overreachingWatch: Boolean,
)

/** OPT-IN experimental HRV-readiness (Plews/Altini SWC) engine. Mirrors Swift `HRVReadiness`. */
object HRVReadiness {

    // ─────────────────────────────────────────────────────────────────────────
    // Constants (name them; mirror Swift exactly)
    // ─────────────────────────────────────────────────────────────────────────

    /** Short rolling baseline window (nights) — the Plews/Altini 7-night HRV baseline. */
    const val ROLL_WINDOW: Int = 7

    /** Long personal-normal window (nights) when enough valid nights exist. */
    const val LONG_WINDOW: Int = 60

    /** Long-window fallback (nights) when fewer than [LONG_WINDOW] valid nights are banked. */
    const val LONG_WINDOW_FALLBACK: Int = 30

    /** Smallest-worthwhile-change half-width factor: the normal band is longMean ± SWC_K·longSD. */
    const val SWC_K: Double = 0.5

    /**
     * Minimum VALID nights before a reading is offered (else null + the honest calibrating edge). Its OWN
     * constant — deliberately NOT aliased to [WatchRecovery.minBaselineNights]: the SWC band needs a longer
     * warm-up than the watch-recovery gate. It only mirrors WatchRecovery's nil+.calibrating HONESTY
     * pattern, not its value.
     */
    const val MIN_NIGHTS: Int = 14

    /** Trailing nights over which the CV trend (overreaching watch) is fit. */
    const val CV_TREND_WINDOW: Int = 28

    /** Floor on the long-window SD so a flat history yields a deterministic, tiny non-degenerate normal
     *  band instead of an ULP-fragile zero-width one (baseline7 and longMean are both the mean of the same
     *  constant here, but can differ by a float ULP, which a zero-width band would flip to primed/suppressed). */
    const val LONG_SD_FLOOR: Double = 1e-9

    // ─────────────────────────────────────────────────────────────────────────
    // Evaluate
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Compute the Plews/Altini HRV-readiness reading. Returns null (calibrating) below [MIN_NIGHTS]
     * valid nights — never a fabricated value.
     *
     * @param avgHrv nightly RMSSD (ms), oldest -> newest; nulls = missing nights. Out-of-range nights
     *   (outside [Baselines.hrvCfg] 5..250 ms) are dropped as decode artefacts.
     */
    fun evaluate(avgHrv: List<Double?>): HRVReadinessResult? {
        val cfg = Baselines.hrvCfg
        // Drop nulls + physiologically implausible nights (shared bounds), keep order oldest -> newest.
        val valid = avgHrv.mapNotNull { v ->
            if (v != null && cfg.minVal <= v && v <= cfg.maxVal) v else null
        }
        // Honesty gate: below MIN_NIGHTS valid nights we refuse to score (calibrating). Never fabricate.
        if (valid.size < MIN_NIGHTS) return null

        // Log domain: ln RMSSD (Plews/Altini). max(.,1.0) guards ln of a sub-1 value; bounds already keep it >=5.
        val ell = valid.map { ln(max(it, 1.0)) }

        // 7-night rolling baseline (the short, robust HRV baseline).
        val baseline7 = RecoveryForecaster.mean(ell.takeLast(ROLL_WINDOW))

        // Long personal-normal window: LONG_WINDOW if we have that many valid nights, else the 30-night fallback.
        val longWin = if (valid.size >= LONG_WINDOW) LONG_WINDOW else LONG_WINDOW_FALLBACK
        val longEll = ell.takeLast(longWin)
        val longMean = RecoveryForecaster.mean(longEll)
        // SD over the long window; if fewer than 2 long nights, fall back to the 7-night SD; floored so a
        // flat history gives a deterministic tiny band rather than an ULP-fragile zero-width one.
        val longSDraw = if (longEll.size >= 2) RecoveryForecaster.sampleSD(longEll)
        else RecoveryForecaster.sampleSD(ell.takeLast(ROLL_WINDOW))
        val longSD = max(longSDraw, LONG_SD_FLOOR)

        // Smallest-worthwhile-change band (±0.5 SD in the log domain).
        val swcHalf = SWC_K * longSD
        val normalLow = longMean - swcHalf
        val normalHigh = longMean + swcHalf

        // Tier: above the band -> primed; inside (inclusive of the low edge) -> normal; below -> suppressed.
        val tier = when {
            baseline7 > normalHigh -> ReadinessTier.PRIMED
            baseline7 >= normalLow -> ReadinessTier.NORMAL
            else -> ReadinessTier.SUPPRESSED
        }

        // Overreaching watch (INFORMATIONAL — never changes the tier): a sustained FALLING coefficient-of-
        // variation trend while the 7-night baseline sits below the long mean (parasympathetic overreach).
        // Build a rolling CV series (one point per night with a full trailing-7 window) over the last
        // CV_TREND_WINDOW nights, then OLS its slope.
        val cvSeries = ArrayList<Double>()
        val cvStart = max(ROLL_WINDOW - 1, ell.size - CV_TREND_WINDOW)
        for (i in cvStart until ell.size) {
            val w = ell.subList(i - ROLL_WINDOW + 1, i + 1)
            val m = RecoveryForecaster.mean(w)
            val cv = if (m != 0.0) 100.0 * RecoveryForecaster.sampleSD(w) / m else 0.0
            cvSeries.add(cv)
        }
        val cvSlope = RecoveryForecaster.leastSquaresSlope(cvSeries)
        val overreachingWatch = cvSlope < 0.0 && baseline7 < longMean

        return HRVReadinessResult(
            tier = tier,
            baseline7Ms = exp(baseline7),
            normalLowMs = exp(normalLow),
            normalHighMs = exp(normalHigh),
            overreachingWatch = overreachingWatch,
        )
    }
}
