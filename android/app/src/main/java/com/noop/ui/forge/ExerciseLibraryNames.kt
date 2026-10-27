package com.noop.ui.forge

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.noop.R
import java.util.Locale

@Composable
internal fun equipmentName(id: String): String = EQUIPMENT_NAMES[id]?.let { stringResource(it) }
    ?: id.replace('-', ' ').replace('_', ' ').replaceFirstChar { it.titlecase(Locale.getDefault()) }

@Composable
internal fun measurementName(id: String): String = stringResource(when (id) {
    "weight_reps" -> R.string.forge_library_mode_weight_reps
    "bodyweight_reps" -> R.string.forge_library_mode_bodyweight_reps
    "weighted_bodyweight" -> R.string.forge_library_mode_weighted_bodyweight
    "assisted_bodyweight" -> R.string.forge_library_mode_assisted_bodyweight
    "repetitions" -> R.string.forge_library_mode_repetitions
    "duration" -> R.string.forge_library_mode_duration
    "distance_duration" -> R.string.forge_library_mode_distance_duration
    else -> R.string.forge_library_region_other
})

@Composable
internal fun regionName(id: String): String = stringResource(when (id) {
    "chest" -> R.string.forge_library_region_chest
    "back" -> R.string.forge_library_region_back
    "shoulders" -> R.string.forge_library_region_shoulders
    "arms" -> R.string.forge_library_region_arms
    "core" -> R.string.forge_library_region_core
    "legs" -> R.string.forge_library_region_legs
    else -> R.string.forge_library_region_other
})

@Composable
internal fun librarySourceName(source: String): String = when (source) {
    "user" -> stringResource(R.string.forge_library_created_by_you)
    "exercise_db" -> "ExerciseDB"
    "imported" -> stringResource(R.string.forge_library_imported)
    else -> "NOOP"
}

private val EQUIPMENT_NAMES = mapOf(
    "barbell" to R.string.forge_library_eq_barbell,
    "dumbbell" to R.string.forge_library_eq_dumbbell,
    "kettlebell" to R.string.forge_library_eq_kettlebell,
    "cable" to R.string.forge_library_eq_cable,
    "machine" to R.string.forge_library_eq_machine,
    "band" to R.string.forge_library_eq_band,
    "bench" to R.string.forge_library_eq_bench,
    "pull-up-bar" to R.string.forge_library_eq_pull_up_bar,
    "squat-rack" to R.string.forge_library_eq_squat_rack,
    "weight-belt" to R.string.forge_library_eq_weight_belt,
    "bodyweight" to R.string.forge_library_eq_bodyweight,
    "ez-bar" to R.string.forge_library_eq_ez_bar,
    "trap-bar" to R.string.forge_library_eq_trap_bar,
    "smith-machine" to R.string.forge_library_eq_smith_machine,
    "stability-ball" to R.string.forge_library_eq_stability_ball,
    "bosu-ball" to R.string.forge_library_eq_bosu_ball,
    "foam-roller" to R.string.forge_library_eq_foam_roller,
    "ab-wheel" to R.string.forge_library_eq_ab_wheel,
    "rope" to R.string.forge_library_eq_rope,
    "tire" to R.string.forge_library_eq_tire,
    "hammer" to R.string.forge_library_eq_hammer,
    "dip-bar" to R.string.forge_library_eq_dip_bar,
    "box" to R.string.forge_library_eq_box,
    "medicine-ball" to R.string.forge_library_eq_medicine_ball,
    "sled" to R.string.forge_library_eq_sled,
    "rings" to R.string.forge_library_eq_rings,
)
