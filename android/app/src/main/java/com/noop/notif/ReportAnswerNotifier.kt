package com.noop.notif

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.R
import com.noop.core.SwiftCore
import com.noop.ui.NotifPrefs
import com.noop.ui.appLaunchIntent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * Tells somebody that a problem THEY reported moved. The Apple twin is `ProjectReportWatcher.swift`,
 * and the rules are the core's, not this file's: `project.reports` and `project.thread` decide what
 * counts as new, so neither platform has its own idea of it.
 *
 * Narrow on purpose, because the project page's own rule is no badge, no bell, no unread dot. This
 * speaks only about this device's own reports, and only when the status moved or the developer said
 * something. Never a release, never somebody else's report, never a count.
 *
 * No push and no polling: there is no service here that knows devices. It looks when the app comes
 * forward, at most every six hours, and a device that has reported nothing never calls at all.
 */
object ReportAnswerNotifier {
    private const val CHANNEL_ID = "noop_report_answer"
    private const val NOTIF_BASE = 4210
    private const val PREF_ENABLED = "noop.projectReportNotices"
    private const val PREF_LAST = "noop.projectReportLastCheck"
    private const val INTERVAL_MS = 6L * 60 * 60 * 1000

    fun isOn(context: Context): Boolean = NotifPrefs.getBool(context, PREF_ENABLED, true)

    fun setOn(context: Context, on: Boolean) = NotifPrefs.setBool(context, PREF_ENABLED, on)

    /** Look, unless it was looked at in the last six hours. Returns what moved. */
    suspend fun checkIfDue(context: Context, now: Long = System.currentTimeMillis()): List<Change> {
        if (!isOn(context)) return emptyList()
        val last = NotifPrefs.getLong(context, PREF_LAST, 0L)
        if (now - last < INTERVAL_MS) return emptyList()
        NotifPrefs.setLong(context, PREF_LAST, now)
        return check()
    }

    data class Change(val code: String, val title: String, val status: String, val answered: Boolean)

    /** One read per remembered report. The core records what was seen, so nothing is said twice. */
    suspend fun check(): List<Change> = withContext(Dispatchers.IO) {
        val reports = runCatching {
            JSONObject(SwiftCore.call("project.reports", "{}") ?: "").optJSONArray("reports")
        }.getOrNull() ?: JSONArray()
        val changes = mutableListOf<Change>()
        for (index in 0 until reports.length()) {
            val row = reports.optJSONObject(index) ?: continue
            val code = row.optString("code")
            if (code.isEmpty()) continue
            val seenStatus = row.optString("seenStatus", "arrived")
            // Over is over: a fixed or refused report cannot move again on its own, and asking after
            // it every six hours for the rest of the install's life can only confirm what is already
            // on the screen. The Apple twin skips the same two.
            if (seenStatus == "fixed" || seenStatus == "notPlanned") continue
            val seenMessages = row.optInt("seenMessages")
            val answer = runCatching {
                JSONObject(SwiftCore.call("project.thread", JSONObject().put("code", code).toString()) ?: "")
            }.getOrNull() ?: continue
            if (!answer.optBoolean("ok")) continue

            val status = answer.optString("status", "arrived")
            val messages = answer.optJSONArray("messages") ?: JSONArray()
            val last = if (messages.length() > 0) messages.optJSONObject(messages.length() - 1) else null
            val answered = messages.length() > seenMessages && last?.optBoolean("mine") == false
            if (status != seenStatus || answered) {
                changes += Change(code, row.optString("title"), status, answered)
            }
        }
        changes
    }

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun announce(context: Context, changes: List<Change>) {
        if (changes.isEmpty()) return
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            val open = PendingIntent.getActivity(
                context, 11, appLaunchIntent(context),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            changes.forEachIndexed { index, change ->
                val body = if (change.answered) {
                    context.getString(R.string.report_notice_answered)
                } else {
                    context.getString(statusRes(change.status))
                }
                val n = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_heart)
                    .setContentTitle(context.getString(R.string.report_notice_title))
                    .setContentText(body)
                    .setContentIntent(open)
                    .setAutoCancel(true)
                    .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                    .build()
                NotificationManagerCompat.from(context).notify(NOTIF_BASE + index, n)
            }
        }
    }

    /** Only the states that are news to the person who reported it. */
    private fun statusRes(status: String): Int = when (status) {
        "fixed" -> R.string.report_notice_fixed
        "working" -> R.string.report_notice_working
        "notPlanned" -> R.string.report_notice_not_planned
        else -> R.string.report_notice_read
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            // The same two strings the switch in Settings carries, so the channel in the system's
            // own list cannot say something else, and neither is left in English.
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, context.getString(R.string.report_notice_switch),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = context.getString(R.string.report_notice_switch_detail)
                },
            )
        }
    }
}
