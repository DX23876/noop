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
        SwiftCore.call("read.metricSeries", JSONObject().put("deviceId", deviceId).put("key", key).put("from", from).put("to", to).toString())
            ?.let { parseSeries(it, deviceId) }

    fun metricKeys(deviceId: String): List<String>? =
        SwiftCore.call("read.metricKeys", JSONObject().put("deviceId", deviceId).toString())?.let(::parseKeys)

    fun metricCount(deviceId: String, key: String): Int? =
        SwiftCore.call("read.metricCount", JSONObject().put("deviceId", deviceId).put("key", key).toString())?.let(::parseCount)

    fun appleDaily(deviceId: String, from: String, to: String): List<AppleDaily>? =
        SwiftCore.call("read.appleDaily", JSONObject().put("deviceId", deviceId).put("from", from).put("to", to).toString())
            ?.let { parseAppleDaily(it, deviceId) }

    fun dailyMetrics(deviceId: String, from: String, to: String): List<DailyMetric>? =
        SwiftCore.call("read.dailyMetrics", JSONObject().put("deviceId", deviceId).put("from", from).put("to", to).toString())
            ?.let { CoreDailyRows.parse(it, deviceId) }

    // The parsers answer null for anything but the expected shape, including the core's `null` for a failed read,
    // so the repository reads Room instead.
    internal fun parseSeries(json: String, deviceId: String): List<MetricSeriesRow>? = rows(json) { o ->
        MetricSeriesRow(deviceId, o.getString("day"), o.getString("key"), o.getDouble("value"))
    }

    internal fun parseKeys(json: String): List<String>? =
        runCatching { JSONArray(json).let { a -> (0 until a.length()).map(a::getString).sorted() } }.getOrNull()

    internal fun parseCount(json: String): Int? = runCatching { JSONObject(json).getInt("count") }.getOrNull()

    internal fun parseAppleDaily(json: String, deviceId: String): List<AppleDaily>? = rows(json) { o ->
        fun d(k: String) = if (o.has(k) && !o.isNull(k)) o.getDouble(k) else null
        fun n(k: String) = if (o.has(k) && !o.isNull(k)) o.getInt(k) else null
        AppleDaily(deviceId, o.getString("day"), n("steps"), d("activeKcal"), d("basalKcal"), d("vo2max"),
                   n("avgHr"), n("maxHr"), n("walkingHr"), d("weightKg"))
    }

    private fun <T> rows(json: String, row: (JSONObject) -> T): List<T>? =
        runCatching { JSONArray(json).let { a -> (0 until a.length()).map { row(a.getJSONObject(it)) } } }.getOrNull()
}
