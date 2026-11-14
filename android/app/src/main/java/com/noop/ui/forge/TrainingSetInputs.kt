package com.noop.ui.forge

import com.noop.ui.UnitFormatter
import com.noop.ui.UnitSystem

/** Input columns and display-unit conversions only. All training calculations stay in Swift. */
internal enum class TrainingSetInput { Weight, Reps, Left, Right, Seconds, Distance;
    companion object {
        /**
         * Which fields a set of this exercise records. [semantics] is the exercise's own load meaning
         * where it has one (`ExerciseLoadSemantics`): a movement the catalogue calls bodyweight records
         * the plate hung from it too, and without that there was nowhere to put it (#43).
         *
         * The twin of the core's `TrainingSetColumns.inputs`, which the Apple logger reads; the two
         * answer the same question and a column one app draws and the other does not is a number one app
         * cannot show.
         */
        fun columns(mode: String, unilateral: Boolean, semantics: String? = null): List<TrainingSetInput> {
            val reps = if (unilateral) listOf(Left, Right) else listOf(Reps)
            val carriesLoad = semantics == "added_bodyweight" || semantics == "assistance"
            return when (mode) {
                "weight_duration" -> listOf(Weight, Seconds)
                "distance_weight" -> listOf(Weight, Distance)
                "duration" -> listOf(Seconds)
                "distance_duration" -> listOf(Distance, Seconds)
                "bodyweight_reps", "repetitions" -> if (carriesLoad) listOf(Weight) + reps else reps
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
