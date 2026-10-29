package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/** Finished Strength and Cardio readings from the shared Swift core. No training formula lives here. */
object CoreTrainingReports {
    data class Range(val lower: Double, val upper: Double)
    data class Selection(val days: Int, val weekOffset: Int, val minWeekOffset: Int,
                         val monday: String, val sunday: String, val readingDay: String)
    data class Ratio(val day: String, val strength: Double?, val cardio: Double?)
    data class Point(val day: String, val startTs: Long, val value: Double?)
    data class Trend(val slopePerWeek: Double, val spread: Range, val pointCount: Int,
                     val spanDays: Int, val firstValue: Double, val lastValue: Double, val unclear: Boolean)
    data class Record(val value: Double, val day: String, val startTs: Long, val workoutId: String, val reps: Int?)
    data class StrengthOverview(val sessions: Int, val trainingDays: Int, val workingSets: Int,
                                val ratedSets: Int, val volumeKg: Double, val volumeSets: Int, val durationSeconds: Int, val durationSessions: Int,
                                val sessionsPerWeek: Double, val averageRPE: Double?,
                                val activeWeeks: Int, val observedWeeks: Int, val longestStreak: Int,
                                val records: List<PersonalRecord>)
    data class PersonalRecord(val exerciseTitle: String, val workoutId: String,
                              val timestamp: Long, val estimatedOneRepMaxKg: Double)
    data class Muscle(val id: String, val primarySets: Int, val secondarySets: Int,
                      val usualSets: Range?, val stimulus: Double, val usualStimulus: Double?,
                      val band: String?, val fatigue: Double?)
    data class Balance(val axis: String, val setsA: Int, val setsB: Int,
                       val ratio: Double?, val shareA: Double?, val usualRatio: Range?)
    data class ExerciseChoice(val id: String, val title: String, val sessions: Int)
    data class Exercise(val selectedId: String?, val choices: List<ExerciseChoice>,
                        val points: List<Point>, val trend: Trend?, val isVolume: Boolean,
                        val heaviestSet: Record?, val bestSessionVolume: Record?,
                        val bestEstimatedOneRepMax: Record?, val repRecords: Map<String, Record>)
    data class LoggedSet(val type: String, val countsAsWork: Boolean, val weightKg: Double?, val reps: Int?, val rpe: Double?,
                         val durationS: Double?, val distanceM: Double?)
    data class LoggedExercise(val title: String, val sets: List<LoggedSet>)
    data class LoggedSession(val id: String, val title: String, val startTs: Long,
                             val durationS: Double?, val source: String, val exercises: List<LoggedExercise>)
    data class Strength(val selection: Selection, val lane: CoreTrainingLoad.Lane, val ratios: List<Ratio>,
                        val sessions: Int, val workingSets: Int, val volumeSets: Int, val volumeKg: Double,
                        val bodyweightKg: Double, val bodyweightSets: Int,
                        val unpricedBodyweightSets: Int, val unattributedSets: Int,
                        val charge: Double?, val effort: Double?, val activity: List<CoreTraining.ActivityDay>, val overview: StrengthOverview,
                        val muscles: List<Muscle>, val balance: List<Balance>, val exercise: Exercise,
                        val recentSessions: List<LoggedSession>, val genericSessions: List<GenericSession>, val unmappedExercises: List<String>)
    data class EntryDraft(val title: String = "", val workSets: Int = 3, val muscle: String = "other",
                          val effort: String = "", val usesRIR: Boolean = true) {
        fun json(): JSONObject = JSONObject().put("title", title).put("workSets", workSets)
            .put("muscle", muscle).put("effort", effort).put("usesRIR", usesRIR)
    }
    data class GenericSession(val id: String, val title: String, val startTs: Long, val endTs: Long,
                              val source: String, val drafts: List<EntryDraft>, val manualWorkoutId: String?)
    data class CardioSession(val id: String, val startTs: Long, val endTs: Long, val day: String, val sport: String,
                             val source: String, val modality: String, val family: String,
                             val durationS: Double?, val distanceM: Double?, val avgHr: Int?,
                             val maxHr: Int?, val energyKcal: Double?, val strain: Double?,
                             val cardioLoad: Double?, val paceSecPerKm: Double?, val paceSecPer100m: Double?,
                             val speedKmh: Double?)
    data class Sport(val name: String, val modality: String, val sessions: Int,
                     val minutes: Double, val distanceM: Double, val energyKcal: Double)
    data class SportShare(val sport: String, val modality: String, val load: Double, val share: Double)
    data class Zones(val minutes: List<Double>, val sessionsRead: Int, val sessionsPossible: Int,
                     val usedMinuteBuckets: Boolean)
    data class Best(val value: Double, val day: String, val startTs: Long, val sport: String,
                    val distanceM: Double?, val durationS: Double?)
    data class SportProgress(val selectedSport: String?, val modality: String, val metric: String, val choices: List<String>,
                             val pace: List<Point>, val efficiency: List<Point>,
                             val paceTrend: Trend?, val efficiencyTrend: Trend?,
                             val farthest: Best?, val longest: Best?, val paceBests: Map<String, Best>)
    data class Cardio(val selection: Selection, val lane: CoreTrainingLoad.Lane?, val ratios: List<Ratio>,
                      val sessions: List<CardioSession>, val weekSessions: Int, val minutes: Double,
                      val distanceM: Double, val energyKcal: Double, val effort: Double?,
                      val sessionsWithDistance: Int, val typicalMinutes: Range?,
                      val averageHr: Double?, val typicalAverageHr: Double?, val charge: Double?,
                      val topSportPace: Double?, val sports: List<Sport>, val loadShares: List<SportShare>,
                      val zones: Zones?, val progress: SportProgress)

    /** Blocking JNI call; callers open the core store and run this on Dispatchers.IO. */
    fun strength(days: Int = 120, weekOffset: Int = 0, exerciseId: String? = null,
                 firstWeekday: Int = 2, dismissedWorkouts: List<String> = emptyList()): Strength? {
        if (!SwiftCore.available) return null
        val args = JSONObject().put("days", days).put("weekOffset", weekOffset)
            .put("firstWeekday", firstWeekday).put("dismissedWorkouts", JSONArray(dismissedWorkouts))
        exerciseId?.let { args.put("exerciseId", it) }
        return SwiftCore.call("training.strength", args.toString())?.let(::parseStrength)
    }

    /** Pass the profile's five zone starts plus HRmax as six edges, matching HRZoneSet on iOS. */
    fun cardio(maxHR: Double, sex: String, zoneBpmEdges: List<Double>?, days: Int = 120,
               weekOffset: Int = 0, sport: String? = null,
               dismissedWorkouts: List<String> = emptyList()): Cardio? {
        if (!SwiftCore.available) return null
        val args = JSONObject().put("maxHR", maxHR).put("sex", sex).put("days", days)
            .put("weekOffset", weekOffset).put("dismissedWorkouts", JSONArray(dismissedWorkouts))
        sport?.let { args.put("sport", it) }
        zoneBpmEdges?.takeIf { it.size == 6 }?.let { args.put("zoneBpmEdges", JSONArray(it)) }
        return SwiftCore.call("training.cardio", args.toString())?.let(::parseCardio)
    }

    fun session(id: String): LoggedSession? = SwiftCore.call("training.strengthSession", JSONObject().put("id", id).toString())
        ?.let { parse(it, ::loggedSession) }

    fun saveDetails(sessionId: String, drafts: List<EntryDraft>, dismissedWorkouts: List<String>): String {
        val args = JSONObject().put("sessionId", sessionId)
            .put("drafts", JSONArray(drafts.map { it.json() }))
            .put("dismissedWorkouts", JSONArray(dismissedWorkouts))
        return SwiftCore.call("training.saveStrengthDetails", args.toString())?.let {
            runCatching { JSONObject(it).getString("result") }.getOrNull()
        } ?: "saveFailed"
    }

    fun mapExercise(title: String, primary: String, secondary: List<String>): Boolean =
        mutation("training.mapStrengthExercise", JSONObject().put("title", title)
            .put("primary", primary).put("secondary", JSONArray(secondary)))

    fun recordFeedback(muscle: String, feeling: Int): Boolean =
        mutation("training.muscleFeedback", JSONObject().put("muscle", muscle).put("feeling", feeling))

    private fun mutation(op: String, args: JSONObject): Boolean = SwiftCore.call(op, args.toString())?.let {
        runCatching { JSONObject(it).optBoolean("ok") }.getOrDefault(false)
    } ?: false

    internal fun parseStrength(json: String): Strength? = parse(json) { o ->
        val e = o.getJSONObject("exercise")
        val overview = o.getJSONObject("overview")
        Strength(selection(o.getJSONObject("selection")), CoreTrainingLoad.parseLane(o.getJSONObject("lane")), ratios(o),
            o.getInt("sessions"), o.getInt("workingSets"), o.getInt("volumeSets"), o.getDouble("volumeKg"),
            o.getDouble("bodyweightKg"), o.getInt("bodyweightSets"), o.getInt("unpricedBodyweightSets"),
            o.getInt("unattributedSets"), o.double("charge"), o.double("effort"),
            o.array("activity").map { CoreTraining.ActivityDay(it.getString("day"), it.getDouble("minutes")) },
            StrengthOverview(overview.getInt("sessions"), overview.getInt("trainingDays"),
                overview.getInt("workingSets"), overview.getInt("ratedSets"), overview.getDouble("volumeKg"),
                overview.getInt("volumeSets"), overview.getInt("durationSeconds"), overview.getInt("durationSessions"), overview.getDouble("sessionsPerWeek"),
                overview.double("averageRPE"), overview.getInt("activeWeeks"), overview.getInt("observedWeeks"),
                overview.getInt("longestStreak"), overview.array("records").map {
                    PersonalRecord(it.getString("exerciseTitle"), it.getString("workoutId"),
                        it.getLong("timestamp"), it.getDouble("estimatedOneRepMaxKg"))
                }),
            o.array("muscles").map { Muscle(it.getString("id"), it.getInt("primarySets"),
                it.getInt("secondarySets"), it.objectOrNull("usualSets")?.let(::range),
                it.getDouble("stimulus"), it.double("usualStimulus"), it.string("band"), it.double("fatigue")) },
            o.array("balance").map { Balance(it.getString("axis"), it.getInt("setsA"), it.getInt("setsB"),
                it.double("ratio"), it.double("shareA"), it.objectOrNull("usualRatio")?.let(::range)) },
            Exercise(e.string("selectedId"), e.array("choices").map {
                ExerciseChoice(it.getString("id"), it.getString("title"), it.getInt("sessions")) },
                e.array("points").map(::point), e.objectOrNull("trend")?.let(::trend),
                e.getBoolean("isVolume"), e.objectOrNull("heaviestSet")?.let(::record),
                e.objectOrNull("bestSessionVolume")?.let(::record),
                e.objectOrNull("bestEstimatedOneRepMax")?.let(::record),
                e.objectOrNull("repRecords")?.let { records -> records.keys().asSequence()
                    .associateWith { key -> record(records.getJSONObject(key)) } }.orEmpty()),
            o.array("recentSessions").map(::loggedSession), o.array("genericSessions").map { session -> GenericSession(session.getString("id"),
                session.getString("title"), session.getLong("startTs"), session.getLong("endTs"),
                session.getString("source"), session.array("drafts").map { draft -> EntryDraft(
                    draft.getString("title"), draft.getInt("workSets"), draft.getString("muscle"),
                    draft.getString("effort"), draft.getBoolean("usesRIR")) }, session.string("manualWorkoutId")) }, o.strings("unmappedExercises"))
    }

    internal fun parseCardio(json: String): Cardio? = parse(json) { o ->
        val p = o.getJSONObject("progress")
        Cardio(selection(o.getJSONObject("selection")), o.objectOrNull("lane")?.let(CoreTrainingLoad::parseLane), ratios(o),
            o.array("sessions").map { CardioSession(it.getString("id"), it.getLong("startTs"), it.getLong("endTs"),
                it.getString("day"), it.getString("sport"), it.getString("source"),
                it.getString("modality"), it.getString("family"), it.double("durationS"),
                it.double("distanceM"), it.int("avgHr"), it.int("maxHr"), it.double("energyKcal"),
                it.double("strain"), it.double("cardioLoad"), it.double("paceSecPerKm"),
                it.double("paceSecPer100m"), it.double("speedKmh")) },
            o.getInt("weekSessions"), o.getDouble("minutes"), o.getDouble("distanceM"),
            o.getDouble("energyKcal"), o.double("effort"), o.getInt("sessionsWithDistance"),
            o.objectOrNull("typicalMinutes")?.let(::range), o.double("averageHr"),
            o.double("typicalAverageHr"), o.double("charge"), o.double("topSportPace"),
            o.array("sports").map { Sport(it.getString("name"), it.getString("modality"),
                it.getInt("sessions"), it.getDouble("minutes"), it.getDouble("distanceM"),
                it.getDouble("energyKcal")) },
            o.array("loadShares").map { SportShare(it.getString("sport"), it.getString("modality"),
                it.getDouble("load"), it.getDouble("share")) },
            o.objectOrNull("zones")?.let { Zones(it.doubles("minutes"), it.getInt("sessionsRead"),
                it.getInt("sessionsPossible"), it.getBoolean("usedMinuteBuckets")) },
            SportProgress(p.string("selectedSport"), p.getString("modality"), p.getString("metric"), p.strings("choices"), p.array("pace").map(::point),
                p.array("efficiency").map(::point), p.objectOrNull("paceTrend")?.let(::trend),
                p.objectOrNull("efficiencyTrend")?.let(::trend), p.objectOrNull("farthest")?.let(::best),
                p.objectOrNull("longest")?.let(::best), p.objectOrNull("paceBests")?.let { bests ->
                    bests.keys().asSequence().associateWith { key -> best(bests.getJSONObject(key)) }
                }.orEmpty()))
    }

    private fun loggedSession(session: JSONObject) = LoggedSession(session.getString("id"),
        session.getString("title"), session.getLong("startTs"), session.double("durationS"),
        session.getString("source"), session.array("exercises").map { exercise ->
            LoggedExercise(exercise.getString("title"), exercise.array("sets").map { set ->
                LoggedSet(set.getString("type"), set.getBoolean("countsAsWork"), set.double("weightKg"),
                    set.int("reps"), set.double("rpe"), set.double("durationS"), set.double("distanceM"))
            })
        })

    private fun <T> parse(json: String, body: (JSONObject) -> T): T? = runCatching {
        val o = JSONObject(json)
        if (o.has("error")) null else body(o)
    }.getOrNull()
    private fun selection(o: JSONObject) = Selection(o.getInt("days"), o.getInt("weekOffset"),
        o.getInt("minWeekOffset"), o.getString("monday"), o.getString("sunday"), o.getString("readingDay"))
    private fun ratios(o: JSONObject) = o.array("ratios").map {
        Ratio(it.getString("day"), it.double("strength"), it.double("cardio")) }
    private fun range(o: JSONObject) = Range(o.getDouble("lower"), o.getDouble("upper"))
    private fun point(o: JSONObject) = Point(o.getString("day"), o.getLong("startTs"), o.double("value"))
    private fun trend(o: JSONObject) = Trend(o.getDouble("slopePerWeek"), range(o.getJSONObject("spread")),
        o.getInt("pointCount"), o.getInt("spanDays"), o.getDouble("firstValue"), o.getDouble("lastValue"),
        o.getBoolean("directionIsUnclear"))
    private fun record(o: JSONObject) = Record(o.getDouble("value"), o.getString("day"),
        o.getLong("startTs"), o.getString("workoutId"), o.int("reps"))
    private fun best(o: JSONObject) = Best(o.getDouble("value"), o.getString("day"), o.getLong("startTs"),
        o.getString("sport"), o.double("distanceM"), o.double("durationS"))
    private fun JSONObject.objectOrNull(key: String): JSONObject? = if (isNull(key)) null else optJSONObject(key)
    private fun JSONObject.string(key: String): String? = if (isNull(key)) null else optString(key).takeIf { has(key) }
    private fun JSONObject.double(key: String): Double? = if (isNull(key)) null else optDouble(key).takeIf { has(key) }
    private fun JSONObject.int(key: String): Int? = if (isNull(key)) null else optInt(key).takeIf { has(key) }
    private fun JSONObject.array(key: String): List<JSONObject> = optJSONArray(key)?.let { a ->
        (0 until a.length()).map { a.getJSONObject(it) } } ?: emptyList()
    private fun JSONObject.strings(key: String): List<String> = optJSONArray(key)?.let { a ->
        (0 until a.length()).map { a.getString(it) } } ?: emptyList()
    private fun JSONObject.doubles(key: String): List<Double> = optJSONArray(key)?.let { a ->
        (0 until a.length()).map { a.getDouble(it) } } ?: emptyList()
}
