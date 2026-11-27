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

    /** `StrainScorer.strain` in the core: one Effort curve with the fork's calibration, as on iOS. [workout]
     *  scores [hr] as one workout (its time below 50 % HRR counts); false scores a day. */
    fun strain(hr: List<com.noop.data.HrSample>, maxHR: Double?, restingHR: Double,
               workout: Boolean = false): Answer<Double?>? {
        val args = JSONObject().put("hr", hr(hr, { it.ts }, { it.bpm })).put("restingHR", restingHR)
            .put("workout", workout)
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

    /**
     * What adding a sleep by hand over [start, end] would do (`sleep.addPreflight`).
     *
     * The rule is `ManualSleepPlan` in the core, which the Apple side asks the same question: a window on
     * top of a stored sleep is refused with that sleep's span, a window the strap has nothing recorded for
     * is accepted after a warning.
     */
    sealed class AddSleepOutcome {
        object Ok : AddSleepOutcome()
        object NoRawData : AddSleepOutcome()
        object InvalidWindow : AddSleepOutcome()
        data class Blocked(val start: Long, val end: Long) : AddSleepOutcome()
    }

    /** Where the "add a sleep" pickers open (`sleep.addSeed`), by the rule both platforms use. */
    fun addSleepSeed(hasMainSleep: Boolean, dayStart: Long, now: Long): Pair<Long, Long>? {
        if (!CoreShadow.running) return null
        val a = call("sleep.addSeed", JSONObject().put("hasMainSleep", hasMainSleep)
            .put("dayStart", dayStart).put("now", now)) ?: return null
        val start = a.optString("start").toLongOrNull() ?: return null
        val end = a.optString("end").toLongOrNull() ?: return null
        return start to end
    }

    fun addSleepPreflight(deviceId: String, computedDeviceId: String, start: Long, end: Long,
                          method: String, motionAwareWake: Boolean, recipe: String = "standard"): AddSleepOutcome? {
        if (!CoreShadow.running) return null
        val a = call("sleep.addPreflight", JSONObject().put("deviceId", deviceId)
            .put("computedDeviceId", computedDeviceId).put("start", start).put("end", end)
            .put("method", method).put("motionAwareWake", motionAwareWake).put("recipe", recipe)) ?: return null
        return when (a.optString("outcome")) {
            "ok" -> AddSleepOutcome.Ok
            "noRawData" -> AddSleepOutcome.NoRawData
            "blocked" -> AddSleepOutcome.Blocked(a.optString("start").toLongOrNull() ?: 0L,
                                                 a.optString("end").toLongOrNull() ?: 0L)
            else -> AddSleepOutcome.InvalidWindow
        }
    }

    /** A night staged by the core (`sleep.restage`) with [method], [motionAwareWake] and the Lab [recipe]. */
    fun restage(deviceId: String, start: Long, end: Long, method: String, motionAwareWake: Boolean,
                recipe: String = "standard"): Answer<String?>? {
        if (!CoreShadow.running) return null
        val a = call("sleep.restage", JSONObject().put("deviceId", deviceId).put("start", start).put("end", end)
            .put("method", method).put("motionAwareWake", motionAwareWake).put("recipe", recipe)) ?: return null
        return Answer(if (a.isNull("stages")) null else a.optString("stages").ifEmpty { null })
    }
}
