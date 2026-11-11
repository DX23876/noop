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
import com.noop.ui.appLaunchIntent
import java.time.LocalDate
import java.time.ZoneId
import java.util.concurrent.TimeUnit

/**
 * Fork (DX23876), Forge parity 2026-11: the cycle page's switches and the fertile-days reminder, as iOS
 * `FertileReminder`: a notification at 20:00 the evening before and at 08:00 on the first likely fertile day, while
 * that day still lies ahead. Discreet (the default) says only "Cycle update". Local only. Analysis migration required:
 * no.
 */
object CyclePagePrefs {
    private const val FILE = "noop_cycle_page"
    private const val LEARNING = "learning"
    private const val SHOW_FERTILE = "showFertile"
    private const val REMINDER = "fertileReminder"
    private const val DISCREET = "fertileDiscreet"
    private const val WINDOW_START = "fertileWindowStart"

    private fun prefs(c: Context) = c.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
    fun learning(c: Context) = prefs(c).getBoolean(LEARNING, true)
    fun setLearning(c: Context, on: Boolean) = prefs(c).edit().putBoolean(LEARNING, on).apply()
    fun showFertile(c: Context) = prefs(c).getBoolean(SHOW_FERTILE, true)
    fun setShowFertile(c: Context, on: Boolean) = prefs(c).edit().putBoolean(SHOW_FERTILE, on).apply()
    fun reminder(c: Context) = prefs(c).getBoolean(REMINDER, false)
    fun discreet(c: Context) = prefs(c).getBoolean(DISCREET, true)
    internal fun windowStart(c: Context): LocalDate? =
        prefs(c).getLong(WINDOW_START, Long.MIN_VALUE).takeIf { it != Long.MIN_VALUE }?.let(LocalDate::ofEpochDay)

    fun setReminder(c: Context, on: Boolean) {
        prefs(c).edit().putBoolean(REMINDER, on).apply()
        FertileReminderWorker.reschedule(c, windowStart(c))
    }

    fun setDiscreet(c: Context, on: Boolean) {
        prefs(c).edit().putBoolean(DISCREET, on).apply()
        FertileReminderWorker.reschedule(c, windowStart(c))
    }

    internal fun storeWindowStart(c: Context, day: LocalDate?) {
        prefs(c).edit().apply { if (day == null) remove(WINDOW_START) else putLong(WINDOW_START, day.toEpochDay()) }.apply()
    }
}

class FertileReminderWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        if (!CyclePagePrefs.reminder(applicationContext)) return Result.success()
        post(applicationContext, inputData.getBoolean(KEY_EVE, false))
        return Result.success()
    }

    companion object {
        private const val CHANNEL = "noop_cycle"
        private const val KEY_EVE = "eve"
        private const val EVE = "cycle-fertile-eve"
        private const val START = "cycle-fertile-start"
        private const val MORNING_MINUTES = 8 * 60
        private const val EVENING_MINUTES = 20 * 60

        /** Arms (or clears) the two notifications for the first likely fertile day [windowStart]. */
        fun reschedule(context: Context, windowStart: LocalDate?, nowMs: Long = System.currentTimeMillis()) {
            CyclePagePrefs.storeWindowStart(context, windowStart)
            val manager = runCatching { WorkManager.getInstance(context.applicationContext) }.getOrNull() ?: return
            manager.cancelUniqueWork(EVE); manager.cancelUniqueWork(START)
            if (!CyclePagePrefs.reminder(context) || windowStart == null) return
            val zone = ZoneId.systemDefault()
            fun at(day: LocalDate, minutes: Int) = day.atStartOfDay(zone).plusMinutes(minutes.toLong()).toInstant().toEpochMilli()
            listOf(Triple(EVE, at(windowStart.minusDays(1), EVENING_MINUTES), true),
                   Triple(START, at(windowStart, MORNING_MINUTES), false)).forEach { (id, ms, eve) ->
                if (ms <= nowMs) return@forEach
                val request = OneTimeWorkRequestBuilder<FertileReminderWorker>()
                    .setInputData(workDataOf(KEY_EVE to eve))
                    .setInitialDelay(ms - nowMs, TimeUnit.MILLISECONDS).build()
                manager.enqueueUniqueWork(id, ExistingWorkPolicy.REPLACE, request)
            }
        }

        @SuppressLint("MissingPermission") // permission revocation and disabled channels are checked at delivery
        private fun post(context: Context, eve: Boolean) {
            runCatching {
                val notifications = NotificationManagerCompat.from(context)
                if (!notifications.areNotificationsEnabled()) return
                val localized = AppLanguagePrefs.wrap(context)
                val quiet = CyclePagePrefs.discreet(context)
                context.getSystemService(NotificationManager::class.java).createNotificationChannel(
                    NotificationChannel(CHANNEL, localized.getString(R.string.forge_cy_cycle_update), NotificationManager.IMPORTANCE_DEFAULT))
                val title = when {
                    quiet -> R.string.forge_cy_cycle_update
                    eve -> R.string.forge_cy_fertile_days_start_tomorrow
                    else -> R.string.forge_cy_likely_fertile_from_today
                }
                val body = if (quiet) R.string.forge_cy_open_noop_to_see_your else R.string.forge_cy_a_rough_estimate_from_your
                val pending = PendingIntent.getActivity(context, 0, appLaunchIntent(context),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                val notification = NotificationCompat.Builder(context, CHANNEL)
                    .setSmallIcon(R.drawable.ic_stat_heart)
                    .setContentTitle(localized.getString(title)).setContentText(localized.getString(body))
                    .setVisibility(if (quiet) NotificationCompat.VISIBILITY_PRIVATE else NotificationCompat.VISIBILITY_PUBLIC)
                    .setContentIntent(pending).setAutoCancel(true)
                    .setCategory(NotificationCompat.CATEGORY_REMINDER).build()
                notifications.notify(if (eve) EVE else START, 0, notification)
            }
        }
    }
}
