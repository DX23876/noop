package com.noop.notif

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.R
import com.noop.core.CoreActivity
import com.noop.ui.NoopPrefs
import com.noop.ui.appLaunchIntent
import com.noop.ui.forge.ActivitySuggestionState
import com.noop.ui.forge.fill
import com.noop.ui.forge.whenLine
import org.json.JSONObject
import java.util.Calendar

/**
 * The lock-screen side of activity detection on Android, with the same rules as iOS (`ActivitySuggestionNotifier`):
 * one notification per suggestion, at most [MAX_PER_DAY] a day, held overnight, paused for a week after
 * [PAUSE_AFTER] went unanswered. Its buttons answer through the shared core, as the Today prompt does.
 */
object ActivitySuggestionNotifier {
    private const val CHANNEL_ID = "noop_activity_detection"
    private const val STATE_KEY = "noop.activityDetection.notifyState"
    private const val MAX_PER_DAY = 2
    private const val QUIET_FROM = 22
    private const val QUIET_UNTIL = 7
    private const val PAUSE_AFTER = 3
    private const val PAUSE_DAYS = 7
    internal const val ACTION_SAVE = "com.noop.activity.SAVE"
    internal const val ACTION_NOT_TRAINING = "com.noop.activity.NOT_TRAINING"
    internal const val EXTRA_ID = "suggestionId"

    private fun on(context: Context) = CoreActivity.enabled(context) &&
        NoopPrefs.of(context).getBoolean(CoreActivity.KEY_NOTIFY, true)

    private fun notificationId(id: String) = 7400 + (id.hashCode() and 0x7FFF)

    @Synchronized
    fun update(context: Context, result: CoreActivity.Result) {
        val next = result.toAsk.firstOrNull() ?: return
        if (!on(context)) return
        val now = System.currentTimeMillis() / 1000
        val prefs = NoopPrefs.of(context)
        val state = runCatching { JSONObject(prefs.getString(STATE_KEY, "{}")!!) }.getOrDefault(JSONObject())
        val today = Calendar.getInstance().let { "${it.get(Calendar.YEAR)}-${it.get(Calendar.DAY_OF_YEAR)}" }
        if (state.optString("day") != today) { state.put("day", today); state.put("sent", 0) }
        val notified = state.optJSONObject("notified") ?: JSONObject()
        notified.keys().asSequence().toList().forEach { if (notified.getLong(it) < now - 30 * 86_400) notified.remove(it) }
        if (notified.has(next.id) || now < state.optLong("pausedUntil") || state.optInt("sent") >= MAX_PER_DAY) return
        val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        if (hour >= QUIET_FROM || hour < QUIET_UNTIL) return   // asked again by the next morning's update
        val open = result.toAsk.map { it.id }.toSet()
        if (notified.keys().asSequence().count { it in open } >= PAUSE_AFTER) {
            state.put("pausedUntil", now + PAUSE_DAYS * 86_400)
            prefs.edit().putString(STATE_KEY, state.put("notified", notified).toString()).apply()
            return
        }
        notified.put(next.id, now)
        state.put("sent", state.optInt("sent") + 1)
        prefs.edit().putString(STATE_KEY, state.put("notified", notified).toString()).apply()
        post(context, result, next)
    }

    fun answered(context: Context, id: String) {
        val prefs = NoopPrefs.of(context)
        val state = runCatching { JSONObject(prefs.getString(STATE_KEY, "{}")!!) }.getOrDefault(JSONObject())
        state.optJSONObject("notified")?.remove(id)
        prefs.edit().putString(STATE_KEY, state.toString()).apply()
        NotificationManagerCompat.from(context).cancel(notificationId(id))
    }

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    private fun post(context: Context, r: CoreActivity.Result, item: CoreActivity.Item) {
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            val title = com.noop.ui.forge.titleOf(r, item)
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, r.label("section"), NotificationManager.IMPORTANCE_DEFAULT))
            }
            val id = notificationId(item.id)
            fun action(action: String, code: Int) = PendingIntent.getBroadcast(
                context, id * 4 + code,
                Intent(context, ActivitySuggestionActionReceiver::class.java).setAction(action).putExtra(EXTRA_ID, item.id),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val save = if (item.track == "walk") r.label("saveWalk")
                else fill(r.label("saveAs"), listOf(r.label("kind.${item.likelyKind}")), 0)
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(title)
                .setContentText(whenLine(r, item, withMinutes = true))
                .setContentIntent(PendingIntent.getActivity(context, id, appLaunchIntent(context),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
                .addAction(0, save, action(ACTION_SAVE, 1))
                .addAction(0, r.label("notTraining"), action(ACTION_NOT_TRAINING, 2))
                .setAutoCancel(true)
                .build()
            NotificationManagerCompat.from(context).notify(id, n)
        }
    }

    internal fun handle(context: Context, intent: Intent) {
        val id = intent.getStringExtra(EXTRA_ID) ?: return
        ActivitySuggestionState.reload(context)
        val item = ActivitySuggestionState.result.value?.toAsk?.firstOrNull { it.id == id } ?: return
        when (intent.action) {
            ACTION_SAVE -> {
                val kind = item.likelyKind
                CoreActivity.answer(item, if (kind == "walk") "walk" else "sport", "notification",
                                    sport = CoreActivity.sportToken(kind))
            }
            ACTION_NOT_TRAINING -> CoreActivity.answer(item, "everyday", "notification")
        }
        answered(context, id)
        ActivitySuggestionState.reload(context)
    }
}

class ActivitySuggestionActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        Thread {
            try { ActivitySuggestionNotifier.handle(context.applicationContext, intent) }
            catch (e: Exception) { android.util.Log.w("ActivitySuggestion", "action failed: ${e.javaClass.simpleName}") }
            finally { pending.finish() }
        }.start()
    }
}
