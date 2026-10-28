package com.noop.core

import com.noop.analytics.DaytimeStress
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 1.3: today's daytime stress from the shared core (`CoreStress` in NoopCore),
 * which reads the core's union store and scores it as Apple's `StressDayCurve` does (`DaytimeStressDay`). The answer
 * maps onto the existing [DaytimeStress.Result], so the Stress screen and the widget draw it unchanged. Null when the
 * core is not available; the caller then keeps its Room path. Blocking; call off the main thread.
 */
object CoreStress {
    data class Day(val result: DaytimeStress.Result, val usesPersonalBaseline: Boolean)

    fun day(personalBaseline: Boolean): Day? {
        if (!SwiftCore.available) return null
        return SwiftCore.call("stress.day", JSONObject().put("personal", personalBaseline).toString())?.let(::parse)
    }

    /** Today's union heart-rate fingerprint so far, or null when the core cannot tell. */
    fun fingerprint(): String? {
        if (!SwiftCore.available) return null
        val json = SwiftCore.call("stress.fingerprint", "{}") ?: return null
        return runCatching { JSONObject(json).getString("fingerprint") }.getOrNull()?.takeIf { it.isNotEmpty() }
    }

    internal fun parse(json: String): Day? {
        if (json == "null" || json.contains("\"error\"")) return null
        val o = JSONObject(json)
        fun hours(a: JSONArray?) = if (a == null) emptyList() else (0 until a.length()).map { hour(a.getJSONObject(it)) }
        val hours = hours(o.optJSONArray("hours"))
        return Day(
            DaytimeStress.Result(
                hours = hours, sustainedHigh = o.optBoolean("sustainedHigh"), sustainedRun = o.optInt("sustainedRun"),
                dayMean = o.dbl("dayMean"), peak = o.optJSONObject("peak")?.let(::hour),
                activityMaskedHours = o.optInt("activityMaskedHours"), highStressMinutes = o.optInt("highStressMinutes"),
                hrOnlyFallback = o.optBoolean("hrOnlyFallback"),
                timeline = o.optJSONArray("timeline")?.let { hours(it) } ?: hours,
            ),
            usesPersonalBaseline = o.optBoolean("usesPersonalBaseline"),
        )
    }

    private fun hour(h: JSONObject) = DaytimeStress.HourPoint(
        hour = h.getInt("hour"), startTs = h.getLong("startTs"), level = h.dbl("level"), meanHr = h.dbl("meanHR"),
        rmssd = h.dbl("rmssd"), maskedForActivity = h.optBoolean("masked"),
    )

    private fun JSONObject.dbl(key: String): Double? = if (has(key) && !isNull(key)) getDouble(key) else null
}
