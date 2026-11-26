package com.noop.notif

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.R
import com.noop.core.CoreAlerts
import com.noop.core.CoreRead
import com.noop.core.CoreTrainingLoad
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.appLaunchIntent
import com.noop.ui.forge.dismissedTrainingWorkouts
import java.util.concurrent.TimeUnit

/**
 * Fork (DX23876), Android Settings parity: the Training Load alert (Settings › Notifications). Opt-in, default off. One
 * notification when a lane's last seven days move into "well above your usual", the band the Training Load page already
 * shows, and not again until that lane has left it. The once-per-high-phase rule is the core's `alerts.trainingLoad`
 * (`TrainingLoadAlert`, the one the iPhone's notifier calls); this file reads the lanes, keeps each lane's episode flag
 * and posts. It describes load only: whether the load is working is what the Training Load statement decides.
 */
object TrainingLoadNotifier {
    private const val CHANNEL = "noop_training_load"
    private const val KEY_ENABLED = "behavior.trainingLoadAlert"
    private fun episodeKey(kind: String) = "behavior.trainingLoadAlert.$kind.active"

    fun enabled(context: Context): Boolean = NoopPrefs.of(context).getBoolean(KEY_ENABLED, false)

    /**
     * Turns the alert on. The lanes are read once with the alert still off, so a week that is already high opens its
     * episode without a post (the iPhone tracks the episode while the alert is off for the same reason); after that the
     * periodic read keeps the flags and posts. Blocking: call off the main thread.
     */
    suspend fun enable(context: Context) {
        runCatching { check(context, enabled = false) }
        NoopPrefs.of(context).edit().putBoolean(KEY_ENABLED, true).apply()
        TrainingLoadWorker.ensureScheduled(context)
    }

    fun disable(context: Context) {
        NoopPrefs.of(context).edit().putBoolean(KEY_ENABLED, false).apply()
        TrainingLoadWorker.cancel(context)
    }

    /** Reads the lanes and runs the rule. Blocking: call off the main thread (the worker does). */
    suspend fun check(context: Context, enabled: Boolean = enabled(context)) {
        CoreRead.open(context)
        val profile = ProfileStore.from(context)
        val load = CoreTrainingLoad.read(profile.hrMax.toDouble(), profile.sex, dismissedTrainingWorkouts(context)) ?: return
        val prefs = NoopPrefs.of(context)
        val lanes = listOf("strength" to load.strength, "cardio" to load.cardio)
        val decisions = CoreAlerts.trainingLoad(
            enabled,
            lanes.map { (kind, lane) -> CoreAlerts.LaneInput(kind, lane.band, prefs.getBoolean(episodeKey(kind), false)) },
        ) ?: return
        decisions.forEach { d ->
            prefs.edit().putBoolean(episodeKey(d.kind), d.episodeOpen).apply()
            if (d.notify) post(context, d.kind)
        }
    }

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    private fun post(context: Context, kind: String) {
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            val strength = kind == "strength"
            val title = context.getString(if (strength) R.string.fsp3_tla_strength_title else R.string.fsp3_tla_cardio_title)
            val body = context.getString(if (strength) R.string.fsp3_tla_strength_body else R.string.fsp3_tla_cardio_body)
            val open = PendingIntent.getActivity(context, 4, appLaunchIntent(context),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val n = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(title).setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(open).setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_STATUS).setPriority(NotificationCompat.PRIORITY_LOW)
                .build()
            // One id per lane, so a second lane's alert never replaces the first's.
            NotificationManagerCompat.from(context).notify(if (strength) 4211 else 4212, n)
        }
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL) != null) return
            mgr.createNotificationChannel(NotificationChannel(CHANNEL, context.getString(R.string.forge_w_training_load),
                NotificationManager.IMPORTANCE_LOW))
        }
    }
}

/** The periodic read behind the Training Load alert: the load moves over days, so a few hours is ample. */
class TrainingLoadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        if (TrainingLoadNotifier.enabled(applicationContext)) runCatching { TrainingLoadNotifier.check(applicationContext) }
        // Never retry: the next period reads again, and the episode flags mean a late run cannot post twice.
        return Result.success()
    }

    companion object {
        private const val WORK = "noop.trainingLoadAlert"
        const val INTERVAL_HOURS = 6L

        fun cancel(context: Context) {
            runCatching { WorkManager.getInstance(context.applicationContext).cancelUniqueWork(WORK) }
        }

        /** KEEP, so opening NOOP often does not restart the period (the reason [StaleBatteryWorker] gives). */
        fun ensureScheduled(context: Context) {
            runCatching {
                WorkManager.getInstance(context.applicationContext).enqueueUniquePeriodicWork(
                    WORK, ExistingPeriodicWorkPolicy.KEEP,
                    PeriodicWorkRequestBuilder<TrainingLoadWorker>(INTERVAL_HOURS, TimeUnit.HOURS).build())
            }
        }
    }
}
