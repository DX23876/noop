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

/** The rest in progress: when it ends, in epoch milliseconds, and which set it follows. */
internal data class RunningRest(val setId: String, val endsAtMs: Long)

@Composable
internal fun RestBand(rest: RunningRest, onChange: (RunningRest?) -> Unit, onStrapBuzz: () -> Unit) {
    val context = LocalContext.current
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var buzzed by remember(rest.setId) { androidx.compose.runtime.mutableStateOf(false) }
    // The notification that announces the end while NOOP is in the background (`TrainingRestNotification`).
    DisposableEffect(rest) {
        RestNotification.schedule(context, rest.endsAtMs)
        // A rest changed, skipped or left early withdraws it; one that ran out keeps its alarm, which fires now.
        onDispose { if (System.currentTimeMillis() < rest.endsAtMs - 500) RestNotification.cancel(context) }
    }
    LaunchedEffect(rest) {
        while (true) {
            now = System.currentTimeMillis()
            val left = rest.endsAtMs - now
            if (!buzzed && left in 1..5_000 && RestTimerPrefs.strapBuzz(context)) { buzzed = true; onStrapBuzz() }
            if (left <= 0) { restEnded(context); onChange(null); break }
            delay(250)
        }
    }
    val leftS = ((rest.endsAtMs - now) / 1000).coerceAtLeast(0)
    val amber = ForgeTokens.Color.systemOrange.resolve()
    Column(Modifier.fillMaxWidth().background(amber.copy(alpha = 0.14f), RoundedCornerShape(dp12))
               .padding(horizontal = ForgeMetrics.space3, vertical = ForgeMetrics.space2),
           verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
        Text(stringResource(R.string.forge_rest_period).uppercase(), style = Forge.type.overline, color = amber)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(clock(leftS), style = Forge.type.title2, color = Forge.colors.text,
                 modifier = Modifier.weight(1f))
            TextButton(onClick = { onChange(rest.copy(endsAtMs = maxOf(System.currentTimeMillis(), rest.endsAtMs - 15_000))) }) {
                Text("−15", color = amber)
            }
            TextButton(onClick = { onChange(rest.copy(endsAtMs = rest.endsAtMs + 15_000)) }) { Text("+15", color = amber) }
            TextButton(onClick = { onChange(null) }) { Text(stringResource(R.string.forge_rest_skip), color = amber) }
        }
    }
}

private val dp12 = androidx.compose.ui.unit.Dp(12f)

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
