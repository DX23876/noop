package com.noop.core

import com.noop.analytics.ReadinessEngine
import com.noop.data.toCoreJson
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android without Room (`docs/fork/android/CORE-ONLY-PLAN.md`, decision 6): Android's screens ask the
 * shared Swift code for the computations they used to run as Kotlin copies (`math.*`, the Swift `CoreMath`). Each
 * Kotlin copy calls in first and keeps its own body only for a build without the core: [enabled] is off until
 * `NoopApplication` turns it on, so the pure-JVM tests keep exercising the Kotlin copy as before.
 */
object CoreMath {
    /** Whether the core answers; `NoopApplication` points it at the loaded library. */
    @Volatile var enabled: () -> Boolean = { false }

    /** A value the core computed; null in its place means the core gave no answer and the caller computes itself. */
    class Answer<T>(val value: T)

    /** The core's answer to [op], or null when the core is not in this build or the call failed. */
    fun call(op: String, args: JSONObject): JSONObject? {
        if (!enabled()) return null
        val text = runCatching { SwiftCore.call(op, args.toString()) }.getOrNull() ?: return null
        val json = runCatching { JSONObject(text) }.getOrNull() ?: return null
        return json.takeUnless { it.has("error") }
    }

    /** A heart-rate series as `[[ts, bpm], …]`. */
    fun <T> hr(rows: List<T>, ts: (T) -> Long, bpm: (T) -> Int): JSONArray =
        JSONArray().apply { rows.forEach { put(JSONArray().put(ts(it)).put(bpm(it))) } }

    fun optDouble(json: JSONObject, key: String): Double? =
        if (!json.has(key) || json.isNull(key)) null else json.optDouble(key).takeUnless { it.isNaN() }

    /** `StrainScorer.strain` in the core: one Effort curve with the fork's calibration, as on iOS. */
    fun strain(hr: List<com.noop.data.HrSample>, maxHR: Double?, restingHR: Double): Answer<Double?>? {
        val args = JSONObject().put("hr", hr(hr, { it.ts }, { it.bpm })).put("restingHR", restingHR)
        if (maxHR != null) args.put("maxHR", maxHR)
        val answer = call("math.strain", args) ?: return null
        return Answer(optDouble(answer, "value"))
    }

    fun profile(p: com.noop.analytics.UserProfile): JSONObject = JSONObject().put("weightKg", p.weightKg)
        .put("heightCm", p.heightCm).put("age", p.age).put("sex", p.sex).put("stepTicksPerStep", p.stepTicksPerStep)

    /** `WorkoutDetector.estimateBoutCalories` in the core: (active, total) kcal for one bout. */
    fun boutCalories(hr: List<com.noop.data.HrSample>, profile: com.noop.analytics.UserProfile, hrmax: Double?,
                     restingHR: Double?): Pair<Double, Double>? {
        val args = JSONObject().put("hr", hr(hr, { it.ts }, { it.bpm })).put("profile", profile(profile))
        if (hrmax != null) args.put("hrmax", hrmax)
        if (restingHR != null) args.put("restingHR", restingHR)
        val answer = call("math.boutCalories", args) ?: return null
        return answer.optDouble("active", 0.0) to answer.optDouble("total", 0.0)
    }

    /** `ReadinessEngine.evaluate` in the core, carrying the core's wording for the card. */
    fun readiness(days: List<com.noop.data.DailyMetric>, today: String?): com.noop.analytics.ReadinessEngine.Readiness? {
        val args = JSONObject().put("days", JSONArray().apply { days.forEach { put(it.toCoreJson()) } })
        if (today != null) args.put("today", today)
        val a = call("math.readiness", args) ?: return null
        return readinessFrom(a)
    }

    internal fun readinessFrom(a: JSONObject): com.noop.analytics.ReadinessEngine.Readiness {
        val level = runCatching { ReadinessEngine.Level.valueOf(a.optString("level").uppercase()) }.getOrDefault(ReadinessEngine.Level.INSUFFICIENT)
        val (headline, summary) = when (level) {
            ReadinessEngine.Level.PRIMED -> ReadinessEngine.Copy.TODAY_READINESS_PRIMED to ReadinessEngine.Copy.TODAY_READINESS_PRIMED_SUMMARY
            ReadinessEngine.Level.BALANCED -> ReadinessEngine.Copy.TODAY_READINESS_BALANCED to ReadinessEngine.Copy.TODAY_READINESS_BALANCED_SUMMARY
            ReadinessEngine.Level.STRAINED -> ReadinessEngine.Copy.TODAY_READINESS_STRAINED to ReadinessEngine.Copy.TODAY_READINESS_STRAINED_SUMMARY
            ReadinessEngine.Level.RUNDOWN -> ReadinessEngine.Copy.TODAY_READINESS_RUN_DOWN to ReadinessEngine.Copy.TODAY_READINESS_RUN_DOWN_SUMMARY
            ReadinessEngine.Level.INSUFFICIENT -> ReadinessEngine.Copy.TODAY_READINESS_MORE_NIGHTS to ReadinessEngine.Copy.TODAY_READINESS_WEAR_FOR_NIGHTS
        }
        val list = a.optJSONArray("signals") ?: JSONArray()
        val signals = (0 until list.length()).map { i ->
            val s = list.getJSONObject(i)
            val key = s.optString("key")
            ReadinessEngine.Signal(
                key = key,
                labelRes = when (key) {
                    "hrv" -> ReadinessEngine.Copy.TODAY_READINESS_SIGNAL_HRV
                    "rhr" -> ReadinessEngine.Copy.TODAY_READINESS_SIGNAL_RESTING_HR
                    "respRate" -> ReadinessEngine.Copy.TODAY_READINESS_SIGNAL_RESPIRATORY
                    "monotony" -> ReadinessEngine.Copy.TODAY_READINESS_SIGNAL_TRAINING_VARIETY
                    else -> ReadinessEngine.Copy.TODAY_READINESS_SIGNAL_TRAINING_LOAD
                },
                detailRes = ReadinessEngine.Copy.TODAY_READINESS_NORMAL_RANGE,
                flag = runCatching { ReadinessEngine.Flag.valueOf(s.optString("flag").uppercase()) }.getOrDefault(ReadinessEngine.Flag.NEUTRAL),
                labelText = s.optString("label").ifEmpty { null },
                detailText = s.optString("detail").ifEmpty { null },
                evidenceText = if (s.isNull("evidence")) null else s.optString("evidence").ifEmpty { null },
            )
        }
        return ReadinessEngine.Readiness(
            level = level, headlineRes = headline, summaryRes = summary, signals = signals, acwr = null,
            monotony = optDouble(a, "monotony"),
            confidence = com.noop.analytics.ScoreConfidence.entries.firstOrNull { it.raw == a.optString("confidence") }
                ?: com.noop.analytics.ScoreConfidence.CALIBRATING,
            headlineText = a.optString("headline").ifEmpty { null },
            summaryText = a.optString("summary").ifEmpty { null },
        )
    }
}
