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
import com.noop.core.CoreTrainingReminders
import com.noop.ui.AppLanguagePrefs
import com.noop.ui.ProfileStore
import com.noop.ui.appLaunchIntent
import com.noop.ui.forge.dismissedTrainingWorkouts
import kotlinx.coroutines.flow.first
import java.util.concurrent.TimeUnit

/** Local delayed sRPE prompt. Revalidation at delivery protects edits, deletions and preference changes. */
class SessionRatingReminderWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val id = inputData.getString(KEY) ?: return Result.success()
        if (CoreTrainingReminders.prompt(applicationContext) == "off") return Result.success()
        val candidates = read(applicationContext, forDelivery = true)
            ?: return if (runAttemptCount < 3) Result.retry() else Result.failure()
        val candidate = candidates.firstOrNull { it.id == id }
        if (candidate == null) {
            // A backwards clock change can wake a previously scheduled request before its new due time.
            val future = read(applicationContext, forDelivery = false)
            return if (future?.any { it.id == id } == true) Result.retry() else Result.success()
        }
        post(applicationContext, candidate)
        return Result.success()
    }

    companion object {
        private const val TAG = "noop.sessionRatingReminders"
        private const val KEY = "candidateId"
        private const val CHANNEL = "noop_session_rating"

        private suspend fun read(context: Context, forDelivery: Boolean): List<CoreTrainingReminders.Candidate>? =
            CoreTrainingReminders.read(context, ProfileStore.from(context).hrMax.toDouble(),
                dismissedTrainingWorkouts(context), forDelivery)

        /** Called after a Training refresh or rating edit. KEEP never moves an existing deadline. */
        suspend fun synchronize(context: Context) {
            try { reconcile(context) }
            catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (error: Exception) {
                android.util.Log.w("SessionRatingReminder", "Local scheduling failed: ${error.javaClass.simpleName}")
            }
        }

        private suspend fun reconcile(context: Context) {
            val candidates = read(context, forDelivery = false) ?: return
            val manager = WorkManager.getInstance(context.applicationContext)
            val ids = candidates.map { it.id }.toSet()
            // Keep a due worker long enough to revalidate and post within Swift's delivery grace period.
            val due = read(context, forDelivery = true)?.map { it.id }?.toSet() ?: return
            manager.getWorkInfosByTagFlow(TAG).first().forEach { info ->
                val key = info.tags.firstOrNull { it.startsWith("session-rpe-reminder-") }
                if (key != null && key !in ids && key !in due && !info.state.isFinished) manager.cancelUniqueWork(key)
            }
            val now = System.currentTimeMillis() / 1000
            candidates.forEach { candidate ->
                val request = OneTimeWorkRequestBuilder<SessionRatingReminderWorker>()
                    .setInputData(workDataOf(KEY to candidate.id))
                    .setInitialDelay((candidate.fireTs - now).coerceAtLeast(0), TimeUnit.SECONDS)
                    .addTag(TAG).addTag(candidate.id).build()
                manager.enqueueUniqueWork(candidate.id, ExistingWorkPolicy.KEEP, request)
            }
        }

        @SuppressLint("MissingPermission") // permission revocation and disabled channels are checked at delivery
        private fun post(context: Context, candidate: CoreTrainingReminders.Candidate) {
            runCatching {
                val notifications = NotificationManagerCompat.from(context)
                if (!notifications.areNotificationsEnabled()) return
                val localized = AppLanguagePrefs.wrap(context)
                val manager = context.getSystemService(NotificationManager::class.java)
                manager.createNotificationChannel(NotificationChannel(CHANNEL,
                    localized.getString(R.string.forge_rating_reminder_channel), NotificationManager.IMPORTANCE_DEFAULT))
                val intent = appLaunchIntent(context).putExtra(SessionRatingNavigation.EXTRA, candidate.sessionId)
                // Distinct data keeps sessions apart without relying on a platform hash as identity.
                intent.data = android.net.Uri.Builder().scheme("noop").authority("session-rating")
                    .appendPath(candidate.sessionId).build()
                val pending = PendingIntent.getActivity(context, 0, intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                val notification = NotificationCompat.Builder(context, CHANNEL)
                    .setSmallIcon(R.drawable.ic_stat_heart)
                    .setContentTitle(localized.getString(R.string.forge_rating_reminder_title))
                    .setContentText(localized.getString(R.string.forge_rating_reminder_body, candidate.sport))
                    .setContentIntent(pending).setAutoCancel(true)
                    .setCategory(NotificationCompat.CATEGORY_REMINDER).build()
                notifications.notify(candidate.id, 0, notification)
            }
        }
    }
}

/** An activity intent opens the specific session after the ordinary terms and onboarding gates. */
object SessionRatingNavigation {
    const val EXTRA = "noop.sessionRatingId"
    val sessionId = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    fun accept(intent: android.content.Intent?) {
        intent?.getStringExtra(EXTRA)?.takeIf { it.isNotBlank() && it.length <= 1024 }?.let {
            sessionId.value = it
            intent.removeExtra(EXTRA)
        }
    }
}
