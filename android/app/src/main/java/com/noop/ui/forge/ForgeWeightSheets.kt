package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreWeight
import com.noop.notif.BodyMeasurementReminder
import com.noop.ui.UnitSystem
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.TextStyle
import java.util.Locale

/**
 * Fork (DX23876), owner decisions 2026-11-26: the weight page's three editors as iOS's sheets: a weigh-in with its
 * date and note, a date the wearer wants a forecast for, and the page's settings with the weigh-in reminder.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun WeighInEditor(draft: WeighInDraft, fmt: WeightFormat, onCancel: () -> Unit,
                           onSave: (Double, Instant, String?) -> Unit, onDelete: (() -> Unit)?) {
    val colors = Forge.colors
    var text by remember { mutableStateOf(draft.kg?.let { fmt.number(it) } ?: "") }
    var note by remember { mutableStateOf(draft.note ?: "") }
    var day by remember { mutableStateOf(draft.at.atZone(ZoneId.systemDefault()).toLocalDate()) }
    var picking by remember { mutableStateOf(false) }
    val kg = weightForStore(text, fmt.units)?.takeIf { it in 20.0..400.0 }
    SettingsColumn {
        PageTitle(stringResource(if (draft.id == null) R.string.wt_log else R.string.wt_edit_weigh_in), onCancel)
        ForgeCard(Modifier.fillMaxWidth()) {
            OutlinedTextField(value = text, onValueChange = { v -> text = v.filter { it.isDigit() || it == '.' || it == ',' }.take(6) },
                              singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                              suffix = { Text(fmt.unit) }, modifier = Modifier.fillMaxWidth(), colors = forgeFieldColors(),
                              label = { Text(stringResource(R.string.wt_weight)) })
            Spacer(Modifier.height(ForgeMetrics.space3))
            Row(Modifier.fillMaxWidth().clickable { picking = true }.padding(vertical = ForgeMetrics.space2),
                verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.wt_date), style = Forge.type.body, color = colors.text, modifier = Modifier.weight(1f))
                Text(day.format(fmt.dayMonthYear), style = Forge.type.body, color = WEIGHT_TINT.resolve())
            }
            OutlinedTextField(value = note, onValueChange = { note = it.take(200) }, modifier = Modifier.fillMaxWidth(),
                              colors = forgeFieldColors(), label = { Text(stringResource(R.string.wt_note)) })
            if (text.isNotBlank() && kg == null) {
                Text(stringResource(R.string.wt_weight_invalid), style = Forge.type.footnote,
                     color = ForgeTokens.Color.systemOrange.resolve())
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            onDelete?.let { TextButton(onClick = it) { Text(stringResource(R.string.forge_body_delete), color = ForgeTokens.Color.systemRed.resolve()) } }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onCancel) { Text(stringResource(R.string.forge_lay_cancel)) }
            TextButton(enabled = kg != null, onClick = {
                // A weigh-in on another day keeps the time it would have had; today's is now.
                val now = Instant.now()
                val at = if (day == LocalDate.now()) now
                         else day.atTime(draft.at.atZone(ZoneId.systemDefault()).toLocalTime()).atZone(ZoneId.systemDefault()).toInstant()
                kg?.let { onSave(it, at, note.trim().ifEmpty { null }) }
            }) { Text(stringResource(R.string.forge_lay_save), fontWeight = FontWeight.SemiBold) }
        }
    }
    if (picking) ForgeDayPicker(day, onPick = { day = it }, onDismiss = { picking = false })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun EventEditor(draft: EventDraft, onCancel: () -> Unit, onSave: (String, String) -> Unit, onDelete: (() -> Unit)?) {
    val colors = Forge.colors
    var name by remember { mutableStateOf(draft.name) }
    var day by remember { mutableStateOf(draft.day) }
    var picking by remember { mutableStateOf(false) }
    val fmt = rememberWeightFormat(com.noop.ui.UnitPrefs.system(LocalContext.current))
    SettingsColumn {
        PageTitle(stringResource(if (draft.id == null) R.string.wt_new_date else R.string.wt_edit_date), onCancel)
        ForgeCard(Modifier.fillMaxWidth()) {
            OutlinedTextField(value = name, onValueChange = { name = it.take(60) }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                              colors = forgeFieldColors(), label = { Text(stringResource(R.string.wt_date_name)) })
            Spacer(Modifier.height(ForgeMetrics.space3))
            Row(Modifier.fillMaxWidth().clickable { picking = true }.padding(vertical = ForgeMetrics.space2),
                verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.wt_date), style = Forge.type.body, color = colors.text, modifier = Modifier.weight(1f))
                Text(day.format(fmt.dayMonthYear), style = Forge.type.body, color = WEIGHT_TINT.resolve())
            }
            Text(stringResource(R.string.wt_date_footer), style = Forge.type.footnote, color = colors.textSecondary)
        }
        Row(Modifier.fillMaxWidth()) {
            onDelete?.let { TextButton(onClick = it) { Text(stringResource(R.string.wt_delete_date), color = ForgeTokens.Color.systemRed.resolve()) } }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onCancel) { Text(stringResource(R.string.forge_lay_cancel)) }
            TextButton(enabled = name.isNotBlank(), onClick = { onSave(name.trim(), day.toString()) }) {
                Text(stringResource(R.string.forge_lay_save), fontWeight = FontWeight.SemiBold)
            }
        }
    }
    if (picking) {
        val state = androidx.compose.material3.rememberDatePickerState(
            initialSelectedDateMillis = day.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
        androidx.compose.material3.DatePickerDialog(
            onDismissRequest = { picking = false },
            confirmButton = {
                TextButton(onClick = {
                    state.selectedDateMillis?.let { day = Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate() }
                    picking = false
                }) { Text(stringResource(R.string.forge_lay_save)) }
            },
            dismissButton = { TextButton(onClick = { picking = false }) { Text(stringResource(R.string.forge_lay_cancel)) } },
        ) { androidx.compose.material3.DatePicker(state = state) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun WeightSettingsPage(settings: CoreWeight.Settings, rates: CoreWeight.Rates?, fmt: WeightFormat, onBack: () -> Unit,
                                onSave: (CoreWeight.Settings) -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    var s by remember { mutableStateOf(settings) }
    var manualOn by remember { mutableStateOf(settings.manualWishKgPerWeek != null) }
    var manualKg by remember { mutableStateOf(settings.manualWishKgPerWeek ?: -0.5) }
    var reminderOn by remember { mutableStateOf(BodyMeasurementReminder.dailyEnabled(context)) }
    var reminderDays by remember { mutableStateOf(BodyMeasurementReminder.dailyWeekdays(context)) }
    var denied by remember { mutableStateOf(false) }
    var pickingTime by remember { mutableStateOf(false) }
    val minutes0 = BodyMeasurementReminder.dailyMinutes(context)
    var minutes by remember { mutableStateOf(minutes0) }
    SettingsColumn {
        PageTitle(stringResource(R.string.wt_settings), onBack)
        ForgeTitledCard(stringResource(R.string.wt_forecast), stringResource(R.string.wt_settings_forecast_footer)) {
            Text(stringResource(R.string.wt_start_from), style = Forge.type.footnote, color = colors.textSecondary)
            ForgeSegmented(listOf(stringResource(R.string.wt_basis_trend_short), stringResource(R.string.wt_basis_low_short)),
                           if (s.basis == "tenDayLow") 1 else 0, Modifier.fillMaxWidth()) {
                s = s.copy(basis = if (it == 1) "tenDayLow" else "trend")
            }
            Spacer(Modifier.height(ForgeMetrics.space3))
            Text(stringResource(R.string.wt_rate), style = Forge.type.footnote, color = colors.textSecondary)
            val modes = listOf("current", "overall", "wish")
            ForgeSegmented(listOf(stringResource(R.string.wt_rate_current), stringResource(R.string.wt_rate_overall),
                                  stringResource(R.string.wt_rate_plan)), modes.indexOf(s.rateMode).coerceAtLeast(0),
                           Modifier.fillMaxWidth()) { s = s.copy(rateMode = modes[it]) }
            Spacer(Modifier.height(ForgeMetrics.space3))
            Text(stringResource(R.string.wt_current_over), style = Forge.type.footnote, color = colors.textSecondary)
            val windows = listOf(14, 28, 56)
            ForgeSegmented(windows.map { pluralStringResource(R.plurals.wt_days, it, it) }, windows.indexOf(s.rateWindowDays).coerceAtLeast(0),
                           Modifier.fillMaxWidth()) { s = s.copy(rateWindowDays = windows[it]) }
        }
        ForgeTitledCard(stringResource(R.string.wt_plan_rate), stringResource(R.string.wt_plan_rate_footer)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.wt_own_plan_rate), style = Forge.type.body, color = colors.text, modifier = Modifier.weight(1f))
                Switch(checked = manualOn, onCheckedChange = { manualOn = it }, colors = forgeSwitchColors())
            }
            if (manualOn) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = { manualKg = ((manualKg - 0.1).coerceAtLeast(-1.5) * 10).let { Math.round(it) / 10.0 } }) { Text("−") }
                    Text(stringResource(R.string.wt_per_week, fmt.signed(manualKg)), style = Forge.type.headline, color = colors.text,
                         modifier = Modifier.weight(1f))
                    TextButton(onClick = { manualKg = ((manualKg + 0.1).coerceAtMost(1.0) * 10).let { Math.round(it) / 10.0 } }) { Text("+") }
                }
            }
        }
        ForgeTitledCard(stringResource(R.string.wt_stops), null) {
            val steps = listOf<Double?>(null, 2.0, 5.0, 10.0)
            ForgeSegmented(steps.map { it?.let { kg -> fmt.mass(kg).replace(",0", "").replace(".0", "") } ?: stringResource(R.string.wt_automatic) },
                           steps.indexOf(s.milestoneStepKg).coerceAtLeast(0), Modifier.fillMaxWidth()) { s = s.copy(milestoneStepKg = steps[it]) }
        }
        ForgeTitledCard(stringResource(R.string.wt_cards), null) {
            listOf("milestones" to R.string.wt_stops, "forecast" to R.string.wt_forecast, "events" to R.string.wt_dates,
                   "changes" to R.string.wt_change, "week" to R.string.wt_this_week, "chart" to R.string.wt_history_chart,
                   "reports" to R.string.wt_reports).forEach { (key, label) ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(label), style = Forge.type.body, color = colors.text, modifier = Modifier.weight(1f))
                    Switch(checked = s.shows(key), colors = forgeSwitchColors(), onCheckedChange = { on ->
                        s = s.copy(hiddenCards = s.hiddenCards.filter { it != key } + if (on) emptyList() else listOf(key))
                    })
                }
            }
        }
        ForgeTitledCard(stringResource(R.string.wt_reminder), stringResource(if (denied) R.string.body_reminder_denied else R.string.wt_reminder_footer)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.wt_remind_me), style = Forge.type.body, color = colors.text, modifier = Modifier.weight(1f))
                Switch(checked = reminderOn, onCheckedChange = { reminderOn = it }, colors = forgeSwitchColors())
            }
            if (reminderOn) {
                Row(Modifier.fillMaxWidth().clickable { pickingTime = true }.padding(vertical = ForgeMetrics.space2),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.wt_time), style = Forge.type.body, color = colors.text, modifier = Modifier.weight(1f))
                    Text("%02d:%02d".format(minutes / 60, minutes % 60), style = Forge.type.body, color = WEIGHT_TINT.resolve())
                }
                // Monday first; iOS numbers the weekdays 1 = Sunday ... 7 = Saturday, as the stored set does.
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(2, 3, 4, 5, 6, 7, 1).forEach { d ->
                        val on = reminderDays.isEmpty() || d in reminderDays
                        val label = DayOfWeek.of(((d + 5) % 7) + 1).getDisplayName(TextStyle.NARROW, Locale.getDefault())
                        Box(Modifier.weight(1f).height(32.dp)
                                .background(if (on) WEIGHT_TINT.resolve().copy(alpha = 0.18f) else colors.inset, RoundedCornerShape(8.dp))
                                .clickable {
                                    val next = (if (reminderDays.isEmpty()) (1..7).toSet() else reminderDays).toMutableSet()
                                    if (d in next) next.remove(d) else next.add(d)
                                    reminderDays = if (next.size == 7) emptySet() else next
                                }, contentAlignment = Alignment.Center) {
                            Text(label, style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold),
                                 color = if (on) WEIGHT_TINT.resolve() else colors.textSecondary)
                        }
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth()) {
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onBack) { Text(stringResource(R.string.forge_lay_cancel)) }
            TextButton(onClick = {
                BodyMeasurementReminder.setDaily(context, minutes, reminderDays)
                if (reminderOn != BodyMeasurementReminder.dailyEnabled(context)) {
                    denied = !BodyMeasurementReminder.setEnabled(context, reminderOn, daily = true)
                }
                if (!denied) onSave(s.copy(manualWishKgPerWeek = if (manualOn) Math.round(manualKg * 10) / 10.0 else null))
            }) { Text(stringResource(R.string.wt_done), fontWeight = FontWeight.SemiBold) }
        }
    }
    if (pickingTime) {
        val state = rememberTimePickerState(initialHour = minutes / 60, initialMinute = minutes % 60,
                                            is24Hour = android.text.format.DateFormat.is24HourFormat(context))
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { pickingTime = false },
            confirmButton = { TextButton(onClick = { minutes = state.hour * 60 + state.minute; pickingTime = false }) {
                Text(stringResource(R.string.forge_lay_save)) } },
            dismissButton = { TextButton(onClick = { pickingTime = false }) { Text(stringResource(R.string.forge_lay_cancel)) } },
            text = { TimePicker(state = state) },
        )
    }
}
