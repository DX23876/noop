package com.noop.ui.forge

import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.ble.WhoopModel
import com.noop.ui.AppViewModel
import com.noop.ui.DebugExportScheduler
import com.noop.ui.DebugExportSettings
import com.noop.ui.LogExport
import com.noop.ui.NoopPrefs

// Settings parity, wave 3 (SUB-01): the Test Centre as iOS `TestCentreView.forgeBody` draws it in the Forge skin, a
// grouped list (Report a problem, Testing, Maintenance, Experimental) whose rows open one page each. Every page hosts one
// card of the classic screen unchanged (`TestCentreScreen(section = ...)`), so no switch, probe or button moved or changed
// its Bluetooth path; only where it is reached from did.

/** The Test Centre index: four groups in iOS order, each row opening the page that hosts its classic card. */
@Composable
internal fun TestCentreSettingsPage(viewModel: AppViewModel, title: String, onBack: () -> Unit,
                                    onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    // The same 5/MG gate the classic screen reads: the stored model, or a 5/MG seen live this session.
    val live by viewModel.live.collectAsStateWithLifecycle()
    val selectedModelName = remember { NoopPrefs.of(context).getString("noop.selectedWhoopModel", null) }
    val is5MG = selectedModelName == WhoopModel.WHOOP5_MG.name || live.whoop5Detected
    SettingsColumn {
        PageTitle(title, onBack)
        // The same tile-and-line head as the index pages carry, with iOS's stethoscope on the Test Centre's own colour.
        SettingsTileHead(Icons.Filled.MonitorHeart, ForgeTokens.Color.systemIndigo.resolve(), stringResource(R.string.fsw3_tc_blurb))
        // iOS `forgeBody`, "Report a problem": the strap log, the report with it, the daily auto-export and clearing the
        // scheduled files. The export's time of day and how many files to keep stay on the report page.
        val sharing by viewModel.strapLogSharing.collectAsStateWithLifecycle()
        val exportSettings = remember { DebugExportSettings.from(context) }
        var dailyExport by remember { mutableStateOf(exportSettings.enabled) }
        var confirmClear by remember { mutableStateOf(false) }
        SettingsCard(title = stringResource(R.string.forge_roadmap_report), blurb = null) {
            LinkRow(stringResource(R.string.fsw4_tc_strap_log), stringResource(R.string.fsw4_tc_strap_log_hint), busy = sharing) {
                viewModel.shareStrapLog(context)
            }
            RowDivider()
            LinkRow(stringResource(R.string.l10n_test_centre_screen_report_a_bug_with_my_log_5101ee49),
                    stringResource(R.string.fsw4_tc_report_hint)) { onOpen(ForgeSettingsSub.TestCentreExport) }
            RowDivider()
            ToggleRow(stringResource(R.string.fsw4_tc_daily_auto), null, dailyExport) { on ->
                dailyExport = on
                exportSettings.enabled = on
                DebugExportScheduler.reschedule(context)
            }
            RowDivider()
            ActionRow(null, stringResource(R.string.fsw4_tc_clear), destructive = true) { confirmClear = true }
        }
        if (confirmClear) {
            AlertDialog(
                onDismissRequest = { confirmClear = false },
                title = { Text(stringResource(R.string.l10n_test_centre_screen_clear_scheduled_exports_36e93dd0)) },
                text = { Text(stringResource(R.string.l10n_test_centre_screen_this_deletes_every_scheduled_strap_ea52c535)) },
                confirmButton = {
                    TextButton(onClick = {
                        LogExport.clearScheduledExports(context)
                        confirmClear = false
                    }) { Text(stringResource(R.string.l10n_lab_book_screen_clear_719ea396)) }
                },
                dismissButton = {
                    TextButton(onClick = { confirmClear = false }) { Text(stringResource(R.string.l10n_test_centre_screen_cancel_77dfd213)) }
                },
            )
        }
        SettingsCard(title = stringResource(R.string.fsw3_group_testing), blurb = null) {
            Column {
                LinkRow(stringResource(R.string.l10n_test_centre_screen_test_modes_e21f1d3c),
                        stringResource(R.string.fsw3_modes_detail)) { onOpen(ForgeSettingsSub.TestCentreModes) }
                RowDivider()
                LinkRow(stringResource(R.string.fsw3_collector),
                        stringResource(if (is5MG) R.string.fsw3_for_5mg else R.string.fsw3_collector_40)) {
                    onOpen(ForgeSettingsSub.TestCentreCollector)
                }
                if (is5MG) {
                    RowDivider()
                    LinkRow(stringResource(R.string.raw_diag_title), stringResource(R.string.fsw3_for_5mg)) {
                        onOpen(ForgeSettingsSub.TestCentreProtocol)
                    }
                }
            }
        }
        SettingsCard(title = stringResource(R.string.fsw3_group_maintenance), blurb = null) {
            LinkRow(stringResource(R.string.l10n_test_centre_screen_diagnostic_tools_04ba4d3f),
                    stringResource(R.string.fsw3_diag_detail)) { onOpen(ForgeSettingsSub.TestCentreDiagnostics) }
        }
        SettingsCard(title = stringResource(R.string.forge_experimental_section),
                     blurb = stringResource(R.string.fsw3_experimental_footer)) {
            LinkRow(stringResource(R.string.l10n_test_centre_screen_experimental_algorithms_e09581e2),
                    stringResource(R.string.fsw3_experimental_detail)) { onOpen(ForgeSettingsSub.TestCentreExperimental) }
        }
    }
}
