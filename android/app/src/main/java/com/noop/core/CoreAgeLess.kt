package com.noop.core

import android.content.Context
import com.noop.ui.ProfileStore
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 2.3: AgeLess from the shared core (`CoreAgeLess` in NoopCore). Every number,
 * pace class, status line and bar position comes resolved from the shared snapshot and engine. Blocking; call off
 * the main thread.
 */
object CoreAgeLess {
    data class Output(val weeks: List<Week>, val today: String)
    data class Week(
        val day: String, val provisional: Boolean, val coveredDays: Int, val age: Double, val actualAge: Double,
        val delta: Double, val pace: Double?, val paceClass: String?, val projectedAge: Double?, val narrative: String,
        val helper: String?, val lever: String?, val levers: List<Lever>, val leversYears: Double?, val domains: List<Domain>,
    )
    data class Lever(val component: String, val current: Double, val next: Double, val years: Double)
    data class Domain(val domain: String, val years: Double, val measures: List<Measure>)
    data class Measure(
        val component: String, val value: Double?, val years: Double?, val position: Double?,
        val targetPosition: Double?, val trendRising: Boolean?, val trendBetter: Boolean?,
    )

    fun snapshot(context: Context): Output? {
        if (!SwiftCore.available) return null
        CoreUserInputs.ensure(context)
        val profile = ProfileStore.from(context)
        val json = SwiftCore.call("ageless.snapshot", JSONObject().put("age", profile.age).put("sex", profile.sex).toString())
            ?: return null
        return parse(json)
    }

    internal fun parse(json: String): Output? {
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return null
        if (o.has("error")) return null
        return Output(o.optJSONArray("weeks").objects().map(::week), o.optString("today"))
    }

    private fun week(w: JSONObject) = Week(
        day = w.getString("day"), provisional = w.optBoolean("provisional"), coveredDays = w.optInt("coveredDays"),
        age = w.getDouble("age"), actualAge = w.getDouble("actualAge"), delta = w.getDouble("delta"),
        pace = w.dbl("pace"), paceClass = w.str("paceClass"), projectedAge = w.dbl("projectedAge"),
        narrative = w.optString("narrative"), helper = w.str("helper"), lever = w.str("lever"),
        levers = w.optJSONArray("levers").objects().map {
            Lever(it.getString("component"), it.getDouble("current"), it.getDouble("next"), it.getDouble("years"))
        },
        leversYears = w.dbl("leversYears"),
        domains = w.optJSONArray("domains").objects().map { d ->
            Domain(d.getString("domain"), d.getDouble("years"), d.optJSONArray("measures").objects().map {
                Measure(it.getString("component"), it.dbl("value"), it.dbl("years"), it.dbl("position"),
                        it.dbl("targetPosition"), it.bool("trendRising"), it.bool("trendBetter"))
            })
        },
    )

    private fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else (0 until length()).map { getJSONObject(it) }
    private fun JSONObject.dbl(k: String): Double? = if (has(k) && !isNull(k)) getDouble(k) else null
    private fun JSONObject.str(k: String): String? = if (has(k) && !isNull(k)) getString(k) else null
    private fun JSONObject.bool(k: String): Boolean? = if (has(k) && !isNull(k)) getBoolean(k) else null
}
