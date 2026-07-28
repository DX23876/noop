package com.noop.ui

import android.content.Context
import java.time.Instant
import java.time.ZoneId

/**
 * Records alerts that really happened in the app's bell. It deliberately does not represent scheduled
 * reminders: those can be delivered while the process is absent and must not be claimed as events early.
 */
object AlertInbox {
    enum class Kind(
        val key: String,
        val lifetimeMs: Long,
        val deepLink: String? = null,
    ) {
        BATTERY_LOW("battery-low", 3L * 24L * 60L * 60L * 1000L, "devices"),
        BATTERY_RUNTIME("battery-runtime", 3L * 24L * 60L * 60L * 1000L, "devices"),
        BATTERY_FULL("battery-full", 24L * 60L * 60L * 1000L, "devices"),
        ILLNESS("illness", 2L * 24L * 60L * 60L * 1000L),
        INACTIVITY("inactivity", 24L * 60L * 60L * 1000L),
        SMART_ALARM("smart-alarm", 24L * 60L * 60L * 1000L),
    }

    fun post(context: Context, kind: Kind, title: String, message: String, now: Long = System.currentTimeMillis()) {
        val day = Instant.ofEpochMilli(now).atZone(ZoneId.systemDefault()).toLocalDate()
        val key = "${kind.key}:$day"
        UpdateStore.from(context).postOrRefreshAlert(
            alertKey = key,
            title = title,
            message = message,
            deepLink = kind.deepLink,
            expiresAt = now + kind.lifetimeMs,
            now = now,
        )
    }
}
