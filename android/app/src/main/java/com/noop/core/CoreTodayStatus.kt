package com.noop.core

import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 2.3: the readiness verdict and the wearer's activity status under Today's hero,
 * from the shared core (`today.status`, `today.setActivity`). The status lives under Apple's key, where goals,
 * Momentum and the coach read it. Blocking; call off the main thread.
 */
object CoreTodayStatus {
    data class Status(val level: String, val activity: String, val validUntil: Long?)

    fun read(maxHR: Double?, sex: String, dismissedWorkouts: List<String>): Status? {
        if (!SwiftCore.available) return null
        val args = JSONObject().put("sex", sex).put("dismissedWorkouts", org.json.JSONArray(dismissedWorkouts))
            .apply { if (maxHR != null) put("maxHR", maxHR) }
        return SwiftCore.call("today.status", args.toString())?.let(::parse)
    }

    /** The wearer's own status alone: [read] evaluates the day's readiness behind it, which a line that
     *  only names the status must not pay for. */
    data class Activity(val state: String, val validUntil: Long?) {
        val isActive: Boolean get() = state == "active"
    }

    fun activity(): Activity? {
        if (!SwiftCore.available) return null
        return SwiftCore.call("today.activity", "{}")?.let(::parseActivity)
    }

    internal fun parseActivity(json: String): Activity? = runCatching {
        val o = JSONObject(json)
        Activity(o.getString("activity"), if (o.has("validUntil") && !o.isNull("validUntil")) o.getLong("validUntil") else null)
    }.getOrNull()

    /** [duration] is today, threeDays, thisWeek or untilChanged, as the iOS sheet offers them. */
    fun setActivity(state: String, duration: String): Boolean =
        SwiftCore.available && SwiftCore.call("today.setActivity",
            JSONObject().put("state", state).put("duration", duration).toString())?.contains("\"ok\":true") == true

    internal fun parse(json: String): Status? = runCatching {
        val o = JSONObject(json)
        Status(o.getString("level"), o.getString("activity"), if (o.has("validUntil")) o.getLong("validUntil") else null)
    }.getOrNull()
}
