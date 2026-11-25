package com.noop.ui.forge

import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.analytics.Baselines
import com.noop.core.CoreAnalysisMaintenance
import com.noop.core.CoreShadow
import com.noop.ui.AppViewModel
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Settings › Calculations › "If scores look wrong" (iOS `AnalysisMaintenanceSettingsCard`): what the shared engine is
// doing, the two repair actions, and the Charge baseline reset. The numbers and the stall rule come from the core
// (`analysis.maintenance`); this file only words them.

/**
 * The repair card. Polls the core's status once a second while a pass runs (the iPhone card observes the engine), and
 * more slowly otherwise. Refresh today and Recalculate never move the analysis recipe; they are diagnostics.
 */
@Composable
internal fun ScoreRepairSection(viewModel: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var status by remember { mutableStateOf<CoreAnalysisMaintenance.Status?>(null) }
    var poke by remember { mutableIntStateOf(0) }
    var wasWorking by remember { mutableStateOf(false) }
    var confirmRecalculate by remember { mutableStateOf(false) }
    var confirmReset by remember { mutableStateOf(false) }
    var resetDone by remember { mutableStateOf(false) }

    LaunchedEffect(poke) {
        while (true) {
            val next = withContext(Dispatchers.IO) { CoreAnalysisMaintenance.status(context) }
            status = next
            val working = next?.working == true
            // The screens read the store again once the pass has stored its rows.
            if (wasWorking && !working) CoreShadow.noteDataChanged()
            wasWorking = working
            delay(if (working) 1_000L else 2_500L)
        }
    }

    val busy = status?.working == true
    fun begin(action: () -> Boolean) {
        scope.launch {
            withContext(Dispatchers.IO) { action() }
            wasWorking = true
            poke++
        }
    }

    SettingsCard(title = stringResource(R.string.fsp5_repair_title), blurb = stringResource(R.string.fsp5_repair_blurb)) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            val progress = status?.progress
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                if (busy && progress == null) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = Forge.colors.accent)
                val (text, warning) = statusLine(status)
                Text(text, style = Forge.type.caption,
                     color = if (warning) ForgeTokens.StrandPalette.statusWarningForeground.resolve() else Forge.colors.textSecondary)
            }
            // A running pass says what it is doing: the bar, the day with an estimate once one can be justified, and
            // how long ago the last step landed, which is how a stalled pass shows itself.
            if (progress != null) {
                LinearProgressIndicator(progress = { progress.fraction.toFloat() }, modifier = Modifier.fillMaxWidth(),
                                        color = Forge.colors.accent, trackColor = Forge.colors.inset)
                Text(progressDetail(progress), style = Forge.type.caption, color = Forge.colors.textSecondary)
                Text(freshness(progress), style = Forge.type.caption,
                     color = if (progress.stalled) ForgeTokens.StrandPalette.statusWarningForeground.resolve() else Forge.colors.textTertiary)
            }
        }
        RowDivider()
        // The row of the running repair spins; while any pass runs the buttons do nothing, as the iPhone's are disabled.
        LinkRow(stringResource(R.string.fsp5_repair_refresh_today), null, busy = status?.task == "today") {
            if (!busy) begin { CoreAnalysisMaintenance.refreshToday(context, viewModel.repo, viewModel.deviceId) }
        }
        RowDivider()
        LinkRow(stringResource(R.string.fsp5_repair_recalculate), null, busy = status?.task == "recent") {
            if (!busy) confirmRecalculate = true
        }
        Text(stringResource(R.string.fsp5_repair_recalculate_note), style = Forge.type.caption, color = Forge.colors.textTertiary)
        RowDivider()
        LinkRow(stringResource(R.string.fsp5_repair_reset), null) { confirmReset = true }
        Text(stringResource(R.string.fsp5_repair_reset_note), style = Forge.type.caption, color = Forge.colors.textTertiary)
    }

    if (confirmRecalculate) {
        AlertDialog(
            onDismissRequest = { confirmRecalculate = false },
            title = { Text(stringResource(R.string.fsp5_repair_confirm_title)) },
            text = { Text(stringResource(R.string.fsp5_repair_confirm_body)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmRecalculate = false
                    begin { CoreAnalysisMaintenance.reanalyzeRecent(context, viewModel.repo, viewModel.deviceId) }
                }) { Text(stringResource(R.string.fsp5_repair_confirm_action)) }
            },
            dismissButton = { TextButton(onClick = { confirmRecalculate = false }) { Text(stringResource(R.string.forge_cancel)) } })
    }
    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            title = { Text(stringResource(R.string.l10n_settings_screen_recalibrate_your_charge_baseline_018e3846)) },
            text = { Text(stringResource(R.string.l10n_settings_screen_this_restarts_the_roughly_4_night_c610a93d)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmReset = false
                    // Re-anchors every baseline that feeds Charge (HRV, resting heart rate, respiration, skin
                    // temperature) by writing now to both epoch keys, the one source the iPhone's button and
                    // `Baselines.foldHistory` share. No stored day is deleted; the recent days are scored again so
                    // the change shows without waiting for the next sync.
                    val editor = NoopPrefs.of(context).edit()
                    Baselines.recalibrateRecoveryBaselines(editor, System.currentTimeMillis() / 1000L)
                    editor.apply()
                    scope.launch { withContext(Dispatchers.IO) { CoreAnalysisMaintenance.rescore(context, viewModel.repo, viewModel.deviceId) } }
                    viewModel.syncNow()
                    resetDone = true
                }) { Text(stringResource(R.string.l10n_settings_screen_recalibrate_aaa989ea)) }
            },
            dismissButton = { TextButton(onClick = { confirmReset = false }) { Text(stringResource(R.string.forge_cancel)) } })
    }
    if (resetDone) {
        AlertDialog(
            onDismissRequest = { resetDone = false },
            title = { Text(stringResource(R.string.fsp5_repair_reset_done_title)) },
            text = { Text(stringResource(R.string.fsp5_repair_reset_done_body)) },
            confirmButton = { TextButton(onClick = { resetDone = false }) { Text(stringResource(android.R.string.ok)) } })
    }
}

/** The status line and whether it is a warning: a repair that failed names why, else what is running, else when the last one ended. */
@Composable
private fun statusLine(status: CoreAnalysisMaintenance.Status?): Pair<String, Boolean> {
    if (status?.failure == "noCurrentDayActivity") return stringResource(R.string.fsp5_repair_no_activity) to true
    when (status?.task) {
        "recent" -> return stringResource(R.string.fsp5_repair_recalculating) to false
        "today" -> return stringResource(R.string.fsp5_repair_refreshing) to false
    }
    val last = status?.lastRunSeconds ?: return stringResource(R.string.fsp5_repair_ready) to false
    val relative = DateUtils.getRelativeTimeSpanString(last * 1000L, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()
    return stringResource(R.string.fsp5_repair_last_completed, relative) to false
}

/** "Day 7 of 21 · 3 unchanged · about 2 min left", or the stage's own line. */
@Composable
private fun progressDetail(p: CoreAnalysisMaintenance.Status.Progress): String = when (p.stage) {
    "preparing" -> stringResource(R.string.fsp5_repair_preparing)
    "finishing" ->
        if (p.unchanged > 0) stringResource(R.string.fsp5_repair_saving_reused, maxOf(0, p.totalDays - p.unchanged), p.totalDays)
        else stringResource(R.string.fsp5_repair_saving)
    else -> {
        val head = if (p.unchanged > 0) stringResource(R.string.fsp5_repair_day_unchanged, p.day, p.totalDays, p.unchanged)
                   else stringResource(R.string.fsp5_repair_day, p.day, p.totalDays)
        p.eta?.let { stringResource(R.string.fsp5_repair_eta, head, coarse(it)) }
            ?: stringResource(R.string.fsp5_repair_estimating, head)
    }
}

@Composable
private fun freshness(p: CoreAnalysisMaintenance.Status.Progress): String =
    if (p.stalled) stringResource(R.string.fsp5_repair_no_progress, coarse(p.gap))
    else stringResource(R.string.fsp5_repair_last_step, coarse(p.gap))

@Composable
private fun coarse(c: CoreAnalysisMaintenance.Status.Coarse): String =
    stringResource(if (c.unit == "min") R.string.fsp5_repair_minutes else R.string.fsp5_repair_seconds, c.value)
