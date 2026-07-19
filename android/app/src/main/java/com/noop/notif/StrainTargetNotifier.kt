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
import com.noop.ui.NoopPrefs
import com.noop.ui.appLaunchIntent

// MARK: - Target-strain notification (#593)
//
// A single opt-in, default-OFF celebratory nudge: once per day, when the day's Effort (strain) reaches the
// LOW end of today's recovery-derived OPTIMAL strain band (the #43 coupled read), post a "reached your
// optimal strain" notification.
//
// CLEAN-ROOM: this reimplements the BEHAVIOUR only. The copy is NOOP's own — NOT WHOOP's decompiled
// strings — and the target is NOOP's own recovery→strain band (#43), not a value read off another app.
//
// The gate runs on the 0-21 coupled axis: the day's stored Effort (0-100) is converted with the shipped
// UnitFormatter.effortValue(_, WHOOP) at the call site, and the target is the optimal band's `low` (already
// 0-21). It is NOT "the instant" you cross the target — day strain is a per-analytics-pass rollup, so it
// fires on the first pass at/after the crossing. Once-per-day dedupe via a persisted day flag, the same
// crossing-dedupe idiom as ScheduledReportPolicy / BatteryAlertPolicy. Default OFF like every automation.

/** Pure, JVM-testable policy + copy for the target-strain notification — no Android types, so the decision
 *  logic is pinned by StrainTargetPolicyTest independently of the notification plumbing. */
object StrainTargetPolicy {

    /** Fire at most once per day: only when enabled, BOTH the day strain and the target are known, the day
     *  strain has reached the target, and we haven't already posted for [today]. [dayStrain] and [target]
     *  must be on the SAME axis (the 0-21 coupled axis, per the call site). A null [target] means recovery
     *  is unknown (calibrating / unscored) ⇒ no target ⇒ never fires (never guess a target). */
    fun shouldNotify(
        enabled: Boolean,
        dayStrain: Double?,
        target: Double?,
        lastNotifiedDay: String?,
        today: String,
    ): Boolean = enabled &&
        dayStrain != null && target != null &&
        dayStrain >= target &&
        lastNotifiedDay != today

    /** Title + body for the nudge. [target] is the optimal-band low on the 0-21 coupled axis. NOOP's OWN
     *  wording — the feature is reimplemented behaviour, not copied copy. */
    fun copy(target: Int): Pair<String, String> {
        val title = "Optimal strain reached"
        val body = "You've hit today's optimal strain target of $target. Nice work — your recovery earned it."
        return title to body
    }
}

object StrainTargetNotifier {
    // Reuse the daily-reports channel the scheduled reports post to (same family, same importance).
    private const val CHANNEL_ID = "noop_scheduled_reports"
    // #297: distinct id so this never silently replaces another notifier's (4208 morning, 4209 workout).
    private const val STRAIN_TARGET_NOTIF_ID = 4210

    /**
     * Post the optimal-strain nudge if enabled and not already posted [day]. [dayStrain21]/[target21] are
     * on the 0-21 coupled axis (the caller converts the stored 0-100 Effort via UnitFormatter and reads the
     * target off the #43 optimal band). No-op on every path that fails the policy, so the caller can fire it
     * freely each time the days collector republishes.
     */
    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onStrainTarget(context: Context, day: String, dayStrain21: Double?, target21: Int?) {
        if (!StrainTargetPolicy.shouldNotify(
                enabled = NoopPrefs.strainTargetEnabled(context),
                dayStrain = dayStrain21,
                target = target21?.toDouble(),
                lastNotifiedDay = NoopPrefs.reportStrainTargetDay(context),
                today = day,
            )
        ) return
        // Non-null: shouldNotify above required target != null before returning true.
        val copy = StrainTargetPolicy.copy(target21!!)
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            post(context, STRAIN_TARGET_NOTIF_ID, copy.first, copy.second)
            // Mark fired only after a successful post, so a notifications-disabled day still notifies once
            // they're re-enabled while the same day still shows the reached target.
            NoopPrefs.setReportStrainTargetDay(context, day)
        }
    }

    @SuppressLint("MissingPermission")
    private fun post(context: Context, id: Int, title: String, body: String) {
        val openApp = PendingIntent.getActivity(
            context, 3,
            appLaunchIntent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        NotificationManagerCompat.from(context).notify(id, n)
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Daily reports",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "A morning recap and post-workout summary, after your strap syncs."
                },
            )
        }
    }
}
