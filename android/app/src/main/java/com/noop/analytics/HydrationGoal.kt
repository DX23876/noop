package com.noop.analytics

import kotlin.math.roundToInt

/**
 * HydrationGoal — the pure, testable daily fluid-goal engine for the Hydration tracker (MVP).
 *
 * Kotlin twin of the Swift `HydrationGoal` helper; keep every constant + rounding rule BYTE-IDENTICAL so
 * iOS and Android resolve the same goal from the same inputs. No I/O, no Android types — a closed-form
 * function over the user's biological sex and today's Effort/strain score, unit-tested on the JVM.
 *
 * Daily GOAL (ml) = sexBaseline + effortBump, rounded to the nearest 50.
 *   - sexBaseline: male 3700, female 2700, unspecified/other 3200 (read from the profile sex field;
 *     `UserProfile.sex` carries "male" | "female" | "nonbinary").
 *   - effortBump: when today's Effort/strain (0..100) is available, round(effort / 100 * 700), capped
 *     to 0..700; when there's no Effort yet, 0.
 *
 * The output never depends on how much the user has logged — it's a TARGET, derived only from the body
 * profile and the day's load. Logging totals live in the metric-series store, not here.
 */
object HydrationGoal {

    /** Sex baselines (ml), matching the Swift source exactly. */
    const val BASELINE_MALE: Int = 3700
    const val BASELINE_FEMALE: Int = 2700
    const val BASELINE_OTHER: Int = 3200

    /** The most extra fluid a hard day can add (ml). The effort bump is capped here. */
    const val MAX_EFFORT_BUMP: Int = 700

    /** Goals are rounded to the nearest multiple of this (ml) so the readout is a clean round number. */
    const val ROUND_TO: Int = 50

    /** Quick-log amounts (ml). Each tap adds one of these to the day total. */
    const val SIP_ML: Int = 30
    const val CUP_ML: Int = 237
    const val BOTTLE_ML: Int = 500

    /**
     * The sex baseline (ml) for a profile `sex` tag. Anything that isn't "male" / "female" (i.e.
     * "nonbinary", unspecified, an unknown value) falls to the neutral [BASELINE_OTHER]. Case- and
     * whitespace-insensitive, matching the Swift normalisation.
     */
    fun baselineForSex(sex: String): Int = when (sex.trim().lowercase()) {
        "male", "m" -> BASELINE_MALE
        "female", "f" -> BASELINE_FEMALE
        else -> BASELINE_OTHER
    }

    /**
     * The effort bump (ml) for an Effort/strain score in 0..100, or 0 when [effort] is null (no Effort
     * scored yet). `round(effort / 100 * 700)`, then clamped into 0..[MAX_EFFORT_BUMP] so an out-of-range
     * input can't push the goal past the cap or below the baseline.
     */
    fun effortBump(effort: Double?): Int {
        if (effort == null) return 0
        val raw = (effort / 100.0 * MAX_EFFORT_BUMP).roundToInt()
        return raw.coerceIn(0, MAX_EFFORT_BUMP)
    }

    /**
     * The daily goal (ml): [baselineForSex] + [effortBump], rounded to the nearest [ROUND_TO]. [effort]
     * is today's Effort/strain (0..100) or null when not yet scored. Pure — no store reads.
     */
    fun dailyGoalMl(sex: String, effort: Double?): Int {
        val raw = baselineForSex(sex) + effortBump(effort)
        return roundToNearest(raw, ROUND_TO)
    }

    /** Round [value] to the nearest multiple of [step] (step > 0). Half rounds up, matching Swift's
     *  `(value / step).rounded() * step`. */
    fun roundToNearest(value: Int, step: Int): Int {
        if (step <= 0) return value
        return ((value + step / 2) / step) * step
    }
}
