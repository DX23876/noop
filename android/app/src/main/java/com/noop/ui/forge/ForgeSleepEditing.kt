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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.TimeInput
import androidx.compose.material3.TimePickerDefaults
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.noop.R
import com.noop.core.CoreRead
import com.noop.data.DismissedSleep
import com.noop.data.SleepSession
import com.noop.ui.AppViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId

/*
 * Fork (DX23876), Forge parity 2026-11: the new design's night editing on Android, as iOS's `SleepNightEditor` on its
 * Sleep tab: correct the bed and wake times of the night on screen or delete it, with an undo, and the deleted sleep
 * windows that can be recomputed or hidden (`DeletedSleepNightsSection`). The writes are the view model's existing
 * ones (`updateSleepGroupTimes`, `deleteSleepSession`, `recomputeDeletedSleep`), which re-score the day as iOS does.
 */

/** The stored blocks a core night is made of: the merged sessions overlapping its span, its naps left out. */
internal suspend fun nightSessions(viewModel: AppViewModel, night: CoreRead.Night): List<SleepSession> =
    withContext(Dispatchers.IO) {
        runCatching {
            viewModel.repo.sleepSessionsUnion(viewModel.activeStrapId, night.startTs - 12 * 3600, night.endTs + 12 * 3600)
                .filter { s -> (s.startTsAdjusted ?: s.startTs) < night.endTs && s.endTs > night.startTs }
        }.getOrDefault(emptyList())
    }

/** The bed and wake times of [night] to correct, or the night to delete, as iOS's "Edit sleep times" sheet. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SleepEditDialog(night: CoreRead.Night, onSave: (Long, Long) -> Unit, onDelete: () -> Unit, onDismiss: () -> Unit) {
    val colors = Forge.colors
    val zone = ZoneId.systemDefault()
    val start = Instant.ofEpochSecond(night.startTs).atZone(zone)
    val end = Instant.ofEpochSecond(night.endTs).atZone(zone)
    val is24 = android.text.format.DateFormat.is24HourFormat(androidx.compose.ui.platform.LocalContext.current)
    val bed = rememberTimePickerState(start.hour, start.minute, is24)
    val wake = rememberTimePickerState(end.hour, end.minute, is24)
    val pickerColors = TimePickerDefaults.colors(
        timeSelectorSelectedContainerColor = colors.rest.copy(alpha = 0.18f), timeSelectorSelectedContentColor = colors.rest,
        timeSelectorUnselectedContainerColor = colors.inset, timeSelectorUnselectedContentColor = colors.text,
        periodSelectorBorderColor = colors.divider)
    Dialog(onDismissRequest = onDismiss) {
        Column(Modifier.background(colors.surface, RoundedCornerShape(20.dp)).padding(20.dp).verticalScroll(rememberScrollState()),
               verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            Text(stringResource(R.string.forge_sl_edit_times), style = Forge.type.headline, color = colors.text)
            Text(stringResource(R.string.forge_se_blurb), style = Forge.type.caption, color = colors.textSecondary)
            Text(stringResource(R.string.forge_se_asleep), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
            TimeInput(bed, colors = pickerColors)
            Text(stringResource(R.string.forge_se_woke), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
            TimeInput(wake, colors = pickerColors)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.forge_se_delete), style = Forge.type.subhead, color = ForgeTokens.Color.systemRed.resolve(),
                     modifier = Modifier.clickable(role = Role.Button, onClick = onDelete).padding(vertical = 8.dp))
                Spacer(Modifier.weight(1f))
                Text(stringResource(R.string.forge_se_cancel), style = Forge.type.subhead, color = colors.textSecondary,
                     modifier = Modifier.clickable(role = Role.Button, onClick = onDismiss).padding(8.dp))
                Spacer(Modifier.width(ForgeMetrics.space2))
                Text(stringResource(R.string.forge_se_save), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.rest,
                     modifier = Modifier.clickable(role = Role.Button) {
                         // The bed time on the night's first day (the day before when it would fall after waking), the wake
                         // time on its last day (the day after when it would fall before bed).
                         var newEnd = end.withHour(wake.hour).withMinute(wake.minute).withSecond(0)
                         var newStart = start.withHour(bed.hour).withMinute(bed.minute).withSecond(0)
                         if (newStart >= newEnd) newStart = newStart.minusDays(1)
                         if (newEnd.toEpochSecond() - newStart.toEpochSecond() > 20 * 3600) newEnd = newEnd.minusDays(1)
                         if (newEnd > newStart) onSave(newStart.toEpochSecond(), newEnd.toEpochSecond())
                     }.padding(8.dp))
            }
        }
    }
}

/** "Sleep deleted." with Undo, as iOS's `SleepUndoStrip`, while a deletion can still be taken back. */
@Composable
internal fun SleepUndoStrip(onUndo: () -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().background(colors.surface, RoundedCornerShape(12.dp)).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(stringResource(R.string.forge_se_deleted), style = Forge.type.subhead, color = colors.text, modifier = Modifier.weight(1f))
        Text(stringResource(R.string.forge_se_undo), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.accent,
             modifier = Modifier.clickable(role = Role.Button, onClick = onUndo).padding(4.dp))
    }
}

/** The deleted sleep windows with Recompute and Hide, as iOS's `DeletedSleepNightsSection`; nothing without one. */
@Composable
internal fun DeletedSleepWindows(viewModel: AppViewModel) {
    val colors = Forge.colors
    val scope = rememberCoroutineScope()
    var revision by remember { mutableIntStateOf(0) }
    var busy by remember { mutableStateOf<DismissedSleep?>(null) }
    val windows by produceState(emptyList<DismissedSleep>(), revision) {
        value = withContext(Dispatchers.IO) {
            runCatching { viewModel.repo.dismissedSleepsUnion(viewModel.activeStrapId) }.getOrDefault(emptyList())
        }
    }
    if (windows.isEmpty()) return
    val zone = ZoneId.systemDefault()
    val locale = java.util.Locale.getDefault()
    val stamp = java.time.format.DateTimeFormatter.ofPattern(android.text.format.DateFormat.getBestDateTimePattern(locale, "EEEdMMMjmm"), locale)
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        SleepSectionTitle(stringResource(R.string.forge_se_windows))
        ForgeCard(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.forge_se_windows_sub), style = Forge.type.caption, color = colors.textSecondary)
            windows.forEach { w ->
                Box(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2).height(ForgeMetrics.hairline).background(colors.divider))
                Text(stringResource(R.string.l10n_sleep_screen_deleted_sleep_window_range_7bc5f027,
                                    Instant.ofEpochSecond(w.startTs).atZone(zone).format(stamp),
                                    Instant.ofEpochSecond(w.endTs).atZone(zone).format(stamp)),
                     style = Forge.type.subhead, color = colors.text)
                Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space4)) {
                    Text(stringResource(if (busy == w) R.string.forge_se_recomputing else R.string.forge_se_recompute),
                         style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.accent,
                         modifier = Modifier.clickable(enabled = busy == null, role = Role.Button) {
                             busy = w
                             scope.launch { viewModel.recomputeDeletedSleep(w); busy = null; revision++ }
                         })
                    Text(stringResource(R.string.forge_se_hide), style = Forge.type.subhead, color = colors.textSecondary,
                         modifier = Modifier.clickable(enabled = busy == null, role = Role.Button) {
                             scope.launch { viewModel.hideDeletedSleepWindow(w); revision++ }
                         })
                }
            }
            Text(stringResource(R.string.forge_se_import_note), style = Forge.type.caption, color = colors.textTertiary,
                 modifier = Modifier.padding(top = ForgeMetrics.space3))
        }
    }
}
