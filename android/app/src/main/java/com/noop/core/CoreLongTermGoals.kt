package com.noop.core

import android.content.Context
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 2.3: long-term goals from the shared core (`CoreLongTermGoals` in NoopCore). The
 * setup's suggestions come from the shared `LongTermGoalDraft`, the same one the iOS setup runs, and the goal is
 * created and changed inside the core's goal-state transaction. Catalog texts arrive as English keys
 * (`GOAL_CATALOG_TEXT` translates them). Blocking; call off the main thread.
 */
object CoreLongTermGoals {
    data class Template(val id: String, val area: String, val title: String, val blurb: String, val available: Boolean,
                        val reason: String?, val sportChoices: List<String>)
    data class Catalog(val areas: List<String>, val templates: List<Template>)

    /** The setup's state, sent back unchanged with every action. Dates are seconds since 1970. */
    data class State(
        val template: String? = null, val sportIndex: Int = 0, val target: Double = 0.0, val baseline: Double = 0.0,
        val countFromYearStart: Boolean = true, val endDate: Double = 0.0, val hasDate: Boolean = false,
        val targetDate: Double = 0.0, val openEnded: Boolean = true, val fixedWeeks: Int = 12,
        val weeklyOn: Boolean = true, val weeklyTarget: Double = 3.0, val weeklyChoice: String = "workouts",
        val title: String = "", val motivation: String = "", val threshold: Double = 0.0, val band: Double = 1.0,
        val habitKey: String? = null, val habitWantsYes: Boolean = true,
    )

    data class Draft(
        val state: State, val shape: String?, val metric: String?, val weeklyMetric: String?,
        val currentLevel: Double?, val collectedSoFar: Double, val hasMeasuredStart: Boolean,
        val levelStep: Double, val levelLow: Double, val levelHigh: Double,
        val perWeekStep: Double, val perWeekLow: Double, val perWeekHigh: Double,
        val sumStep: Double, val weeklyMetricOfGoal: String?, val risky: Boolean, val requiresReason: Boolean,
        val rate: String?,
    )

    data class Created(val ok: Boolean, val error: String?, val goalId: String?, val existingId: String?,
                       val existingTitle: String?)

    fun catalog(context: Context, dismissedWorkouts: List<String>): Catalog? {
        if (!SwiftCore.available) return null
        if (!CoreUserInputs.ensure(context)) return null
        val json = SwiftCore.call("goals.catalog", args(context, dismissedWorkouts).toString()) ?: return null
        if (json.contains("\"error\"")) return null
        val o = JSONObject(json)
        return Catalog(
            areas = o.optJSONArray("areas").strings(),
            templates = o.optJSONArray("templates").objects().map {
                Template(it.getString("id"), it.getString("area"), it.getString("title"), it.getString("blurb"),
                         it.optBoolean("available"), it.str("reason"), it.optJSONArray("sportChoices").strings())
            },
        )
    }

    /** "suggest", "sum", "weekly" or "none", as `CoreLongTermGoals.draft` applies them. */
    fun draft(context: Context, dismissedWorkouts: List<String>, state: State, action: String): Draft? {
        if (!SwiftCore.available) return null
        if (!CoreUserInputs.ensure(context)) return null
        val json = SwiftCore.call("goals.ltDraft", args(context, dismissedWorkouts)
            .put("state", encode(state).toString()).put("action", action).toString()) ?: return null
        return parseDraft(json)
    }

    fun create(context: Context, dismissedWorkouts: List<String>, state: State, replacing: String?, keepBoth: Boolean,
               riskReason: String?): Created {
        if (!SwiftCore.available) return Created(false, "unavailable", null, null, null)
        if (!CoreUserInputs.ensure(context)) return Created(false, "inputMigration", null, null, null)
        val json = SwiftCore.call("goals.ltCreate", args(context, dismissedWorkouts)
            .put("state", encode(state).toString()).put("keepBoth", keepBoth)
            .apply { if (replacing != null) put("replacing", replacing); if (riskReason != null) put("riskReason", riskReason) }
            .toString()) ?: return Created(false, "unavailable", null, null, null)
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return Created(false, "unavailable", null, null, null)
        if (o.optBoolean("ok")) CoreShadow.noteDataChanged()
        return Created(o.optBoolean("ok"), o.str("error"), o.str("goalId"), o.str("existingId"), o.str("existingTitle"))
    }

    /** "pause" (with a pause reason), "resume", "setAside" or "remove". */
    fun change(id: String, action: String, reason: String? = null): CoreGoals.Change {
        if (!SwiftCore.available) return CoreGoals.Change(false, "unavailable")
        val json = SwiftCore.call("goals.changeLongTerm", JSONObject().put("id", id).put("action", action)
            .apply { if (reason != null) put("reason", reason) }.toString()) ?: return CoreGoals.Change(false, "unavailable")
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return CoreGoals.Change(false, "unavailable")
        if (o.optBoolean("ok")) CoreShadow.noteDataChanged()
        return CoreGoals.Change(o.optBoolean("ok"), o.str("error"))
    }

    private fun args(context: Context, dismissedWorkouts: List<String>): JSONObject {
        val profile = ProfileStore.from(context)
        return JSONObject().withGoalProfile(profile).withGoalHostSettings(context).put("sex", profile.sex).put("lastSync", goalLastSync(context))
            .put("ageless", CoreFeatures.healthspan(context)).put("profileWeightKg", profile.weightKg)
            .put("dismissedWorkouts", JSONArray(dismissedWorkouts))
    }

    internal fun encode(s: State): JSONObject = JSONObject()
        .put("sportIndex", s.sportIndex).put("target", s.target).put("baseline", s.baseline)
        .put("countFromYearStart", s.countFromYearStart).put("endDate", s.endDate).put("hasDate", s.hasDate)
        .put("targetDate", s.targetDate).put("openEnded", s.openEnded).put("fixedWeeks", s.fixedWeeks)
        .put("weeklyOn", s.weeklyOn).put("weeklyTarget", s.weeklyTarget).put("weeklyChoice", s.weeklyChoice)
        .put("title", s.title).put("motivation", s.motivation).put("threshold", s.threshold).put("band", s.band)
        .put("habitWantsYes", s.habitWantsYes)
        .apply { if (s.template != null) put("template", s.template); if (s.habitKey != null) put("habitKey", s.habitKey) }

    internal fun parseDraft(json: String): Draft? {
        if (json == "null" || json.contains("\"error\"")) return null
        val o = JSONObject(json)
        val s = o.getJSONObject("state")
        val state = State(
            template = s.str("template"), sportIndex = s.optInt("sportIndex"), target = s.optDouble("target", 0.0),
            baseline = s.optDouble("baseline", 0.0), countFromYearStart = s.optBoolean("countFromYearStart", true),
            endDate = s.optDouble("endDate", 0.0), hasDate = s.optBoolean("hasDate"),
            targetDate = s.optDouble("targetDate", 0.0), openEnded = s.optBoolean("openEnded", true),
            fixedWeeks = s.optInt("fixedWeeks", 12), weeklyOn = s.optBoolean("weeklyOn", true),
            weeklyTarget = s.optDouble("weeklyTarget", 3.0), weeklyChoice = s.optString("weeklyChoice", "workouts"),
            title = s.optString("title"), motivation = s.optString("motivation"),
            threshold = s.optDouble("threshold", 0.0), band = s.optDouble("band", 1.0), habitKey = s.str("habitKey"),
            habitWantsYes = s.optBoolean("habitWantsYes", true),
        )
        return Draft(
            state = state, shape = o.str("shape"), metric = o.str("metric"), weeklyMetric = o.str("weeklyMetric"),
            currentLevel = o.dbl("currentLevel"), collectedSoFar = o.optDouble("collectedSoFar", 0.0),
            hasMeasuredStart = o.optBoolean("hasMeasuredStart"),
            levelStep = o.optDouble("levelStep", 1.0), levelLow = o.optDouble("levelLow", 0.0),
            levelHigh = o.optDouble("levelHigh", 10_000.0), perWeekStep = o.optDouble("perWeekStep", 1.0),
            perWeekLow = o.optDouble("perWeekLow", 1.0), perWeekHigh = o.optDouble("perWeekHigh", 7.0),
            sumStep = o.optDouble("sumStep", 1.0), weeklyMetricOfGoal = o.str("weeklyMetricOfGoal"),
            risky = o.optBoolean("risky"), requiresReason = o.optBoolean("requiresReason"), rate = o.str("rate"),
        )
    }

    private fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else (0 until length()).map { getJSONObject(it) }
    private fun JSONArray?.strings(): List<String> = if (this == null) emptyList() else (0 until length()).map { getString(it) }
    private fun JSONObject.str(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null
    private fun JSONObject.dbl(key: String): Double? = if (has(key) && !isNull(key)) getDouble(key) else null
}
