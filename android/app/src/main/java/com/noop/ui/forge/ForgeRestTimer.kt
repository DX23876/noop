package com.noop.ui.forge

import android.content.Context
import android.media.RingtoneManager
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import com.noop.R
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.delay
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import android.annotation.SuppressLint
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.ui.platform.LocalLifecycleOwner

/**
 * Fork (DX23876), Android parity plan 2.3: the running rest after a completed set, as iOS's native logger draws it
 * (`LiftSessionView.restBand`): an amber "Rest period" band under the set that ended, the time left, −15 s, +15 s and
 * Skip. When it ends the phone plays a sound and vibrates, each as the Training settings say (the Apple keys); with
 * "Buzz the strap 5 seconds early" on, the strap buzzes three times five seconds before the end.
 */
internal object RestTimerPrefs {
    const val SOUND = "training.timerSound"
    const val HAPTICS = "training.timerHaptics"
    const val KEEP_SCREEN_ON = "workoutKeepScreenOn"
    const val STRAP_BUZZ = "haptics.liftRest"
    const val FEEDBACK = "training.timerFeedback"
    const val STRAP_DOUBLE_TAP = "training.strapDoubleTapLogsSet"
    fun feedback(c: Context) = NoopPrefs.of(c).getBoolean(FEEDBACK, true)
    fun strapDoubleTap(c: Context) = NoopPrefs.of(c).getBoolean(STRAP_DOUBLE_TAP, true)
    fun sound(c: Context) = NoopPrefs.of(c).getBoolean(SOUND, true)
    fun haptics(c: Context) = NoopPrefs.of(c).getBoolean(HAPTICS, true)
    fun keepScreenOn(c: Context) = NoopPrefs.of(c).getBoolean(KEEP_SCREEN_ON, false)
    // In HapticPrefs, the store `AppViewModel.buzz(loops, gate)` checks, so one switch decides.
    fun strapBuzz(c: Context) = com.noop.ui.HapticPrefs.enabled(c, STRAP_BUZZ)
    fun setStrapBuzz(c: Context, on: Boolean) = com.noop.ui.HapticPrefs.setEnabled(c, STRAP_BUZZ, on)
}

/** The rest in progress: which set it follows, when it started and ends (epoch ms), and the time left while paused. */
internal data class RunningRest(val setId: String, val endsAtMs: Long, val startedAtMs: Long = System.currentTimeMillis(),
                                val pausedLeftMs: Long? = null)

/**
 * The running rest, pinned above the bottom edge so it never scrolls away while logging (iOS `WorkoutRestDock`):
 * "Rest" over the time left, −15, +15, pause and Skip, and the share of the rest gone as a bar.
 */
@Composable
internal fun RestDock(rest: RunningRest, onChange: (RunningRest?) -> Unit, onStrapBuzz: () -> Unit,
                      modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var buzzed by remember(rest.setId) { androidx.compose.runtime.mutableStateOf(false) }
    val paused = rest.pausedLeftMs != null
    // The notification that announces the end while NOOP is in the background (`TrainingRestNotification`).
    DisposableEffect(rest) {
        if (!paused) RestNotification.schedule(context, rest.endsAtMs)
        // A rest changed, skipped or left early withdraws it; one that ran out keeps its alarm, which fires now.
        onDispose { if (paused || System.currentTimeMillis() < rest.endsAtMs - 500) RestNotification.cancel(context) }
    }
    LaunchedEffect(rest) {
        while (!paused) {
            now = System.currentTimeMillis()
            val left = rest.endsAtMs - now
            if (!buzzed && left in 1..5_000 && RestTimerPrefs.strapBuzz(context)) { buzzed = true; onStrapBuzz() }
            if (left <= 0) { restEnded(context); onChange(null); break }
            delay(250)
        }
    }
    val leftMs = rest.pausedLeftMs ?: (rest.endsAtMs - now)
    val totalMs = (rest.endsAtMs - rest.startedAtMs).coerceAtLeast(1)
    val accent = Forge.colors.accent
    Column(modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.screenPadding).padding(bottom = ForgeMetrics.space2)
               .background(Forge.colors.surfaceTop, RoundedCornerShape(20.dp))
               .border(1.dp, Forge.colors.border, RoundedCornerShape(20.dp))
               .padding(16.dp),
           verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.forge_lg_rest), style = Forge.type.caption, color = Forge.colors.textSecondary)
                Text(clock((leftMs / 1000).coerceAtLeast(0)), color = Forge.colors.text,
                     style = Forge.type.title1.copy(fontSize = 30.sp, fontFeatureSettings = "tnum"),
                     modifier = Modifier.semantics { contentDescription = context.getString(R.string.forge_lg_rest_remaining) })
            }
            Text("−15", style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = accent,
                 modifier = Modifier.clickable {
                     onChange(if (paused) rest.copy(pausedLeftMs = (rest.pausedLeftMs!! - 15_000).coerceAtLeast(0))
                              else rest.copy(endsAtMs = maxOf(System.currentTimeMillis(), rest.endsAtMs - 15_000)))
                 }.semantics { contentDescription = context.getString(R.string.forge_lg_minus15) })
            Text("+15", style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = accent,
                 modifier = Modifier.clickable {
                     onChange(if (paused) rest.copy(pausedLeftMs = rest.pausedLeftMs!! + 15_000, endsAtMs = rest.endsAtMs + 15_000)
                              else rest.copy(endsAtMs = rest.endsAtMs + 15_000))
                 }.semantics { contentDescription = context.getString(R.string.forge_lg_plus15) })
            Icon(if (paused) Icons.Rounded.PlayArrow else Icons.Rounded.Pause,
                 stringResource(if (paused) R.string.forge_lg_resume else R.string.forge_lg_pause), tint = accent,
                 modifier = Modifier.size(22.dp).clickable {
                     val t = System.currentTimeMillis()
                     // Resuming keeps the rest's length: it ends the time left from now and started that length before.
                     onChange(if (paused) (t + rest.pausedLeftMs!!).let { end -> rest.copy(endsAtMs = end, startedAtMs = end - totalMs, pausedLeftMs = null) }
                              else rest.copy(pausedLeftMs = (rest.endsAtMs - t).coerceAtLeast(0)))
                 })
            Text(stringResource(R.string.forge_lg_skip), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = Color.White,
                 modifier = Modifier.background(accent, RoundedCornerShape(50)).clickable { onChange(null) }
                     .padding(horizontal = 14.dp, vertical = 7.dp))
        }
        LoggerBar((1f - leftMs.toFloat() / totalMs).coerceIn(0f, 1f), accent)
    }
}

/** Minutes and seconds left, as the rest clock shows them. */
private fun clock(seconds: Long): String = "%d:%02d".format(seconds / 60, seconds % 60)

/** iOS: while the workout is open a timer ends with the sound only, no banner; vibration as set. */
private fun restEnded(context: Context) {
    // In the background the notification carries the sound; the band only speaks while the logger is seen.
    if (!RestNotification.loggerOnScreen) return
    if (RestTimerPrefs.sound(context)) runCatching {
        RingtoneManager.getRingtone(context, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))?.play()
    }
    if (RestTimerPrefs.haptics(context)) runCatching {
        @Suppress("DEPRECATION")
        val v = context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        v.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 180, 120, 180), -1))
    }
}

/**
 * The end of a rest announced by the system while the logger is not on screen (iOS `TrainingRestNotification`): an
 * alarm at the end time posts "Rest complete" with the sound as Settings › Training says. With the logger on screen
 * the band itself plays the sound and vibrates, so no notification is posted then.
 */
internal object RestNotification {
    private const val CHANNEL_ID = "training_rest"
    private const val CHANNEL_SILENT_ID = "training_rest_silent"
    private const val NOTIFICATION_ID = 7310
    @Volatile var loggerOnScreen = false

    private fun pending(context: Context) = PendingIntent.getBroadcast(context, NOTIFICATION_ID,
        Intent(context, RestEndReceiver::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    fun schedule(context: Context, atMs: Long) {
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        runCatching {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()) {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending(context))
            } else {
                alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending(context))
            }
        }
    }

    fun cancel(context: Context) {
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending(context))
    }

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled()
    fun post(context: Context) {
        if (loggerOnScreen || !RestTimerPrefs.feedback(context) ||
            !NotificationManagerCompat.from(context).areNotificationsEnabled()) return
        val sound = RestTimerPrefs.sound(context)
        val channel = if (sound) CHANNEL_ID else CHANNEL_SILENT_ID
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val c = NotificationChannel(channel, context.getString(R.string.forge_rest_channel), NotificationManager.IMPORTANCE_HIGH)
            if (!sound) c.setSound(null, null)
            c.enableVibration(RestTimerPrefs.haptics(context))
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(c)
        }
        val n = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(context.getString(R.string.forge_rest_done_title))
            .setContentText(context.getString(R.string.forge_rest_done_body))
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(PendingIntent.getActivity(context, NOTIFICATION_ID, com.noop.ui.appLaunchIntent(context),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            .setAutoCancel(true)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, n) }
    }
}

class RestEndReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = RestNotification.post(context)
}

/** Marks the logger as seen while its page is resumed, so a rest ending then needs no notification. */
@Composable
internal fun TrackLoggerOnScreen() {
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> RestNotification.loggerOnScreen = true
                Lifecycle.Event.ON_PAUSE -> RestNotification.loggerOnScreen = false
                else -> Unit
            }
        }
        owner.lifecycle.addObserver(observer)
        RestNotification.loggerOnScreen = owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
        onDispose { owner.lifecycle.removeObserver(observer); RestNotification.loggerOnScreen = false }
    }
}

/** Keeps the display awake while the session page is open, when Settings › Training asks for it. */
@Composable
internal fun KeepScreenOnWhileLogging() {
    val context = LocalContext.current
    val view = LocalView.current
    DisposableEffect(Unit) {
        val on = RestTimerPrefs.keepScreenOn(context)
        if (on) view.keepScreenOn = true
        onDispose { if (on) view.keepScreenOn = false }
    }
}
