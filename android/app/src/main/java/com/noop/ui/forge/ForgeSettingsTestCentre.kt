package com.noop.ui.forge

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.ble.WhoopModel
import com.noop.ui.AppViewModel
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
        Text(stringResource(R.string.fsw3_tc_blurb), style = Forge.type.subhead, color = Forge.sceneInk.secondary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        SettingsCard(title = stringResource(R.string.forge_roadmap_report), blurb = stringResource(R.string.fsw3_report_footer)) {
            LinkRow(stringResource(R.string.l10n_test_centre_screen_report_a_bug_with_my_log_5101ee49),
                    stringResource(R.string.fsw3_report_detail)) { onOpen(ForgeSettingsSub.TestCentreExport) }
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
