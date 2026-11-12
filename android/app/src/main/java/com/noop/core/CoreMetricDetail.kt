package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876): a measure's detail page from the shared core (`CoreMetricDetail`, `MetricDetailInsights`): the
 * statistics over the window the page shows, the change against the window before it and the catalog measures that
 * moved with it, as iOS `MetricDetailView` reads them. Blocking; call off the main thread.
 */
object CoreMetricDetail {
    data class Correlation(val key: String, val source: String, val title: String, val category: String,
                           val r: Double, val n: Int)
    data class Insights(val n: Int, val mean: Double?, val min: Double?, val max: Double?, val delta: Double?,
                        val pctChange: Double?, val direction: Int, val correlations: List<Correlation>)

    /** [series] is the measure's whole history and [windowed] the part on screen, both ascending (day, value). */
    fun insights(catalogKey: String, catalogSource: String, series: List<Pair<String, Double>>,
                 windowed: List<Pair<String, Double>>, isAll: Boolean, revision: Int): Insights? {
        if (!SwiftCore.available) return null
        fun pairs(points: List<Pair<String, Double>>) =
            JSONArray().apply { points.forEach { (day, value) -> put(JSONArray().put(day).put(value)) } }
        val args = JSONObject().put("key", catalogKey).put("source", catalogSource).put("series", pairs(series))
            .put("windowed", pairs(windowed)).put("isAll", isAll).put("revision", revision)
        return parse(SwiftCore.call("metric.detailInsights", args.toString()) ?: return null)
    }

    internal fun parse(json: String): Insights? = runCatching {
        val o = JSONObject(json)
        if (o.has("error")) return null
        fun opt(name: String) = if (o.has(name) && !o.isNull(name)) o.getDouble(name) else null
        val rows = o.optJSONArray("correlations") ?: JSONArray()
        Insights(o.optInt("n"), opt("mean"), opt("min"), opt("max"), opt("delta"), opt("pctChange"), o.optInt("direction"),
            (0 until rows.length()).map { rows.getJSONObject(it) }.map {
                Correlation(it.getString("key"), it.getString("source"), it.getString("title"), it.getString("category"),
                            it.getDouble("r"), it.getInt("n"))
            })
    }.getOrNull()
}
