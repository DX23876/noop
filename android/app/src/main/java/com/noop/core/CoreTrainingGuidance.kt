package com.noop.core

import android.content.Context
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import org.json.JSONArray
import org.json.JSONObject

/** The Training Load settings of phase 2 (docs/fork/TRAINING_LOAD_PLAN.md §8), the same keys as on Apple. */
object TrainingGuidancePrefs {
    const val FOCUS = "trainingLoad.focus"
    const val PULSE_UNRELIABLE = "trainingLoad.pulseUnreliable"
    const val MORNING_ADVICE = "trainingLoad.morningAdvice"
    const val MORNING_ADVICE_DAY = "trainingLoad.morningAdviceDay"
    const val LAB_INSTRUMENTS = "trainingLoad.labInstruments"

    /** The illness signal is raised, as the app last evaluated it (`AppViewModel`). In memory only. */
    @Volatile var illnessRaised: Boolean = false
}

/**
 * The morning advice, "enough?", the offers and the rating to ask for, read from the shared core
 * (`training.guidance`, `TrainingGuidanceReader`), the same snapshot the iPhone's Today, Training tab and coach show.
 * Every figure and every decision comes from the core; Kotlin only passes the wearer's settings. Blocking; call off
 * the main thread.
 */
object CoreTrainingGuidance {
    data class Advice(val stance: String, val reason: String, val state: String, val limitedLane: String?,
                      val effortLow: Double?, val effortHigh: Double?, val ateTooLittle: Boolean,
                      val band21Low: Int? = null, val band21High: Int? = null)
    data class Offer(val kind: String, val title: String?, val sport: String?, val minutes: Int?, val group: String?,
                     val sets: Int?)
    data class Week(val start: String, val minutes: Int, val everydayMinutes: Int, val ratedMinutes: Int,
                    val strengthDays: Int, val targetLow: Int, val targetHigh: Int, val strengthDaysLow: Int,
                    val balanceHint: Boolean, val complete: Boolean)
    data class Food(val ateTooLittle: Boolean, val ateOverPlan: Boolean, val proteinLow: Boolean)
    data class Rating(val sessionId: String, val sport: String, val startTs: Long, val endTs: Long)
    data class Movable(val id: String, val title: String, val tomorrow: String)
    data class Snapshot(val today: String, val advice: Advice, val offers: List<Offer>, val cardioFocus: String,
                        val strengthFocus: String, val weeks: List<Week>, val carried: Boolean, val askRating: Rating?,
                        val food: Food, val movablePlan: Movable? = null) {
        val thisWeek: Week? get() = weeks.lastOrNull()
    }
    data class GoalReading(val note: String?, val noteIsHeadline: Boolean)
    data class GoalReadings(val cardio: GoalReading, val strength: GoalReading, val food: Food,
                            val proteinHint: Boolean = false)
    data class Instrument(val direction: String, val sessions: Int, val pairs: Int?, val passes: Boolean)
    data class Instruments(val cadence: Instrument, val recovery: Instrument, val pace: Instrument)

    /** The settings every guidance read takes, without the heart-rate maximum and sex the caller adds. */
    fun hostArgs(context: Context): JSONObject {
        val prefs = NoopPrefs.of(context)
        val profile = ProfileStore(prefs)
        return JSONObject()
            .put("age", profile.age)
            .put("pulseUnreliable", prefs.getBoolean(TrainingGuidancePrefs.PULSE_UNRELIABLE, false))
            .put("unwell", TrainingGuidancePrefs.illnessRaised)
            .put("firstWeekday", if (prefs.getString("training.weekStartsOn", null) == "sunday") 1 else 2)
            .apply {
                prefs.getString(TrainingGuidancePrefs.FOCUS, null)?.takeIf { it.isNotEmpty() }?.let { put("focus", it) }
                prefs.getString(CoreDietPlan.KEY, null)?.let { put("plan", it) }
            }
    }

    private fun args(context: Context, maxHR: Double?, sex: String, dismissed: List<String>): String =
        hostArgs(context).put("sex", sex).put("dismissedWorkouts", JSONArray(dismissed))
            .apply { if (maxHR != null) put("maxHR", maxHR) }.toString()

    fun read(context: Context, maxHR: Double?, sex: String, dismissed: List<String> = emptyList()): Snapshot? {
        if (!SwiftCore.available) return null
        return SwiftCore.call("training.guidance", args(context, maxHR, sex, dismissed))?.let { parse(it) }
    }

    fun goalReadings(context: Context, maxHR: Double?, sex: String, dismissed: List<String> = emptyList()): GoalReadings? {
        if (!SwiftCore.available) return null
        val text = SwiftCore.call("training.goalReadings", args(context, maxHR, sex, dismissed)) ?: return null
        return runCatching {
            val o = JSONObject(text)
            fun reading(r: JSONObject) = GoalReading(r.optString("note").takeIf { r.has("note") && !r.isNull("note") },
                                                     r.optBoolean("noteIsHeadline"))
            GoalReadings(reading(o.getJSONObject("cardio")), reading(o.getJSONObject("strength")), food(o.getJSONObject("food")),
                         o.optBoolean("proteinHint"))
        }.getOrNull()
    }

    fun instruments(context: Context, maxHR: Double?, sex: String, dismissed: List<String> = emptyList()): Instruments? {
        if (!SwiftCore.available) return null
        val text = SwiftCore.call("training.instruments", args(context, maxHR, sex, dismissed)) ?: return null
        return runCatching {
            val o = JSONObject(text)
            fun one(i: JSONObject) = Instrument(i.optString("direction"), i.optInt("sessions"),
                                                if (i.has("pairs") && !i.isNull("pairs")) i.optInt("pairs") else null,
                                                i.optBoolean("passes"))
            Instruments(one(o.getJSONObject("cadence")), one(o.getJSONObject("recovery")), one(o.getJSONObject("pace")))
        }.getOrNull()
    }

    /** Moves today's planned session to tomorrow (`coach.plan.reschedule`), only on the wearer's tap (Q17). */
    fun moveToTomorrow(m: Movable): Boolean {
        if (!SwiftCore.available) return false
        return SwiftCore.call("coach.plan.reschedule", JSONObject().put("id", m.id).put("day", m.tomorrow).toString()) != null
    }

    private fun food(o: JSONObject) = Food(o.optBoolean("ateTooLittle"), o.optBoolean("ateOverPlan"), o.optBoolean("proteinLow"))

    /** Today's advice as first given (`training.adviceOfDay`), read cheaply without the full guidance. */
    fun adviceOfDay(): Advice? {
        if (!SwiftCore.available) return null
        val text = SwiftCore.call("training.adviceOfDay", "{}") ?: return null
        if (text == "null") return null
        return runCatching { advice(JSONObject(text)) }.getOrNull()
    }

    private fun advice(a: JSONObject) = Advice(a.optString("stance"), a.optString("reason"), a.optString("state"),
        optString(a, "limitedLane"), optDouble(a, "effortLow"), optDouble(a, "effortHigh"), a.optBoolean("ateTooLittle"),
        if (a.has("band21Low") && !a.isNull("band21Low")) a.optInt("band21Low") else null,
        if (a.has("band21High") && !a.isNull("band21High")) a.optInt("band21High") else null)

    private fun optDouble(o: JSONObject, key: String): Double? = if (o.has(key) && !o.isNull(key)) o.optDouble(key) else null
    private fun optString(o: JSONObject, key: String): String? = if (o.has(key) && !o.isNull(key)) o.optString(key) else null

    internal fun parse(text: String): Snapshot? = runCatching {
        val o = JSONObject(text)
        val advice = advice(o.getJSONObject("advice"))
        val offers = o.optJSONArray("offers")?.let { arr ->
            (0 until arr.length()).map { i ->
                val x = arr.getJSONObject(i)
                Offer(x.optString("kind"), optString(x, "title"), optString(x, "sport"),
                      if (x.has("minutes")) x.optInt("minutes") else null, optString(x, "group"),
                      if (x.has("sets")) x.optInt("sets") else null)
            }
        } ?: emptyList()
        val weeks = o.optJSONArray("weeks")?.let { arr ->
            (0 until arr.length()).map { i ->
                val w = arr.getJSONObject(i)
                Week(w.optString("start"), w.optInt("minutes"), w.optInt("everydayMinutes"), w.optInt("ratedMinutes"),
                     w.optInt("strengthDays"), w.optInt("targetLow"), w.optInt("targetHigh"), w.optInt("strengthDaysLow"),
                     w.optBoolean("balanceHint"), w.optBoolean("complete"))
            }
        } ?: emptyList()
        val rating = o.optJSONObject("askRating")?.let {
            Rating(it.optString("sessionId"), it.optString("sport"), it.optLong("startTs"), it.optLong("endTs"))
        }
        val movable = o.optJSONObject("movablePlan")?.let {
            Movable(it.optString("id"), it.optString("title"), it.optString("tomorrow"))
        }
        Snapshot(o.optString("today"), advice, offers, o.getJSONObject("cardioFocus").optString("focus"),
                 o.getJSONObject("strengthFocus").optString("focus"), weeks, o.optBoolean("carried"), rating,
                 food(o.getJSONObject("food")), movable)
    }.getOrNull()
}

/**
 * One guidance snapshot for the whole app, read once per change of the core's data (`CoreShadow.dataRevision`)
 * rather than once per card: Today, the Training tab, Training Load and the Effort target all collect this.
 */
object TrainingGuidanceHolder {
    private val state = kotlinx.coroutines.flow.MutableStateFlow<CoreTrainingGuidance.Snapshot?>(null)
    val snapshot: kotlinx.coroutines.flow.StateFlow<CoreTrainingGuidance.Snapshot?> = state
    private val lock = kotlinx.coroutines.sync.Mutex()
    @Volatile private var loadedKey: String? = null

    /** Reads the snapshot unless one for `revision` and `generation` is already loaded. Call off the main thread. */
    suspend fun ensure(context: Context, revision: Long, generation: Int, maxHR: Double?, sex: String,
                       dismissed: List<String>) {
        val key = "$revision|$generation"
        if (loadedKey == key) return
        lock.lock()
        try {
            if (loadedKey == key) return
            val fresh = CoreTrainingGuidance.read(context, maxHR, sex, dismissed)
            state.value = fresh
            loadedKey = key
            // The coupled band helpers read today's capped band from here (Training Load plan, Q14).
            com.noop.ui.todayBandOverride = fresh?.advice?.let { a ->
                val low = a.band21Low; val high = a.band21High
                if (low != null && high != null) com.noop.ui.OptimalStrainRange(low, high) else null
            }
        } finally { lock.unlock() }
    }
}
