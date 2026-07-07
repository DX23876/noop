package com.noop.analytics

import kotlin.math.ln
import kotlin.math.pow

/*
 * CaffeineDecay.kt — caffeine window (#526): a simple, honest on-device half-life decay estimate.
 *
 * Faithful Kotlin mirror of Strand/Data/CaffeineLog.swift (the CaffeineDecay enum + CaffeineActiveEstimate
 * struct). The user logs a caffeine intake (time + OPTIONAL mg); NOOP shows a rough "still active" hint.
 * This is a GUIDE from what the user logged using a ~5–6 h population-average half-life, NOT a measurement
 * and NOT a health claim. The honesty rules — unknown dose stays unknown, future-dated logs can't amplify
 * a dose — are enforced here and pinned by CaffeineDecayTest. Cross-platform parity is the contract.
 */
object CaffeineDecay {

    /** The half-life used for the estimate, in hours. A population-average adult figure (~5–6 h); the
     *  estimate is only a rough guide because real clearance varies widely. */
    const val DEFAULT_HALF_LIFE_HOURS = 5.5

    /** Fraction (0..1) of a single dose still present [hoursElapsed] after intake. A negative elapsed time
     *  (a future-dated log) clamps to 1.0 — nothing has decayed yet — rather than amplifying the dose. */
    fun fractionRemaining(hoursElapsed: Double, halfLifeHours: Double = DEFAULT_HALF_LIFE_HOURS): Double {
        if (halfLifeHours <= 0) return 0.0
        val t = maxOf(0.0, hoursElapsed)
        return 0.5.pow(t / halfLifeHours)
    }

    /** Estimated mg still active from one dose of [doseMg], [hoursElapsed] after intake. */
    fun remainingMg(doseMg: Double, hoursElapsed: Double, halfLifeHours: Double = DEFAULT_HALF_LIFE_HOURS): Double =
        maxOf(0.0, doseMg) * fractionRemaining(hoursElapsed, halfLifeHours)

    /** Total mg still active across several intakes (each mg + hoursElapsed), at one moment. Intakes with
     *  an unknown dose are excluded from the mg total — we won't invent an amount. */
    fun totalRemainingMg(
        intakes: List<Pair<Double, Double>>, // (doseMg, hoursElapsed)
        halfLifeHours: Double = DEFAULT_HALF_LIFE_HOURS,
    ): Double = intakes.sumOf { remainingMg(it.first, it.second, halfLifeHours) }

    /** Hours until a single dose decays to [fraction] of itself (default 25%, ~two half-lives). */
    fun hoursUntilFraction(fraction: Double, halfLifeHours: Double = DEFAULT_HALF_LIFE_HOURS): Double {
        if (fraction <= 0 || fraction >= 1 || halfLifeHours <= 0) return 0.0
        return halfLifeHours * (ln(fraction) / ln(0.5))
    }

    /** True when a dose is still meaningfully active [hoursElapsed] after intake — more than [threshold]
     *  (default 25%) remains. Covers the dose-UNKNOWN case (can't show mg, but can honestly flag active). */
    fun isStillActive(
        hoursElapsed: Double,
        threshold: Double = 0.25,
        halfLifeHours: Double = DEFAULT_HALF_LIFE_HOURS,
    ): Boolean = fractionRemaining(hoursElapsed, halfLifeHours) > threshold

    // MARK: - Cutoff window (PR#566, mvanhorn) — the latest caffeine time before bed.
    //
    // Reframes [hoursUntilFraction] as a clock-friendly "stop drinking after" cutoff: given a bedtime and
    // an acceptable residual fraction at bedtime, the cutoff is [bedtime − hoursUntilFraction(target)]. A
    // dose taken at the cutoff decays to exactly [targetResidualFraction] by bedtime; anything later still
    // has more than that on board. The math is the same decay model as the "still active" hint — only the
    // framing changes — so the honesty rules carry over (population-average half-life, a guide not a rule).

    /** Default acceptable residual at bedtime: a quarter of the dose. Two half-lives' worth (~11 h on the
     *  5.5 h default), matching the [isStillActive] active threshold so "still active" and "past cutoff"
     *  agree. */
    const val DEFAULT_BEDTIME_RESIDUAL = 0.25

    /** How many hours BEFORE bedtime the caffeine cutoff falls — i.e. the lead time over which a dose
     *  decays to [targetResidualFraction]. A pure number (no clock); the UI subtracts it from bedtime. */
    fun cutoffLeadHours(
        targetResidualFraction: Double = DEFAULT_BEDTIME_RESIDUAL,
        halfLifeHours: Double = DEFAULT_HALF_LIFE_HOURS,
    ): Double = hoursUntilFraction(targetResidualFraction, halfLifeHours)

    /**
     * The caffeine cutoff as minutes-since-midnight, given a [bedtimeMinutes] (also since midnight). The
     * cutoff can fall on the previous day (negative raw value) for an early bedtime + long lead; it's
     * normalised into [0, 1440) so the caller can format it as a wall-clock time. Pure.
     */
    fun cutoffMinutesSinceMidnight(
        bedtimeMinutes: Int,
        targetResidualFraction: Double = DEFAULT_BEDTIME_RESIDUAL,
        halfLifeHours: Double = DEFAULT_HALF_LIFE_HOURS,
    ): Int {
        val leadMin = (cutoffLeadHours(targetResidualFraction, halfLifeHours) * 60.0).toInt()
        val raw = bedtimeMinutes - leadMin
        // Normalise into a single day so an early bedtime with a long lead doesn't read as a negative time.
        return ((raw % 1440) + 1440) % 1440
    }

    /**
     * True when an intake at [intakeMinutes] (minutes since midnight) is LATER than the cutoff for
     * [bedtimeMinutes] — i.e. it'll still have more than [targetResidualFraction] on board at bedtime.
     * Both times are same-day wall-clock minutes; daytime intakes well before the cutoff return false.
     * A cutoff that wrapped to the previous evening (early bedtime) means any same-day intake is "late".
     */
    fun isPastCutoff(
        intakeMinutes: Int,
        bedtimeMinutes: Int,
        targetResidualFraction: Double = DEFAULT_BEDTIME_RESIDUAL,
        halfLifeHours: Double = DEFAULT_HALF_LIFE_HOURS,
    ): Boolean {
        val leadMin = (cutoffLeadHours(targetResidualFraction, halfLifeHours) * 60.0).toInt()
        val rawCutoff = bedtimeMinutes - leadMin
        // Compare on the raw (un-normalised) axis so a cutoff in the previous evening (rawCutoff < 0)
        // correctly makes every positive same-day intake "past cutoff".
        return intakeMinutes > rawCutoff
    }
}

/** One logged caffeine intake — an epoch-seconds timestamp and an OPTIONAL amount in mg. */
data class CaffeineIntake(
    val id: String,
    /** When the caffeine was consumed (unix seconds). */
    val atEpochSec: Long,
    /** Amount in mg, if the user gave one. null = logged it, didn't say how much — never invented. */
    val mg: Double? = null,
)

/** A computed, honest summary of the caffeine still active right now from the logged intakes. Mirror of
 *  Swift CaffeineActiveEstimate. */
data class CaffeineActiveEstimate(
    val activeIntakeCount: Int,
    /** Total mg still active across intakes that HAD a known dose; null when none did (so the UI shows the
     *  dose-unknown phrasing rather than a fabricated mg). */
    val totalRemainingMg: Double?,
    /** Hours since the MOST RECENT still-active intake, for the "had one ~Nh ago" phrasing. */
    val hoursSinceMostRecentActive: Double?,
) {
    val hasActive: Boolean get() = activeIntakeCount > 0

    companion object {
        /** Build the estimate for [nowEpochSec] from a set of intakes using the decay model. Pure. */
        fun compute(
            intakes: List<CaffeineIntake>,
            nowEpochSec: Long,
            halfLifeHours: Double = CaffeineDecay.DEFAULT_HALF_LIFE_HOURS,
            activeThreshold: Double = 0.25,
        ): CaffeineActiveEstimate {
            var activeCount = 0
            var mgSum = 0.0
            var anyMg = false
            var mostRecentActiveHours: Double? = null

            for (intake in intakes) {
                val hours = (nowEpochSec - intake.atEpochSec) / 3600.0
                // A future-dated intake (hours < 0) isn't active yet.
                if (hours < 0) continue
                if (!CaffeineDecay.isStillActive(hours, activeThreshold, halfLifeHours)) continue
                activeCount++
                intake.mg?.let {
                    mgSum += CaffeineDecay.remainingMg(it, hours, halfLifeHours)
                    anyMg = true
                }
                if (mostRecentActiveHours == null || hours < mostRecentActiveHours) {
                    mostRecentActiveHours = hours
                }
            }
            return CaffeineActiveEstimate(
                activeIntakeCount = activeCount,
                totalRemainingMg = if (anyMg) mgSum else null,
                hoursSinceMostRecentActive = mostRecentActiveHours,
            )
        }
    }
}
