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
    if (RestTimerPrefs.sound(context)) runCatching {
        RingtoneManager.getRingtone(context, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))?.play()
    }
    if (RestTimerPrefs.haptics(context)) runCatching {
        @Suppress("DEPRECATION")
        val v = context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        v.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 180, 120, 180), -1))
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
