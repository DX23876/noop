package com.noop.core

import android.content.Context
import android.util.Log
import com.noop.BuildConfig
import com.noop.NoopApplication
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android plan E-2: what the screens read from the shared core's store. The core resolves each
 * value as the Apple screens do (imported values first, the core's own scores filling the gaps) and answers with a
 * small JSON document; this parses it. Every read blocks until the store answers, so call it off the main thread.
 * A read returns null or an empty list when the core is not in this build, no session runs, or nothing is stored.
 */
object CoreRead {
    @Volatile private var opened = false

    /** Whether a screen has opened the core's store in this process, so a background reader may use it. */
    val isOpen: Boolean get() = opened

    /** One day as the Today screen shows it. */
    data class Day(
        val day: String,
        val charge: Double?, val effort: Double?, val rest: Double?,
        val sleepMinutes: Double?, val deepMinutes: Double?, val remMinutes: Double?, val lightMinutes: Double?,
        val efficiency: Double?, val restingHr: Int?, val hrv: Double?, val respRate: Double?, val spo2: Double?,
        val skinTempDev: Double?, val steps: Int?,
        /** Who supplied the scores' inputs, as the hero names them: names, or "#workoutFiles", "#nutrition", "#cached". */
        val heroSource: List<String> = emptyList(),
    )

    /**
     * One night with its stages; times are epoch seconds. [stages] is the timeline (empty for an imported night
     * that stores totals only), [minutes] the stage totals by core name ("wake", "light", "deep", "rem"), summed
     * over the night's blocks as on iOS; null from a core that predates them.
     */
    data class Night(
        val startTs: Long, val endTs: Long, val efficiency: Double?, val restingHr: Int?, val hrv: Double?,
        val edited: Boolean, val stages: List<Stage>, val minutes: Map<String, Double>? = null,
    ) {
        data class Stage(val stage: String, val start: Long, val end: Long)
    }

    /** The mean heart rate of one five-minute stretch starting at [ts] (unix seconds). */
    data class HeartPoint(val ts: Long, val bpm: Double)

    /** One value of a metric on one day. */
    data class Point(val day: String, val value: Double)

    /** The metrics a trend screen can chart; the name is the core's. */
    enum class Metric(val key: String) {
        Charge("charge"), Effort("effort"), Rest("rest"), Hrv("hrv"), RestingHr("restingHr"),
        SleepMinutes("sleepMinutes"), RespRate("respRate"), Spo2("spo2"), Steps("steps"), SkinTemp("skinTemp"),
    }

    /**
     * Opens the core's store for the screens: the same session the Bluetooth client feeds, started here under the
     * active strap's id when no strap has connected yet in this process. A demo build then fills an empty store
     * with the demo history. Blocks; call off the main thread before the first read.
     */
    @Synchronized
    fun open(context: Context) {
        // Synchronized, so a screen that reads while another is still opening waits for the session instead of
        // reading before it exists and getting nothing.
        if (opened || !SwiftCore.available) return
        val app = context.applicationContext as NoopApplication
        // The session's strap is the Bluetooth client's to move (it follows a switch); this only starts it.
        CoreShadow.ensureStarted(app, app.activeDeviceId, followActive = false)
        if (BuildConfig.ENABLE_DEMO) Log.i("CoreRead", "demo days written=${SwiftCore.seedDemo()}")
        opened = true
    }

    fun day(day: String): Day? = read { SwiftCore.readDay(day) }?.let(::parseDay)

    fun nights(from: Long, to: Long): List<Night> = read { SwiftCore.readNights(from, to) }?.let(::parseNights).orEmpty()

    fun series(metric: Metric, from: String, to: String): List<Point> =
        read { SwiftCore.readSeries(metric.key, from, to) }?.let(::parseSeries).orEmpty()

    fun heartRate(from: Long, to: Long): List<HeartPoint> =
        read { SwiftCore.readHeartRate(from, to) }?.let(::parseHeartRate).orEmpty()

    private inline fun read(call: () -> String?): String? = if (SwiftCore.available) call() else null

    // The core leaves a missing value out of the document rather than writing null; both read as null here.
    private fun JSONObject.double(key: String): Double? = if (has(key) && !isNull(key)) getDouble(key) else null
    private fun JSONObject.int(key: String): Int? = if (has(key) && !isNull(key)) getInt(key) else null

    internal fun parseDay(json: String): Day? {
        if (json == "null") return null
        val o = JSONObject(json)
        return Day(
            day = o.getString("day"),
            charge = o.double("charge"), effort = o.double("effort"), rest = o.double("rest"),
            sleepMinutes = o.double("sleepMinutes"), deepMinutes = o.double("deepMinutes"),
            remMinutes = o.double("remMinutes"), lightMinutes = o.double("lightMinutes"),
            efficiency = o.double("efficiency"), restingHr = o.int("restingHr"), hrv = o.double("hrv"),
            respRate = o.double("respRate"), spo2 = o.double("spo2"), skinTempDev = o.double("skinTempDev"),
            steps = o.int("steps"),
            heroSource = o.optJSONArray("heroSource")?.let { a -> (0 until a.length()).map(a::getString) }.orEmpty(),
        )
    }

    internal fun parseNights(json: String): List<Night> {
        val a = JSONArray(json)
        return (0 until a.length()).map { i ->
            val o = a.getJSONObject(i)
            val stages = o.getJSONArray("stages").let { s ->
                (0 until s.length()).map { j ->
                    val st = s.getJSONObject(j)
                    Night.Stage(st.getString("stage"), st.getLong("start"), st.getLong("end"))
                }
            }
            val minutes = o.optJSONObject("minutes")?.let { m ->
                listOf("wake", "light", "deep", "rem").associateWith { m.optDouble(it, 0.0) }
            }
            Night(o.getLong("startTs"), o.getLong("endTs"), o.double("efficiency"), o.int("restingHr"),
                  o.double("hrv"), o.getBoolean("edited"), stages, minutes)
        }
    }

    internal fun parseSeries(json: String): List<Point> {
        val a = JSONArray(json)
        return (0 until a.length()).map { i -> a.getJSONObject(i).let { Point(it.getString("day"), it.getDouble("value")) } }
    }

    internal fun parseHeartRate(json: String): List<HeartPoint> {
        val a = JSONArray(json)
        return (0 until a.length()).map { i -> a.getJSONObject(i).let { HeartPoint(it.getLong("ts"), it.getDouble("bpm")) } }
    }
}
