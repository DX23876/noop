package com.noop.core

import android.content.Context
import com.noop.analytics.CyclePhaseEngine
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Forge parity 2026-11: the cycle from the shared core (`CoreCycle` in NoopCore over
 * `CycleReading.swift`, the reading the iPhone runs): the phase from the nights, the page's snapshot with the
 * fertile-days estimate, the training pattern and the day log. Android only words and draws it. Blocking; call off
 * the main thread. Analysis migration required: no.
 */
object CoreCycle {
    data class Fertile(val firstDay: Int, val lastDay: Int, val basis: String, val pastRiseDays: List<Int>,
                       val typicalRiseDay: Int?, val status: String?, val daysUntil: Int?, val day: Int?, val of: Int?) {
        val length: Int get() = lastDay - firstDay + 1
    }

    data class Verdict(val kind: String, val rpeDelta: Double?, val volumeDrop: Double?)
    data class Pattern(val cyclesUsed: Int, val progressCycles: Int, val progressRated: Int, val minCycles: Int,
                       val minSessionsPerPhase: Int, val rpeThreshold: Double, val verdicts: Map<String, Verdict>)

    /** One day's notes. [flow] is 1 spotting, 2 light, 3 medium, 4 heavy. */
    data class LogDay(val flow: Int? = null, val symptoms: Set<String> = emptySet(), val moods: Set<String> = emptySet(),
                      val ovulationTest: Boolean = false)

    data class Compare(val tempDelta: Double?, val rhrDelta: Double?, val hrvDelta: Double?, val chargeNow: Double?,
                       val chargeBefore: Double?, val wakeNow: Double?, val wakeBefore: Double?)

    /** The page's snapshot as the core worked it out (`CycleSnapshot`). */
    data class Snapshot(
        val cycleDay: Int?, val dayRange: IntRange?, val length: Int, val phase: String?, val shiftDay: Int?,
        val periodLength: Int, val nextWindow: IntRange?, val temps: List<Pair<Int, Double>>, val startDay: String?,
        val periodDays: Set<String>, val compare: Compare?, val cyclesSeen: Int, val confidence: String?,
        val moodsThisPhase: Map<String, Int>, val fertile: Fertile?, val fertileDays: Set<String>,
        val fertileStartDayAhead: String?,
        /** The phase each day of the dial is drawn in, day 1 first. */
        val dayPhases: List<String?> = emptyList(),
    )

    data class Output(val today: String, val starts: List<String>, val todayLog: LogDay, val result: CyclePhaseEngine.Result?,
                      val snapshot: Snapshot, val pattern: Pattern?)

    /** Stable storage ids, in the order the log sheet shows them (`CycleLog.symptomIds`, `moodIds`). */
    val SYMPTOMS = listOf("cramps", "headache", "bloating", "tender_breasts", "back_pain", "acne", "tired", "cravings")
    val MOODS = listOf("calm", "happy", "irritable", "low", "anxious", "sensitive")

    fun read(context: Context, showFertile: Boolean, learning: Boolean, dismissedWorkouts: List<String>): Output? {
        if (!SwiftCore.available) return null
        CoreRead.open(context)
        val args = JSONObject().put("showFertile", showFertile).put("learning", learning)
            .put("dismissedWorkouts", JSONArray(dismissedWorkouts))
        return SwiftCore.call("cycle.read", args.toString())?.let(::parseOutput)
    }

    /** The phase alone, for the Health signals and the classic tracker. */
    fun phase(context: Context): CyclePhaseEngine.Result? {
        if (!SwiftCore.available) return null
        CoreRead.open(context)
        val json = SwiftCore.call("cycle.phase", "{}") ?: return null
        if (json.trim() == "null") return null
        return runCatching { JSONObject(json).takeIf { !it.has("error") }?.let(::parseResult) }.getOrNull()
    }

    /** Saves today's notes; true when the core also logged a new period start. Null when the save failed. */
    fun save(context: Context, day: String, log: LogDay, previous: LogDay, starts: List<String>): Boolean? {
        if (!SwiftCore.available) return null
        CoreRead.open(context)
        val args = JSONObject().put("day", day).put("log", logJson(log)).put("previous", logJson(previous))
            .put("starts", JSONArray(starts))
        val o = SwiftCore.call("cycle.saveLog", args.toString())?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return null
        return if (o.optBoolean("ok")) o.optBoolean("startLogged") else null
    }

    private fun logJson(d: LogDay) = JSONObject().apply {
        d.flow?.let { put("flow", it) }
        put("symptoms", JSONArray(d.symptoms.sorted())); put("moods", JSONArray(d.moods.sorted()))
        put("ovulationTest", d.ovulationTest)
    }

    private fun JSONObject.intOrNull(k: String) = if (has(k) && !isNull(k)) getInt(k) else null
    private fun JSONObject.doubleOrNull(k: String) = if (has(k) && !isNull(k)) getDouble(k) else null
    private fun JSONObject.stringOrNull(k: String) = if (has(k) && !isNull(k)) getString(k) else null
    private fun JSONArray?.strings(): List<String> = this?.let { a -> (0 until a.length()).map { a.getString(it) } }.orEmpty()

    internal fun parseOutput(json: String): Output? = runCatching {
        val o = JSONObject(json)
        if (o.has("error")) return null
        val log = o.getJSONObject("todayLog")
        val s = o.getJSONObject("snapshot")
        val fertile = s.optJSONObject("fertile")?.let { f ->
            Fertile(f.getInt("firstDay"), f.getInt("lastDay"), f.getString("basis"),
                    f.optJSONArray("pastRiseDays")?.let { a -> (0 until a.length()).map { a.getInt(it) } }.orEmpty(),
                    f.intOrNull("typicalRiseDay"), f.stringOrNull("status"), f.intOrNull("daysUntil"), f.intOrNull("day"), f.intOrNull("of"))
        }
        val compare = s.optJSONObject("compare")?.let { c ->
            Compare(c.doubleOrNull("tempDelta"), c.doubleOrNull("rhrDelta"), c.doubleOrNull("hrvDelta"), c.doubleOrNull("chargeNow"),
                    c.doubleOrNull("chargeBefore"), c.doubleOrNull("wakeNow"), c.doubleOrNull("wakeBefore"))
        }
        val temps = s.optJSONArray("temps")?.let { a -> (0 until a.length()).map { a.getJSONObject(it).let { t -> t.getInt("day") to t.getDouble("value") } } }.orEmpty()
        val moods = s.optJSONObject("moodsThisPhase")?.let { m -> m.keys().asSequence().associateWith { m.getInt(it) } }.orEmpty()
        val snap = Snapshot(
            s.intOrNull("cycleDay"),
            s.intOrNull("dayRangeLow")?.let { lo -> s.intOrNull("dayRangeHigh")?.let { lo..it } },
            s.getInt("length"), s.stringOrNull("phase"), s.intOrNull("shiftDay"), s.getInt("periodLength"),
            s.intOrNull("nextLow")?.let { lo -> s.intOrNull("nextHigh")?.let { lo..it } },
            temps, s.stringOrNull("startDay"), s.optJSONArray("periodDays").strings().toSet(), compare, s.getInt("cyclesSeen"),
            s.stringOrNull("confidence"), moods, fertile, s.optJSONArray("fertileDays").strings().toSet(),
            s.stringOrNull("fertileStartDayAhead"),
            s.optJSONArray("dayPhases")?.let { a -> (0 until a.length()).map { if (a.isNull(it)) null else a.getString(it) } }.orEmpty())
        Output(o.getString("today"), o.optJSONArray("starts").strings(),
               LogDay(log.intOrNull("flow"), log.optJSONArray("symptoms").strings().toSet(), log.optJSONArray("moods").strings().toSet(),
                      log.optBoolean("ovulationTest")),
               o.optJSONObject("result")?.let(::parseResult), snap, o.optJSONObject("pattern")?.let(::parsePattern))
    }.getOrNull()

    private fun parseResult(r: JSONObject): CyclePhaseEngine.Result = CyclePhaseEngine.Result(
        phase = CyclePhaseEngine.Phase.entries.firstOrNull { it.raw == r.getString("phase") } ?: CyclePhaseEngine.Phase.UNKNOWN,
        confidence = CyclePhaseEngine.Confidence.entries.firstOrNull { it.raw == r.getString("confidence") } ?: CyclePhaseEngine.Confidence.LEARNING,
        cycleDayLow = r.intOrNull("cycleDayLow"), cycleDayHigh = r.intOrNull("cycleDayHigh"), cycleLengthDays = r.intOrNull("cycleLengthDays"),
        nextPeriodWindow = r.optJSONObject("nextPeriodWindow")?.let { CyclePhaseEngine.NextPeriodWindow(it.getString("earliestDay"), it.getString("latestDay")) },
        shiftMarkers = r.optJSONArray("shiftMarkers").strings().map { CyclePhaseEngine.ShiftMarker(it) },
        note = r.optString("note"))

    internal fun parsePattern(o: JSONObject): Pattern {
        val v = o.getJSONObject("verdicts")
        val verdicts = v.keys().asSequence().associateWith { k ->
            val x = v.getJSONObject(k)
            Verdict(x.getString("kind"), x.doubleOrNull("rpeDelta"), x.doubleOrNull("volumeDrop"))
        }
        return Pattern(o.getInt("cyclesUsed"), o.getInt("progressCycles"), o.getInt("progressRated"), o.getInt("minCycles"),
                       o.getInt("minSessionsPerPhase"), o.getDouble("rpeThreshold"), verdicts)
    }
}
