package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/** Prepared period totals and adaptations. Kotlin only lays out the finished core readings. */
object CoreTrainingHistory {
    data class Period(val start: String, val end: String, val total: Double?, val estimatedTotal: Double?,
                      val level: Double?, val band: String?, val knownDays: Int, val unknownDays: Int,
                      val estimatedDays: Int, val unrecordedDays: Int, val measured: Int?, val possible: Int?)
    data class Value(val start: String, val end: String, val value: Double?)
    data class Lift(val id: String, val title: String, val values: List<Value>)
    data class Choice(val id: String, val title: String, val sessions: Int)
    data class Output(val span: String, val first: String, val last: String, val resolution: String,
                      val today: String, val earliest: String?, val jumpDay: String?,
                      val strength: List<Period>, val cardio: List<Period>, val session: List<Period>,
                      val lifts: List<Lift>, val choices: List<Choice>, val vo2: List<Value>, val vo2Apple: List<Value>)

    fun read(span: String, jumpDay: String?, lifts: List<String>, maxHR: Double, sex: String,
             dismissedWorkouts: List<String>): Output? {
        val args = JSONObject().put("span", span).put("lifts", JSONArray(lifts))
            .put("maxHR", maxHR).put("sex", sex).put("dismissedWorkouts", JSONArray(dismissedWorkouts))
        jumpDay?.let { args.put("jumpDay", it) }
        return SwiftCore.call("training.history", args.toString())?.let(::parse)
    }

    internal fun parse(json: String): Output? = runCatching {
        val o = JSONObject(json)
        if (o.has("error")) return null
        fun periods(key: String) = o.objects(key).map { p ->
            Period(p.getString("start"), p.getString("end"), p.number("total"), p.number("estimatedTotal"),
                p.number("level"), p.text("band"), p.getInt("knownDays"), p.getInt("unknownDays"),
                p.getInt("estimatedDays"), p.getInt("unrecordedDays"), p.integer("measured"), p.integer("possible"))
        }
        Output(o.getString("span"), o.getString("first"), o.getString("last"), o.getString("resolution"),
            o.getString("today"), o.text("earliest"), o.text("jumpDay"), periods("strength"), periods("cardio"), periods("session"),
            o.objects("lifts").map { Lift(it.getString("id"), it.getString("title"), values(it, "values")) },
            o.objects("choices").map { Choice(it.getString("id"), it.getString("title"), it.getInt("sessions")) },
            values(o, "vo2"), values(o, "vo2Apple"))
    }.getOrNull()

    private fun values(o: JSONObject, key: String) = o.objects(key).map {
        Value(it.getString("start"), it.getString("end"), it.number("value"))
    }
    private fun JSONObject.objects(key: String): List<JSONObject> = getJSONArray(key).let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
    private fun JSONObject.text(key: String): String? = if (isNull(key)) null else getString(key)
    private fun JSONObject.number(key: String): Double? = if (isNull(key)) null else getDouble(key)
    private fun JSONObject.integer(key: String): Int? = if (isNull(key)) null else getInt(key)
}
