package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Forge parity 2026-11: what a Today measure tile says beside its figure, from the shared core
 * (`MeasureTileReading`, the reading the iPhone's tiles use): the latest value against the median of the 30 before it,
 * and whether that move reads good, small or large for the body. Blocking; call off the main thread. Analysis
 * migration required: no.
 */
object CoreTile {
    /** What a tile over two columns adds: the usual and the last 30 values' range, written as the tile writes them. */
    data class Summary(val usual: String, val low: String, val high: String)
    data class Delta(val text: String?, val tone: String?, val summary: Summary? = null)

    /**
     * What a tile knows about itself beyond today's figure (`MeasureFacts`): the week's average and total, the
     * newest reading with its day and how long ago that was, the change against a reading a week older, and
     * what is left of a goal. A field is null when the data cannot answer it, never a stand-in.
     *
     * One reading for both phones: the same week must not be averaged here and again in Swift, which is where
     * two numbers for one fact begin to disagree.
     */
    data class Facts(val today: Double?, val weekAverage: Double?, val weekTotal: Double?,
                     val lastValue: Double?, val lastDay: String?, val daysSinceLast: Int?,
                     val weekChange: Double?, val target: Double?, val targetLeft: Double?,
                     /** The same figures as the tile writes them, formatted in the core so both phones round alike. */
                     val todayText: String?, val weekAverageText: String?, val weekTotalText: String?,
                     val weekChangeText: String?, val targetLeftText: String?)

    /**
     * [days] and [values] are one series, oldest first and the same length; [today] is the logical day key.
     * [key] is the shared CATALOGUE key ("rhr", not "restingHr"), because that is what decides the decimals.
     */
    fun facts(key: String, days: List<String>, values: List<Double>, today: String, target: Double? = null): Facts? {
        if (!SwiftCore.available || days.isEmpty() || days.size != values.size) return null
        val args = JSONObject().put("key", key).put("days", JSONArray(days)).put("values", JSONArray(values))
            .put("today", today)
        if (target != null) args.put("target", target)
        val json = SwiftCore.call("tile.facts", args.toString()) ?: return null
        return runCatching {
            val o = JSONObject(json)
            fun d(name: String): Double? = if (o.isNull(name)) null else o.optDouble(name)
            fun t(name: String): String? = if (o.isNull(name)) null else o.optString(name)
            Facts(d("today"), d("weekAverage"), d("weekTotal"), d("lastValue"),
                  t("lastDay"), if (o.isNull("daysSinceLast")) null else o.optInt("daysSinceLast"),
                  d("weekChange"), d("target"), d("targetLeft"),
                  t("todayText"), t("weekAverageText"), t("weekTotalText"), t("weekChangeText"), t("targetLeftText"))
        }.getOrNull()
    }

    /** [key] is the shared catalog key ("hrv", "rhr", "spo2", "resp_rate", "skin_temp", "weight", ...). */
    fun delta(key: String, values: List<Double>): Delta? {
        if (!SwiftCore.available || values.size < 8) return null
        val json = SwiftCore.call("tile.delta", JSONObject().put("key", key).put("values", JSONArray(values)).toString()) ?: return null
        return runCatching {
            val o = JSONObject(json)
            val s = o.optJSONObject("summary")
            Delta(if (o.isNull("delta")) null else o.optString("delta"), if (o.isNull("tone")) null else o.optString("tone"),
                  s?.let { Summary(it.optString("usual"), it.optString("low"), it.optString("high")) })
        }.getOrNull()
    }
}
