package com.noop.core

import com.noop.ui.ProfileStore
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android Settings parity: the Profile page's facts from the shared core (`CoreProfile`): the maximum
 * heart rate with where it came from, the hint under an entered VO₂max, and the heart-rate zone editor's drafts.
 * The rules are the Apple Profile page's (`MaxHeartRate`, `PeakMETResolver`, `HRZones`). Blocking; call off the main
 * thread, since the core answers on the main queue.
 */
object CoreProfile {
    /** The maximum heart rate in force and its source (`override`, `measured`, `gellish` or `default`). */
    data class MaxHeartRate(val bpm: Int, val source: String, val confirmedOn: String?)

    /** One band of the editor's preview: the first and last whole bpm, and the edges as percent text ("65", "62.5"). */
    data class ZoneBand(val number: Int, val lowerBpm: Int, val upperBpm: Int, val lowerPercentText: String,
                        val upperPercentText: String)

    /**
     * One draft of the zone editor: the bounds in each unit, whether the draft is a legal set, the bands to show, and
     * the row summary (whether the zones are the wearer's own and the five bounds as text, "110/125/140/155/170 bpm").
     */
    data class ZoneDraft(val mode: String, val percents: List<Double>, val bpms: List<Double>, val legal: Boolean,
                         val bands: List<ZoneBand>, val custom: Boolean, val bounds: String)

    fun maxHeartRate(age: Int, override: Int): MaxHeartRate? {
        if (!SwiftCore.available) return null
        val o = call("profile.maxHeartRate", JSONObject().put("age", age).put("override", override)) ?: return null
        val source = o.optString("source")
        if (source.isEmpty()) return null
        return MaxHeartRate(o.optInt("bpm"), source, o.optString("confirmedOn").takeIf { it.isNotEmpty() })
    }

    /** Asks the core for the automatic maximum at the profile's age and keeps the answer where [ProfileStore.hrMaxAuto] reads it. */
    fun refreshMaxHeartRate(profile: ProfileStore): Boolean {
        val age = profile.age
        val auto = maxHeartRate(age, 0) ?: return false
        profile.cacheCoreMaxHeartRate(age, auto.bpm, auto.source, auto.confirmedOn)
        return true
    }

    /** Whether the ceiling in use is the formula's for a body beyond what it was fitted on, so a measurement is advised. */
    fun vo2FormulaAdvised(weightKg: Double, heightCm: Double): Boolean {
        if (!SwiftCore.available) return false
        return call("profile.vo2Hint", JSONObject().put("weightKg", weightKg).put("heightCm", heightCm))
            ?.optBoolean("advised") == true
    }

    /**
     * Resolves, steps and validates one draft of the zone editor. [step] is the bound to move one notch (index, up);
     * a bound never stored is seeded from the zones in force, so the mode not in use still has numbers to show.
     */
    fun zones(mode: String, percents: List<Double>, bpms: List<Double>, maxHr: Int, autoSource: String,
              step: Pair<Int, Boolean>? = null): ZoneDraft? {
        if (!SwiftCore.available) return null
        val args = JSONObject().put("mode", mode).put("percents", JSONArray(percents)).put("bpms", JSONArray(bpms))
            .put("maxHR", maxHr).put("autoSource", autoSource)
        if (step != null) args.put("step", JSONObject().put("index", step.first).put("up", step.second))
        return parseZones(call("profile.zones", args) ?: return null)
    }

    internal fun parseZones(o: JSONObject): ZoneDraft? {
        val rows = o.optJSONArray("zones") ?: return null
        fun numbers(key: String): List<Double> = o.optJSONArray(key)?.let { a -> (0 until a.length()).map(a::getDouble) }.orEmpty()
        return ZoneDraft(
            o.optString("mode", "auto"), numbers("percents"), numbers("bpms"), o.optBoolean("legal"),
            (0 until rows.length()).map {
                val z = rows.getJSONObject(it)
                ZoneBand(z.getInt("number"), z.getInt("lowerBpm"), z.getInt("upperBpm"),
                         z.optString("lowerPercentText"), z.optString("upperPercentText"))
            },
            o.optBoolean("custom"), o.optString("bounds"),
        )
    }

    /** The equipment a wearer can pick from, as Settings › Training offers it on Apple (`TrainingPreferences.knownEquipment`). */
    fun equipmentChoices(): List<String>? {
        if (!SwiftCore.available) return null
        val ids = call("profile.equipmentChoices", JSONObject())?.optJSONArray("ids") ?: return null
        return (0 until ids.length()).map(ids::getString)
    }

    private fun call(op: String, args: JSONObject): JSONObject? = runCatching {
        JSONObject(SwiftCore.call(op, args.toString()) ?: return null).takeUnless { it.has("error") }
    }.getOrNull()
}
