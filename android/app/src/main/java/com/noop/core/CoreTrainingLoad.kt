package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 2.3: the Training Load readings from the shared core (`CoreTrainingLoad` in
 * NoopCore), computed by the same `TrainingLoadPreparation.prepare` the iPhone runs. Blocking; call off the main
 * thread. States arrive as the Swift enums' raw values ("below", "usual", "productive", …).
 */
object CoreTrainingLoad {
    data class Lane(
        val sevenDayTotal: Double, val sevenDayWorkingSets: Int, val percent: Double?,
        val band: String?, val guardState: String?, val daysBelowUsual: Int, val readingDay: String?,
        val maturity: String, val isLowerBound: Boolean, val monotony: Double?, val strain: Double?,
        val weekOverWeek: Double?, val measuredCount: Int, val possibleCount: Int,
    )
    data class Verdict(val kind: String, val value: String)
    data class Statement(val kind: String, val lane: String?, val verdict: Verdict?, val low: String?,
                         val high: String?, val severity: String?, val flag: Boolean?)
    data class Room(val beforeAbove: Double, val beforeWellAbove: Double?)
    data class Reading(val day: String, val value: Double, val segment: String)
    data class Ratio(val day: String, val strength: Double?, val cardio: Double?)
    data class Week(val day: String, val strength: String?, val cardio: String?)
    data class Output(
        val strength: Lane, val cardio: Lane, val session: Lane,
        val ratios: List<Ratio>, val history: List<Week>,
        val strengthVerdict: Verdict?, val cardioVerdict: Verdict?, val statement: Statement,
        val recoveryState: String, val strainedNights: Int, val nightsRead: Int, val recoveryNights: Int,
        val flaggingOnLatestNight: List<String>, val readOnLatestNight: List<String>,
        val strengthAdaptation: String, val cardioAdaptation: String,
        val strengthRoom: Room?, val cardioRoom: Room?, val strengthSettles: String?, val cardioSettles: String?,
        val sustainedLanes: List<String>?, val sustainedWeeks: Int?,
        val rising: Int, val unclear: Int, val falling: Int,
        val vo2Primary: Reading?, val vo2Line: List<Reading>, val vo2Apple: Reading?,
        val evidence: String, val evidenceSource: String?, val evidenceSport: String?, val evidenceSessions: Int?,
        val provisionalBand: String?, val cardioMeasured: Boolean, val appleSource: String, val trustedShare: Double,
    )

    /** The readings for the wearer's maximum heart rate and sex, the inputs the cardio load is priced with. */
    fun read(maxHR: Double?, sex: String, dismissedWorkouts: List<String> = emptyList()): Output? {
        if (!SwiftCore.available) return null
        val args = JSONObject().put("sex", sex).put("dismissedWorkouts", JSONArray(dismissedWorkouts))
            .apply { if (maxHR != null) put("maxHR", maxHR) }
        return SwiftCore.call("training.load", args.toString())?.let(::parse)
    }

    internal fun parse(json: String): Output? {
        if (json == "null" || json.contains("\"error\"")) return null
        val o = JSONObject(json)
        fun lane(x: JSONObject) = Lane(
            x.getDouble("sevenDayTotal"), x.getInt("sevenDayWorkingSets"), x.dbl("percent"),
            x.str("band"), x.str("guardState"), x.optInt("daysBelowUsual"), x.str("readingDay"),
            x.optString("maturity", "immediate"), x.optBoolean("isLowerBound"), x.dbl("monotony"), x.dbl("strain"),
            x.dbl("weekOverWeek"), x.optInt("measuredCount"), x.optInt("possibleCount"))
        fun verdict(x: JSONObject?) = x?.let { Verdict(it.getString("kind"), it.getString("value")) }
        fun room(x: JSONObject?) = x?.let { Room(it.getDouble("beforeAbove"), it.dbl("beforeWellAbove")) }
        fun reading(x: JSONObject?) = x?.let { Reading(it.getString("day"), it.getDouble("value"), it.getString("segment")) }
        val st = o.getJSONObject("statement")
        return Output(
            strength = lane(o.getJSONObject("strength")), cardio = lane(o.getJSONObject("cardio")),
            session = lane(o.getJSONObject("session")),
            ratios = o.optJSONArray("ratios").objects().map { Ratio(it.getString("day"), it.dbl("strength"), it.dbl("cardio")) },
            history = o.optJSONArray("history").objects().map { Week(it.getString("day"), it.str("strength"), it.str("cardio")) },
            strengthVerdict = verdict(o.optJSONObject("strengthVerdict")),
            cardioVerdict = verdict(o.optJSONObject("cardioVerdict")),
            statement = Statement(st.getString("kind"), st.str("lane"), verdict(st.optJSONObject("verdict")),
                                  st.str("low"), st.str("high"), st.str("severity"),
                                  if (st.has("flag") && !st.isNull("flag")) st.getBoolean("flag") else null),
            recoveryState = o.optString("recoveryState", "unknown"), strainedNights = o.optInt("strainedNights"),
            nightsRead = o.optInt("nightsRead"), recoveryNights = o.optInt("recoveryNights", 7),
            flaggingOnLatestNight = o.optJSONArray("flaggingOnLatestNight").strings(),
            readOnLatestNight = o.optJSONArray("readOnLatestNight").strings(),
            strengthAdaptation = o.optString("strengthAdaptation", "notEnoughData"),
            cardioAdaptation = o.optString("cardioAdaptation", "notEnoughData"),
            strengthRoom = room(o.optJSONObject("strengthRoom")), cardioRoom = room(o.optJSONObject("cardioRoom")),
            strengthSettles = o.str("strengthSettles"), cardioSettles = o.str("cardioSettles"),
            sustainedLanes = o.optJSONArray("sustainedLanes")?.strings(), sustainedWeeks = o.int("sustainedWeeks"),
            rising = o.optInt("rising"), unclear = o.optInt("unclear"), falling = o.optInt("falling"),
            vo2Primary = reading(o.optJSONObject("vo2Primary")),
            vo2Line = o.optJSONArray("vo2Line").objects().mapNotNull { reading(it) },
            vo2Apple = reading(o.optJSONObject("vo2Apple")),
            evidence = o.optString("evidence", "none"), evidenceSource = o.str("evidenceSource"),
            evidenceSport = o.str("evidenceSport"), evidenceSessions = o.int("evidenceSessions"),
            provisionalBand = o.str("provisionalBand"), cardioMeasured = o.optBoolean("cardioMeasured"),
            appleSource = o.optString("appleSource", "apple-health"), trustedShare = o.optDouble("trustedShare", 0.6),
        )
    }

    private fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else (0 until length()).map { getJSONObject(it) }
    private fun JSONArray?.strings(): List<String> = if (this == null) emptyList() else (0 until length()).map { getString(it) }
    private fun JSONObject.str(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null
    private fun JSONObject.dbl(key: String): Double? = if (has(key) && !isNull(key)) getDouble(key) else null
    private fun JSONObject.int(key: String): Int? = if (has(key) && !isNull(key)) getInt(key) else null
}
