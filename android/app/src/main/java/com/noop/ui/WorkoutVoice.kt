package com.noop.ui

import android.content.Context
import android.icu.text.MeasureFormat
import android.icu.util.Measure
import android.icu.util.MeasureUnit
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.speech.tts.TextToSpeech
import com.noop.R
import com.noop.core.SwiftCore
import org.json.JSONObject
import java.util.Locale

/**
 * Fork (DX23876), Android parity 2026-11-12: the live workout's voice, as iOS's `WorkoutVoiceCoach` and
 * `WorkoutFeedbackPreferences`. The shared core decides each second whether to announce or warn
 * (`WorkoutVoiceDecider`, ops `workout.voice.*`); this side reads the wearer's choices under iOS's keys, words the
 * sentence in the app language and speaks it offline. Off by default; headphones only unless the speaker is allowed.
 * Analysis migration required: no.
 */
object WorkoutVoicePrefs {
    const val ENABLED = "workout.voice.enabled"
    const val SPEAKER = "workout.voice.speaker"
    const val DISTANCE_INTERVAL = "workout.voice.distanceInterval"
    const val TIME_INTERVAL = "workout.voice.timeInterval"
    const val MOTION_ALERT = "workout.alert.motion"
    const val HEART_RATE_ALERT = "workout.alert.heartRate"
    /** iOS's `ZoneTrainingPrefs.lastTargetZoneKey`: the target zone the last workout started with. */
    const val TARGET_ZONE = "zoneTraining.lastTargetZone"
    const val FAST_PACE = "workout.alert.fastPace"
    const val SLOW_PACE = "workout.alert.slowPace"
    const val LOW_SPEED = "workout.alert.lowSpeed"
    const val HIGH_SPEED = "workout.alert.highSpeed"

    private fun prefs(c: Context) = NoopPrefs.of(c)
    fun enabled(c: Context) = prefs(c).getBoolean(ENABLED, false)
    fun speaker(c: Context) = prefs(c).getBoolean(SPEAKER, false)
    fun distanceInterval(c: Context) = prefs(c).getFloat(DISTANCE_INTERVAL, 1f).toDouble().takeIf { it in listOf(0.0, 0.5, 1.0, 2.0) } ?: 1.0
    fun timeInterval(c: Context) = prefs(c).getFloat(TIME_INTERVAL, 600f).toDouble().takeIf { it in listOf(300.0, 600.0, 900.0) } ?: 600.0
    fun motionAlert(c: Context) = prefs(c).getBoolean(MOTION_ALERT, false)
    fun heartRateAlert(c: Context) = prefs(c).getBoolean(HEART_RATE_ALERT, false)
    fun targetZone(c: Context): Int? = prefs(c).getInt(TARGET_ZONE, 0).takeIf { it in 1..5 }
    fun setTargetZone(c: Context, zone: Int?) = prefs(c).edit().apply {
        if (zone != null && zone in 1..5) putInt(TARGET_ZONE, zone) else remove(TARGET_ZONE)
    }.apply()
    fun fastPace(c: Context) = prefs(c).getFloat(FAST_PACE, 300f).toDouble()
    fun slowPace(c: Context) = prefs(c).getFloat(SLOW_PACE, 420f).toDouble()
    fun lowSpeed(c: Context) = prefs(c).getFloat(LOW_SPEED, 15f).toDouble()
    fun highSpeed(c: Context) = prefs(c).getFloat(HIGH_SPEED, 30f).toDouble()
    fun setBool(c: Context, key: String, on: Boolean) = prefs(c).edit().putBoolean(key, on).apply()
    fun setNumber(c: Context, key: String, value: Double) = prefs(c).edit().putFloat(key, value.toFloat()).apply()
}

class WorkoutVoice(context: Context) {
    private val app = context.applicationContext
    private var tts: TextToSpeech? = null
    private var ready = false

    /** The running workout at one second, as the core's decider reads it. */
    data class Snapshot(val elapsedSeconds: Int, val distanceMeters: Double?, val distanceFresh: Boolean, val paused: Boolean,
                        val speedMps: Double?, val bpm: Int?, val sport: String, val usesRoute: Boolean,
                        val zone: Int? = null, val targetZone: Int? = null)

    private fun words(): Context = AppLanguagePrefs.wrap(app)
    private fun locale(): Locale = words().resources.configuration.locales[0]

    private fun ensureTts() {
        if (tts != null) return
        tts = TextToSpeech(app) { status -> ready = status == TextToSpeech.SUCCESS; if (ready) tts?.language = locale() }
    }

    private fun args(s: Snapshot): JSONObject {
        val c = app
        val imperial = UnitPrefs.distanceSystem(c) == UnitSystem.IMPERIAL
        return JSONObject().put("voice", WorkoutVoicePrefs.enabled(c)).put("distanceInterval", WorkoutVoicePrefs.distanceInterval(c))
            .put("timeInterval", WorkoutVoicePrefs.timeInterval(c)).put("imperial", imperial).put("usesRoute", s.usesRoute)
            .put("heartRateAlert", WorkoutVoicePrefs.heartRateAlert(c)).put("motionAlert", WorkoutVoicePrefs.motionAlert(c))
            .put("fastPace", WorkoutVoicePrefs.fastPace(c)).put("slowPace", WorkoutVoicePrefs.slowPace(c))
            .put("lowSpeed", WorkoutVoicePrefs.lowSpeed(c)).put("highSpeed", WorkoutVoicePrefs.highSpeed(c))
            .put("now", System.currentTimeMillis() / 1000.0).put("elapsed", s.elapsedSeconds)
            .apply { s.distanceMeters?.let { put("distance", it) }; s.speedMps?.let { put("speed", it) } }
            .put("distanceFresh", s.distanceFresh).put("paused", s.paused).put("sport", s.sport)
            .apply { s.zone?.let { put("zone", it) }; s.targetZone?.let { put("targetZone", it) } }
    }

    /** A workout began (or was restored): no backlog is spoken. */
    fun begin(s: Snapshot) {
        if (!SwiftCore.available) return
        if (WorkoutVoicePrefs.enabled(app)) ensureTts()
        SwiftCore.call("workout.voice.begin", args(s).toString())
    }

    /** One second of the workout; speaks a warning or an announcement when the core decides one is due. */
    fun tick(s: Snapshot) {
        if (!SwiftCore.available) return
        val out = SwiftCore.call("workout.voice.tick", args(s).toString())?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return
        val enabled = WorkoutVoicePrefs.enabled(app)
        if (enabled) ensureTts()
        val usesSpeed = out.optBoolean("usesSpeed")
        val r = words()
        when {
            out.has("warning") -> if (enabled) say(r.getString(when (out.getString("warning")) {
                "zoneAbove" -> R.string.wv_zone_above
                "zoneBelow" -> R.string.wv_zone_below
                "faster" -> R.string.wv_faster
                else -> R.string.wv_slower
            }))
            out.optBoolean("announce") -> say(feedback(
                if (out.has("distance")) out.getDouble("distance") else null, s.elapsedSeconds, s.speedMps, s.bpm, usesSpeed))
        }
    }

    fun paused() { stop(); if (WorkoutVoicePrefs.enabled(app)) say(words().getString(R.string.wv_paused)) }
    fun resumed() { if (WorkoutVoicePrefs.enabled(app)) say(words().getString(R.string.wv_resumed)) }

    /** The recap after a workout ends, as iOS's `WorkoutAnnouncementText.summary`. */
    fun ended(elapsedSeconds: Int, distanceMeters: Double?, sport: String, averageBpm: Int?) {
        if (!WorkoutVoicePrefs.enabled(app)) return
        ensureTts()
        val r = words()
        val imperial = UnitPrefs.distanceSystem(app) == UnitSystem.IMPERIAL
        val usesSpeed = SwiftCore.call("workout.voice.sport", JSONObject().put("sport", sport).toString())
            ?.let { runCatching { JSONObject(it).optBoolean("usesSpeed") }.getOrNull() } ?: false
        val time = duration(elapsedSeconds)
        val parts = mutableListOf(r.getString(R.string.wv_ended))
        val split = if (imperial) 1609.344 else 1000.0
        if (distanceMeters != null && distanceMeters >= 100) {
            parts += r.getString(R.string.wv_dist_in, distance(distanceMeters, imperial), time)
            if (usesSpeed && elapsedSeconds > 0) parts += r.getString(R.string.wv_avg_speed, speed(distanceMeters / elapsedSeconds, imperial))
            else {
                val perSplit = Math.round(elapsedSeconds / (distanceMeters / split)).toInt()
                parts += r.getString(if (imperial) R.string.wv_avg_pace_mi else R.string.wv_avg_pace_km, duration(perSplit))
            }
        } else parts += r.getString(R.string.wv_time, time)
        averageBpm?.let { parts += r.getString(R.string.wv_avg_hr, it) }
        say(parts.joinToString(" "))
    }

    fun stop() { tts?.stop() }

    fun shutdown() { tts?.shutdown(); tts = null; ready = false }

    /** Distance, time, current pace or speed, and heart rate only when measured, as iOS's `feedback`. */
    private fun feedback(distanceM: Double?, elapsed: Int, speedMps: Double?, bpm: Int?, usesSpeed: Boolean): String {
        val r = words()
        val imperial = UnitPrefs.distanceSystem(app) == UnitSystem.IMPERIAL
        val parts = mutableListOf<String>()
        distanceM?.let { parts += distance(it, imperial) + "." }
        parts += r.getString(R.string.wv_time, duration(elapsed))
        if (speedMps != null && speedMps.isFinite() && speedMps > 0) {
            if (usesSpeed) parts += r.getString(R.string.wv_speed, speed(speedMps, imperial))
            else {
                val perUnit = Math.round((if (imperial) 1609.344 else 1000.0) / speedMps).toInt()
                parts += r.getString(if (imperial) R.string.wv_pace_mi else R.string.wv_pace_km, duration(perUnit))
            }
        }
        bpm?.let { parts += r.getString(R.string.wv_hr, it) }
        return parts.joinToString(" ")
    }

    /** "5 minutes, 42 seconds", spelled for speech in the app language. */
    private fun duration(seconds: Int): String {
        val s = seconds.coerceAtLeast(0)
        val f = MeasureFormat.getInstance(locale(), MeasureFormat.FormatWidth.WIDE)
        val measures = if (s >= 3600) listOf(Measure(s / 3600, MeasureUnit.HOUR), Measure((s % 3600) / 60, MeasureUnit.MINUTE))
                       else listOf(Measure(s / 60, MeasureUnit.MINUTE), Measure(s % 60, MeasureUnit.SECOND))
        val kept = measures.filter { it.number.toInt() != 0 }.ifEmpty { listOf(measures.last()) }
        return f.formatMeasures(*kept.toTypedArray())
    }

    private fun number() = android.icu.text.NumberFormat.getNumberInstance(locale()).apply { maximumFractionDigits = 1; minimumFractionDigits = 0 }

    private fun distance(meters: Double, imperial: Boolean): String {
        val value = if (imperial) meters / 1609.344 else meters / 1000
        val f = MeasureFormat.getInstance(locale(), MeasureFormat.FormatWidth.WIDE, number())
        return f.format(Measure(value, if (imperial) MeasureUnit.MILE else MeasureUnit.KILOMETER))
    }

    private fun speed(mps: Double, imperial: Boolean): String {
        val f = MeasureFormat.getInstance(locale(), MeasureFormat.FormatWidth.WIDE, number())
        return if (imperial) f.format(Measure(mps * 2.2369362921, MeasureUnit.MILE_PER_HOUR))
               else f.format(Measure(mps * 3.6, MeasureUnit.KILOMETER_PER_HOUR))
    }

    /** Speaks into headphones only, unless the wearer allowed the speaker (iOS's default). */
    private fun say(text: String) {
        if (text.isBlank()) return
        if (!WorkoutVoicePrefs.speaker(app) && !headphones()) return
        ensureTts()
        if (!ready) return
        tts?.language = locale()
        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "noop-workout")
    }

    private fun headphones(): Boolean {
        val am = app.getSystemService(AudioManager::class.java) ?: return false
        return am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
            it.type in setOf(AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                             AudioDeviceInfo.TYPE_USB_HEADSET) ||
                (android.os.Build.VERSION.SDK_INT >= 31 && it.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
        }
    }
}
