package com.noop.core

import com.noop.data.WhoopRepository
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 1.3: one metric resolved across every compatible source as the iPhone's
 * `Repository.resolvedSeries` does (`MetricResolver`, `read.resolvedSeries`). Behind the same Lab switch as the daily
 * rows ([CoreDailyRows.coreReads]); Health, Lab Book and Compare read it through [WhoopRepository.resolvedSeries].
 * Blocking; call off the main thread.
 */
object CoreResolvedSeries {
    fun read(key: String, source: String, from: String, to: String, whoopSource: String): WhoopRepository.MetricSeriesResolution? {
        if (!SwiftCore.available) return null
        val json = SwiftCore.call("read.resolvedSeries", JSONObject().put("key", key).put("source", source)
            .put("from", from).put("to", to).put("whoopSource", whoopSource).toString()) ?: return null
        return parse(json)
    }

    internal fun parse(json: String): WhoopRepository.MetricSeriesResolution? {
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return null
        if (!o.has("points")) return null
        val c = o.getJSONArray("candidates"); val p = o.getJSONArray("points")
        return WhoopRepository.MetricSeriesResolution(
            o.getString("requestedSource"),
            (0 until c.length()).map { c.getJSONObject(it).let { x -> WhoopRepository.MetricSourceCandidate(x.getString("source"), x.getString("key")) } },
            (0 until p.length()).map { p.getJSONObject(it).let { x ->
                WhoopRepository.ResolvedMetricPoint(x.getString("day"), x.getDouble("value"), x.getString("source"), x.getString("sourceKey")) } },
        )
    }
}
