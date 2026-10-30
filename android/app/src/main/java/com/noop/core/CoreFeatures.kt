package com.noop.core

import android.content.Context
import com.noop.ui.NoopPrefs

/**
 * Fork (DX23876): the Lab switches of the shared core, off by default as on iOS. The keys are the Apple ones
 * (`HealthspanFeature.defaultsKey`, `RhythmAgeFeature.defaultsKey`), so a setting means the same on both platforms.
 */
object CoreFeatures {
    const val HEALTHSPAN_KEY = "noopHealthspanAge"
    const val RHYTHM_AGE_KEY = "noopRhythmAge"
    const val EXERCISE_VO2MAX_KEY = "noopExerciseVO2max"
    const val EFFORT_STRENGTH_BONUS_KEY = "noopEffortStrengthBonus"

    /** AgeLess: an age from nine measures of sleep, activity and fitness. */
    fun healthspan(context: Context): Boolean = NoopPrefs.of(context).getBoolean(HEALTHSPAN_KEY, false)

    /** The daily rhythm (CosinorAge beta), WHOOP 5.0 and MG. */
    fun rhythmAge(context: Context): Boolean = NoopPrefs.of(context).getBoolean(RHYTHM_AGE_KEY, false)

    /** Training-based VO₂max on Training Load (`PuffinExperiment.exerciseVO2maxKey`). */
    fun exerciseVO2max(context: Context): Boolean = NoopPrefs.of(context).getBoolean(EXERCISE_VO2MAX_KEY, false)

    fun setExerciseVO2max(context: Context, on: Boolean) =
        NoopPrefs.of(context).edit().putBoolean(EXERCISE_VO2MAX_KEY, on).apply()

    /** Rated strength sessions add to Effort (`PuffinExperiment.effortStrengthBonusKey`), read by the core's pass. */
    fun effortStrengthBonus(context: Context): Boolean =
        NoopPrefs.of(context).getBoolean(EFFORT_STRENGTH_BONUS_KEY, false)

    fun setEffortStrengthBonus(context: Context, on: Boolean) =
        NoopPrefs.of(context).edit().putBoolean(EFFORT_STRENGTH_BONUS_KEY, on).apply()

    fun setHealthspan(context: Context, on: Boolean) =
        NoopPrefs.of(context).edit().putBoolean(HEALTHSPAN_KEY, on).apply()

    fun setRhythmAge(context: Context, on: Boolean) =
        NoopPrefs.of(context).edit().putBoolean(RHYTHM_AGE_KEY, on).apply()
}
