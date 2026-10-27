package com.noop.core

import android.content.Context
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 1.2 and 2.3: goals from the shared core (`CoreGoals` in NoopCore). The core
 * reads the store through the shared `GoalInputLoader`, evaluates with the shared `GoalTrackingModel` and changes the
 * goals only inside its goal-state transaction, so the numbers and the stored goals are the Apple app's. States
 * arrive as the Swift enums' raw values ("onTrack", "behind", "achieved", …). Blocking; call off the main thread.
 */
object CoreGoals {
    data class Contribution(val id: String, val day: String, val title: String, val value: Double,
                            val isManual: Boolean, val reason: String?)
    data class HistoryEntry(val periodStart: String, val target: Double, val value: Double, val outcome: String)
    data class Period(
        val id: String, val metric: String, val period: String, val status: String,
        val target: Double, val threshold: Double?, val sportFilter: List<String>, val parentGoalId: String?,
        val periodStart: String, val periodDays: List<String>, val todayIndex: Int, val daysLeft: Int,
        val current: Double, val periodTarget: Double, val fraction: Double, val paceFraction: Double?,
        val remaining: Double, val requiredPerDay: Double?, val state: String, val isProtected: Boolean,
        val dayValues: List<Double?>, val restDays: List<String>,
        val history: List<HistoryEntry>, val currentStreak: Int, val bestStreak: Int,
        val counted: List<Contribution>, val notCounted: List<Contribution>, val suggestedDays: List<String>,
        val aggregation: String, val step: Double, val rangeLow: Double, val rangeHigh: Double,
    )
    data class LongTerm(
        val id: String, val title: String, val status: String, val targetDate: String?, val health: String,
        val progress: Double?, val reason: String, val nextAction: String, val currentStreak: Int,
        val bestStreak: Int, val periodGoalIds: List<String>,
    )
    data class Action(
        val id: String, val actionId: String, val title: String, val kind: String, val day: String,
        val isCompleted: Boolean, val isAutomatic: Boolean, val measured: Double?, val measuredTarget: Double?,
    )
    data class Output(val period: List<Period>, val longTerm: List<LongTerm>, val today: List<Action>,
                      val week: List<Action>, val periodLimit: Int)
    data class MetricChoice(
        val metric: String, val aggregation: String, val reason: String?, val available: Boolean,
        val weekDefault: Double, val weekStep: Double, val weekLow: Double, val weekHigh: Double,
        val monthDefault: Double, val monthStep: Double, val monthLow: Double, val monthHigh: Double,
        val threshold: Double?,
    )
    data class Setup(val metrics: List<MetricChoice>, val openCount: Int, val periodLimit: Int)
    data class Change(val ok: Boolean, val error: String?)

    /** Every goal, refreshed and evaluated as the Apple `GoalTrackingStore.refresh` does. */
    fun snapshot(context: Context, dismissedWorkouts: List<String>): Output? {
        if (!SwiftCore.available) return null
        return SwiftCore.call("goals.snapshot", settings(context, dismissedWorkouts))?.let(::parse)
    }

    /** The metrics the weekly and monthly goal setup offers, with each one's target range. */
    fun setup(context: Context, dismissedWorkouts: List<String>): Setup? {
        if (!SwiftCore.available) return null
        val json = SwiftCore.call("goals.setup", settings(context, dismissedWorkouts)) ?: return null
        if (json == "null" || json.contains("\"error\"")) return null
        val o = JSONObject(json)
        return Setup(
            metrics = o.optJSONArray("metrics").objects().map {
                MetricChoice(it.getString("metric"), it.getString("aggregation"), it.str("reason"),
                    it.optBoolean("available"), it.getDouble("weekDefault"), it.getDouble("weekStep"),
                    it.getDouble("weekLow"), it.getDouble("weekHigh"), it.getDouble("monthDefault"),
                    it.getDouble("monthStep"), it.getDouble("monthLow"), it.getDouble("monthHigh"), it.dbl("threshold"))
            },
            openCount = o.optInt("openCount"), periodLimit = o.optInt("periodLimit", 6),
        )
    }

    fun addPeriodGoal(metric: String, period: String, target: Double, threshold: Double?): Change =
        change("goals.addPeriod", JSONObject().put("metric", metric).put("period", period).put("target", target)
            .apply { if (threshold != null) put("threshold", threshold) })

    /** "setTarget", "pause", "resume", "end" or "remove", as the Apple detail page offers them. */
    fun changePeriodGoal(id: String, action: String, target: Double? = null, reason: String? = null): Change =
        change("goals.changePeriod", JSONObject().put("id", id).put("action", action)
            .apply { if (target != null) put("target", target); if (reason != null) put("reason", reason) })

    fun toggleAction(actionId: String, day: String): Change =
        change("goals.toggleAction", JSONObject().put("actionId", actionId).put("day", day))

    private fun change(op: String, args: JSONObject): Change {
        if (!SwiftCore.available) return Change(false, "unavailable")
        val json = SwiftCore.call(op, args.toString()) ?: return Change(false, "unavailable")
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return Change(false, "unavailable")
        return Change(o.optBoolean("ok"), o.str("error"))
    }

    private fun settings(context: Context, dismissedWorkouts: List<String>): String {
        val lastSync = NoopPrefs.lastSyncAt(context)
        return JSONObject().put("sex", ProfileStore.from(context).sex)
            .put("lastSync", lastSync).put("ageless", CoreFeatures.healthspan(context))
            .put("dismissedWorkouts", JSONArray(dismissedWorkouts)).toString()
    }

    internal fun parse(json: String): Output? {
        if (json == "null" || json.contains("\"error\"")) return null
        val o = JSONObject(json)
        fun contribution(x: JSONObject) = Contribution(x.getString("id"), x.getString("day"), x.getString("title"),
            x.getDouble("value"), x.optBoolean("isManual"), x.str("reason"))
        fun action(x: JSONObject) = Action(x.getString("id"), x.getString("actionId"), x.getString("title"),
            x.getString("kind"), x.getString("day"), x.optBoolean("isCompleted"), x.optBoolean("isAutomatic"),
            x.dbl("measured"), x.dbl("measuredTarget"))
        return Output(
            period = o.optJSONArray("period").objects().map { p ->
                Period(
                    id = p.getString("id"), metric = p.getString("metric"), period = p.getString("period"),
                    status = p.getString("status"), target = p.getDouble("target"), threshold = p.dbl("threshold"),
                    sportFilter = p.optJSONArray("sportFilter").strings(), parentGoalId = p.str("parentGoalId"),
                    periodStart = p.getString("periodStart"), periodDays = p.optJSONArray("periodDays").strings(),
                    todayIndex = p.optInt("todayIndex"), daysLeft = p.optInt("daysLeft"),
                    current = p.getDouble("current"), periodTarget = p.getDouble("periodTarget"),
                    fraction = p.getDouble("fraction"), paceFraction = p.dbl("paceFraction"),
                    remaining = p.getDouble("remaining"), requiredPerDay = p.dbl("requiredPerDay"),
                    state = p.getString("state"), isProtected = p.optBoolean("isProtected"),
                    dayValues = p.optJSONArray("dayValues").let { a ->
                        if (a == null) emptyList() else (0 until a.length()).map { if (a.isNull(it)) null else a.getDouble(it) }
                    },
                    restDays = p.optJSONArray("restDays").strings(),
                    history = p.optJSONArray("history").objects().map {
                        HistoryEntry(it.getString("periodStart"), it.getDouble("target"), it.getDouble("value"),
                                     it.getString("outcome"))
                    },
                    currentStreak = p.optInt("currentStreak"), bestStreak = p.optInt("bestStreak"),
                    counted = p.optJSONArray("counted").objects().map(::contribution),
                    notCounted = p.optJSONArray("notCounted").objects().map(::contribution),
                    suggestedDays = p.optJSONArray("suggestedDays").strings(),
                    aggregation = p.optString("aggregation", "count"), step = p.optDouble("step", 1.0),
                    rangeLow = p.optDouble("rangeLow", 0.0), rangeHigh = p.optDouble("rangeHigh", 100.0),
                )
            },
            longTerm = o.optJSONArray("longTerm").objects().map { g ->
                LongTerm(g.getString("id"), g.getString("title"), g.getString("status"), g.str("targetDate"),
                    g.getString("health"), g.dbl("progress"), g.optString("reason"), g.optString("nextAction"),
                    g.optInt("currentStreak"), g.optInt("bestStreak"), g.optJSONArray("periodGoalIds").strings())
            },
            today = o.optJSONArray("today").objects().map(::action),
            week = o.optJSONArray("week").objects().map(::action),
            periodLimit = o.optInt("periodLimit", 6),
        )
    }

    private fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else (0 until length()).map { getJSONObject(it) }
    private fun JSONArray?.strings(): List<String> = if (this == null) emptyList() else (0 until length()).map { getString(it) }
    private fun JSONObject.str(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null
    private fun JSONObject.dbl(key: String): Double? = if (has(key) && !isNull(key)) getDouble(key) else null
}
