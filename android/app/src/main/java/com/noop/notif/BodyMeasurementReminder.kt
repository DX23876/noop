package com.noop.notif

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.noop.R
import com.noop.ui.AppLanguagePrefs
import com.noop.ui.NoopPrefs
import com.noop.ui.appLaunchIntent
import java.time.DayOfWeek
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.TemporalAdjusters
import java.util.concurrent.TimeUnit

/**
 * Fork (DX23876), Android parity 2026-11-12: the Body page's two reminders, as iOS `BodyMeasurementReminder`: a weekly
 * tape reminder (Sunday 08:00 by default) and an optional daily weigh-in (07:00). Same keys as iOS, default off,
 * local only. Each fires once and arms the next, so it lands at the clock time. Analysis migration required: no.
 */
object BodyMeasurementReminder {
    private const val WEEKLY_ENABLED = "body.reminder.weekly.enabled"
    private const val WEEKLY_WEEKDAY = "body.reminder.weekly.weekday"   // 1 = Sunday … 7 = Saturday, as iOS
    private const val WEEKLY_MINUTES = "body.reminder.weekly.minutes"
    private const val DAILY_ENABLED = "body.reminder.daily.enabled"
    private const val DAILY_MINUTES = "body.reminder.daily.minutes"
    internal const val WEEKLY_ID = "body-measurement-weekly"
    internal const val DAILY_ID = "body-weigh-in-daily"

    fun weeklyEnabled(c: Context) = NoopPrefs.of(c).getBoolean(WEEKLY_ENABLED, false)
    fun dailyEnabled(c: Context) = NoopPrefs.of(c).getBoolean(DAILY_ENABLED, false)

    /**
     * Turns a reminder on or off. Returns false when notifications are off for NOOP, so nothing is armed that would
     * never arrive; the page says so instead.
     */
    fun setEnabled(c: Context, on: Boolean, daily: Boolean): Boolean {
        val allowed = !on || NotificationManagerCompat.from(c).areNotificationsEnabled()
        NoopPrefs.of(c).edit().putBoolean(if (daily) DAILY_ENABLED else WEEKLY_ENABLED, on && allowed).apply()
        refresh(c)
        return allowed
    }

    /** Re-arms whatever is enabled and clears what is not. Safe on launch and after a change. */
    fun refresh(c: Context, now: ZonedDateTime = ZonedDateTime.now(ZoneId.systemDefault())) {
        val manager = runCatching { WorkManager.getInstance(c.applicationContext) }.getOrNull() ?: return
        val prefs = NoopPrefs.of(c)
        if (weeklyEnabled(c)) {
            val weekday = prefs.getInt(WEEKLY_WEEKDAY, 1).coerceIn(1, 7)
            val minutes = prefs.getInt(WEEKLY_MINUTES, 8 * 60).coerceIn(0, 24 * 60 - 1)
            // iOS counts 1 as Sunday; java.time counts Monday as 1.
            val day = DayOfWeek.of(((weekday + 5) % 7) + 1)
            var next = now.with(TemporalAdjusters.nextOrSame(day)).toLocalDate().atStartOfDay(now.zone).plusMinutes(minutes.toLong())
            if (!next.isAfter(now)) next = next.plusWeeks(1)
            arm(manager, WEEKLY_ID, next, now, daily = false)
        } else manager.cancelUniqueWork(WEEKLY_ID)
        if (dailyEnabled(c)) {
            val minutes = prefs.getInt(DAILY_MINUTES, 7 * 60).coerceIn(0, 24 * 60 - 1)
            var next = now.toLocalDate().atStartOfDay(now.zone).plusMinutes(minutes.toLong())
            if (!next.isAfter(now)) next = next.plusDays(1)
            arm(manager, DAILY_ID, next, now, daily = true)
        } else manager.cancelUniqueWork(DAILY_ID)
    }

    private fun arm(manager: WorkManager, id: String, at: ZonedDateTime, now: ZonedDateTime, daily: Boolean) {
        val delay = at.toInstant().toEpochMilli() - now.toInstant().toEpochMilli()
        manager.enqueueUniqueWork(id, ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<BodyReminderWorker>()
            .setInputData(workDataOf("daily" to daily)).setInitialDelay(delay, TimeUnit.MILLISECONDS).build())
    }
}

class BodyReminderWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val daily = inputData.getBoolean("daily", false)
        val on = if (daily) BodyMeasurementReminder.dailyEnabled(applicationContext) else BodyMeasurementReminder.weeklyEnabled(applicationContext)
        if (on) post(applicationContext, daily)
        // Arms the next one a minute on, so this firing is never picked again.
        BodyMeasurementReminder.refresh(applicationContext, ZonedDateTime.now(ZoneId.systemDefault()).plusMinutes(1))
        return Result.success()
    }

    @SuppressLint("MissingPermission") // permission revocation and disabled channels are checked at delivery
    private fun post(context: Context, daily: Boolean) {
        runCatching {
            val notifications = NotificationManagerCompat.from(context)
            if (!notifications.areNotificationsEnabled()) return
            val localized = AppLanguagePrefs.wrap(context)
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, localized.getString(R.string.forge_body_title), NotificationManager.IMPORTANCE_DEFAULT))
            val pending = PendingIntent.getActivity(context, 0, appLaunchIntent(context),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val notification = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(localized.getString(if (daily) R.string.body_reminder_weigh_title else R.string.body_reminder_measure_title))
                .setContentText(localized.getString(if (daily) R.string.body_reminder_weigh_body else R.string.body_reminder_measure_body))
                .setStyle(NotificationCompat.BigTextStyle().bigText(localized.getString(
                    if (daily) R.string.body_reminder_weigh_body else R.string.body_reminder_measure_body)))
                .setContentIntent(pending).setAutoCancel(true).setCategory(NotificationCompat.CATEGORY_REMINDER).build()
            notifications.notify(if (daily) BodyMeasurementReminder.DAILY_ID else BodyMeasurementReminder.WEEKLY_ID, 0, notification)
        }
    }

    private companion object { const val CHANNEL = "noop_body" }
}
