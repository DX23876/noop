package com.noop.core

import android.content.Context
import com.noop.ui.NoopPrefs
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 2.3: the settings Apple keeps in UserDefaults and the shared core reads from its
 * own (goal limits, rest days, the step goal, a new exercise's sets and rest), read and written through `prefs.read`
 * and `prefs.write`. The core accepts only those keys and their ranges. Keys Kotlin screens also read (weight unit,
 * default rest) are mirrored into [NoopPrefs] under the same name, so both sides agree.
 */
object CorePrefs {
    const val LONG_TERM_LIMIT = "goals.limit.longTerm"
    const val PERIOD_LIMIT = "goals.limit.period"
    const val REST_WEEKDAYS = "training.restWeekdays"
    const val STEP_GOAL = "momentum.stepGoal"
    const val MOTIVATION = "goals.motivation.enabled"
    const val INVITE_DISMISSED = "goals.todayInviteDismissed"
    const val INTRO_SEEN = "goals.introSeen"
    const val NEW_EXERCISE_SETS = "training.newExerciseSets"
    const val DEFAULT_REST = "training.defaultRestSeconds"
    const val WARMUP_REST = "training.warmupRestSeconds"
    const val WEIGHT_UNIT = "training.weightUnit"
    /** Per-set effort entry: `off`, `rir` or `rpe` (`TrainingPreferences.effortKey`, iOS default `rpe`). */
    const val EFFORT_SCALE = "training.effortScale"
    /** Where daily steps come from: `automatic`, `strap` or `phone` (`StepsSource`, iOS Devices and data sources). */
    const val STEPS_SOURCE = "steps.source"
    private val MIRRORED = setOf(DEFAULT_REST, WARMUP_REST, WEIGHT_UNIT, EFFORT_SCALE)

    fun read(context: Context): JSONObject = runCatching {
        CoreRead.open(context)
        JSONObject(SwiftCore.call("prefs.read", "{}") ?: "{}")
    }.getOrDefault(JSONObject())

    /** Where daily steps come from (`automatic`, `strap` or `phone`), as the core holds it; the core must be open. */
    fun stepsSource(): String = runCatching {
        JSONObject(SwiftCore.call("prefs.read", "{}") ?: "{}").optString(STEPS_SOURCE, "automatic")
    }.getOrDefault("automatic")

    /** Sets where daily steps come from; the core rebuilds the AgeLess weeks, which read steps. True when it took it. */
    fun setStepsSource(context: Context, source: String): Boolean = runCatching {
        CoreRead.open(context)
        SwiftCore.call("steps.setSource", JSONObject().put("source", source).toString())?.contains("\"ok\":true") == true
    }.getOrDefault(false).also { if (it) CoreShadow.noteDataChanged() }

    /** True when the core took the value. */
    fun write(context: Context, key: String, value: Any): Boolean {
        val done = runCatching {
            CoreRead.open(context)
            val wire = if (value is List<*>) JSONArray(value) else value
            SwiftCore.call("prefs.write", JSONObject().put("key", key).put("value", wire).toString())
                ?.contains("\"ok\":true") == true
        }.getOrDefault(false)
        if (done && key in MIRRORED) NoopPrefs.of(context).edit().apply {
            when (value) { is Int -> putInt(key, value); is String -> putString(key, value) }
        }.apply()
        return done
    }
}
