package com.noop.core

import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate

/**
 * Training plans through the shared core (`CorePlans` in NoopCore): the plans the wearer holds, what each
 * one amounts to in a week, the ready-made ones, the builder, the blocks a plan has run, and a session kept
 * as a routine.
 *
 * Nothing here decides anything. Which plan may be followed, how a plan is built, what a week adds up to and
 * what stands out about it are all the core's answers, so this and the Apple app say the same thing rather
 * than agreeing by accident. Blocking; call off the main thread.
 */
object CorePlans {

    data class Routine(val id: String, val title: String, val exerciseCount: Int, val minutes: Int,
                       /** ISO weekdays, Monday 1. */
                       val weekdays: List<Int>)

    data class Block(val weeks: Int, val progression: String, val deloadInFinalWeek: Boolean,
                     val deloadEveryWeeks: Int?, val deloadFactor: Double,
                     /** Null while the plan rests: a plan nobody follows has no week to report. */
                     val week: Int?, val isDeload: Boolean, val isFinished: Boolean)

    data class Plan(val id: String, val title: String, val kind: String, val notes: String?,
                    val isActive: Boolean, val sessionsPerWeek: Int?, val cardioMinutesPerWeek: Int?,
                    val originKind: String, val originName: String?, val originAttribution: String?,
                    val block: Block?, val routines: List<Routine>,
                    /** Weekday (ISO, Monday 1) to the routine ids planned on it. */
                    val days: Map<Int, List<String>>) {
        val dayCount get() = days.count { it.value.isNotEmpty() }
    }

    /** One thing that stood out, with the figures it compared. The wording is the screen's. */
    data class Finding(val kind: String, val region: String? = null, val weeklySets: Double? = null,
                       val usualWeeklySets: Double? = null, val firstWeekday: Int? = null,
                       val secondWeekday: Int? = null, val routineId: String? = null,
                       val minutes: Int? = null, val askedMinutes: Int? = null)

    data class Review(val setsByRegion: Map<String, Double>, val minutesByRoutine: Map<String, Int>,
                      val sessionsPerWeek: Int, val findings: List<Finding>)

    data class Template(val id: String, val title: String, val summary: String, val daysPerWeek: Int,
                        val requiredEquipment: List<String>, val sourceName: String?,
                        val sourceAttribution: String?)

    data class BlockRun(val id: String, val startedOn: String, val endedOn: String?, val outcome: String,
                        val plannedSessions: Int?, val doneSessions: Int, val daysTrained: Int,
                        val workSets: Int, val loadKg: Double, val unpricedWorkSets: Int,
                        val deltaWorkSets: Int?, val deltaLoadKg: Double?)


    data class SetPlan(val id: String, val phase: String, val weightKg: Double?, val repsMin: Int?,
                       val repsMax: Int?, val durationS: Int?) {
        val isWarmup get() = phase == "warmup"
    }

    data class Progression(val policy: String, val weightIncrementKg: Double, val repsMin: Int,
                           val repsMax: Int, val failuresBeforeDeload: Int)

    data class RoutineExerciseDetail(val id: String, val exerciseId: String, val title: String,
                                     val mode: String, val restSeconds: Int, val warmupRestSeconds: Int?,
                                     val supersetId: String?, val note: String?,
                                     /** Null when the exercise follows the routine's own default. */
                                     val progression: Progression?, val sets: List<SetPlan>) {
        val workSets get() = sets.count { !it.isWarmup }
    }

    data class RoutineDetail(val id: String, val title: String, val notes: String?, val planId: String?,
                             val planTitle: String?, val weekdays: List<Int>, val minutes: Int,
                             val defaultProgression: Progression, val excludeFromProgression: Boolean,
                             val exercises: List<RoutineExerciseDetail>)

    data class Snapshot(val plans: List<Plan>, val templates: List<Template>) {
        val activeStrength get() = plans.firstOrNull { it.isActive && it.kind == "strength" }
    }

    data class PreviewRoutine(val title: String, val minutes: Int, val lines: List<String>)

    /** A plan the builder produced that nobody has saved yet. */
    data class Preview(val title: String, val routines: List<PreviewRoutine>, val review: Review)

    private fun call(op: String, args: JSONObject = JSONObject()): String? =
        if (SwiftCore.available) SwiftCore.call(op, args.toString()) else null

    private fun today(): String = LocalDate.now().toString()

    // MARK: Reads

    fun snapshot(): Snapshot? =
        call("plans.snapshot", JSONObject().put("day", today()))?.let { json ->
            runCatching {
                val o = JSONObject(json)
                Snapshot(o.optJSONArray("plans").objects().map(::parsePlan),
                         o.optJSONArray("templates").objects().map(::parseTemplate))
            }.getOrNull()
        }

    /** What a plan amounts to in a week. [minutes] is what the wearer said a session may take, if anything. */
    fun review(planId: String, minutes: Int? = null): Review? =
        call("plans.review", JSONObject().put("id", planId)
            .apply { if (minutes != null) put("minutes", minutes) })
            ?.let { json -> runCatching { parseReview(JSONObject(json)) }.getOrNull() }

    fun blockRuns(planId: String): List<BlockRun> =
        call("plans.blockRuns", JSONObject().put("id", planId).put("day", today()))
            ?.let { json ->
                runCatching { JSONArray(json).objects().map(::parseRun) }.getOrNull()
            } ?: emptyList()

    // MARK: Writes

    /**
     * Creates or edits a plan. Only the fields given are changed, so a rename sends a title alone.
     * Returns the plan's id.
     */
    fun save(id: String? = null, title: String? = null, kind: String? = null, notes: String? = null,
             sessionsPerWeek: Int? = null, cardioMinutesPerWeek: Int? = null,
             blockWeeks: Int? = null, deloadInFinalWeek: Boolean? = null, deloadEveryWeeks: Int? = null,
             blockProgression: String? = null, clearBlock: Boolean = false,
             targets: Boolean = false): String? {
        val args = JSONObject()
        if (id != null) args.put("id", id)
        if (title != null) args.put("title", title)
        if (kind != null) args.put("kind", kind)
        if (notes != null) args.put("notes", notes)
        if (targets) {
            args.put("sessionsPerWeek", sessionsPerWeek ?: JSONObject.NULL)
            args.put("cardioMinutesPerWeek", cardioMinutesPerWeek ?: JSONObject.NULL)
        }
        // A block is only touched when the caller says so: `clearBlock` removes it, a week count sets it.
        if (clearBlock) args.put("blockWeeks", 0)
        else if (blockWeeks != null) {
            args.put("blockWeeks", blockWeeks)
            if (deloadInFinalWeek != null) args.put("deloadInFinalWeek", deloadInFinalWeek)
            args.put("deloadEveryWeeks", deloadEveryWeeks ?: JSONObject.NULL)
            if (blockProgression != null) args.put("blockProgression", blockProgression)
        }
        return call("plans.save", args)?.let {
            runCatching { JSONObject(it).optString("id").ifEmpty { null } }.getOrNull()
        }
    }

    /** Takes a plan up. The day is this device's own, which is what a block counts from. */
    fun activate(id: String): Boolean =
        call("plans.activate", JSONObject().put("id", id).put("day", today()))?.contains("true") == true

    fun deactivate(id: String): Boolean =
        call("plans.deactivate", JSONObject().put("id", id).put("day", today()))?.contains("true") == true

    fun delete(id: String): Boolean =
        call("plans.delete", JSONObject().put("id", id))?.contains("true") == true

    fun duplicate(id: String, title: String): String? =
        call("plans.duplicate", JSONObject().put("id", id).put("title", title))?.let {
            runCatching { JSONObject(it).optString("id").ifEmpty { null } }.getOrNull()
        }

    /**
     * Builds a plan from the wearer's answers. With [save] false it is only shown, which is what the
     * wizard's preview is: nothing is written until they say so.
     */
    fun build(daysPerWeek: Int, equipment: List<String>, experience: String, emphasis: String,
              minutes: Int, weightStepKg: Double, blockWeeks: Int? = null, title: String? = null,
              save: Boolean = false, activate: Boolean = false): Preview? {
        val args = JSONObject()
            .put("daysPerWeek", daysPerWeek).put("equipment", JSONArray(equipment))
            .put("experience", experience).put("emphasis", emphasis)
            .put("minutes", minutes).put("weightStepKg", weightStepKg)
            .put("save", save).put("activate", activate).put("day", today())
        if (blockWeeks != null) args.put("blockWeeks", blockWeeks)
        if (title != null) args.put("title", title)
        return call("plans.build", args)?.let { json ->
            runCatching {
                val o = JSONObject(json)
                if (o.has("error")) return@runCatching null
                Preview(o.optString("title"),
                        o.optJSONArray("routines").objects().map {
                            PreviewRoutine(it.optString("title"), it.optInt("minutes"),
                                           it.optJSONArray("lines").strings())
                        },
                        parseReview(o.getJSONObject("review")))
            }.getOrNull()
        }
    }

    /** Writes one of the ready-made plans, resting, and returns its id. */
    fun useTemplate(id: String, weightStepKg: Double): String? =
        call("plans.useTemplate", JSONObject().put("id", id).put("weightStepKg", weightStepKg))?.let {
            runCatching { JSONObject(it).optString("id").ifEmpty { null } }.getOrNull()
        }

    /** Keeps a session that has been done as a routine, in the plan the wearer picked. */
    fun routineFromWorkout(workoutId: String, title: String, planId: String?): Boolean =
        call("plans.routineFromWorkout", JSONObject().put("workoutId", workoutId).put("title", title)
            .apply { if (planId != null) put("planId", planId) })?.contains("true") == true

    // MARK: Parsing

    private fun parsePlan(o: JSONObject): Plan {
        val days = mutableMapOf<Int, List<String>>()
        o.optJSONObject("days")?.let { raw ->
            raw.keys().forEach { key ->
                key.toIntOrNull()?.let { days[it] = raw.optJSONArray(key).strings() }
            }
        }
        return Plan(
            o.getString("id"), o.optString("title"), o.optString("kind", "strength"),
            o.optStringOrNull("notes"), o.optBoolean("isActive"),
            o.optIntOrNull("sessionsPerWeek"), o.optIntOrNull("cardioMinutesPerWeek"),
            o.optString("originKind", "own"), o.optStringOrNull("originName"),
            o.optStringOrNull("originAttribution"),
            o.optJSONObject("block")?.let { b ->
                Block(b.optInt("weeks"), b.optString("progression", "none"),
                      b.optBoolean("deloadInFinalWeek"), b.optIntOrNull("deloadEveryWeeks"),
                      b.optDouble("deloadFactor", 0.9), b.optIntOrNull("week"),
                      b.optBoolean("isDeload"), b.optBoolean("isFinished"))
            },
            o.optJSONArray("routines").objects().map {
                Routine(it.getString("id"), it.optString("title"), it.optInt("exerciseCount"),
                        it.optInt("minutes"), it.optJSONArray("weekdays").ints())
            },
            days)
    }

    private fun parseTemplate(o: JSONObject) = Template(
        o.getString("id"), o.optString("title"), o.optString("summary"), o.optInt("daysPerWeek"),
        o.optJSONArray("requiredEquipment").strings(), o.optStringOrNull("sourceName"),
        o.optStringOrNull("sourceAttribution"))

    private fun parseReview(o: JSONObject): Review {
        val sets = mutableMapOf<String, Double>()
        o.optJSONObject("setsByRegion")?.let { raw -> raw.keys().forEach { sets[it] = raw.optDouble(it) } }
        val minutes = mutableMapOf<String, Int>()
        o.optJSONObject("minutesByRoutine")?.let { raw -> raw.keys().forEach { minutes[it] = raw.optInt(it) } }
        return Review(sets, minutes, o.optInt("sessionsPerWeek"),
                      o.optJSONArray("findings").objects().map {
                          Finding(it.optString("kind"), it.optStringOrNull("region"),
                                  it.optDoubleOrNull("weeklySets"), it.optDoubleOrNull("usualWeeklySets"),
                                  it.optIntOrNull("firstWeekday"), it.optIntOrNull("secondWeekday"),
                                  it.optStringOrNull("routineId"), it.optIntOrNull("minutes"),
                                  it.optIntOrNull("askedMinutes"))
                      })
    }

    private fun parseRun(o: JSONObject) = BlockRun(
        o.getString("id"), o.optString("startedOn"), o.optStringOrNull("endedOn"),
        o.optString("outcome", "running"), o.optIntOrNull("plannedSessions"), o.optInt("doneSessions"),
        o.optInt("daysTrained"), o.optInt("workSets"), o.optDouble("loadKg", 0.0),
        o.optInt("unpricedWorkSets"), o.optIntOrNull("deltaWorkSets"), o.optDoubleOrNull("deltaLoadKg"))

    // MARK: One routine, in full

    /** Everything a routine holds, for the editor. */
    fun routine(id: String): RoutineDetail? =
        call("plans.routine", JSONObject().put("id", id))?.let { json ->
            runCatching {
                val o = JSONObject(json)
                if (o.has("error")) return@runCatching null
                RoutineDetail(
                    o.getString("id"), o.optString("title"), o.optStringOrNull("notes"),
                    o.optStringOrNull("planId"), o.optStringOrNull("planTitle"),
                    o.optJSONArray("weekdays").ints(), o.optInt("minutes"),
                    parseProgression(o.getJSONObject("defaultProgression")),
                    o.optBoolean("excludeFromProgression"),
                    o.optJSONArray("exercises").objects().map { e ->
                        RoutineExerciseDetail(
                            e.getString("id"), e.optString("exerciseId"), e.optString("title"),
                            e.optString("mode", "weight_reps"), e.optInt("restSeconds"),
                            e.optIntOrNull("warmupRestSeconds"), e.optStringOrNull("supersetId"),
                            e.optStringOrNull("note"),
                            e.optJSONObject("progression")?.let(::parseProgression),
                            e.optJSONArray("sets").objects().map { set ->
                                SetPlan(set.getString("id"), set.optString("phase", "work"),
                                        set.optDoubleOrNull("weightKg"), set.optIntOrNull("repsMin"),
                                        set.optIntOrNull("repsMax"), set.optIntOrNull("durationS"))
                            })
                    })
            }.getOrNull()
        }

    /**
     * One edit to a routine, applied and saved by the core.
     *
     * The screen names the operation and sends the values it changed; what a new set or a new exercise
     * starts out as is the core's decision, once, for both platforms.
     */
    fun editRoutine(op: String, routineId: String? = null, args: JSONObject = JSONObject()): Boolean {
        val payload = JSONObject().put("op", op)
        if (routineId != null) payload.put("routineId", routineId)
        args.keys().forEach { payload.put(it, args.get(it)) }
        return call("plans.editRoutine", payload)?.contains("true") == true
    }

    private fun parseProgression(o: JSONObject) = Progression(
        o.optString("policy", "off"), o.optDouble("weightIncrementKg", 2.5),
        o.optInt("repsMin", 6), o.optInt("repsMax", 10), o.optInt("failuresBeforeDeload", 3))

    private fun JSONArray?.objects(): List<JSONObject> =
        if (this == null) emptyList() else (0 until length()).map { getJSONObject(it) }

    private fun JSONArray?.strings(): List<String> =
        if (this == null) emptyList() else (0 until length()).map { getString(it) }

    private fun JSONArray?.ints(): List<Int> =
        if (this == null) emptyList() else (0 until length()).map { getInt(it) }

    private fun JSONObject.optStringOrNull(key: String): String? =
        if (isNull(key)) null else optString(key).ifEmpty { null }

    private fun JSONObject.optIntOrNull(key: String): Int? = if (isNull(key)) null else optInt(key)

    private fun JSONObject.optDoubleOrNull(key: String): Double? =
        if (isNull(key)) null else optDouble(key).takeIf { !it.isNaN() }
}
