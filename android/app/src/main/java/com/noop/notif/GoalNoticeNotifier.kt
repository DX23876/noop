package com.noop.notif

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.R
import com.noop.core.CoreGoals
import com.noop.core.CoreRead
import com.noop.ui.NoopPrefs
import com.noop.ui.NotifPrefs
import com.noop.ui.appLaunchIntent

/**
 * Fork (DX23876), Android parity plan 2.3: the goal notifications iOS sends (`GoalEventNotifier`): a daily goal
 * reached, a streak in danger in the evening, a new badge, a long-term milestone. The shared core decides what to
 * say and keeps the count (`GoalEventPlan`); this posts it. Off until the wearer switches a kind on, on the goals
 * page. Called after every data update; cheap when every kind is off. Blocking; call off the main thread.
 */
object GoalNoticeNotifier {
    enum class Kind(val key: String) { Reached("reached"), Streak("streak"), Badge("badge"), Milestone("milestone") }

    private const val CHANNEL_ID = "noop_goals"
    private const val STATE_KEY = "goals.notify.state"
    private const val NOTICE_ID_BASE = 4230

    fun isOn(context: Context, kind: Kind): Boolean = NoopPrefs.of(context).getBoolean("goals.notify.${kind.key}", false)

    fun setOn(context: Context, kind: Kind, on: Boolean) {
        NoopPrefs.of(context).edit().putBoolean("goals.notify.${kind.key}", on).apply()
    }

    fun evaluate(context: Context, dismissedWorkouts: List<String>, workoutInProgress: Boolean) {
        val kinds = Kind.values().filter { isOn(context, it) }.map { it.key }
        if (kinds.isEmpty() || !CoreRead.isOpen) return
        val prefs = NoopPrefs.of(context)
        val result = CoreGoals.notices(
            context, dismissedWorkouts, kinds, quiet = NotifPrefs.inQuietHours(context),
            // Apple places the evening reminder three hours before the wind-down bedtime; Android has no wind-down
            // schedule yet, so it takes Apple's own fallback, 19:00.
            eveningMinute = 19 * 60, workoutInProgress = workoutInProgress, appIsActive = appIsActive(),
            state = prefs.getString(STATE_KEY, null),
        ) ?: return
        prefs.edit().putString(STATE_KEY, result.state).apply()
        result.messages.forEachIndexed { index, message -> post(context, NOTICE_ID_BASE + index, message) }
    }

    /** While the app is on screen the ring's own moment says it instead, as on iOS. */
    private fun appIsActive(): Boolean {
        val info = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(info)
        return info.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    private fun post(context: Context, id: Int, message: CoreGoals.Notice) {
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            val open = PendingIntent.getActivity(context, 7, appLaunchIntent(context),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(message.title)
                .setContentText(message.body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(message.body))
                .setContentIntent(open)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()
            NotificationManagerCompat.from(context).notify(id, n)
        }
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            mgr.createNotificationChannel(NotificationChannel(CHANNEL_ID, context.getString(R.string.forge_gn_channel),
                NotificationManager.IMPORTANCE_DEFAULT))
        }
    }
}
