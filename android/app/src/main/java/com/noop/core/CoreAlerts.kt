package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android Settings parity: the decisions behind the alert settings, from the shared core
 * (`CoreAlerts` in NoopCore). The Training Load alert's once-per-high-phase rule (`TrainingLoadAlert`) and the
 * heart-rate ceiling's buzz rule (`HRCeilingAlertEngine`) are the ones the Apple Notifications and Strap Actions pages
 * run. Blocking; call off the main thread.
 */
object CoreAlerts {
    /** One lane's answer: whether to post now and the episode state to keep for the next read. */
    data class LaneDecision(val kind: String, val notify: Boolean, val episodeOpen: Boolean)

    /** A lane as the Training Load read states it: its kind ("strength", "cardio"), its band and the stored episode. */
    data class LaneInput(val kind: String, val band: String?, val episodeOpen: Boolean)

    fun trainingLoad(enabled: Boolean, lanes: List<LaneInput>): List<LaneDecision>? {
        if (!SwiftCore.available) return null
        val args = JSONObject().put("enabled", enabled).put("lanes", JSONArray(lanes.map {
            JSONObject().put("kind", it.kind).put("episodeOpen", it.episodeOpen).apply { if (it.band != null) put("band", it.band) }
        }))
        val answer = runCatching { JSONObject(SwiftCore.call("alerts.trainingLoad", args.toString()) ?: return null) }.getOrNull() ?: return null
        val rows = answer.optJSONArray("lanes") ?: return null
        return (0 until rows.length()).map {
            val r = rows.getJSONObject(it)
            LaneDecision(r.optString("kind"), r.optBoolean("notify"), r.optBoolean("episodeOpen"))
        }
    }

    /** The ceiling engine's memory between two samples, kept by the caller as the core hands it back. */
    class CeilingState internal constructor(internal val json: JSONObject?)

    /** What the engine asks of the strap for one sample, and what the screen reads from the ceiling. */
    data class CeilingAnswer(
        /** The ceiling in force (bpm), null when it cannot be resolved. */
        val ceiling: Double?,
        /** The whole-bpm value the wearer crosses, for "Buzz at N BPM". */
        val displayBpm: Int?,
        /** "warning", "recovered" or null. */
        val cue: String?,
        /** How many loops the strap buzzes for the cue. */
        val loops: Int,
        val episodeActive: Boolean,
        val state: CeilingState,
    )

    /**
     * The ceiling of the wearer's setting ([mode] "zone" with [allowedZone] and the five band starts, or "bpm" with
     * [fixedBpm]). With [now] it advances the engine one sample ([bpm] null for no reading) from [state]; without it
     * it only resolves the ceiling.
     */
    fun hrCeiling(
        mode: String, allowedZone: Int, fixedBpm: Int, zoneLowerBpm: List<Double>, maxHr: Int,
        now: Long? = null, bpm: Int? = null, gate: Boolean = false, reminderMode: String = "standard",
        state: CeilingState? = null,
    ): CeilingAnswer? {
        if (!SwiftCore.available) return null
        val args = JSONObject().put("mode", mode).put("allowedZone", allowedZone).put("fixedBpm", fixedBpm)
            .put("zoneLowerBpm", JSONArray(zoneLowerBpm)).put("maxHR", maxHr).put("gate", gate)
            .put("reminderMode", reminderMode)
        if (now != null) args.put("now", now)
        if (bpm != null) args.put("bpm", bpm)
        state?.json?.let { args.put("state", it) }
        val o = runCatching { JSONObject(SwiftCore.call("alerts.hrCeiling", args.toString()) ?: return null) }.getOrNull() ?: return null
        if (o.has("error")) return null
        return CeilingAnswer(
            ceiling = if (o.has("ceiling")) o.getDouble("ceiling") else null,
            displayBpm = if (o.has("displayBpm")) o.getInt("displayBpm") else null,
            cue = if (o.has("cue")) o.getString("cue") else null,
            loops = o.optInt("loops"), episodeActive = o.optBoolean("episodeActive"),
            state = CeilingState(o.optJSONObject("state")),
        )
    }
}
