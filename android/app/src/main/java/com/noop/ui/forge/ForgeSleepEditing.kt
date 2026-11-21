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
import androidx.compose.runtime.LaunchedEffect
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
import com.noop.ui.AppViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId

/*
 * Fork (DX23876), Forge parity 2026-11: the new design's night editing on Android, as iOS's `SleepNightEditor` on its
 * Sleep tab: correct the bed and wake times of the night on screen or delete it, with an undo, and the deleted sleep
 * windows that can be recomputed or hidden (`DeletedSleepNightsSection`). Both writes go through the shared core
 * (`CoreSleepEdit`), which plans the change, resolves which namespace owns each row, re-stages a night that grew and
 * names why it refused; this file turns that name into one sentence and keeps the undo.
 */

/**
 * One correction or deletion, and what the screen should say about it.
 *
 * [message] is null when it worked. [undo] names the rows the core is holding, for the strip that offers to put them
 * back. Both layouts of the Sleep tab go through here, so neither can grow its own idea of what a refusal means.
 */
internal data class SleepChange(
    val message: String?,
    val undo: SleepUndoOffer? = null,
)

/**
 * What the undo strip is offering, and what it may say about it.
 *
 * [token] names the rows the core is holding, [retired] is what it took out, and [fromEdit] says which
 * of the two things happened. The strip used to carry one sentence for both, so a corrected night was
 * announced as a deleted one; iOS has branched this copy since the night editor shipped
 * (`SleepNightEditing.strip`).
 */
internal data class SleepUndoOffer(
    val token: String,
    val retired: List<com.noop.core.CoreSleepEdit.Retired>,
    val fromEdit: Boolean,
    /** The bounds the deletion suppresses, for the promise the strip makes about re-detection. */
    val startTs: Long,
    val endTs: Long,
)

/** Correct the times of [night], on the blocks the night itself names. */
internal suspend fun applySleepEdit(viewModel: AppViewModel, context: android.content.Context,
                                    night: CoreRead.Night, newStartTs: Long, newEndTs: Long,
                                    experiment: com.noop.ble.PuffinExperiment): SleepChange =
    readChange(context, viewModel.editSleepNight(night.blocks, newStartTs, newEndTs,
                                                 experiment.sleepStagerMethod, experiment.motionAwareWake),
               fromEdit = true, startTs = newStartTs, endTs = newEndTs)

/** Take [night] out, every block of it. */
internal suspend fun applySleepDelete(viewModel: AppViewModel, context: android.content.Context,
                                      night: CoreRead.Night): SleepChange =
    readChange(context, viewModel.deleteSleepNight(night.blocks),
               fromEdit = false, startTs = night.startTs, endTs = night.endTs)

/** The same for one nap, which is one stored row rather than a night's group. */
internal suspend fun applyNapDelete(viewModel: AppViewModel, context: android.content.Context,
                                    nap: CoreRead.Nap, block: CoreRead.Night.Block): SleepChange =
    readChange(context, viewModel.deleteSleepNight(listOf(block)),
               fromEdit = false, startTs = nap.startTs, endTs = nap.endTs)

private fun readChange(context: android.content.Context, answer: com.noop.core.CoreSleepEdit.Answer,
                       fromEdit: Boolean, startTs: Long, endTs: Long): SleepChange {
    val undo = answer.undoToken?.let { SleepUndoOffer(it, answer.retired, fromEdit, startTs, endTs) }
    // A partial deletion is both at once: it happened, so the undo must be there, and it did not happen
    // whole, so the sentence must be there too.
    return when {
        answer.outcome == com.noop.core.CoreSleepEdit.Outcome.PARTIAL ->
            SleepChange(context.getString(R.string.forge_sl_edit_partial), undo)
        answer.ok -> SleepChange(null, undo)
        else -> SleepChange(context.getString(sleepChangeMessage(answer.outcome)))
    }
}

/**
 * The one sentence a refused correction gets, by the core's own name for it.
 *
 * Every one of these used to be the same thing on Android: nothing happened, no dialog, no log line. The wearer whose
 * nights NOOP computes itself hit `noBlocks`/`ownerUnresolved` on every single attempt and had no way to find out
 * (2026-11-21). The wording follows the Apple twin (`SleepNightEditing.failureMessage`).
 */
internal fun sleepChangeMessage(outcome: com.noop.core.CoreSleepEdit.Outcome): Int = when (outcome) {
    com.noop.core.CoreSleepEdit.Outcome.INVALID_WINDOW -> R.string.forge_sl_edit_failed_window
    com.noop.core.CoreSleepEdit.Outcome.NO_OVERLAP -> R.string.forge_sl_edit_failed_overlap
    com.noop.core.CoreSleepEdit.Outcome.WRITE_FAILED -> R.string.forge_sl_edit_failed_write
    // noBlocks, ownerUnresolved, notFound and a missing core all mean the same thing to the wearer: the night's
    // stored record was not there to change. Saying which of them it was belongs in the strap log, not on screen.
    else -> R.string.forge_sl_edit_failed_missing
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

/**
 * "Add entry, Sleep" asking the Sleep page to open the add dialog when it appears, as the food log's
 * `FoodArrival` does. The entry used to open the tab and stop there (reported 2026-11-20).
 */
internal object SleepArrival {
    @Volatile private var pending = false
    fun requestAdd() { pending = true }
    fun consume(): Boolean = pending.also { pending = false }
}

/** Where the add dialog's pickers open, from the core's own rule; the last hour if the core is not up. */
internal suspend fun seedForAdd(hasMainSleep: Boolean): Pair<Long, Long> {
    val now = System.currentTimeMillis() / 1000L
    return withContext(Dispatchers.IO) {
        com.noop.core.CoreMath.addSleepSeed(hasMainSleep, now, now)
    } ?: (now - 3600 to now)
}

/**
 * Adding a sleep NOOP never recorded, the twin of iOS's "Add a sleep" sheet.
 *
 * The seed decides where the pickers start: the previous evening to the morning on a day with no main
 * sleep, the last hour on a day that has one. The core answers whether the window is free
 * (`CoreMath.addSleepPreflight`), so the refusal and the warning read the same on both platforms, and
 * neither screen decides for itself what counts as a conflict.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SleepAddDialog(seedStart: Long, seedEnd: Long, viewModel: AppViewModel,
                            onEditInstead: (Long) -> Unit, onDismiss: () -> Unit) {
    val colors = Forge.colors
    val zone = ZoneId.systemDefault()
    val seedFrom = Instant.ofEpochSecond(seedStart).atZone(zone)
    val seedTo = Instant.ofEpochSecond(seedEnd).atZone(zone)
    val context = androidx.compose.ui.platform.LocalContext.current
    val is24 = android.text.format.DateFormat.is24HourFormat(context)
    val bed = rememberTimePickerState(seedFrom.hour, seedFrom.minute, is24)
    val wake = rememberTimePickerState(seedTo.hour, seedTo.minute, is24)
    // The DAY the sleep began. Without it the window could only ever be pinned to the two days the seed
    // opened on, so times typed into the small hours landed a day early and a nap from last week could not
    // be added at all. The wake day follows from the times: a wake at or before the bed time is the morning
    // after, which is what every night does.
    var bedDay by remember { mutableStateOf(seedFrom.toLocalDate()) }
    var pickingDate by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val experiment = remember(context) { com.noop.ble.PuffinExperiment.from(context) }
    var problem by remember { mutableStateOf<String?>(null) }
    var exit by remember { mutableStateOf<Pair<String, () -> Unit>?>(null) }
    val pickerColors = TimePickerDefaults.colors(
        timeSelectorSelectedContainerColor = colors.rest.copy(alpha = 0.18f), timeSelectorSelectedContentColor = colors.rest,
        timeSelectorUnselectedContainerColor = colors.inset, timeSelectorUnselectedContentColor = colors.text,
        periodSelectorBorderColor = colors.divider)

    fun chosen(): Pair<Long, Long>? {
        val start = bedDay.atTime(bed.hour, bed.minute).atZone(zone)
        var end = bedDay.atTime(wake.hour, wake.minute).atZone(zone)
        if (!end.isAfter(start)) end = end.plusDays(1)
        return if (end.isAfter(start)) start.toEpochSecond() to end.toEpochSecond() else null
    }

    fun commit(start: Long, end: Long) {
        scope.launch { viewModel.addManualNap(start, end); onDismiss() }
    }

    if (pickingDate) {
        // Today at the latest: a sleep cannot have begun in the future, and the core would refuse it.
        val state = androidx.compose.material3.rememberDatePickerState(
            initialSelectedDateMillis = bedDay.atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toEpochMilli(),
            selectableDates = object : androidx.compose.material3.SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean =
                    utcTimeMillis <= java.time.LocalDate.now().atStartOfDay(java.time.ZoneOffset.UTC)
                        .toInstant().toEpochMilli()
            })
        androidx.compose.material3.DatePickerDialog(
            onDismissRequest = { pickingDate = false },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    state.selectedDateMillis?.let {
                        bedDay = java.time.Instant.ofEpochMilli(it).atZone(java.time.ZoneOffset.UTC).toLocalDate()
                    }
                    pickingDate = false
                }) { Text(stringResource(R.string.forge_se_save)) }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { pickingDate = false }) {
                    Text(stringResource(R.string.forge_se_cancel))
                }
            }) { androidx.compose.material3.DatePicker(state) }
    }
    Dialog(onDismissRequest = onDismiss) {
        Column(Modifier.background(colors.surface, RoundedCornerShape(20.dp)).padding(20.dp).verticalScroll(rememberScrollState()),
               verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            Text(stringResource(R.string.forge_sl_add_title), style = Forge.type.headline, color = colors.text)
            Text(stringResource(R.string.forge_sl_add_blurb), style = Forge.type.caption, color = colors.textSecondary)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.forge_sl_add_day), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                     color = colors.text)
                Spacer(Modifier.weight(1f))
                Text(bedDay.format(java.time.format.DateTimeFormatter.ofLocalizedDate(java.time.format.FormatStyle.MEDIUM)),
                     style = Forge.type.subhead, color = colors.accent,
                     modifier = Modifier.clickable(role = Role.Button) { pickingDate = true }.padding(8.dp))
            }
            Text(stringResource(R.string.forge_se_asleep), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
            TimeInput(bed, colors = pickerColors)
            Text(stringResource(R.string.forge_se_woke), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
            TimeInput(wake, colors = pickerColors)
            problem?.let {
                Text(it, style = Forge.type.caption, color = ForgeTokens.Color.systemRed.resolve())
            }
            // The one thing to do about the refusal, when there is one. Only a labelled control commits.
            exit?.let { (title, run) ->
                Text(title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.accent,
                     modifier = Modifier.clickable(role = Role.Button, onClick = run).padding(vertical = 8.dp))
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Spacer(Modifier.weight(1f))
                Text(stringResource(R.string.forge_se_cancel), style = Forge.type.subhead, color = colors.textSecondary,
                     modifier = Modifier.clickable(role = Role.Button, onClick = onDismiss).padding(8.dp))
                Spacer(Modifier.width(ForgeMetrics.space2))
                Text(stringResource(R.string.forge_se_save), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.rest,
                     modifier = Modifier.clickable(role = Role.Button) {
                         val window = chosen() ?: return@clickable
                         problem = null; exit = null
                         scope.launch {
                             val outcome = withContext(Dispatchers.IO) {
                                 com.noop.core.CoreMath.addSleepPreflight(
                                     deviceId = viewModel.activeStrapId,
                                     computedDeviceId = viewModel.repo.computedDeviceId(viewModel.activeStrapId),
                                     start = window.first, end = window.second,
                                     method = experiment.sleepStagerMethod,
                                     motionAwareWake = experiment.motionAwareWake)
                             }
                             when (outcome) {
                                 is com.noop.core.CoreMath.AddSleepOutcome.Ok, null -> commit(window.first, window.second)
                                 is com.noop.core.CoreMath.AddSleepOutcome.InvalidWindow ->
                                     problem = context.getString(R.string.forge_sl_add_invalid)
                                 is com.noop.core.CoreMath.AddSleepOutcome.NoRawData -> {
                                     problem = context.getString(R.string.forge_sl_add_no_raw)
                                     exit = context.getString(R.string.forge_sl_add_anyway) to
                                         { commit(window.first, window.second) }
                                 }
                                 is com.noop.core.CoreMath.AddSleepOutcome.Blocked -> {
                                     val fmt = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT)
                                     problem = context.getString(R.string.forge_sl_add_blocked,
                                         fmt.format(java.util.Date(outcome.start * 1000)),
                                         fmt.format(java.util.Date(outcome.end * 1000)))
                                     exit = context.getString(R.string.forge_sl_add_edit_that) to
                                         { onEditInstead(outcome.start) }
                                 }
                             }
                         }
                     }.padding(8.dp))
            }
        }
    }
}

/** "Sleep deleted." with Undo, as iOS's `SleepUndoStrip`, while a deletion can still be taken back. */
@Composable
internal fun SleepUndoStrip(offer: SleepUndoOffer, onUndo: () -> Unit, onExpire: () -> Unit) {
    val colors = Forge.colors
    val format = rememberClockFormatter()
    val zone = ZoneId.systemDefault()
    // Takes itself off screen, as iOS's banner does. The offer outlives nothing: the rows it would put
    // back are held in memory by the core, so a strip that waits all evening promises what a restart
    // takes away. Keyed on the token, so a newer offer cancels this wait rather than clearing itself.
    LaunchedEffect(offer.token) {
        kotlinx.coroutines.delay(UNDO_VISIBLE_MILLIS)
        onExpire()
    }
    fun clock(ts: Long) = Instant.ofEpochSecond(ts).atZone(zone).format(format)
    // The three cases iOS already tells apart. A correction did not delete the night; a hand-made or
    // hand-corrected night carries no re-detection marker, so promising one would be a lie; only a
    // detected night that was deleted gets the promise, with the window it covers.
    val message = when {
        offer.fromEdit -> stringResource(R.string.forge_se_removed_outside)
        offer.retired.firstOrNull()?.writesTombstone != true -> stringResource(R.string.forge_se_deleted)
        else -> stringResource(R.string.forge_se_deleted_suppressed, clock(offer.startTs), clock(offer.endTs))
    }
    Row(Modifier.fillMaxWidth().background(colors.surface, RoundedCornerShape(12.dp)).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(message, style = Forge.type.subhead, color = colors.text, modifier = Modifier.weight(1f))
        Text(stringResource(R.string.forge_se_undo), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.accent,
             modifier = Modifier.clickable(role = Role.Button, onClick = onUndo).padding(4.dp))
    }
}

/** How long the undo strip stays, as iOS's banner (`SleepNightEditing.presentUndo`). */
private const val UNDO_VISIBLE_MILLIS = 7_000L

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
