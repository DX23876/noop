package com.noop.ui

import android.content.Context

/**
 * AutoWorkoutPrefs — the dismissed spans the old auto-detect Today card recorded ("startSec:endSec" tokens,
 * twin of the iOS "workouts.autoDetectDismissed" list). Nothing writes them any more; activity detection's
 * resolver honours them so a span the wearer once rejected is never asked about again (decision 2026-10-31).
 */
object AutoWorkoutPrefs {
    private const val FILE = "noop_auto_workout_prefs"
    private const val KEY_DISMISSED = "workouts.autoDetectDismissed"

    fun dismissedTokens(ctx: Context): List<String> =
        ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .getStringSet(KEY_DISMISSED, emptySet()).orEmpty().toList()
}
