package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android plan E-2: what the screens read from the shared core's store. The core resolves each
 * value as the Apple screens do (imported values first, the core's own scores filling the gaps) and answers with a
 * small JSON document; this parses it. Every read blocks until the store answers, so call it off the main thread.
 * A read returns null or an empty list when the core is not in this build, no session runs, or nothing is stored.
 */
object CoreRead {
    /** One day as the Today screen shows it. */
    data class Day(
        val day: String,
        val charge: Double?, val effort: Double?, val rest: Double?,
        val sleepMinutes: Double?, val deepMinutes: Double?, val remMinutes: Double?, val lightMinutes: Double?,
        val efficiency: Double?, val restingHr: Int?, val hrv: Double?, val respRate: Double?, val spo2: Double?,
        val skinTempDev: Double?, val steps: Int?,
    )

    /** One stretch of sleep with its stages; times are epoch seconds. */
    data class Night(
        val startTs: Long, val endTs: Long, val efficiency: Double?, val restingHr: Int?, val hrv: Double?,
        val edited: Boolean, val stages: List<Stage>,
    ) {
        data class Stage(val stage: String, val start: Long, val end: Long)
    }

    /** One value of a metric on one day. */
    data class Point(val day: String, val value: Double)

    /** The metrics a trend screen can chart; the name is the core's. */
    enum class Metric(val key: String) {
        Charge("charge"), Effort("effort"), Rest("rest"), Hrv("hrv"), RestingHr("restingHr"),
        SleepMinutes("sleepMinutes"), RespRate("respRate"),
    }

    fun day(day: String): Day? = read { SwiftCore.readDay(day) }?.let(::parseDay)

    fun nights(from: Long, to: Long): List<Night> = read { SwiftCore.readNights(from, to) }?.let(::parseNights).orEmpty()

    fun series(metric: Metric, from: String, to: String): List<Point> =
        read { SwiftCore.readSeries(metric.key, from, to) }?.let(::parseSeries).orEmpty()

    private inline fun read(call: () -> String?): String? = if (SwiftCore.available) call() else null

    // The core leaves a missing value out of the document rather than writing null; both read as null here.
    private fun JSONObject.double(key: String): Double? = if (has(key) && !isNull(key)) getDouble(key) else null
    private fun JSONObject.int(key: String): Int? = if (has(key) && !isNull(key)) getInt(key) else null

    internal fun parseDay(json: String): Day? {
        if (json == "null") return null
        val o = JSONObject(json)
        return Day(
            day = o.getString("day"),
            charge = o.double("charge"), effort = o.double("effort"), rest = o.double("rest"),
            sleepMinutes = o.double("sleepMinutes"), deepMinutes = o.double("deepMinutes"),
            remMinutes = o.double("remMinutes"), lightMinutes = o.double("lightMinutes"),
            efficiency = o.double("efficiency"), restingHr = o.int("restingHr"), hrv = o.double("hrv"),
            respRate = o.double("respRate"), spo2 = o.double("spo2"), skinTempDev = o.double("skinTempDev"),
            steps = o.int("steps"),
        )
    }

    internal fun parseNights(json: String): List<Night> {
        val a = JSONArray(json)
        return (0 until a.length()).map { i ->
            val o = a.getJSONObject(i)
            val stages = o.getJSONArray("stages").let { s ->
                (0 until s.length()).map { j ->
                    val st = s.getJSONObject(j)
                    Night.Stage(st.getString("stage"), st.getLong("start"), st.getLong("end"))
                }
            }
            Night(o.getLong("startTs"), o.getLong("endTs"), o.double("efficiency"), o.int("restingHr"),
                  o.double("hrv"), o.getBoolean("edited"), stages)
        }
    }

    internal fun parseSeries(json: String): List<Point> {
        val a = JSONArray(json)
        return (0 until a.length()).map { i -> a.getJSONObject(i).let { Point(it.getString("day"), it.getDouble("value")) } }
    }
}
