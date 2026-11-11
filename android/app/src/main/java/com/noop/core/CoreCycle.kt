package com.noop.core

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Forge parity 2026-11: the cycle page's two shared reads (`CoreCycle` in NoopCore), the rough
 * fertile-days estimate (`FertileWindow`) and whether the wearer's own training differs by phase
 * (`CycleTrainingPattern`), learned from the same strength sessions and ratings as on iOS. Blocking; call off the
 * main thread. Analysis migration required: no.
 */
object CoreCycle {
    data class Fertile(val firstDay: Int, val lastDay: Int, val basis: String, val pastRiseDays: List<Int>,
                       val typicalRiseDay: Int?, val status: String?, val daysUntil: Int?, val day: Int?, val of: Int?) {
        val length: Int get() = lastDay - firstDay + 1
    }

    data class Verdict(val kind: String, val rpeDelta: Double?, val volumeDrop: Double?)
    data class Pattern(val cyclesUsed: Int, val progressCycles: Int, val progressRated: Int, val minCycles: Int,
                       val minSessionsPerPhase: Int, val rpeThreshold: Double, val verdicts: Map<String, Verdict>)

    /** One logged cycle for the pattern: its start, the temperature rise found inside it and its period length. */
    data class Cycle(val start: String, val shift: String?, val periodDays: Int)

    fun fertile(pastRiseDays: List<Int>, currentRiseDay: Int?, positiveTestDay: Int?, cycleDay: Int?): Fertile? {
        if (!SwiftCore.available) return null
        val args = JSONObject().put("pastRiseDays", JSONArray(pastRiseDays))
        currentRiseDay?.let { args.put("currentRiseDay", it) }
        positiveTestDay?.let { args.put("positiveTestDay", it) }
        cycleDay?.let { args.put("cycleDay", it) }
        return SwiftCore.call("cycle.fertile", args.toString())?.let(::parseFertile)
    }

    fun pattern(context: Context, cycles: List<Cycle>, dismissedWorkouts: List<String>): Pattern? {
        if (!SwiftCore.available) return null
        CoreRead.open(context)
        val list = JSONArray()
        cycles.forEach { c ->
            list.put(JSONObject().put("start", c.start).put("periodDays", c.periodDays).apply { c.shift?.let { put("shift", it) } })
        }
        val args = JSONObject().put("cycles", list).put("dismissedWorkouts", JSONArray(dismissedWorkouts))
        return SwiftCore.call("cycle.pattern", args.toString())?.let(::parsePattern)
    }

    internal fun parseFertile(json: String): Fertile? = runCatching {
        if (json.trim() == "null") return null
        val o = JSONObject(json)
        if (o.has("error")) return null
        val past = o.optJSONArray("pastRiseDays")?.let { a -> (0 until a.length()).map { a.getInt(it) } }.orEmpty()
        fun int(k: String) = if (o.has(k) && !o.isNull(k)) o.getInt(k) else null
        Fertile(o.getInt("firstDay"), o.getInt("lastDay"), o.getString("basis"), past, int("typicalRiseDay"),
                if (o.has("status") && !o.isNull("status")) o.getString("status") else null, int("daysUntil"), int("day"), int("of"))
    }.getOrNull()

    internal fun parsePattern(json: String): Pattern? = runCatching {
        val o = JSONObject(json)
        if (o.has("error")) return null
        val v = o.getJSONObject("verdicts")
        val verdicts = v.keys().asSequence().associateWith { k ->
            val x = v.getJSONObject(k)
            fun d(n: String) = if (x.has(n) && !x.isNull(n)) x.getDouble(n) else null
            Verdict(x.getString("kind"), d("rpeDelta"), d("volumeDrop"))
        }
        Pattern(o.getInt("cyclesUsed"), o.getInt("progressCycles"), o.getInt("progressRated"), o.getInt("minCycles"),
                o.getInt("minSessionsPerPhase"), o.getDouble("rpeThreshold"), verdicts)
    }.getOrNull()
}
