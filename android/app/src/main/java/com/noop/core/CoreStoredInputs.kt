package com.noop.core

import com.noop.data.AppleDaily
import com.noop.data.DailyMetric
import com.noop.data.MetricSeriesRow
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 1.3: the stored inputs the core has held since the input lanes moved
 * (2026-10-28), read back one source at a time: imported and check-in series, imported days and the Health
 * Connect and Apple Health days. [owns] says which sources those are: everything but a computed ("-noop") source,
 * which the core only has once the strap path runs through it. Behind the same Lab switch as the daily rows;
 * [com.noop.data.WhoopRepository] reads it. Blocking; call off the main thread.
 */
object CoreStoredInputs {
    /** Whether the lanes mirror [deviceId]'s rows into the core (`CoreInputLanes.mirror`). */
    fun owns(deviceId: String): Boolean = SwiftCore.available && !deviceId.endsWith("-noop")

    fun metricSeries(deviceId: String, key: String, from: String, to: String): List<MetricSeriesRow>? =
        array("read.metricSeries", JSONObject().put("deviceId", deviceId).put("key", key).put("from", from).put("to", to))
            ?.let { a -> (0 until a.length()).map { a.getJSONObject(it).let { o ->
                MetricSeriesRow(deviceId, o.getString("day"), o.getString("key"), o.getDouble("value")) } } }

    fun metricKeys(deviceId: String): List<String>? =
        array("read.metricKeys", JSONObject().put("deviceId", deviceId))?.let { a -> (0 until a.length()).map(a::getString).sorted() }

    fun metricCount(deviceId: String, key: String): Int? =
        SwiftCore.call("read.metricCount", JSONObject().put("deviceId", deviceId).put("key", key).toString())
            ?.let { runCatching { JSONObject(it).getInt("count") }.getOrNull() }

    fun appleDaily(deviceId: String, from: String, to: String): List<AppleDaily>? =
        array("read.appleDaily", JSONObject().put("deviceId", deviceId).put("from", from).put("to", to))
            ?.let { a -> (0 until a.length()).map { a.getJSONObject(it).let { o ->
                fun d(k: String) = if (o.has(k) && !o.isNull(k)) o.getDouble(k) else null
                fun n(k: String) = if (o.has(k) && !o.isNull(k)) o.getInt(k) else null
                AppleDaily(deviceId, o.getString("day"), n("steps"), d("activeKcal"), d("basalKcal"), d("vo2max"),
                           n("avgHr"), n("maxHr"), n("walkingHr"), d("weightKg"))
            } } }

    fun dailyMetrics(deviceId: String, from: String, to: String): List<DailyMetric>? =
        SwiftCore.call("read.dailyMetrics", JSONObject().put("deviceId", deviceId).put("from", from).put("to", to).toString())
            ?.let { CoreDailyRows.parse(it, deviceId) }

    private fun array(op: String, args: JSONObject): JSONArray? =
        SwiftCore.call(op, args.toString())?.let { runCatching { JSONArray(it) }.getOrNull() }
}
