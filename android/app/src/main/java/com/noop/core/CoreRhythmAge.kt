package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 2.3: the daily-rhythm readout from the shared core (`CoreRhythmAge`), its
 * comparisons, busiest window and sentences resolved in the wearer's language. Blocking; call off the main thread.
 */
object CoreRhythmAge {
    data class Output(
        val state: String, val collectedHours: Double?, val advance: Double?, val hourly: List<Double?>,
        val typical: List<Double>, val movementLevel: Int?, val contrastLevel: Int?, val busiestStart: Int?,
        val daySentence: String?, val lever: String?, val history: List<Pair<String, Double>>,
    )

    fun snapshot(): Output? {
        if (!SwiftCore.available) return null
        return parse(SwiftCore.call("rhythm.snapshot", "{}") ?: return null)
    }

    internal fun parse(json: String): Output? {
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return null
        if (o.has("error")) return null
        fun JSONObject.dbl(k: String): Double? = if (has(k) && !isNull(k)) getDouble(k) else null
        fun JSONObject.int(k: String): Int? = if (has(k) && !isNull(k)) getInt(k) else null
        fun JSONObject.str(k: String): String? = if (has(k) && !isNull(k)) getString(k) else null
        fun JSONArray?.doubles(): List<Double?> = if (this == null) emptyList() else (0 until length()).map { if (isNull(it)) null else getDouble(it) }
        val history = o.optJSONArray("history")
        return Output(
            state = o.optString("state", "empty"), collectedHours = o.dbl("collectedHours"), advance = o.dbl("advance"),
            hourly = o.optJSONArray("hourly").doubles(), typical = o.optJSONArray("typical").doubles().map { it ?: 0.0 },
            movementLevel = o.int("movementLevel"), contrastLevel = o.int("contrastLevel"), busiestStart = o.int("busiestStart"),
            daySentence = o.str("daySentence"), lever = o.str("lever"),
            history = if (history == null) emptyList() else (0 until history.length()).map {
                history.getJSONObject(it).let { p -> p.getString("day") to p.getDouble("advance") }
            },
        )
    }
}
