package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.analytics.Sport

/**
 * Fork (DX23876), Android parity 2026-11-12: the workout's voice and warning choices, as iOS's
 * `WorkoutFeedbackSettingsView` opened from the start sheet. Voice feedback with its distance and time intervals and
 * the speaker, and the pace or speed warnings with their range. Zone warnings wait for a target zone on Android.
 */
@Composable
fun WorkoutFeedbackDialog(sport: Sport, gpsEnabled: Boolean, onDismiss: () -> Unit) {
    val c = LocalContext.current
    val imperial = UnitPrefs.distanceSystem(c) == UnitSystem.IMPERIAL
    val usesSpeed = remember(sport) {
        com.noop.core.SwiftCore.call("workout.voice.sport", org.json.JSONObject().put("sport", sport.name).toString())
            ?.let { runCatching { org.json.JSONObject(it).optBoolean("usesSpeed") }.getOrNull() } ?: false
    }
    var voice by remember { mutableStateOf(WorkoutVoicePrefs.enabled(c)) }
    var speaker by remember { mutableStateOf(WorkoutVoicePrefs.speaker(c)) }
    var distance by remember { mutableDoubleStateOf(WorkoutVoicePrefs.distanceInterval(c)) }
    var time by remember { mutableDoubleStateOf(WorkoutVoicePrefs.timeInterval(c)) }
    var motion by remember { mutableStateOf(WorkoutVoicePrefs.motionAlert(c)) }
    var fast by remember { mutableDoubleStateOf(WorkoutVoicePrefs.fastPace(c)) }
    var slow by remember { mutableDoubleStateOf(WorkoutVoicePrefs.slowPace(c)) }
    var low by remember { mutableDoubleStateOf(WorkoutVoicePrefs.lowSpeed(c)) }
    var high by remember { mutableDoubleStateOf(WorkoutVoicePrefs.highSpeed(c)) }
    fun clock(s: Double) = "%d:%02d".format(s.toInt() / 60, s.toInt() % 60)
    val unit = if (imperial) "mi" else "km"
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.wv_voice)) },
        text = {
            Column(Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SwitchLine(stringResource(R.string.wv_voice), voice) { voice = it; WorkoutVoicePrefs.setBool(c, WorkoutVoicePrefs.ENABLED, it) }
                if (voice) {
                    if (gpsEnabled) Choice(stringResource(R.string.wv_distance), listOf(0.0, 0.5, 1.0, 2.0), distance,
                        { v -> if (v == 0.0) c.getString(R.string.wv_time_only)
                               else UnitFormatter.distanceFromMeters(v * (if (imperial) 1609.344 else 1000.0), UnitPrefs.distanceSystem(c)) }) {
                        distance = it; WorkoutVoicePrefs.setNumber(c, WorkoutVoicePrefs.DISTANCE_INTERVAL, it)
                    }
                    Choice(stringResource(R.string.wv_time_ann), listOf(300.0, 600.0, 900.0), time, { v -> c.getString(R.string.forge_tw_min, (v / 60).toInt()) }) {
                        time = it; WorkoutVoicePrefs.setNumber(c, WorkoutVoicePrefs.TIME_INTERVAL, it)
                    }
                    SwitchLine(stringResource(R.string.wv_speaker), speaker) { speaker = it; WorkoutVoicePrefs.setBool(c, WorkoutVoicePrefs.SPEAKER, it) }
                }
                Text(stringResource(R.string.wv_voice_note), style = NoopType.caption, color = Palette.textSecondary)
                if (gpsEnabled) {
                    Text(stringResource(R.string.wv_warnings), style = NoopType.headline, color = Palette.textPrimary,
                         modifier = Modifier.padding(top = 8.dp))
                    SwitchLine(stringResource(R.string.wv_motion), motion) { motion = it; WorkoutVoicePrefs.setBool(c, WorkoutVoicePrefs.MOTION_ALERT, it) }
                    if (motion) {
                        if (usesSpeed) {
                            val sys = UnitPrefs.distanceSystem(c)
                            Stepper(stringResource(R.string.wv_min_speed, UnitFormatter.speedFromKilometersPerHour(low, sys) ?: ""),
                                    { low = (low - 1).coerceIn(1.0, 100.0); WorkoutVoicePrefs.setNumber(c, WorkoutVoicePrefs.LOW_SPEED, low) },
                                    { low = (low + 1).coerceIn(1.0, 100.0); WorkoutVoicePrefs.setNumber(c, WorkoutVoicePrefs.LOW_SPEED, low) })
                            Stepper(stringResource(R.string.wv_max_speed, UnitFormatter.speedFromKilometersPerHour(high, sys) ?: ""),
                                    { high = (high - 1).coerceIn(1.0, 100.0); WorkoutVoicePrefs.setNumber(c, WorkoutVoicePrefs.HIGH_SPEED, high) },
                                    { high = (high + 1).coerceIn(1.0, 100.0); WorkoutVoicePrefs.setNumber(c, WorkoutVoicePrefs.HIGH_SPEED, high) })
                        } else {
                            Stepper(stringResource(R.string.wv_fast_pace, clock(fast), unit),
                                    { fast = (fast - 30).coerceIn(120.0, 1800.0); WorkoutVoicePrefs.setNumber(c, WorkoutVoicePrefs.FAST_PACE, fast) },
                                    { fast = (fast + 30).coerceIn(120.0, 1800.0); WorkoutVoicePrefs.setNumber(c, WorkoutVoicePrefs.FAST_PACE, fast) })
                            Stepper(stringResource(R.string.wv_slow_pace, clock(slow), unit),
                                    { slow = (slow - 30).coerceIn(120.0, 1800.0); WorkoutVoicePrefs.setNumber(c, WorkoutVoicePrefs.SLOW_PACE, slow) },
                                    { slow = (slow + 30).coerceIn(120.0, 1800.0); WorkoutVoicePrefs.setNumber(c, WorkoutVoicePrefs.SLOW_PACE, slow) })
                        }
                        val invalid = if (usesSpeed) low > high else fast > slow
                        if (invalid) Text(stringResource(R.string.wv_invalid), style = NoopType.caption, color = Palette.statusWarning)
                    }
                    Text(stringResource(R.string.wv_warnings_note), style = NoopType.caption, color = Palette.textSecondary)
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.forge_th_done)) } },
    )
}

@Composable
private fun SwitchLine(title: String, on: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        Switch(checked = on, onCheckedChange = onChange)
    }
}

@Composable
private fun Choice(title: String, options: List<Double>, selected: Double, label: (Double) -> String, onPick: (Double) -> Unit) {
    Column {
        Text(title, style = NoopType.body, color = Palette.textPrimary)
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            options.forEach { v ->
                TextButton(onClick = { onPick(v) }) {
                    Text(label(v), color = if (v == selected) Palette.accent else Palette.textSecondary)
                }
            }
        }
    }
}

@Composable
private fun Stepper(text: String, minus: () -> Unit, plus: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(text, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        TextButton(onClick = minus) { Text("−") }
        Spacer(Modifier.padding(2.dp))
        TextButton(onClick = plus) { Text("+") }
    }
}
