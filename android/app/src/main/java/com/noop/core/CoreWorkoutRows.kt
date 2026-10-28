package com.noop.core

import com.noop.data.WorkoutRow
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs

/**
 * Fork (DX23876), Android parity plan 1.3: the workout list as the iPhone's `Repository.workoutRows` builds it, read
 * from the shared core (`read.workouts`), so the Workouts screen can stop assembling Room's own. It rides the same
 * Lab switch as the daily rows ([CoreDailyRows.coreReads]) and the same rule: default only after a real-data
 * comparison ([compare]) shows 0 differences. Blocking; call off the main thread.
 */
object CoreWorkoutRows {
    /** The core's list over the last [days] days, newest first; null without a core. */
    fun rows(days: Int, dismissedWorkouts: List<String>): List<WorkoutRow>? {
        if (!SwiftCore.available) return null
        val json = SwiftCore.call("read.workouts",
            JSONObject().put("days", days).put("dismissedWorkouts", JSONArray(dismissedWorkouts)).toString()) ?: return null
        return parse(json)
    }

    /**
     * Apple's rows carry no device id and no GPS route: the source names the row, and a route lives beside it.
     * The device id is the source, which is how the core keeps them apart.
     */
    internal fun parse(json: String): List<WorkoutRow>? {
        val a = runCatching { JSONArray(json) }.getOrNull() ?: return null
        return (0 until a.length()).map { i ->
            val o = a.getJSONObject(i)
            fun d(k: String) = if (o.has(k) && !o.isNull(k)) o.getDouble(k) else null
            fun n(k: String) = if (o.has(k) && !o.isNull(k)) o.getInt(k) else null
            fun s(k: String) = if (o.has(k) && !o.isNull(k)) o.getString(k) else null
            WorkoutRow(
                deviceId = o.getString("source"), startTs = o.getLong("startTs"), endTs = o.getLong("endTs"),
                sport = o.getString("sport"), source = o.getString("source"), durationS = d("durationS"),
                energyKcal = d("energyKcal"), avgHr = n("avgHr"), maxHr = n("maxHr"), strain = d("strain"),
                distanceM = d("distanceM"), zonesJSON = s("zonesJSON"), notes = s("notes"), steps = n("steps"),
            )
        }
    }

    /** Lays each Room row's GPS route onto the core's row for the same session, until routes have a core lane. */
    fun withRoutes(core: List<WorkoutRow>, room: List<WorkoutRow>): List<WorkoutRow> {
        val routes = room.filter { it.routePolyline != null }.associateBy({ it.startTs to it.sport }, { it.routePolyline })
        return core.map { r -> routes[r.startTs to r.sport]?.let { r.copy(routePolyline = it) } ?: r }
    }

    /** One field of one session (start and sport) where the two lists disagree. */
    data class Deviation(val session: String, val field: String, val room: String, val core: String)

    /** Every (session, field) where Room's list and the core's differ beyond rounding; a session only one side has counts once. */
    fun compare(room: List<WorkoutRow>, core: List<WorkoutRow>): List<Deviation> {
        fun key(w: WorkoutRow) = "${w.startTs} ${w.sport}"
        val r = room.associateBy(::key); val c = core.associateBy(::key)
        val out = mutableListOf<Deviation>()
        for (k in (r.keys + c.keys).toSortedSet()) {
            val a = r[k]; val b = c[k]
            if (a == null || b == null) { out += Deviation(k, "row", if (a == null) "–" else "present", if (b == null) "–" else "present"); continue }
            fun cmp(name: String, x: Any?, y: Any?) {
                val same = when {
                    x == null || y == null -> x == y
                    x is Number && y is Number -> abs(x.toDouble() - y.toDouble()) <= 1e-6 * maxOf(1.0, abs(x.toDouble()))
                    else -> x == y
                }
                if (!same) out += Deviation(k, name, x.toString(), y.toString())
            }
            cmp("endTs", a.endTs, b.endTs); cmp("source", a.source, b.source); cmp("durationS", a.durationS, b.durationS)
            cmp("energyKcal", a.energyKcal, b.energyKcal); cmp("avgHr", a.avgHr, b.avgHr); cmp("maxHr", a.maxHr, b.maxHr)
            cmp("strain", a.strain, b.strain); cmp("distanceM", a.distanceM, b.distanceM); cmp("steps", a.steps, b.steps)
        }
        return out
    }
}
