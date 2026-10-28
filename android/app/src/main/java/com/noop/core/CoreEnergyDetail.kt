package com.noop.core

import android.content.Context
import com.noop.ui.ProfileStore
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 2.3: the Energy detail from the shared core (`CoreEnergyDetail`): the last 30
 * days, one day's burn-rate curve with its sessions and split, and a comparison curve. Blocking; call off the main
 * thread.
 */
object CoreEnergyDetail {
    data class Summary(
        val day: String, val total: Double?, val active: Double?, val basal: Double?, val bmr24h: Double?,
        val projectedLow: Double?, val projectedHigh: Double?, val source: String, val sourceLabel: String,
        val confidence: String, val confidenceLabel: String, val compactLine: String?,
    )
    data class Point(val start: Double, val duration: Double, val kcalPerMinute: Double)
    data class Band(val start: Double, val end: Double, val sport: String)
    data class Detail(
        val today: String, val day: String, val summaries: List<Summary>, val selected: Summary?, val points: List<Point>,
        val bands: List<Band>, val trainingKcal: Double?, val movementKcal: Double?, val comparison: String,
        val comparisonPoints: List<Point>, val comparisonCaption: String?, val comparisonUnavailable: String?,
    )

    fun read(context: Context, day: String?, comparison: String, dismissedWorkouts: List<String>): Detail? {
        if (!SwiftCore.available) return null
        CoreUserInputs.ensure(context)
        val profile = ProfileStore.from(context)
        val args = JSONObject().withGoalProfile(profile).withGoalHostSettings(context).put("sex", profile.sex)
            .put("lastSync", goalLastSync(context)).put("dismissedWorkouts", JSONArray(dismissedWorkouts))
            .put("day", day ?: "").put("comparison", comparison)
        return parse(SwiftCore.call("energy.detail", args.toString()) ?: return null)
    }

    internal fun parse(json: String): Detail? {
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return null
        if (!o.has("summaries")) return null
        fun JSONObject.dbl(k: String) = if (has(k) && !isNull(k)) getDouble(k) else null
        fun JSONObject.str(k: String) = if (has(k) && !isNull(k)) getString(k) else null
        fun JSONArray?.objects() = if (this == null) emptyList() else (0 until length()).map { getJSONObject(it) }
        fun summary(s: JSONObject) = Summary(
            s.getString("day"), s.dbl("total"), s.dbl("active"), s.dbl("basal"), s.dbl("bmr24h"), s.dbl("projectedLow"),
            s.dbl("projectedHigh"), s.optString("source"), s.optString("sourceLabel"), s.optString("confidence"),
            s.optString("confidenceLabel"), s.str("compactLine"))
        fun points(a: JSONArray?) = a.objects().map { Point(it.getDouble("start"), it.getDouble("duration"), it.getDouble("kcalPerMinute")) }
        return Detail(
            today = o.getString("today"), day = o.getString("day"), summaries = o.optJSONArray("summaries").objects().map(::summary),
            selected = o.optJSONObject("selected")?.let(::summary), points = points(o.optJSONArray("points")),
            bands = o.optJSONArray("bands").objects().map { Band(it.getDouble("start"), it.getDouble("end"), it.optString("sport")) },
            trainingKcal = o.dbl("trainingKcal"), movementKcal = o.dbl("movementKcal"), comparison = o.optString("comparison"),
            comparisonPoints = points(o.optJSONArray("comparisonPoints")), comparisonCaption = o.str("comparisonCaption"),
            comparisonUnavailable = o.str("comparisonUnavailable"),
        )
    }
}
