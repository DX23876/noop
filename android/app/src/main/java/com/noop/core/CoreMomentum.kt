package com.noop.core

import android.content.Context
import com.noop.analytics.Baselines
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 1.2: Momentum from the shared core (`CoreMomentum` in NoopCore): the feed the
 * iOS Today card shows, built, ranked and worded by the shared `MomentumBuilder` and `MomentumResolver`, in the
 * wearer's language. The dwell bookkeeping lives under the Apple keys (`DashboardMomentum.Keys`). Blocking; call off
 * the main thread.
 */
object CoreMomentum {
    data class Message(
        val kind: String, val tone: String, val headline: String, val detail: String, val actionLine: String?,
        val progress: Double?, val progressLabel: String?, val progressChip: String?, val deltaText: String?,
        val actionTitle: String?, val destination: String?,
    )

    private const val SNOOZED = "momentum.snoozed"
    private const val LAST_KIND = "momentum.lastKind"
    private const val LAST_AT = "momentum.lastAt"
    private const val LAST_AT_MILLIS = "momentum.lastAtMillis"

    /** Cheap clock read: the core owns the logical-day rollover, including its pre-dawn boundary. */
    fun logicalDay(): String? {
        if (!SwiftCore.available) return null
        val json = SwiftCore.call("momentum.day", "{}") ?: return null
        return runCatching { JSONObject(json).getString("day") }.getOrNull()
    }

    /**
     * What only the app holds (`DashboardMomentum.LiveInput`): the health alert in the banner's own words, the strap's
     * remaining runtime and the cycle phase with its day range, the phase only while cycle tracking is on.
     */
    data class Live(val healthAlert: String? = null, val strapHoursRemaining: Double? = null,
                    val cyclePhase: String? = null, val cycleDayLow: Int? = null, val cycleDayHigh: Int? = null)

    fun feed(context: Context, dismissedWorkouts: List<String>, live: Live = Live()): List<Message>? {
        if (!SwiftCore.available) return null
        if (!CoreUserInputs.ensure(context)) return null
        val prefs = NoopPrefs.of(context)
        val profile = ProfileStore.from(context)
        val args = JSONObject().withGoalProfile(profile).withGoalHostSettings(context).put("sex", profile.sex)
            .put("lastSync", goalLastSync(context)).put("ageless", CoreFeatures.healthspan(context))
            .put("dismissedWorkouts", JSONArray(dismissedWorkouts))
            .put("hrvEpoch", prefs.getLong(Baselines.hrvBaselineEpochKey, 0L).toDouble())
            .put("recoveryEpoch", prefs.getLong(Baselines.recoveryBaselineEpochKey, 0L).toDouble())
            .put("snoozed", prefs.getString(SNOOZED, "") ?: "")
            .put("lastKind", prefs.getString(LAST_KIND, "") ?: "")
            .put("lastAt", if (prefs.contains(LAST_AT_MILLIS)) prefs.getLong(LAST_AT_MILLIS, 0L) / 1000.0
                 else (prefs.all[LAST_AT] as? Number)?.toDouble() ?: 0.0)
        live.healthAlert?.let { args.put("healthAlert", it) }
        live.strapHoursRemaining?.let { args.put("strapHoursRemaining", it) }
        live.cyclePhase?.let { args.put("cyclePhase", it) }
        live.cycleDayLow?.let { args.put("cycleDayLow", it) }
        live.cycleDayHigh?.let { args.put("cycleDayHigh", it) }
        return SwiftCore.call("momentum.feed", args.toString())?.let(::parse)
    }

    /** Called when the leading message is presented, not merely fetched. Preserve millisecond precision. */
    fun noteShown(context: Context, kind: String) {
        val prefs = NoopPrefs.of(context)
        if (prefs.getString(LAST_KIND, null) == kind) return
        prefs.edit().putString(LAST_KIND, kind).putLong(LAST_AT_MILLIS, System.currentTimeMillis()).apply()
    }

    /** Hides a message kind for the rest of the logical day, as the card's close button does on iOS. */
    fun snooze(context: Context, kind: String): Boolean {
        if (!SwiftCore.available) return false
        val prefs = NoopPrefs.of(context)
        val json = SwiftCore.call("momentum.snooze", JSONObject().put("kind", kind)
            .put("snoozed", prefs.getString(SNOOZED, "") ?: "").toString()) ?: return false
        val snoozed = runCatching { JSONObject(json).getString("snoozed") }.getOrNull() ?: return false
        prefs.edit().putString(SNOOZED, snoozed).apply()
        CoreShadow.noteDataChanged()
        return true
    }

    internal fun parse(json: String): List<Message>? = runCatching {
        val output = JSONObject(json)
        if (output.has("error")) return null
        val a = output.getJSONArray("messages")
        (0 until a.length()).map { a.getJSONObject(it) }.map { m ->
            Message(m.getString("kind"), m.getString("tone"), m.getString("headline"), m.optString("detail"),
                    m.str("actionLine"), m.dbl("progress"), m.str("progressLabel"), m.str("progressChip"),
                    m.str("deltaText"), m.str("actionTitle"), m.str("destination"))
        }
    }.getOrNull()

    private fun JSONObject.str(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null
    private fun JSONObject.dbl(key: String): Double? = if (has(key) && !isNull(key)) getDouble(key) else null
}
