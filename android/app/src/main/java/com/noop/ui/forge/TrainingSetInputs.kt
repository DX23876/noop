package com.noop.ui.forge

import com.noop.ui.UnitFormatter
import com.noop.ui.UnitSystem

/** Input columns and display-unit conversions only. All training calculations stay in Swift. */
internal enum class TrainingSetInput { Weight, Reps, Left, Right, Seconds, Distance;
    companion object {
        fun columns(mode: String, unilateral: Boolean): List<TrainingSetInput> {
            val reps = if (unilateral) listOf(Left, Right) else listOf(Reps)
            return when (mode) {
                "duration" -> listOf(Seconds)
                "distance_duration" -> listOf(Distance, Seconds)
                "bodyweight_reps", "repetitions" -> reps
                "weight_reps", "weighted_bodyweight", "assisted_bodyweight" -> listOf(Weight) + reps
                else -> emptyList()
            }
        }
        fun editedMeasurement(original: Double?, initialText: String, text: String, convert: (Double) -> Double): Double? {
            if (text == initialText) return original
            return text.replace(',', '.').toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 }?.let(convert)
        }
        fun massForInput(kg: Double, units: UnitSystem): Double =
            if (units == UnitSystem.IMPERIAL) UnitFormatter.kgToPounds(kg) else kg
        fun massForStore(value: Double, units: UnitSystem): Double =
            if (units == UnitSystem.IMPERIAL) value / UnitFormatter.POUNDS_PER_KILOGRAM else value
        fun distanceForInput(meters: Double, units: UnitSystem): Double =
            if (units == UnitSystem.IMPERIAL) UnitFormatter.kmToMiles(meters / 1000) else meters / 1000
        fun distanceForStore(value: Double, units: UnitSystem): Double =
            (if (units == UnitSystem.IMPERIAL) value / UnitFormatter.MILES_PER_KILOMETER else value) * 1000
    }
}
