package com.noop.core

import android.content.Context
import com.noop.ui.NoopPrefs
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), activity detection (decision 2026-10-31): the suggestions, the one resolver and the answer table
 * from the shared core (`activity.list`, `activity.answer`, `activity.undo`), so Today, the inbox and the
 * notifications on Android read the same state as on Apple. Blocking; call off the main thread.
 */
object CoreActivity {
    const val KEY_WALKS = "noop.activityDetection.walks"
    const val KEY_LEVEL = "noop.activityDetection.level"
    const val KEY_NOTIFY = "noop.activityDetection.notifications"

    data class Item(
        val id: String, val track: String, val start: Long, val end: Long, val avgBpm: Int?, val load: Double,
        val kinds: List<String>, val state: String, val asks: Boolean,
    ) {
        val minutes: Long get() = (end - start) / 60
        val likelyKind: String get() = kinds.firstOrNull() ?: "other"
    }

    data class Result(val toAsk: List<Item>, val inbox: List<Item>, val labels: Map<String, String>) {
        fun label(key: String) = labels[key].orEmpty()
    }

    fun enabled(context: Context) = NoopPrefs.autoDetectWorkouts(context)

    /** Refreshes the recent days (with `maxHR`) and returns what to ask and the inbox rows. */
    fun list(context: Context, maxHR: Int?, dismissed: List<String>, snoozed: Set<String>): Result? {
        if (!SwiftCore.available || !enabled(context)) return null
        val p = NoopPrefs.of(context)
        val args = JSONObject()
            .put("walks", p.getBoolean(KEY_WALKS, true))
            .put("level", p.getString(KEY_LEVEL, "balanced"))
            .put("dismissed", JSONArray(dismissed))
            .put("snoozed", JSONArray(snoozed.toList()))
            .apply { if (maxHR != null) put("maxHR", maxHR) }
        return SwiftCore.call("activity.list", args.toString())?.let(::parse)
    }

    /** `answer` is everyday or housework, or sport/walk with the session as saved (`sport`, `start`, `end`). */
    fun answer(item: Item, answer: String, origin: String, sport: String? = null, start: Long? = null,
               end: Long? = null, shownAt: Long? = null): Boolean {
        if (!SwiftCore.available) return false
        val args = JSONObject().put("id", item.id).put("answer", answer).put("origin", origin)
            .apply {
                sport?.let { put("sport", it) }
                start?.let { put("start", it) }
                end?.let { put("end", it) }
                shownAt?.let { put("shownAt", it) }
            }
        return SwiftCore.call("activity.answer", args.toString())?.contains("\"ok\":true") == true
    }

    fun undo(item: Item): Boolean = SwiftCore.available && SwiftCore.call(
        "activity.undo",
        JSONObject().put("track", item.track).put("start", item.start).put("end", item.end).toString(),
    )?.contains("\"ok\":true") == true

    /** The stored sport a kind is saved as, the spelling the rest of the app already reads. */
    fun sportToken(kind: String) = when (kind) {
        "walk" -> "Walking"
        "run" -> "Running"
        "cycle" -> "Cycling"
        "strength" -> "Strength Training"
        else -> "Workout"
    }

    internal fun parse(json: String): Result? = runCatching {
        val o = JSONObject(json)
        fun items(key: String): List<Item> {
            val a = o.optJSONArray(key) ?: return emptyList()
            return (0 until a.length()).map { i ->
                val it = a.getJSONObject(i)
                val kinds = it.optJSONArray("kinds")
                Item(
                    id = it.getString("id"), track = it.getString("track"), start = it.getLong("start"),
                    end = it.getLong("end"), avgBpm = if (it.has("avgBpm")) it.getInt("avgBpm") else null,
                    load = it.optDouble("load", 0.0),
                    kinds = kinds?.let { k -> (0 until k.length()).map(k::getString) } ?: emptyList(),
                    state = it.getString("state"), asks = it.optBoolean("asks", false),
                )
            }
        }
        val l = o.optJSONObject("labels")
        val labels = l?.keys()?.asSequence()?.associateWith { l.getString(it) } ?: emptyMap()
        Result(items("toAsk"), items("inbox"), labels)
    }.getOrNull()
}
