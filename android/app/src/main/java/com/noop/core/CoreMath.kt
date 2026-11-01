package com.noop.core

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
}
