package com.noop.core

import android.content.Context
import com.noop.ui.NoopPrefs
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), decision 2026-11-09: the diet planner from the shared core (`CoreDietPlan.swift`). The plan is the
 * same JSON under the same key as on iOS (`DietPlan.storageKey`); every figure comes from the core.
 * Blocking; call off the main thread.
 */
object CoreDietPlan {
    const val KEY = "food.plan"

    /** The wearer's choices, field for field as Swift `DietPlan`. */
    data class Plan(
        val goal: String = "lose", val mode: String = "simple", val pacePercent: Double = 0.5, val form: String = "balanced",
        val addon: String? = null, val strength: Boolean = false, val goalWeightKg: Double? = null, val steering: String = "coached",
        val proteinPerKg: Double? = null, val carbShareOfRest: Double? = null, val fixedKcal: Double? = null,
        val dietBreakEveryWeeks: Int? = null, val keep: List<String> = emptyList(), val startDay: String, val startWeightKg: Double,
        val adjustmentKcal: Double = 0.0, val lastAdjustedDay: String? = null, val hideNumbers: Boolean = false,
        val pregnantOrNursing: Boolean = false,
    ) {
        fun json(): String = JSONObject().apply {
            put("goal", goal); put("mode", mode); put("pacePercent", pacePercent); put("form", form)
            addon?.let { put("addon", it) }; put("strength", strength); goalWeightKg?.let { put("goalWeightKg", it) }
            put("steering", steering); proteinPerKg?.let { put("proteinPerKg", it) }; carbShareOfRest?.let { put("carbShareOfRest", it) }
            fixedKcal?.let { put("fixedKcal", it) }; dietBreakEveryWeeks?.let { put("dietBreakEveryWeeks", it) }
            put("keep", JSONArray(keep)); put("startDay", startDay); put("startWeightKg", startWeightKg)
            put("adjustmentKcal", adjustmentKcal); lastAdjustedDay?.let { put("lastAdjustedDay", it) }
            put("hideNumbers", hideNumbers); put("pregnantOrNursing", pregnantOrNursing)
        }.toString()

        companion object {
            fun parse(raw: String?): Plan? = runCatching {
                val o = JSONObject(raw ?: return null)
                fun num(k: String) = if (o.has(k) && !o.isNull(k)) o.optDouble(k) else null
                val keep = o.optJSONArray("keep")
                Plan(o.optString("goal", "lose"), o.optString("mode", "simple"), o.optDouble("pacePercent", 0.5),
                     o.optString("form", "balanced"), o.optString("addon").ifEmpty { null }, o.optBoolean("strength"),
                     num("goalWeightKg"), o.optString("steering", "coached"), num("proteinPerKg"), num("carbShareOfRest"),
                     num("fixedKcal"), if (o.has("dietBreakEveryWeeks")) o.optInt("dietBreakEveryWeeks") else null,
                     (0 until (keep?.length() ?: 0)).map { keep!!.optString(it) }, o.getString("startDay"),
                     o.getDouble("startWeightKg"), o.optDouble("adjustmentKcal", 0.0), o.optString("lastAdjustedDay").ifEmpty { null },
                     o.optBoolean("hideNumbers"), o.optBoolean("pregnantOrNursing"))
            }.getOrNull()
        }
    }

    data class Person(val weightKg: Double, val heightCm: Double?, val age: Int?, val sex: String)

    data class Week(val week: Int, val lowKg: Double, val midKg: Double, val highKg: Double, val holding: Boolean)
    data class Resolved(
        val goal: String, val averageKcal: Double, val eatingDayKcal: Double, val fastingDayKcal: Double?, val proteinG: Double,
        val carbsG: Double, val fatG: Double, val burnKcal: Double, val dailyDeltaKcal: Double, val pacePercent: Double,
        val paceKgPerWeek: Double, val adjustmentKcal: Double, val effortScore: Double, val effort: String, val goalWeightKg: Double?,
        val notes: List<String>, val weeks: List<Week>, val goalWeeks: Pair<Int, Int>?, val dayKcal: Double,
        val dayProteinG: Double, val dayCarbsG: Double, val dayFatG: Double,
    )
    data class Suggestion(val form: String, val reason: String)
    data class Outcome(val changeKcal: Double, val hold: String?, val trendKgPerWeek: Double?, val plannedKgPerWeek: Double)

    fun load(context: Context): Plan? = Plan.parse(NoopPrefs.of(context).getString(KEY, null))

    fun save(context: Context, plan: Plan?) {
        NoopPrefs.of(context).edit().apply { if (plan == null) remove(KEY) else putString(KEY, plan.json()) }.apply()
    }

    private fun base(person: Person, burnKcal: Double?, kcalPerKg: Double?) = JSONObject().apply {
        put("weightKg", person.weightKg); person.heightCm?.let { put("heightCm", it) }; person.age?.let { put("age", it) }
        put("sex", person.sex); burnKcal?.let { put("burnKcal", it) }; kcalPerKg?.let { put("kcalPerKg", it) }
    }

    private fun call(op: String, args: JSONObject): JSONObject? {
        if (!SwiftCore.available) return null
        val text = SwiftCore.call(op, args.toString()) ?: return null
        if (text == "null") return null
        return runCatching { JSONObject(text) }.getOrNull()?.takeIf { !it.has("error") }
    }

    private fun JSONObject.num(k: String): Double? = if (has(k) && !isNull(k)) optDouble(k).takeIf { !it.isNaN() } else null

    fun resolve(plan: Plan, person: Person, burnKcal: Double?, kcalPerKg: Double?, day: String): Resolved? {
        val json = call("food.planResolve", base(person, burnKcal, kcalPerKg).put("plan", plan.json()).put("day", day)) ?: return null
        val r = json.optJSONObject("result") ?: return null
        val f = json.optJSONObject("forecast")
        val weeks = f?.optJSONArray("weeks") ?: JSONArray()
        val range = f?.optJSONArray("goalWeeks")
        val notes = r.optJSONArray("notes") ?: JSONArray()
        val m = json.optJSONObject("dayMacros")
        return Resolved(r.optString("goal"), r.optDouble("averageKcal"), r.optDouble("eatingDayKcal"), r.num("fastingDayKcal"),
            r.optDouble("proteinG"), r.optDouble("carbsG"), r.optDouble("fatG"), r.optDouble("burnKcal"), r.optDouble("dailyDeltaKcal"),
            r.optDouble("pacePercent"), r.optDouble("paceKgPerWeek"), r.optDouble("adjustmentKcal"), r.optDouble("effortScore"),
            r.optString("effort"), r.num("goalWeightKg"), (0 until notes.length()).map { notes.optString(it) },
            (0 until weeks.length()).mapNotNull { i -> weeks.optJSONObject(i)?.let {
                Week(it.optInt("week"), it.optDouble("lowKg"), it.optDouble("midKg"), it.optDouble("highKg"), it.optBoolean("holding"))
            } },
            if (range != null && range.length() == 2) range.optInt(0) to range.optInt(1) else null,
            json.optDouble("dayKcal"), m?.optDouble("proteinG") ?: 0.0, m?.optDouble("carbsG") ?: 0.0, m?.optDouble("fatG") ?: 0.0)
    }

    fun suggest(keep: List<String>, likesRules: Boolean, strength: Boolean, mode: String): List<Suggestion> {
        val json = call("food.planSuggest", JSONObject().put("keep", JSONArray(keep)).put("likesRules", likesRules)
            .put("strength", strength).put("mode", mode)) ?: return emptyList()
        val a = json.optJSONArray("suggestions") ?: return emptyList()
        return (0 until a.length()).mapNotNull { a.optJSONObject(it)?.let { o -> Suggestion(o.optString("form"), o.optString("reason")) } }
    }

    fun weekly(plan: Plan, person: Person, burnKcal: Double?, kcalPerKg: Double?): Outcome? {
        val o = call("food.planWeekly", base(person, burnKcal, kcalPerKg).put("plan", plan.json())) ?: return null
        return Outcome(o.optDouble("changeKcal"), o.optString("hold").ifEmpty { null }, o.num("trendKgPerWeek"), o.optDouble("plannedKgPerWeek"))
    }

    fun fit(plan: Plan, foodId: String, group: String?): Int {
        val args = JSONObject().put("plan", plan.json()).put("foodId", foodId)
        group?.let { args.put("group", it) }
        return call("food.planFit", args)?.optInt("fit") ?: 0
    }
}
