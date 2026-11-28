package com.noop.core

import org.json.JSONObject
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * A sport in the wearer's language (`workout.sportName`), from the iPhone's catalogue keys through the shared core,
 * so "Strength Training" reads "Krafttraining" here as it does there. Display only: filters, groupings and stored
 * names keep the English [com.noop.ui.WorkoutEditing.displaySport]. Remembered per language and sport, since a list
 * asks for the same few sports on every row.
 */
object CoreSportName {
    private val cache = ConcurrentHashMap<String, String>()

    fun name(sport: String): String {
        val key = Locale.getDefault().toLanguageTag() + "|" + sport
        cache[key]?.let { return it }
        val fallback = com.noop.ui.WorkoutEditing.displaySport(sport)
        if (!SwiftCore.available) return fallback
        val json = SwiftCore.call("workout.sportName", JSONObject().put("sport", sport).toString()) ?: return fallback
        val name = runCatching { JSONObject(json).getString("name") }.getOrNull()?.takeIf { it.isNotEmpty() } ?: return fallback
        cache[key] = name
        return name
    }
}
