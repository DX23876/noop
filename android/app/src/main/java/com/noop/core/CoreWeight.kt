package com.noop.core

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

/**
 * Fork (DX23876), owner decisions 2026-11-26: the weight page from the shared core (`CoreWeight.swift`,
 * `WeightTracker`). Every figure comes from the core; this file only parses it and sends the wearer's settings and
 * dates back. Settings and dates live in the goal preferences, so the goals backup carries them. Blocking; call
 * off the main thread.
 */
object CoreWeight {
    data class Point(val at: Long, val kg: Double)
    data class Change(val days: Int?, val kg: Double)
    data class Week(val high: Point, val low: Point, val latest: Point, val trendKg: Double, val readings: List<Point>, val trend: List<Point>)
    data class Rates(val current: Double?, val overall: Double?, val wish: Double?, val wishSource: String?, val wishIsSteep: Boolean)
    data class Forecast(val startKg: Double, val basis: String, val startAt: Long, val rateMode: String, val rateKgPerWeek: Double?,
                        val state: String, val targetAt: Long?)
    data class Event(val id: String, val name: String, val day: String)
    data class EventForecast(val event: Event, val phase: String, val daysAway: Int, val predictedKg: Double?,
                             val predictedBeforeKg: Double?, val measuredKg: Double?)
    data class Milestone(val kg: Double, val reachedDay: String?)
    data class Milestones(val route: List<Milestone>, val reachedCount: Int, val next: Double?, val toNextKg: Double?, val progress: Double)
    data class Goal(val baseline: Double, val target: Double, val createdAt: Long, val targetAt: Long?, val band: Double?)
    data class Reading(val at: Long, val kg: Double, val note: String?, val id: String?, val source: String)
    data class LogRow(val reading: Reading, val day: String, val trendKg: Double, val weeklyRateKg: Double?, val milestoneKg: Double?)
    data class Report(val period: String, val key: String, val start: Long, val count: Int, val enough: Boolean, val low: Point?,
                      val averageKg: Double?, val trendChangeKg: Double?, val ratePerWeekKg: Double?, val vsPreviousKg: Double?,
                      val readings: List<Point>, val trend: List<Point>)
    data class Snapshot(
        val latest: Point, val trendKg: Double, val trendSettled: Boolean, val readingCount: Int, val changes: List<Change>,
        val week: Week?, val rates: Rates, val forecast: Forecast, val events: List<EventForecast>, val milestones: Milestones?,
        val goal: Goal?, val log: List<LogRow>, val months: List<Report>, val years: List<Report>,
        val readings: List<Point>, val trend: List<Point>,
    )
    /** The wearer's choices, field for field as Swift `WeightTracker.Settings`. */
    data class Settings(
        val basis: String = "trend", val rateMode: String = "current", val rateWindowDays: Int = 28,
        val milestoneStepKg: Double? = null, val manualWishKgPerWeek: Double? = null, val hiddenCards: List<String> = emptyList(),
    ) {
        fun json(): String = JSONObject().apply {
            put("basis", basis); put("rateMode", rateMode); put("rateWindowDays", rateWindowDays)
            milestoneStepKg?.let { put("milestoneStepKg", it) }; manualWishKgPerWeek?.let { put("manualWishKgPerWeek", it) }
            put("hiddenCards", JSONArray(hiddenCards))
        }.toString()
        fun shows(card: String) = card !in hiddenCards
    }
    data class Page(val snapshot: Snapshot?, val settings: Settings, val events: List<Event>, val goalSource: String?)

    fun page(context: Context): Page? {
        if (!SwiftCore.available) return null
        CoreUserInputs.ensure(context)
        val plan = com.noop.ui.NoopPrefs.of(context).getString(CoreDietPlan.KEY, null)
        val json = SwiftCore.call("weight.snapshot", JSONObject().apply { plan?.let { put("plan", it) } }.toString()) ?: return null
        return parse(json)
    }

    fun saveSettings(settings: Settings): Boolean =
        ok(SwiftCore.call("weight.saveSettings", JSONObject().put("settings", settings.json()).toString()))

    fun saveEvent(id: String?, name: String, day: String): Boolean =
        ok(SwiftCore.call("weight.saveEvent", JSONObject().put("name", name).put("day", day).apply { id?.let { put("id", it) } }.toString()))

    fun deleteEvent(id: String): Boolean = ok(SwiftCore.call("weight.deleteEvent", JSONObject().put("id", id).toString()))

    /** The daily weigh-in reminder's next moment by the shared rule, or null when none falls in the next three weeks. */
    fun nextReminder(context: Context, minutes: Int, weekdays: Set<Int>, now: Instant): Instant? {
        if (!SwiftCore.available) return null
        CoreUserInputs.ensure(context)
        val json = SwiftCore.call("weight.nextReminder", JSONObject().put("minutes", minutes)
            .put("weekdays", JSONArray(weekdays.sorted())).put("now", now.epochSecond).toString()) ?: return null
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return null
        return if (o.isNull("at")) null else Instant.ofEpochSecond(o.getLong("at"))
    }

    fun weighedToday(context: Context): Boolean {
        if (!SwiftCore.available) return false
        CoreUserInputs.ensure(context)
        val json = SwiftCore.call("weight.weighedToday", "{}") ?: return false
        return runCatching { JSONObject(json).optBoolean("weighed") }.getOrDefault(false)
    }

    private fun ok(json: String?) = json != null && runCatching { JSONObject(json).optBoolean("ok") }.getOrDefault(false)

    // MARK: parsing

    private fun JSONObject.num(k: String): Double? = if (has(k) && !isNull(k)) optDouble(k).takeIf { !it.isNaN() } else null
    private fun JSONObject.long(k: String): Long? = if (has(k) && !isNull(k)) optDouble(k).toLong() else null
    private fun JSONObject.str(k: String): String? = if (has(k) && !isNull(k)) optString(k) else null
    private fun <T> JSONArray?.list(f: (JSONObject) -> T): List<T> =
        if (this == null) emptyList() else (0 until length()).map { f(getJSONObject(it)) }

    private fun point(o: JSONObject) = Point(o.getDouble("date").toLong(), o.getDouble("kg"))
    private fun report(o: JSONObject) = Report(
        o.getString("period"), o.getString("key"), o.getDouble("start").toLong(), o.getInt("count"), o.getBoolean("enough"),
        o.optJSONObject("low")?.let(::point), o.num("averageKg"), o.num("trendChangeKg"), o.num("ratePerWeekKg"),
        o.num("vsPreviousKg"), o.optJSONArray("readings").list(::point), o.optJSONArray("trend").list(::point),
    )
    private fun event(o: JSONObject) = Event(o.getString("id"), o.getString("name"), o.getString("day"))

    internal fun parse(json: String): Page? = runCatching {
        val root = JSONObject(json)
        val s = root.optJSONObject("settings")
        val settings = if (s == null) Settings() else Settings(
            s.optString("basis", "trend"), s.optString("rateMode", "current"), s.optInt("rateWindowDays", 28),
            s.num("milestoneStepKg"), s.num("manualWishKgPerWeek"),
            s.optJSONArray("hiddenCards")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList(),
        )
        val snap = root.optJSONObject("snapshot")?.let { o ->
            val r = o.getJSONObject("rates")
            val f = o.getJSONObject("forecast")
            Snapshot(
                latest = point(o.getJSONObject("latest")), trendKg = o.getDouble("trendKg"), trendSettled = o.getBoolean("trendSettled"),
                readingCount = o.getInt("readingCount"),
                changes = o.optJSONArray("changes").list { Change(if (it.isNull("days") || !it.has("days")) null else it.getInt("days"), it.getDouble("kg")) },
                week = o.optJSONObject("week")?.let { w ->
                    Week(point(w.getJSONObject("high")), point(w.getJSONObject("low")), point(w.getJSONObject("latest")),
                         w.getDouble("trendKg"), w.optJSONArray("readings").list(::point), w.optJSONArray("trend").list(::point))
                },
                rates = Rates(r.num("currentKgPerWeek"), r.num("overallKgPerWeek"), r.num("wishKgPerWeek"), r.str("wishSource"),
                              r.optBoolean("wishIsSteep")),
                forecast = Forecast(f.getDouble("startKg"), f.getString("basis"), f.getDouble("startDate").toLong(),
                                    f.getString("rateMode"), f.num("rateKgPerWeek"), f.getString("state"), f.long("targetDate")),
                events = o.optJSONArray("events").list { e ->
                    EventForecast(event(e.getJSONObject("event")), e.getString("phase"), e.getInt("daysAway"), e.num("predictedKg"),
                                  e.num("predictedBeforeKg"), e.num("measuredKg"))
                },
                milestones = o.optJSONObject("milestones")?.let { m ->
                    Milestones(m.optJSONArray("route").list { Milestone(it.getDouble("kg"), it.str("reachedDay")) },
                               m.getInt("reachedCount"), m.num("next"), m.num("toNextKg"), m.getDouble("progress"))
                },
                goal = o.optJSONObject("goal")?.let { g ->
                    Goal(g.getDouble("baseline"), g.getDouble("target"), g.getDouble("createdAt").toLong(), g.long("targetDate"), g.num("band"))
                },
                log = o.optJSONArray("log").list { row ->
                    val rd = row.getJSONObject("reading")
                    LogRow(Reading(rd.getDouble("date").toLong(), rd.getDouble("kg"), rd.str("note"), rd.str("id"), rd.optString("source")),
                           row.getString("day"), row.getDouble("trendKg"), row.num("weeklyRateKg"), row.num("milestoneKg"))
                },
                months = o.optJSONArray("months").list(::report), years = o.optJSONArray("years").list(::report),
                readings = o.optJSONArray("readings").list(::point), trend = o.optJSONArray("trend").list(::point),
            )
        }
        Page(snap, settings, root.optJSONArray("events").list(::event), root.str("goalSource"))
    }.getOrNull()
}
