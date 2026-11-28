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
import com.noop.core.CoreRead
import com.noop.core.CoreTrainingGuidance
import com.noop.core.TrainingGuidancePrefs
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.appLaunchIntent
import com.noop.ui.forge.dismissedTrainingWorkouts
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Calendar

/**
 * The morning advice as one notification (Training Load plan, phase 2, Q16 and Q25), as the iPhone's
 * `MorningAdviceNotifier`: only when switched on, once a day, as soon as last night is scored, and never while the
 * coach's morning brief is on, which opens with the same advice. Default off. The advice itself is the core's.
 */
object MorningAdviceNotifier {
    private const val CHANNEL = "noop_morning_advice"
    private const val ID = 4221

    suspend fun postIfDue(context: Context) = withContext(Dispatchers.IO) {
        runCatching {
            val prefs = NoopPrefs.of(context)
            if (!prefs.getBoolean(TrainingGuidancePrefs.MORNING_ADVICE, false)) return@runCatching
            if (com.noop.ui.CoachBriefSettings.from(context).enabled) return@runCatching
            val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
            if (hour < 5 || hour >= 12) return@runCatching
            // Already posted today: nothing to read.
            if (prefs.getString(TrainingGuidancePrefs.MORNING_ADVICE_DAY, null) == java.time.LocalDate.now().toString()) {
                return@runCatching
            }
            CoreRead.open(context)
            val profile = ProfileStore.from(context)
            val g = CoreTrainingGuidance.read(context, profile.hrMax.toDouble(), profile.sex, dismissedTrainingWorkouts(context))
                ?: return@runCatching
            if (g.advice.state != "ready" || prefs.getString(TrainingGuidancePrefs.MORNING_ADVICE_DAY, null) == g.today) {
                return@runCatching
            }
            prefs.edit().putString(TrainingGuidancePrefs.MORNING_ADVICE_DAY, g.today).apply()
            post(context, g.advice)
        }
    }

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    private fun post(context: Context, a: CoreTrainingGuidance.Advice) {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
        ensureChannel(context)
        val stance = context.getString(when (a.stance) {
            "push" -> R.string.forge_tg_push
            "easy" -> R.string.forge_tg_easy
            "rest" -> R.string.forge_tg_rest
            else -> R.string.forge_tg_steady
        })
        val body = context.getString(when (a.reason) {
            "illness" -> R.string.forge_tg_reason_illness
            "strainedRecovery" -> R.string.forge_tg_reason_strained
            "lowCharge" -> R.string.forge_tg_reason_low_charge
            "strengthWellAbove" -> R.string.forge_tg_reason_strength_high
            "cardioWellAbove" -> R.string.forge_tg_reason_cardio_high
            "bothWellAbove" -> R.string.forge_tg_reason_both_high
            "planned" -> R.string.forge_tg_reason_planned
            "plannedShorter" -> R.string.forge_tg_reason_planned_shorter
            "behindGoal" -> R.string.forge_tg_reason_behind
            "noNight" -> R.string.forge_tg_reason_no_night
            else -> R.string.forge_tg_reason_steady
        })
        val open = PendingIntent.getActivity(context, 5, appLaunchIntent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(stance).setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(open).setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS).setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        NotificationManagerCompat.from(context).notify(ID, n)
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL) != null) return
            mgr.createNotificationChannel(NotificationChannel(CHANNEL, context.getString(R.string.forge_tg_morning_title),
                NotificationManager.IMPORTANCE_LOW))
        }
    }
}
