package com.noop.core

import android.content.Context
import com.noop.data.DailyMetric
import com.noop.ui.NoopPrefs
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs

/**
 * Fork (DX23876), Android parity plan 1.3: the daily rows as the iPhone's `Repository.days` holds them, read from the
 * shared core (`read.dailyRows`), so the classic screens can stop reading Room's own merge. Off by default
 * ([coreReads]) until a real-data comparison ([compare]) shows the two agree. Blocking; call off the main thread.
 */
object CoreDailyRows {
    const val CORE_READS_KEY = "core.dailyRows.reads"

    fun coreReads(context: Context): Boolean = NoopPrefs.of(context).getBoolean(CORE_READS_KEY, false)
    fun setCoreReads(context: Context, on: Boolean) = NoopPrefs.of(context).edit().putBoolean(CORE_READS_KEY, on).apply()

    /** The core's merged rows between [from] and [to] (day keys), oldest first, tagged with [deviceId]; null without a core. */
    fun rows(from: String, to: String, deviceId: String): List<DailyMetric>? {
        if (!SwiftCore.available) return null
        val json = SwiftCore.call("read.dailyRows", JSONObject().put("from", from).put("to", to).toString()) ?: return null
        return parse(json, deviceId)
    }

    internal fun parse(json: String, deviceId: String): List<DailyMetric>? {
        val a = runCatching { JSONArray(json) }.getOrNull() ?: return null
        return (0 until a.length()).map { i ->
            val o = a.getJSONObject(i)
            fun d(k: String) = if (o.has(k) && !o.isNull(k)) o.getDouble(k) else null
            fun n(k: String) = if (o.has(k) && !o.isNull(k)) o.getInt(k) else null
            DailyMetric(
                deviceId = deviceId, day = o.getString("day"), totalSleepMin = d("totalSleepMin"), efficiency = d("efficiency"),
                deepMin = d("deepMin"), remMin = d("remMin"), lightMin = d("lightMin"), disturbances = n("disturbances"),
                restingHr = n("restingHr"), avgHrv = d("avgHrv"), recovery = d("recovery"), strain = d("strain"),
                exerciseCount = n("exerciseCount"), spo2Pct = d("spo2Pct"), skinTempDevC = d("skinTempDevC"),
                respRateBpm = d("respRateBpm"), steps = n("steps"), activeKcalEst = d("activeKcalEst"),
                spo2Red = n("spo2Red"), spo2Ir = n("spo2Ir"),
                avgSdnn = d("avgSdnn"), skinTempC = d("skinTempC"),
                sleepHrOnly = if (o.has("sleepHrOnly") && !o.isNull("sleepHrOnly")) o.getBoolean("sleepHrOnly") else null,
            )
        }
    }

    /** One field of one day where the two reads disagree. */
    data class Deviation(val day: String, val field: String, val room: String, val core: String)

    /** Every (day, field) where Room's merge and the core's differ beyond rounding; a day only one side has counts once. */
    fun compare(room: List<DailyMetric>, core: List<DailyMetric>): List<Deviation> {
        val r = room.associateBy { it.day }; val c = core.associateBy { it.day }
        val out = mutableListOf<Deviation>()
        for (day in (r.keys + c.keys).toSortedSet()) {
            val a = r[day]; val b = c[day]
            if (a == null || b == null) { out += Deviation(day, "row", if (a == null) "–" else "present", if (b == null) "–" else "present"); continue }
            fun cmp(name: String, x: Any?, y: Any?) {
                val same = when {
                    x == null || y == null -> x == y
                    x is Number && y is Number -> abs(x.toDouble() - y.toDouble()) <= 1e-6 * maxOf(1.0, abs(x.toDouble()))
                    else -> x == y
                }
                if (!same) out += Deviation(day, name, x.toString(), y.toString())
            }
            cmp("totalSleepMin", a.totalSleepMin, b.totalSleepMin); cmp("efficiency", a.efficiency, b.efficiency)
            cmp("deepMin", a.deepMin, b.deepMin); cmp("remMin", a.remMin, b.remMin); cmp("lightMin", a.lightMin, b.lightMin)
            cmp("disturbances", a.disturbances, b.disturbances); cmp("restingHr", a.restingHr, b.restingHr)
            cmp("avgHrv", a.avgHrv, b.avgHrv); cmp("recovery", a.recovery, b.recovery); cmp("strain", a.strain, b.strain)
            cmp("exerciseCount", a.exerciseCount, b.exerciseCount); cmp("spo2Pct", a.spo2Pct, b.spo2Pct)
            cmp("skinTempDevC", a.skinTempDevC, b.skinTempDevC); cmp("respRateBpm", a.respRateBpm, b.respRateBpm)
            cmp("steps", a.steps, b.steps); cmp("avgSdnn", a.avgSdnn, b.avgSdnn); cmp("skinTempC", a.skinTempC, b.skinTempC)
        }
        return out
    }
}
