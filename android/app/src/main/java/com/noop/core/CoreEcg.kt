package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 2.3: saved WHOOP MG ECG readings from the shared core (`CoreEcg`): the list,
 * one reading's strip with the strap's result and the measurements taken from it. Blocking; call off the main thread.
 */
object CoreEcg {
    data class Reading(
        val id: String, val startTs: Long, val category: String, val title: String, val tone: String,
        val averageHr: Int?, val variability: Int?, val seconds: Int, val wrist: String, val resultCode: Int,
        val quality: Int?, val missingSegments: Int, val interruptions: Int, val status: String, val unreadable: List<String>,
    )
    data class Analysis(
        val meanHeartRate: Double, val minHeartRate: Double, val maxHeartRate: Double, val irregularBeats: Int,
        val rmssdMs: Double?, val sdnnMs: Double?, val pnn50: Double?, val template: List<Double>, val templateRIndex: Int,
        val beatsAveraged: Int, val beatsDetected: Int, val fiducialsMs: List<Pair<String, Double>>,
        val prMs: Double?, val qrsMs: Double?, val qtMs: Double?, val qtcFridericiaMs: Double?,
    )
    data class Detail(val reading: Reading, val samples: List<Int?>, val analysis: Analysis?)

    fun readings(): List<Reading>? = call("ecg.readings", "{}")?.let(::parseList)
    fun delete(id: String): List<Reading>? = call("ecg.delete", JSONObject().put("id", id).toString())?.let(::parseList)
    fun reading(id: String): Detail? = call("ecg.reading", JSONObject().put("id", id).toString())?.let(::parseDetail)

    private fun JSONObject.dbl(k: String) = if (has(k) && !isNull(k)) getDouble(k) else null
    private fun JSONObject.int(k: String) = if (has(k) && !isNull(k)) getInt(k) else null

    internal fun parseList(json: String): List<Reading>? {
        val a = runCatching { JSONObject(json).getJSONArray("readings") }.getOrNull() ?: return null
        return (0 until a.length()).map { reading(a.getJSONObject(it)) }
    }

    private fun reading(o: JSONObject) = Reading(
        o.getString("id"), o.getLong("startTs"), o.optString("category"), o.optString("title"), o.optString("tone"),
        o.int("averageHr"), o.int("variability"), o.optInt("seconds"), o.optString("wrist"), o.optInt("resultCode"),
        o.int("quality"), o.optInt("missingSegments"), o.optInt("interruptions"), o.optString("status"),
        o.optJSONArray("unreadable").let { u -> (0 until (u?.length() ?: 0)).map { u!!.getString(it) } },
    )

    internal fun parseDetail(json: String): Detail? {
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return null
        val samples = o.optJSONArray("samples") ?: JSONArray()
        val analysis = o.optJSONObject("analysis")?.let { a ->
            val t = a.optJSONArray("template") ?: JSONArray()
            Analysis(
                a.getDouble("meanHeartRate"), a.getDouble("minHeartRate"), a.getDouble("maxHeartRate"), a.optInt("irregularBeats"),
                a.dbl("rmssdMs"), a.dbl("sdnnMs"), a.dbl("pnn50"), (0 until t.length()).map { t.getDouble(it) },
                a.optInt("templateRIndex"), a.optInt("beatsAveraged"), a.optInt("beatsDetected"),
                listOf("P" to "pOnsetMs", "Q" to "qrsOnsetMs", "J" to "jPointMs", "T" to "tEndMs")
                    .mapNotNull { (label, key) -> a.dbl(key)?.let { label to it } },
                a.dbl("prMs"), a.dbl("qrsMs"), a.dbl("qtMs"), a.dbl("qtcFridericiaMs"),
            )
        }
        return Detail(reading(o.getJSONObject("reading")),
                      (0 until samples.length()).map { if (samples.isNull(it)) null else samples.getInt(it) }, analysis)
    }

    private fun call(op: String, args: String): String? = if (SwiftCore.available) SwiftCore.call(op, args) else null
}
