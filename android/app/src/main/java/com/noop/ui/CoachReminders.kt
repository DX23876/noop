package com.noop.ui

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.noop.R
import com.noop.core.CoreCoach
import java.util.concurrent.TimeUnit

/**
 * The coach's two on-device reminders, as iOS has them: the daily check-in (`CoachCheckIn`, at a fixed time or at
 * the learned wake time) and plan reminders (`PlanReminder`, at the time set for an agreed session). Neither calls
 * a provider. The words come from the shared coach when they are scheduled and travel with the work, so a worker
 * never has to start the core. Both stop while the coach's master switch is off.
 */
object CoachReminders {
    private const val PREFS = "noop_coach_reminders"
    private const val CHECKIN_WORK = "noop_coach_checkin_daily"
    private const val PLAN_TAG = "noop_coach_plan_reminder"
    private const val CHANNEL_ID = "noop_coach_reminders"
    private const val CHECKIN_NOTIF_ID = 7101

    /** The check-in's settings: on, the mode (`fixed` or `afterWake`), the fixed time and the last learned wake. */
    data class CheckIn(val enabled: Boolean, val afterWake: Boolean, val timeMinutes: Int, val wakeMinutes: Int?) {
        /** `CoachCheckIn.effectiveMinutes`: the learned wake time in its mode, the fixed time until one is learned. */
        val effectiveMinutes: Int get() = if (afterWake) (wakeMinutes ?: timeMinutes).coerceIn(0, 24 * 60 - 1) else timeMinutes
    }

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun checkIn(context: Context): CheckIn = prefs(context).let {
        CheckIn(it.getBoolean("checkin.enabled", false), it.getString("checkin.mode", "fixed") == "afterWake",
                it.getInt("checkin.time", 8 * 60), if (it.contains("checkin.wake")) it.getInt("checkin.wake", 0) else null)
    }

    fun planRemindersEnabled(context: Context): Boolean = prefs(context).getBoolean("plan.enabled", false)

    /** Saves the check-in, the words its notification uses, and schedules it again. */
    fun setCheckIn(context: Context, value: CheckIn, title: String? = null, body: String? = null) {
        prefs(context).edit().apply {
            putBoolean("checkin.enabled", value.enabled)
            putString("checkin.mode", if (value.afterWake) "afterWake" else "fixed")
            putInt("checkin.time", value.timeMinutes)
            if (value.wakeMinutes != null) putInt("checkin.wake", value.wakeMinutes)
            title?.let { putString("checkin.title", it) }
            body?.let { putString("checkin.body", it) }
        }.apply()
        rescheduleCheckIn(context, replace = true)
    }

    /** Arms the daily check-in at its effective minute, or cancels it when off or the coach is switched off. */
    fun rescheduleCheckIn(context: Context, replace: Boolean = false) {
        val wm = WorkManager.getInstance(context.applicationContext)
        val c = checkIn(context)
        if (!c.enabled || !NoopPrefs.coachEnabled(context.applicationContext)) {
            wm.cancelUniqueWork(CHECKIN_WORK)
            return
        }
        val request = PeriodicWorkRequestBuilder<CheckInWorker>(1, TimeUnit.DAYS)
            .setInitialDelay(CoachBriefScheduler.delayToNextOccurrenceMs(c.effectiveMinutes), TimeUnit.MILLISECONDS)
            .build()
        wm.enqueueUniquePeriodicWork(CHECKIN_WORK,
            if (replace) ExistingPeriodicWorkPolicy.CANCEL_AND_REENQUEUE else ExistingPeriodicWorkPolicy.KEEP, request)
    }

    /** App start: learns the wake time again when the check-in follows it, then re-arms both reminders. */
    fun refreshOnLaunch(context: Context) {
        val c = checkIn(context)
        if (c.enabled && c.afterWake) {
            com.noop.core.CoreRead.open(context)
            val wake = CoreCoach.checkIn(c.timeMinutes)?.wakeMinutes
            if (wake != null && wake != c.wakeMinutes) {
                prefs(context).edit().putInt("checkin.wake", wake).apply()
                rescheduleCheckIn(context, replace = true)
                return
            }
        }
        rescheduleCheckIn(context)
        if (planRemindersEnabled(context)) {
            com.noop.core.CoreRead.open(context)
            reschedulePlan(context, UnitPrefs.effortScale(context).raw)
        }
    }

    fun setPlanReminders(context: Context, on: Boolean, effortScale: String) {
        prefs(context).edit().putBoolean("plan.enabled", on).apply()
        reschedulePlan(context, effortScale)
    }

    /**
     * One reminder per agreed session with a time still ahead (`coach.plan.reminders`), replacing the previous set,
     * so a moved, swapped or finished session never fires at its old time. Runs off the main thread.
     */
    fun reschedulePlan(context: Context, effortScale: String) {
        val app = context.applicationContext
        val wm = WorkManager.getInstance(app)
        wm.cancelAllWorkByTag(PLAN_TAG)
        if (!planRemindersEnabled(app) || !NoopPrefs.coachEnabled(app)) return
        val now = System.currentTimeMillis()
        CoreCoach.planReminders(effortScale).forEach { r ->
            val at = (r.at * 1000).toLong()
            if (at <= now) return@forEach
            val request = OneTimeWorkRequestBuilder<PlanReminderWorker>()
                .setInitialDelay(at - now, TimeUnit.MILLISECONDS)
                .setInputData(workDataOf("id" to r.id, "title" to r.title, "body" to r.body))
                .addTag(PLAN_TAG)
                .build()
            wm.enqueueUniqueWork("$PLAN_TAG-${r.id}", ExistingWorkPolicy.REPLACE, request)
        }
    }

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    internal fun post(context: Context, id: Int, title: String, body: String) {
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, title, NotificationManager.IMPORTANCE_DEFAULT))
            }
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(android.app.PendingIntent.getActivity(context, id, appLaunchIntent(context),
                    android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT))
                .setAutoCancel(true)
                .build()
            NotificationManagerCompat.from(context).notify(id, n)
        }
    }

    class CheckInWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
        override suspend fun doWork(): Result {
            val app = applicationContext
            if (!checkIn(app).enabled || !NoopPrefs.coachEnabled(app)) return Result.success()
            val p = prefs(app)
            post(app, CHECKIN_NOTIF_ID, p.getString("checkin.title", null) ?: return Result.success(),
                 p.getString("checkin.body", null).orEmpty())
            return Result.success()
        }
    }

    class PlanReminderWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
        override suspend fun doWork(): Result {
            val app = applicationContext
            if (!planRemindersEnabled(app) || !NoopPrefs.coachEnabled(app)) return Result.success()
            val id = inputData.getString("id") ?: return Result.success()
            post(app, 7200 + (id.hashCode() and 0xFFFF), inputData.getString("title").orEmpty(), inputData.getString("body").orEmpty())
            return Result.success()
        }
    }
}
