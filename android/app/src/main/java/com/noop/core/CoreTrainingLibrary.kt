package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/** The library's metadata and records are read from Swift; no training calculation lives here. */
object CoreTrainingLibrary {
    data class Row(val id: String, val title: String, val mode: String, val source: String,
                   val primaryMuscle: String?, val aliases: List<String>, val region: String,
                   val primary: List<String>, val secondary: List<String>, val equipment: List<String>, val matchingMuscles: List<String>)
    data class Catalog(val exercises: List<Row>, val muscles: List<String>, val equipment: List<String>,
                       val regions: List<String>, val modes: List<String>, val provider: String,
                       val licence: String, val attribution: String?, val availableExerciseIds: List<String> = emptyList(),
                       val groups: List<Group> = emptyList())
    /** A muscle group of "Find by muscle" (`ExerciseMuscleGroup`), with the exercises it is the main or a side target of. */
    data class Group(val id: String, val title: String, val muscleIds: List<String>, val primary: List<String>, val secondary: List<String>)
    data class Records(val sessions: Int, val heaviestKg: Double?, val estimatedOneRepMaxKg: Double?, val lastPerformedTs: Long?)
    data class Recent(val startTs: Long, val isNative: Boolean, val workingSets: Int, val heaviestKg: Double?)
    data class Detail(val exercise: Row, val instructions: List<String>, val attribution: String?,
                      val unilateral: Boolean, val hasDraft: Boolean, val records: Records, val recent: List<Recent>)

    fun catalog(availableEquipment: List<String> = emptyList()): Catalog? = call("training.library", JSONObject().put("availableEquipment", JSONArray(availableEquipment)))?.let(::parseCatalog)
    fun detail(id: String, dismissedWorkouts: List<String>): Detail? = call("training.exerciseDetail",
        JSONObject().put("id", id).put("dismissedWorkouts", JSONArray(dismissedWorkouts)))?.let(::parseDetail)
    fun create(title: String, mode: String, primary: String, equipment: String, instruction: String, unilateral: Boolean): String? =
        call("training.createExercise", JSONObject().put("title", title).put("mode", mode).put("primary", primary)
            .put("equipment", equipment).put("instruction", instruction).put("unilateral", unilateral))
            ?.let { parse(it) { o -> o.getString("id") } }
    fun importCatalog(json: String): Int? = call("training.importCatalog", JSONObject().put("archive", json))
        ?.let { parse(it) { o -> o.getInt("count") } }

    internal fun parseCatalog(json: String): Catalog? = parse(json) { o -> Catalog(
        o.getJSONArray("exercises").objects().map(::row), o.strings("muscles"), o.strings("equipment"),
        o.strings("regions"), o.strings("modes"), o.getString("provider"), o.getString("licence"), o.string("attribution"), o.strings("availableExerciseIds"),
        o.optJSONArray("groups")?.objects()?.map { Group(it.getString("id"), it.getString("title"), it.strings("muscleIds"),
            it.strings("primary"), it.strings("secondary")) }.orEmpty()) }
    internal fun parseDetail(json: String): Detail? = parse(json) { o ->
        val r = o.getJSONObject("records")
        Detail(row(o.getJSONObject("exercise")), o.strings("instructions"), o.string("attribution"),
            o.getBoolean("unilateral"), o.getBoolean("hasDraft"),
            Records(r.getInt("sessions"), r.double("heaviestKg"), r.double("estimatedOneRepMaxKg"), r.long("lastPerformedTs")),
            o.getJSONArray("recent").objects().map { Recent(it.getLong("startTs"), it.getBoolean("isNative"),
                it.getInt("workingSets"), it.double("heaviestKg")) })
    }
    private fun row(o: JSONObject) = Row(o.getString("id"), o.getString("title"), o.getString("mode"),
        o.getString("source"), o.string("primaryMuscle"), o.strings("aliases"), o.getString("region"),
        o.strings("primary"), o.strings("secondary"), o.strings("equipment"), o.strings("matchingMuscles"))
    private fun call(op: String, args: JSONObject = JSONObject()): String? =
        if (SwiftCore.available) SwiftCore.call(op, args.toString()) else null
    private fun <T> parse(json: String, read: (JSONObject) -> T): T? = runCatching {
        val o = JSONObject(json); if (o.has("error")) null else read(o)
    }.getOrNull()
    private fun JSONObject.string(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null
    private fun JSONObject.double(key: String): Double? = if (has(key) && !isNull(key)) getDouble(key) else null
    private fun JSONObject.long(key: String): Long? = if (has(key) && !isNull(key)) getLong(key) else null
    private fun JSONObject.strings(key: String): List<String> = getJSONArray(key).let { a -> (0 until a.length()).map { a.getString(it) } }
    private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
}
