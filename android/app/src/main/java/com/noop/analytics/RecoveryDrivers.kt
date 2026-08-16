package com.noop.analytics

import kotlin.math.abs
import kotlin.math.roundToInt

// RecoveryDrivers.kt - the USER-FACING "What shaped it" breakdown for the Charge (recovery) score.
//
// Kotlin twin of the Swift RecoveryScorer chargeDrivers reference. Where RecoveryScorerTrace emits a
// terse engineer-facing strap-log trace, this produces the ordered, plain-English driver rows the
// dashboard renders UNDER the Charge ring: one row per real term, each carrying the signed point
// contribution to the score (deltaPoints), the night's value, the personal baseline it was scored
// against, and a short verdict.
//
// HONEST BY CONSTRUCTION. Every row is recomputed from the SAME inputs RecoveryScorer.recovery reads,
// with the SAME zScore call, weights and logistic, so a driver can never describe a term the score
// did not actually use. A MISSING input yields NO row (never a fabricated zero-contribution row): the
// term simply drops, exactly as it drops + renormalizes inside recovery(...). deltaPoints is the
// term's MARGINAL effect on the final 0-100 score: score(actual) minus score(this term neutralized to
// its personal baseline, i.e. z = 0), holding the other terms. That is a real local sensitivity, not a
// linear apportionment, so the signed points are exactly "how many points this signal moved Charge
// versus sitting at your baseline". Pure + side-effect-free (no clock, no I/O), so a fixture night pins
// the exact rows. No em-dashes, no PII (values + baselines are the user's own, never logged here).

/**
 * One driver row behind the Charge (recovery) score, in the SHARED CONTRACT shape the iOS/macOS and
 * Android dashboards both render. Field names are byte-identical across platforms.
 *
 * @property label short signal name, e.g. "Resting HR".
 * @property deltaPoints signed contribution to the 0-100 Charge score versus this signal sitting at
 *   the personal baseline (positive = lifted Charge, negative = pulled it down). A real marginal
 *   sensitivity, never a fabricated apportionment.
 * @property valueText the night's value, formatted with its unit, e.g. "58 bpm".
 * @property baselineText the personal baseline the value was scored against, e.g. "61 bpm baseline".
 * @property verdict short plain-English read, e.g. "below baseline, supporting recovery".
 */
data class ChargeDriver(
    val label: String,
    val deltaPoints: Int,
    val valueText: String,
    val baselineText: String,
    val verdict: String,
)

object RecoveryDrivers {

    /**
     * The ordered "What shaped it" driver rows for one night's Charge score, or an EMPTY list when the
     * score itself can't compute (cold-start HRV baseline not usable, or a missing hard input) - the same
     * gate RecoveryScorer.recovery returns null on. Each present term gets exactly one row; a term whose
     * input is missing yields NO row.
     *
     * Mirrors RecoveryScorer.recovery / RecoveryScorerTrace argument-for-argument so the rows are scored
     * against the identical inputs as the headline number. Takes [BaselineState] so each row can name the
     * personal baseline (mean) it was measured against.
     *
     * @param hrv tonight's HRV (RMSSD, ms).
     * @param rhr tonight's resting HR (bpm).
     * @param resp tonight's respiration (rpm); null drops the resp row.
     * @param hrvBaseline HRV baseline (required; an unusable one yields an empty list, matching the
     *   recovery cold-start gate).
     * @param rhrBaseline resting-HR baseline; null drops the RHR row.
     * @param respBaseline respiration baseline; null drops the resp row.
     * @param sleepPerf rest-quality proxy in 0..1 (Rest composite / 100, or efficiency); null drops the
     *   Sleep row.
     * @param skinTempDev tonight's skin-temperature deviation from the personal baseline (raw +/- C);
     *   null drops the Skin temp row. Surfaced as a RELATIVE deviation, never an absolute temperature.
     */
    fun chargeDrivers(
        hrv: Double,
        rhr: Double,
        resp: Double?,
        hrvBaseline: BaselineState,
        rhrBaseline: BaselineState?,
        respBaseline: BaselineState?,
        sleepPerf: Double?,
        skinTempDev: Double? = null,
    ): List<ChargeDriver> {
        // No score => no real contributions to attribute (cold-start). recovery(...) enforces the usable
        // gate; mirror it so a nil headline never yields fabricated driver rows.
        val full = RecoveryScorer.recovery(
            hrv = hrv, rhr = rhr, resp = resp,
            hrvBaseline = hrvBaseline, rhrBaseline = rhrBaseline,
            respBaseline = respBaseline, sleepPerf = sleepPerf, skinTempDev = skinTempDev,
        ) ?: return emptyList()

        // Marginal-vs-neutral attribution: a term's deltaPoints is the full score minus the score
        // recomputed with THAT term held at its personal baseline (its z forced to 0) while every term,
        // including this one, keeps its weight. Routes through recovery(...) itself (same terms, same
        // weighting, same logistic) so the points can never drift from the headline. A term reaches
        // z = 0 at: HRV / resting HR / respiration = the baseline mean, Rest quality = sleepPerfCenter,
        // skin-temp deviation = 0. Mirrors the Swift ChargeDrivers `points(...)` helper.
        fun points(neutralised: Double?): Int = (full - (neutralised ?: full)).roundToInt()

        // Did the parasympathetic-saturation signature fire on THIS night (low HRV corroborated by a low,
        // decoupled resting HR)? Detection ONLY: the guard's easing is not applied, so deltaPoints below is
        // the full, unguarded HRV penalty. The verdict merely NAMES the detected pattern so the UI can
        // surface it while real firings accumulate. See the header in RecoveryScorer.kt.
        val hrvZFull = RecoveryScorer.zScore(hrv, hrvBaseline.baseline, hrvBaseline.spread)
        val rhrZFull: Double? = rhrBaseline?.let { RecoveryScorer.zScore(it.baseline, rhr, it.spread) }
        val hrvSaturationDetected =
            RecoveryScorer.parasympatheticSaturation(hrvZ = hrvZFull, rhrZ = rhrZFull).active

        // One row per present term, appended in the SAME order the iOS twin uses (HRV, resting HR, Sleep,
        // respiration, skin temp), then sorted biggest-mover-first so the row that explains the most sits on
        // top. Labels / value text / verdicts are byte-identical to the Swift canonical.
        val drivers = ArrayList<ChargeDriver>()

        // HRV (dominant driver; always present once the score exists). Neutral = HRV at the baseline mean.
        drivers.add(
            ChargeDriver(
                label = "Heart rate variability",
                deltaPoints = points(
                    RecoveryScorer.recovery(
                        hrv = hrvBaseline.baseline, rhr = rhr, resp = resp,
                        hrvBaseline = hrvBaseline, rhrBaseline = rhrBaseline,
                        respBaseline = respBaseline, sleepPerf = sleepPerf, skinTempDev = skinTempDev,
                    ),
                ),
                valueText = "${hrv.roundToInt()} ms",
                baselineText = "${hrvBaseline.baseline.roundToInt()} ms baseline",
                verdict = hrvVerdict(
                    value = hrv,
                    baseline = hrvBaseline.baseline,
                    saturationDetected = hrvSaturationDetected,
                ),
            ),
        )
        // Resting HR (lower vs baseline supports recovery). Neutral = resting HR at the baseline mean.
        if (rhrBaseline != null) {
            drivers.add(
                ChargeDriver(
                    label = "Resting heart rate",
                    deltaPoints = points(
                        RecoveryScorer.recovery(
                            hrv = hrv, rhr = rhrBaseline.baseline, resp = resp,
                            hrvBaseline = hrvBaseline, rhrBaseline = rhrBaseline,
                            respBaseline = respBaseline, sleepPerf = sleepPerf, skinTempDev = skinTempDev,
                        ),
                    ),
                    valueText = "${rhr.roundToInt()} bpm",
                    baselineText = "${rhrBaseline.baseline.roundToInt()} bpm baseline",
                    verdict = rhrVerdict(value = rhr, baseline = rhrBaseline.baseline),
                ),
            )
        }
        // Rest quality (the Rest composite; neutral at sleepPerfCenter).
        if (sleepPerf != null) {
            drivers.add(
                ChargeDriver(
                    label = "Sleep quality",
                    deltaPoints = points(
                        RecoveryScorer.recovery(
                            hrv = hrv, rhr = rhr, resp = resp,
                            hrvBaseline = hrvBaseline, rhrBaseline = rhrBaseline,
                            respBaseline = respBaseline, sleepPerf = RecoveryScorer.sleepPerfCenter,
                            skinTempDev = skinTempDev,
                        ),
                    ),
                    valueText = "${(sleepPerf * 100.0).roundToInt()}%",
                    baselineText = "",   // centred on a fixed "good night", not a learned baseline
                    verdict = sleepVerdict(sleepPerf),
                ),
            )
        }
        // Respiration (lower vs baseline supports recovery). Neutral = respiration at the baseline mean.
        if (resp != null && respBaseline != null) {
            drivers.add(
                ChargeDriver(
                    label = "Respiratory rate",
                    deltaPoints = points(
                        RecoveryScorer.recovery(
                            hrv = hrv, rhr = rhr, resp = respBaseline.baseline,
                            hrvBaseline = hrvBaseline, rhrBaseline = rhrBaseline,
                            respBaseline = respBaseline, sleepPerf = sleepPerf, skinTempDev = skinTempDev,
                        ),
                    ),
                    valueText = String.format(java.util.Locale.US, "%.1f br/min", resp),
                    baselineText = String.format(java.util.Locale.US, "%.1f br/min baseline", respBaseline.baseline),
                    verdict = respVerdict(value = resp, baseline = respBaseline.baseline),
                ),
            )
        }
        // Skin-temp deviation (symmetric penalty: any drift lowers Charge). Neutral = zero drift, so the
        // delta is always <= 0 (a penalty removed). Surface it as a RELATIVE deviation, never an absolute.
        if (skinTempDev != null) {
            drivers.add(
                ChargeDriver(
                    label = "Skin temperature",
                    deltaPoints = points(
                        RecoveryScorer.recovery(
                            hrv = hrv, rhr = rhr, resp = resp,
                            hrvBaseline = hrvBaseline, rhrBaseline = rhrBaseline,
                            respBaseline = respBaseline, sleepPerf = sleepPerf, skinTempDev = 0.0,
                        ),
                    ),
                    valueText = String.format(java.util.Locale.US, "%+.1f C vs baseline", skinTempDev),
                    baselineText = "",   // a deviation already; the reference is the personal baseline (0)
                    verdict = skinTempVerdict(skinTempDev),
                ),
            )
        }

        // Biggest mover first; a stable sort preserves the iOS append order on ties.
        return drivers.sortedByDescending { abs(it.deltaPoints) }
    }

    /**
     * HRV verdict matching the Swift canonical `hrvVerdict(value:baseline:saturationDetected:)`: above
     * baseline supports recovery; below baseline limits it; at baseline is neutral. When the
     * parasympathetic-saturation signature fired (low HRV corroborated by a low, decoupled resting HR) the
     * pattern is NAMED, but the "limiting recovery" read stays, because that is what the score actually did:
     * the easing is detected-only and did NOT change these points. The hedge is deliberate too, since the
     * same low-HRV + low-RHR pattern is also reported for non-functional overreaching, which is the opposite
     * of benign. Byte-for-byte the same strings as the iOS twin.
     */
    private fun hrvVerdict(value: Double, baseline: Double, saturationDetected: Boolean): String = when {
        value > baseline -> "above baseline, supporting recovery"
        value < baseline ->
            if (saturationDetected) {
                "below baseline, limiting recovery, though low resting HR suggests this may be " +
                    "parasympathetic saturation rather than fatigue"
            } else {
                "below baseline, limiting recovery"
            }
        else -> "at baseline"
    }

    /** Resting-HR verdict (lower is better). Mirrors Swift `rhrVerdict` exactly. */
    private fun rhrVerdict(value: Double, baseline: Double): String = when {
        value < baseline -> "below baseline, supporting recovery"
        value > baseline -> "above baseline, limiting recovery"
        else -> "at baseline"
    }

    /** Respiration verdict (lower is better). Mirrors Swift `respVerdict` exactly. */
    private fun respVerdict(value: Double, baseline: Double): String = when {
        value < baseline -> "below baseline, supporting recovery"
        value > baseline -> "above baseline, limiting recovery"
        else -> "at baseline"
    }

    /** Rest-quality verdict (higher is better), centred on sleepPerfCenter. Mirrors Swift `sleepVerdict`. */
    private fun sleepVerdict(sleepPerf: Double): String = when {
        sleepPerf > RecoveryScorer.sleepPerfCenter -> "a strong night, supporting recovery"
        sleepPerf < RecoveryScorer.sleepPerfCenter -> "below a good night, limiting recovery"
        else -> "a typical night"
    }

    /** Half-width (C) of the "typical" skin-temp band; matches Swift skinTempTypicalBandC. */
    private const val SKIN_TEMP_TYPICAL_BAND_C: Double = 0.3

    /**
     * Skin-temp verdict (symmetric): a drift within the typical band reads neutral, beyond it limits
     * recovery, warmer or cooler. Mirrors the Swift skinTempVerdict exactly.
     */
    private fun skinTempVerdict(dev: Double): String = when {
        abs(dev) <= SKIN_TEMP_TYPICAL_BAND_C -> "near baseline"
        dev > 0.0 -> "warmer than baseline, limiting recovery"
        else -> "cooler than baseline, limiting recovery"
    }
}
