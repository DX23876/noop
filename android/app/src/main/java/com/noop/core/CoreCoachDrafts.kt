package com.noop.core

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * The drafts the shared coach leaves for review (`CoreCoachDrafts.swift`, `CoreGoalReview.swift`): a Hevy routine, a
 * Hevy workout, and a goal with routines and weekly or monthly goals. The coach only drafts; sending or applying is the
 * wearer's tap. Blocking JNI calls; run them off the main thread.
 */
object CoreCoachDrafts {
    data class Exercise(val title: String, val superset: String?, val sets: List<String>, val rest: String?, val notes: String?)
    data class Routine(
        val id: String, val header: String, val title: String, val counts: String, val rationale: String,
        val warnings: List<String>, val replaces: Boolean, val removed: List<String>, val added: List<String>,
        val exercises: List<Exercise>, val error: String?,
    )
    data class WorkoutCard(val label: String, val title: String, val date: String, val exercises: List<Exercise>, val volume: String)
    data class Workout(val id: String, val header: String, val cards: List<WorkoutCard>, val createNote: String?, val error: String?)
    data class Drafts(val routine: Routine?, val workout: Workout?, val goalId: String?, val sent: String?, val error: String?,
                      val labels: Map<String, String>)

    /** kg or lb for the logged sets, as the training screens choose it. */
    fun weightUnit(context: Context): String =
        when (com.noop.ui.NoopPrefs.of(context).getString("training.weightUnit", null)) {
            "pounds" -> "pounds"
            "kilograms" -> "kilograms"
            else -> if (com.noop.ui.UnitPrefs.system(context) == com.noop.ui.UnitSystem.IMPERIAL) "pounds" else "kilograms"
        }

    /** Reads the drafts, or first applies [op] (`routine.send`, `routine.decline`, `workout.send`, `workout.decline`) to [id]. */
    fun drafts(context: Context, op: String? = null, id: String? = null): Drafts? {
        if (!SwiftCore.available) return null
        val args = JSONObject().put("weightUnit", weightUnit(context))
        id?.let { args.put("id", it) }
        val raw = SwiftCore.call(if (op == null) "coach.drafts" else "coach.drafts.$op", args.toString()) ?: return null
        return runCatching { parse(JSONObject(raw)) }.getOrNull()
    }

    private fun JSONObject.str(k: String) = if (!has(k) || isNull(k)) null else optString(k).takeIf { it.isNotEmpty() }
    private fun JSONArray?.strings() = (0 until (this?.length() ?: 0)).map { this!!.getString(it) }
    private fun labels(o: JSONObject?) = o?.keys()?.asSequence()?.associateWith { o.getString(it) } ?: emptyMap()
    private fun exercises(a: JSONArray?) = (0 until (a?.length() ?: 0)).map { a!!.getJSONObject(it).let { e ->
        Exercise(e.getString("title"), e.str("superset"), e.optJSONArray("sets").strings(), e.str("rest"), e.str("notes")) } }

    internal fun parse(o: JSONObject): Drafts {
        val routine = o.optJSONObject("routine")?.let { r ->
            Routine(r.getString("id"), r.getString("header"), r.getString("title"), r.getString("counts"), r.optString("rationale"),
                    r.optJSONArray("warnings").strings(), r.optBoolean("replaces"), r.optJSONArray("removed").strings(),
                    r.optJSONArray("added").strings(), exercises(r.optJSONArray("exercises")), r.str("error"))
        }
        val workout = o.optJSONObject("workout")?.let { w ->
            val cards = w.optJSONArray("cards")
            Workout(w.getString("id"), w.getString("header"),
                    (0 until (cards?.length() ?: 0)).map { cards!!.getJSONObject(it).let { c ->
                        WorkoutCard(c.getString("label"), c.getString("title"), c.getString("date"),
                                    exercises(c.optJSONArray("exercises")), c.getString("volume")) } },
                    w.str("createNote"), w.str("error"))
        }
        return Drafts(routine, workout, o.str("goalId"), o.str("sent"), o.str("error"), labels(o.optJSONObject("labels")))
    }

    // MARK: - Goal and routine draft (`CoachGoalSetupReviewView`)

    data class Choice(val id: String, val label: String, val on: Boolean)
    data class Goal(
        val include: Boolean, val includeLabel: String, val templateTitle: String?, val kind: String, val kinds: List<Choice>,
        val title: String, val showBaseline: Boolean, val baselineLabel: String, val baseline: String,
        val showTarget: Boolean, val targetLabel: String, val target: String, val evidence: String?,
        val dateAllowed: Boolean, val hasDate: Boolean, val date: Double, val tags: List<Choice>,
        val safetyWarning: String?, val volumeWarning: String?,
    )
    data class RoutineEdit(val title: String, val kind: String, val steps: Int, val sports: String, val minutes: Int,
                           val hasMinimum: Boolean, val daily: Boolean, val weekdays: List<Int>, val goalIds: List<String>)
    data class ReviewRoutine(val id: String, val title: String, val detail: String, val linked: String, val selected: Boolean,
                             val unavailable: Boolean, val edit: RoutineEdit)
    data class Period(val id: String, val title: String, val sports: String?, val serves: String?, val amount: String,
                      val note: String?, val selected: Boolean)
    data class Review(
        val open: Boolean, val title: String, val rationale: String, val goal: Goal?, val routines: List<ReviewRoutine>,
        val periods: List<Period>, val goals: List<Choice>, val canApply: Boolean, val ask: String?, val keepBoth: Boolean,
        val error: String?, val applied: Boolean, val labels: Map<String, String>,
    )

    /** One step of the review: `open` with an id, `set` with one changed field, `routine`, `apply` with a stage, `decline`. */
    fun review(op: String, args: JSONObject = JSONObject()): Review? {
        if (!SwiftCore.available) return null
        val raw = SwiftCore.call("coach.drafts.goal.$op", args.toString()) ?: return null
        return runCatching { parseReview(JSONObject(raw)) }.getOrNull()
    }

    private fun choices(a: JSONArray?) = (0 until (a?.length() ?: 0)).map { a!!.getJSONObject(it).let { c ->
        Choice(c.getString("id"), c.getString("label"), c.optBoolean("on")) } }

    internal fun parseReview(o: JSONObject): Review {
        val goal = o.optJSONObject("goal")?.let { g ->
            Goal(g.getBoolean("include"), g.getString("includeLabel"), g.str("templateTitle"), g.getString("kind"),
                 choices(g.optJSONArray("kinds")), g.optString("title"), g.optBoolean("showBaseline"), g.optString("baselineLabel"),
                 g.optString("baseline"), g.optBoolean("showTarget"), g.optString("targetLabel"), g.optString("target"),
                 g.str("evidence"), g.optBoolean("dateAllowed"), g.optBoolean("hasDate"), g.optDouble("date"),
                 choices(g.optJSONArray("tags")), g.str("safetyWarning"), g.str("volumeWarning"))
        }
        val r = o.optJSONArray("routines")
        val routines = (0 until (r?.length() ?: 0)).map { r!!.getJSONObject(it).let { x ->
            val e = x.getJSONObject("edit")
            val days = e.optJSONArray("weekdays")
            ReviewRoutine(x.getString("id"), x.getString("title"), x.optString("detail"), x.optString("linked"),
                          x.optBoolean("selected"), x.optBoolean("unavailable"),
                          RoutineEdit(e.optString("title"), e.optString("kind"), e.optInt("steps"), e.optString("sports"),
                                      e.optInt("minutes"), e.optBoolean("hasMinimum"), e.optBoolean("daily"),
                                      (0 until (days?.length() ?: 0)).map { days!!.getInt(it) }, e.optJSONArray("goalIds").strings()))
        } }
        val p = o.optJSONArray("periods")
        val periods = (0 until (p?.length() ?: 0)).map { p!!.getJSONObject(it).let { x ->
            Period(x.getString("id"), x.getString("title"), x.str("sports"), x.str("serves"), x.getString("amount"),
                   x.str("note"), x.optBoolean("selected")) } }
        return Review(o.optBoolean("open"), o.optString("title"), o.optString("rationale"), goal, routines, periods,
                      choices(o.optJSONArray("goals")), o.optBoolean("canApply"), o.str("ask"), o.optBoolean("keepBoth"),
                      o.str("error"), o.optBoolean("applied"), labels(o.optJSONObject("labels")))
    }
}
