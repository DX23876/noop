package com.noop.core

import android.content.Context
import com.noop.ui.NoopPrefs
import org.json.JSONArray
import org.json.JSONObject

/** The host carries the choice and platform scheduling; eligibility and timing come from Swift. */
object CoreTrainingReminders {
    const val PREFERENCE = "training.sessionRatingPrompt"
    data class Candidate(val id: String, val sessionId: String, val sport: String,
                         val startTs: Long, val endTs: Long, val fireTs: Long)

    fun prompt(context: Context): String = NoopPrefs.of(context).getString(PREFERENCE, "whenUseful") ?: "whenUseful"

    fun read(context: Context, maxHR: Double, dismissed: List<String>, forDelivery: Boolean = false): List<Candidate>? = runCatching {
        CoreRead.open(context)
        val args = JSONObject().put("prompt", prompt(context)).put("maxHR", maxHR)
            .put("dismissedWorkouts", JSONArray(dismissed)).put("forDelivery", forDelivery)
        parse(SwiftCore.call("training.sessionReminders", args.toString()) ?: error("coreUnavailable"))
    }.getOrNull()

    internal fun parse(json: String): List<Candidate> {
        val rows = JSONArray(json)
        return (0 until rows.length()).map { index ->
            val row = rows.getJSONObject(index)
            Candidate(row.getString("id"), row.getString("sessionId"), row.getString("sport"),
                row.getLong("startTs"), row.getLong("endTs"), row.getLong("fireTs"))
        }
    }
}
