package com.noop.core

import android.content.Context
import com.noop.ui.NoopPrefs

/**
 * Fork (DX23876): the two Lab passes of the shared core, off by default as on iOS. The keys are the Apple ones
 * (`HealthspanFeature.defaultsKey`, `RhythmAgeFeature.defaultsKey`), so a setting means the same on both platforms.
 */
object CoreFeatures {
    const val HEALTHSPAN_KEY = "noopHealthspanAge"
    const val RHYTHM_AGE_KEY = "noopRhythmAge"

    /** AgeLess: an age from nine measures of sleep, activity and fitness. */
    fun healthspan(context: Context): Boolean = NoopPrefs.of(context).getBoolean(HEALTHSPAN_KEY, false)

    /** The daily rhythm (CosinorAge beta), WHOOP 5.0 and MG. */
    fun rhythmAge(context: Context): Boolean = NoopPrefs.of(context).getBoolean(RHYTHM_AGE_KEY, false)

    fun setHealthspan(context: Context, on: Boolean) =
        NoopPrefs.of(context).edit().putBoolean(HEALTHSPAN_KEY, on).apply()

    fun setRhythmAge(context: Context, on: Boolean) =
        NoopPrefs.of(context).edit().putBoolean(RHYTHM_AGE_KEY, on).apply()
}
