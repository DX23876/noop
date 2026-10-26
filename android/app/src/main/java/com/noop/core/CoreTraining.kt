package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 2.3: native training through the shared core (`CoreTraining` in NoopCore),
 * the same store calls, draft builder and workout engine the Apple app uses. Blocking; call off the main thread.
 * The draft and workouts come back as the core's JSON; the screens keep the parts they show and send changes as
 * operations, so prefill, progression and completion are never rebuilt in Kotlin.
 */
object CoreTraining {
    data class Exercise(val id: String, val title: String, val primaryMuscle: String?)
    data class Routine(val id: String, val title: String, val exerciseIds: List<String>,
                       val muscles: Map<String, Double>, val weekdays: List<Int>) {
        val exerciseCount get() = exerciseIds.size
    }
    data class PlannedDay(val day: String, val weekday: Int, val isToday: Boolean, val routineIds: List<String>)
    data class SetLine(val weightKg: Double?, val reps: Int?, val durationS: Double?, val distanceM: Double?)
    data class ExerciseLine(val title: String, val sets: List<SetLine>)
    data class Session(val id: String, val title: String, val startTs: Long, val durationS: Double,
                       val workingSets: Int, val volumeKg: Double, val exerciseCount: Int, val lines: List<ExerciseLine>)
    data class ActivityDay(val day: String, val minutes: Double)
    data class Coverage(val workingSets: Int, val mappedSets: Int, val ratedSets: Int)
    data class Evidence(val exercise: String, val session: String)
    data class Balance(val muscleId: String, val effectiveSets: Double, val share: Double, val usualShare: Double?,
                       val state: String, val evidence: List<Evidence>)
    data class Fatigue(val muscleId: String, val relative: Double, val tauHours: Double, val personal: Boolean,
                       val evidence: List<Evidence>)
    data class StrengthExercise(val title: String, val points: Int, val slopePerWeek: Double?, val unclear: Boolean)
    data class Strength(val muscleId: String, val slopePerWeek: Double?, val direction: String,
                        val exercises: List<StrengthExercise>)
    /** The three readings of the muscle analytics card (`MuscleAnalyticsSnapshot`), with what each one covers. */
    data class MuscleAnalytics(val balance: List<Balance>, val balanceCoverage: Coverage, val personalBaseline: Boolean,
                               val fatigue: List<Fatigue>, val fatigueCoverage: Coverage,
                               val strength: List<Strength>, val strengthCoverage: Coverage)
    data class Snapshot(val exercises: List<Exercise>, val routines: List<Routine>, val week: List<PlannedDay>,
                        val sessions: List<Session>, val hasDraft: Boolean, val activity: List<ActivityDay>,
                        val muscles: MuscleAnalytics)
    data class Starter(val index: Int, val title: String, val exercises: List<String>)

    data class DraftSet(val id: String, val index: Int, val warmup: Boolean, val weightKg: Double?, val reps: Int?,
                        val done: Boolean)
    data class DraftExercise(val id: String, val exerciseId: String, val restSeconds: Int, val sets: List<DraftSet>)
    data class Draft(val id: String, val title: String, val startedAt: Long, val exercises: List<DraftExercise>)

    private fun call(op: String, args: JSONObject = JSONObject()): String? =
        if (SwiftCore.available) SwiftCore.call(op, args.toString()) else null

    fun snapshot(dismissedWorkouts: List<String> = emptyList()): Snapshot? =
        call("training.snapshot", JSONObject().put("days", 4_000).put("dismissedWorkouts", JSONArray(dismissedWorkouts)))
            ?.let(::parseSnapshot)

    fun startDraft(routineIds: List<String>): Draft? =
        call("training.startDraft", JSONObject().put("routineIds", JSONArray(routineIds)))?.let(::parseDraft)

    fun setValues(exercise: String, set: String, weightKg: Double?, reps: Int?, done: Boolean?): Draft? =
        call("training.changeDraft", JSONObject().put("change", "set").put("exercise", exercise).put("set", set)
            .put("weightKg", weightKg ?: JSONObject.NULL).put("reps", reps ?: JSONObject.NULL)
            .apply { if (done != null) put("done", done) })?.let(::parseDraft)

    fun addSet(exercise: String): Draft? =
        call("training.changeDraft", JSONObject().put("change", "addSet").put("exercise", exercise))?.let(::parseDraft)

    fun addExercise(exerciseId: String): Draft? =
        call("training.changeDraft", JSONObject().put("change", "addExercise").put("exerciseId", exerciseId))
            ?.let(::parseDraft)

    fun removeExercise(exercise: String): Draft? =
        call("training.changeDraft", JSONObject().put("change", "removeExercise").put("exercise", exercise))
            ?.let(::parseDraft)

    /** The current draft unchanged; null when no session is in progress. */
    fun draft(): Draft? = call("training.changeDraft", JSONObject().put("change", "none"))?.let(::parseDraft)

    /** True when the workout was saved (at least one completed set). */
    fun finish(sessionRPE: Double?): Boolean =
        call("training.finishDraft", JSONObject().put("sessionRPE", sessionRPE ?: JSONObject.NULL))
            ?.let { it != "null" && it.startsWith("{") && !it.contains("\"error\"") } ?: false

    fun discard(draftId: String): Boolean =
        call("training.discardDraft", JSONObject().put("id", draftId))?.contains("true") == true

    /**
     * Creates or, with [id], edits a routine: exercises it already had keep their planned sets, new ones get the Apple
     * editor's defaults, and [weekdays] (ISO, Monday 1) schedule it on exactly those days.
     */
    fun createRoutine(title: String, exerciseIds: List<String>, id: String? = null, weekdays: List<Int>? = null): Boolean =
        call("training.createRoutine", JSONObject().put("title", title).put("exerciseIds", JSONArray(exerciseIds))
            .apply { if (id != null) put("id", id) }
            .apply { if (weekdays != null) put("weekdays", JSONArray(weekdays)) })?.contains("true") == true

    fun duplicateRoutine(id: String, title: String): Boolean =
        call("training.duplicateRoutine", JSONObject().put("id", id).put("title", title))?.contains("true") == true

    fun starters(): List<Starter> = call("training.starters")?.takeIf { it.startsWith("[") }?.let { json ->
        JSONArray(json).objects().map { Starter(it.getInt("index"), it.getString("title"), it.optJSONArray("exercises").strings()) }
    }.orEmpty()

    fun addStarter(index: Int): Boolean =
        call("training.addStarter", JSONObject().put("index", index))?.contains("true") == true

    /** Replaces the weekly schedule: routine ids per ISO weekday (Monday 1). */
    fun setSchedule(days: Map<Int, List<String>>): Boolean =
        call("training.setSchedule", JSONObject().put("days", JSONObject().apply {
            days.forEach { (weekday, ids) -> put(weekday.toString(), JSONArray(ids)) }
        }))?.contains("true") == true

    fun deleteRoutine(id: String): Boolean =
        call("training.deleteRoutine", JSONObject().put("id", id))?.contains("true") == true

    internal fun parseSnapshot(json: String): Snapshot? {
        if (json == "null" || json.contains("\"error\"")) return null
        val o = JSONObject(json)
        val exercises = o.optJSONArray("exercises").objects().map {
            Exercise(it.getString("id"), it.getString("title"), it.optStringOrNull("primaryMuscleId"))
        }
        val plan = o.getJSONObject("plan")
        val routineMuscles = o.optJSONObject("routineMuscles")
        val routineWeekdays = o.optJSONObject("routineWeekdays")
        val routines = plan.optJSONArray("routines").objects().map {
            val id = it.getString("id")
            Routine(id, it.getString("title"),
                    it.optJSONArray("exercises").objects().map { e -> e.getString("exerciseId") },
                    routineMuscles?.optJSONObject(id).doubles(),
                    routineWeekdays?.optJSONArray(id).ints())
        }
        val week = o.optJSONArray("week").objects().map {
            PlannedDay(it.getString("day"), it.getInt("weekday"), it.getBoolean("isToday"),
                       it.optJSONArray("routineIds").strings())
        }
        val sessions = o.optJSONArray("strength").objects().map {
            Session(it.getString("id"), it.getString("title"), it.getLong("startTs"), it.getDouble("durationS"),
                    it.getInt("workingSets"), it.getDouble("volumeKg"), it.optInt("exerciseCount"),
                    it.optJSONArray("lines").objects().map { l ->
                        ExerciseLine(l.getString("title"), l.optJSONArray("sets").objects().map { st ->
                            SetLine(st.optDoubleOrNull("weightKg"), st.optIntOrNull("reps"), st.optDoubleOrNull("durationS"),
                                    st.optDoubleOrNull("distanceM"))
                        })
                    })
        }
        val activity = o.optJSONArray("activity").objects().map { ActivityDay(it.getString("day"), it.getDouble("minutes")) }
        val m = o.optJSONObject("muscles") ?: JSONObject()
        fun coverage(key: String) = m.optJSONObject(key)?.let {
            Coverage(it.optInt("workingSets"), it.optInt("mappedSets"), it.optInt("ratedSets"))
        } ?: Coverage(0, 0, 0)
        fun evidence(a: JSONArray?) = a.objects().map { Evidence(it.getString("exercise"), it.getString("session")) }
        val muscles = MuscleAnalytics(
            balance = m.optJSONArray("balance").objects().map {
                Balance(it.getString("muscleId"), it.getDouble("effectiveSets"), it.getDouble("share"),
                        it.optDoubleOrNull("usualShare"), it.getString("state"), evidence(it.optJSONArray("evidence")))
            },
            balanceCoverage = coverage("balanceCoverage"), personalBaseline = m.optBoolean("personalBaseline"),
            fatigue = m.optJSONArray("fatigue").objects().map {
                Fatigue(it.getString("muscleId"), it.getDouble("relative"), it.getDouble("tauHours"),
                        it.optBoolean("personal"), evidence(it.optJSONArray("evidence")))
            },
            fatigueCoverage = coverage("fatigueCoverage"),
            strength = m.optJSONArray("strength").objects().map {
                Strength(it.getString("muscleId"), it.optDoubleOrNull("slopePerWeek"), it.getString("direction"),
                         it.optJSONArray("exercises").objects().map { e ->
                             StrengthExercise(e.getString("title"), e.optInt("points"), e.optDoubleOrNull("slopePerWeek"),
                                              e.optBoolean("unclear"))
                         })
            },
            strengthCoverage = coverage("strengthCoverage"),
        )
        return Snapshot(exercises, routines, week, sessions, o.has("draft") && !o.isNull("draft"), activity, muscles)
    }

    internal fun parseDraft(json: String): Draft? {
        if (json == "null" || json.contains("\"error\"")) return null
        val o = JSONObject(json)
        return Draft(o.getString("id"), o.getString("title"), o.getLong("startedAt"),
            o.optJSONArray("exercises").objects().map { e ->
                DraftExercise(e.getString("id"), e.getString("exerciseId"), e.optInt("restSeconds", 90),
                    e.optJSONArray("sets").objects().map { s ->
                        DraftSet(s.getString("id"), s.optInt("index"), s.optString("phase") == "warmup",
                                 if (s.has("weightKg") && !s.isNull("weightKg")) s.getDouble("weightKg") else null,
                                 if (s.has("reps") && !s.isNull("reps")) s.getInt("reps") else null,
                                 s.optBoolean("isCompleted"))
                    })
            })
    }

    private fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else (0 until length()).map { getJSONObject(it) }
    private fun JSONArray?.strings(): List<String> = if (this == null) emptyList() else (0 until length()).map { getString(it) }
    private fun JSONObject.optStringOrNull(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null
    private fun JSONObject.optDoubleOrNull(key: String): Double? = if (has(key) && !isNull(key)) getDouble(key) else null
    private fun JSONObject.optIntOrNull(key: String): Int? = if (has(key) && !isNull(key)) getInt(key) else null
    private fun JSONObject?.doubles(): Map<String, Double> =
        if (this == null) emptyMap() else keys().asSequence().associateWith { getDouble(it) }
    private fun JSONArray?.ints(): List<Int> = if (this == null) emptyList() else (0 until length()).map { getInt(it) }
}
