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
        serializedPass(
            read = { prefs.getString(STATE_KEY, null) },
            compute = { state ->
                CoreGoals.notices(
                    context, dismissedWorkouts, kinds, quiet = NotifPrefs.inQuietHours(context),
                    eveningMinute = eveningMinute(context), workoutInProgress = workoutInProgress,
                    appIsActive = appIsActive(), state = state,
                )?.let { it.state to it.messages }
            },
            write = { prefs.edit().putString(STATE_KEY, it).commit() },
            deliver = { messages -> messages.forEachIndexed { index, message -> post(context, NOTICE_ID_BASE + index, message) } },
        )
    }

    private val passLock = Any()

    /**
     * One pass at a time: read the count, let the core decide, store the new count, post. The view model starts a
     * pass on every data update, so two can overlap; without this both read the same count and both post the
     * same notice. The count is written before the next pass may read it.
     */
    internal fun <T> serializedPass(read: () -> String?, compute: (String?) -> Pair<String, T>?,
                                    write: (String) -> Unit, deliver: (T) -> Unit) {
        val delivery = synchronized(passLock) {
            val (state, messages) = compute(read()) ?: return
            write(state)
            messages
        }
        deliver(delivery)
    }

    /** Never later than this minute of the day (21:00), as `GoalEventPlan.latestMinute`. */
    private const val LATEST_MINUTE = 21 * 60

    /**
     * Three hours before the usual bedtime (tomorrow's wake time minus the sleep need, from the wind-down and alarm
     * settings), 19:00 when that lands oddly (`GoalEventNotifier.eveningMinute`).
     */
    internal fun eveningMinute(context: Context, now: java.util.Calendar = java.util.Calendar.getInstance()): Int {
        val tomorrow = (now.clone() as java.util.Calendar).apply { add(java.util.Calendar.DAY_OF_YEAR, 1) }
        val wake = com.noop.alarm.SmartAlarmStore.from(context).targetFor(tomorrow.get(java.util.Calendar.DAY_OF_WEEK))
        return eveningMinuteFor(wake, com.noop.alarm.WindDownStore.from(context).sleepNeedMinutes)
    }

    /** The reminder minute for a wake time and sleep need: three hours before bedtime, 19:00 outside 16:00 to 20:45. */
    internal fun eveningMinuteFor(wakeMinutes: Int, sleepNeedMinutes: Int): Int {
        val reminder = wakeMinutes - sleepNeedMinutes + 24 * 60 - 180
        return if (reminder in (16 * 60)..(LATEST_MINUTE - 15)) reminder else 19 * 60
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
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(message.title)
                .setContentText(message.body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(message.body))
                .setContentIntent(open)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            // The evening reminder: "Remind me in 1 hour", and "Tick off" when exactly one box is open.
            if (message.evening) {
                if (message.tickGoalId != null && message.tickDay != null) {
                    builder.addAction(0, context.getString(R.string.forge_gn_tick),
                        actionIntent(context, id, ACTION_TICK, message))
                }
                builder.addAction(0, context.getString(R.string.forge_gn_snooze), actionIntent(context, id, ACTION_SNOOZE, message))
            }
            NotificationManagerCompat.from(context).notify(id, builder.build())
        }.onFailure { android.util.Log.w("GoalNotice", "post failed: ${it.javaClass.simpleName} ${it.message}") }
    }

    private const val ACTION_TICK = "com.noop.goal.TICK"
    private const val ACTION_SNOOZE = "com.noop.goal.SNOOZE"

    private fun actionIntent(context: Context, id: Int, action: String, m: CoreGoals.Notice): PendingIntent =
        PendingIntent.getBroadcast(context, id * 4 + if (action == ACTION_TICK) 1 else 2,
            android.content.Intent(context, GoalNoticeActionReceiver::class.java).setAction(action)
                .putExtra("id", id).putExtra("noticeId", m.id).putExtra("title", m.title).putExtra("body", m.body)
                .putExtra("goalId", m.tickGoalId).putExtra("day", m.tickDay),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    /** A tap on a notification button: tick the one open box, or post the same reminder again in an hour. */
    internal fun handle(context: Context, intent: android.content.Intent) {
        val id = intent.getIntExtra("id", NOTICE_ID_BASE)
        when (intent.action) {
            ACTION_TICK -> {
                val goal = intent.getStringExtra("goalId") ?: return
                val day = intent.getStringExtra("day") ?: return
                if (!CoreRead.isOpen) CoreRead.open(context)
                CoreGoals.toggleAction(goal, day)
                NotificationManagerCompat.from(context).cancel(id)
            }
            ACTION_SNOOZE -> {
                NotificationManagerCompat.from(context).cancel(id)
                val fire = java.util.Calendar.getInstance().apply { add(java.util.Calendar.HOUR_OF_DAY, 1) }
                val minute = fire.get(java.util.Calendar.HOUR_OF_DAY) * 60 + fire.get(java.util.Calendar.MINUTE)
                // As iOS (`isQuiet(fire)`): not past 21:00, not in the quiet hours when it would fire.
                if (!snoozeMayFire(minute, NotifPrefs.inQuietHours(context, fire))) return
                val again = CoreGoals.Notice(intent.getStringExtra("noticeId").orEmpty(), intent.getStringExtra("title").orEmpty(),
                    intent.getStringExtra("body").orEmpty(), evening = true,
                    tickGoalId = intent.getStringExtra("goalId"), tickDay = intent.getStringExtra("day"))
                val repost = actionIntent(context, id, ACTION_SNOOZE_FIRE, again)
                (context.getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager)
                    .setAndAllowWhileIdle(android.app.AlarmManager.RTC, fire.timeInMillis, repost)
            }
            ACTION_SNOOZE_FIRE -> post(context, id, CoreGoals.Notice(intent.getStringExtra("noticeId").orEmpty(),
                intent.getStringExtra("title").orEmpty(), intent.getStringExtra("body").orEmpty(), true,
                intent.getStringExtra("goalId"), intent.getStringExtra("day")))
        }
    }

    private const val ACTION_SNOOZE_FIRE = "com.noop.goal.SNOOZE_FIRE"

    /** A snoozed reminder fires only before 21:00 and outside the quiet hours at its fire time ([fireMinute]). */
    internal fun snoozeMayFire(fireMinute: Int, quietAtFire: Boolean): Boolean = fireMinute < LATEST_MINUTE && !quietAtFire

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

/** Receives the goal notification buttons (see [GoalNoticeNotifier.handle]). */
class GoalNoticeActionReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: android.content.Intent) {
        val pending = goAsync()
        Thread {
            try { GoalNoticeNotifier.handle(context.applicationContext, intent) }
            catch (e: Exception) { android.util.Log.w("GoalNotice", "action failed: ${e.javaClass.simpleName}") }
            finally { pending.finish() }
        }.start()
    }
}
