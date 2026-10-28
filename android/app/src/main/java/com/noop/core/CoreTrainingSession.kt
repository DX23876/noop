package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/** Session details and deliberate ratings from the shared store. No physiological calculation is hosted here. */
object CoreTrainingSession {
    data class HeartPoint(val ts: Long, val bpm: Double)
    data class Rating(val id: String, val rpe: Double, val loadAU: Double?, val timing: String,
                      val durationMinutes: Double?, val ratedAtTs: Long?)
    data class Set(val index: Int, val type: String, val isWorking: Boolean, val weightKg: Double?,
                   val reps: Int?, val leftReps: Int?, val rightReps: Int?, val durationS: Double?,
                   val distanceM: Double?, val rpe: Double?, val e1rmKg: Double?, val bodyweightLoadKg: Double?)
    data class Exercise(val title: String, val kind: String, val notes: String?, val primary: String?,
                        val secondary: List<String>, val workingSets: Int, val topSetKg: Double?, val sets: List<Set>)
    data class Summary(val workingSets: Int, val exerciseCount: Int, val volumeSets: Int, val ratedSets: Int,
                       val volumeKg: Double, val bodyweightVolumeKg: Double, val unpricedBodyweightSets: Int,
                       val meanRPE: Double?, val densityKgPerMinute: Double?)
    data class Output(val id: String, val canonicalId: String?, val title: String, val source: String, val kind: String,
                      val startTs: Long, val endTs: Long, val durationS: Double?, val notes: String?, val avgHr: Int?,
                      val maxHr: Int?, val distanceM: Double?, val energyKcal: Double?, val summary: Summary?,
                      val groups: List<List<Exercise>>, val heartRate: List<HeartPoint>, val zoneMinutes: List<Double>?,
                      val bucketSeconds: Int, val rating: Rating?)

    fun read(id: String, maxHR: Double, zoneBpmEdges: List<Double>?, dismissed: List<String>): Output? {
        val args = arguments(id, dismissed).put("maxHR", maxHR)
        zoneBpmEdges?.takeIf { it.size == 6 }?.let { args.put("zoneBpmEdges", JSONArray(it)) }
        return SwiftCore.call("training.sessionDetail", args.toString())?.let(::parse)
    }

    fun rate(id: String, rpe: Double?, remove: Boolean, dismissed: List<String>): Boolean {
        val args = arguments(id, dismissed).put("remove", remove)
        rpe?.let { args.put("rpe", it) }
        return SwiftCore.call("training.sessionRating", args.toString())?.let {
            runCatching { JSONObject(it).optBoolean("ok") }.getOrDefault(false)
        } ?: false
    }
    private fun arguments(id: String, dismissed: List<String>) = JSONObject().put("id", id).put("dismissedWorkouts", JSONArray(dismissed))

    internal fun parse(json: String): Output? = runCatching {
        val o = JSONObject(json)
        if (o.has("error")) return null
        val summary = o.optJSONObject("summary")?.let { s -> Summary(s.getInt("workingSets"), s.getInt("exerciseCount"),
            s.getInt("volumeSets"), s.getInt("ratedSets"), s.getDouble("volumeKg"), s.getDouble("bodyweightVolumeKg"),
            s.getInt("unpricedBodyweightSets"), s.number("meanRPE"), s.number("densityKgPerMinute")) }
        val groups = o.getJSONArray("groups").let { a -> (0 until a.length()).map { group ->
            a.getJSONArray(group).objects().map { e -> Exercise(e.getString("title"), e.getString("kind"), e.text("notes"),
                e.text("primary"), e.getJSONArray("secondary").let { names -> (0 until names.length()).map(names::getString) },
                e.getInt("workingSets"), e.number("topSetKg"), e.getJSONArray("sets").objects().map { s ->
                    Set(s.getInt("index"), s.getString("type"), s.getBoolean("isWorking"), s.number("weightKg"),
                        s.integer("reps"), s.integer("leftReps"), s.integer("rightReps"), s.number("durationS"),
                        s.number("distanceM"), s.number("rpe"), s.number("e1rmKg"), s.number("bodyweightLoadKg"))
                }) }
        } }
        val rating = o.optJSONObject("rating")?.let { r -> Rating(r.getString("id"), r.getDouble("rpe"), r.number("loadAU"),
            r.getString("timing"), r.number("durationMinutes"), r.long("ratedAtTs")) }
        Output(o.getString("id"), o.text("canonicalId"), o.getString("title"), o.getString("source"), o.getString("kind"),
            o.getLong("startTs"), o.getLong("endTs"), o.number("durationS"), o.text("notes"), o.integer("avgHr"),
            o.integer("maxHr"), o.number("distanceM"), o.number("energyKcal"), summary, groups,
            o.getJSONArray("heartRate").objects().map { HeartPoint(it.getLong("ts"), it.getDouble("bpm")) },
            o.optJSONArray("zoneMinutes")?.let { a -> (0 until a.length()).map(a::getDouble) }, o.getInt("bucketSeconds"), rating)
    }.getOrNull()
    private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map(::getJSONObject)
    private fun JSONObject.number(key: String): Double? = if (isNull(key)) null else getDouble(key)
    private fun JSONObject.integer(key: String): Int? = if (isNull(key)) null else getInt(key)
    private fun JSONObject.long(key: String): Long? = if (isNull(key)) null else getLong(key)
    private fun JSONObject.text(key: String): String? = if (isNull(key)) null else getString(key)
}
