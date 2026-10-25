package com.noop.ui

import kotlin.math.roundToInt

// The pure helpers of the former Coupled view (task #43), kept for the screens and the view model that still
// read them: the slept-vs-needed duration format, the strain band word and the OPTIMAL strain band.

/** The missing-value placeholder, matching the app's shipped "No Data" token. */
private const val COUPLED_NO_DATA = "No Data"

/** "6h 42m" from a minutes count, for the slept-vs-needed read. Mirrors CoupledView.hoursMinutes EXACTLY. */
internal fun hoursMinutes(minutes: Double): String {
    val total = minutes.roundToInt().coerceAtLeast(0)
    return "${total / 60}h ${total % 60}m"
}

/**
 * The strain band word for a 0..1 fill fraction, byte-identical to the Swift StrandDesign StrainGauge bands
 * (LIGHT/MODERATE/STRENUOUS/HIGH/ALL-OUT at 6/10/14/18 of 21). The Android StrainGauge has no internal state
 * word, so the coupled strain card computes it for the overline.
 */
internal fun strainBandWord(fraction: Double): String = when {
    fraction < 6.0 / 21 -> "LIGHT"
    fraction < 10.0 / 21 -> "MODERATE"
    fraction < 14.0 / 21 -> "STRENUOUS"
    fraction < 18.0 / 21 -> "HIGH"
    else -> "ALL-OUT"
}

// MARK: - OPTIMAL strain range (task #43) — pure display-only recovery->strain mapping
//
// The classic coupled read suggests a Day-Strain target BAND from today's recovery: a green day earns a
// higher optimal band, a red day a lower one. PRESENTATION ONLY, never fed back into any score. These are
// the APPROVED bands and MUST stay byte-identical to the Swift CoupledView.optimalStrainRange:
//   recovery >= 67 (green)        -> 14-18 of 21
//   34 <= recovery <= 66 (yellow) -> 10-14
//   recovery < 34 (red)           -> 4-10
// null recovery (calibrating / unscored day) -> null, the caller renders the no-data token, never a
// guessed band.

internal data class OptimalStrainRange(val low: Int, val high: Int)

/** The pure recovery->optimal-strain band, or null when recovery is unknown. */
internal fun optimalStrainRange(recovery: Double?): OptimalStrainRange? {
    val r = recovery ?: return null
    return when {
        r >= 67 -> OptimalStrainRange(14, 18)
        r >= 34 -> OptimalStrainRange(10, 14)
        else -> OptimalStrainRange(4, 10)
    }
}

/**
 * The optimal band's UPPER bound as a 0..1 fraction of the 0-21 axis, for the tube fill. 0 (an empty tube)
 * when recovery is unknown, so the tube never fabricates a band the text is refusing to name.
 *
 * Twin of Swift CoupledView.optimalUpperFraction. Reads the upper bound rather than the midpoint because
 * the tube shows how far up the axis the suggested band REACHES, which is what pairs with "14 to 18"
 * printed above it.
 */
internal fun optimalUpperFraction(recovery: Double?): Double {
    val band = optimalStrainRange(recovery) ?: return 0.0
    return (band.high.toDouble() / 21.0).coerceIn(0.0, 1.0)
}

/**
 * The optimal strain band as a 0..1 fraction range of the 0-21 axis, for ring target arcs.
 * null when recovery is unknown, so the caller renders no target zone.
 *
 * Sibling of [optimalUpperFraction], which returns only the upper bound for the tube fill.
 * This returns the full band as a range, for the GlowRing target arc.
 */
internal fun optimalFractionRange(recovery: Double?): ClosedFloatingPointRange<Float>? {
    val band = optimalStrainRange(recovery) ?: return null
    val low = (band.low.toDouble() / 21.0).coerceIn(0.0, 1.0).toFloat()
    val high = (band.high.toDouble() / 21.0).coerceIn(0.0, 1.0).toFloat()
    return low..high
}

/** The optimal band as display text ("14 to 18" / the no-data token). Byte-identical to the Swift twin. */
internal fun optimalStrainRangeText(recovery: Double?): String {
    val band = optimalStrainRange(recovery) ?: return COUPLED_NO_DATA
    return "${band.low} to ${band.high}"
}
