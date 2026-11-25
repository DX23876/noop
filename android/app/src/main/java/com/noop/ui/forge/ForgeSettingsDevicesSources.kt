package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CallSplit
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.DeviceHub
import androidx.compose.material.icons.rounded.Layers
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.noop.R
import com.noop.core.CorePrefs
import com.noop.ui.AddDeviceWizard
import com.noop.ui.AppViewModel
import com.noop.ui.DevicesScreen
import com.noop.ui.FusedRecordRoute
import com.noop.ui.Palette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Settings package 2: Devices and data sources (iOS `ForgeDevicesSourcesView`) and the Devices screen under the Strap
// page. Rows that open a page hand the route to the Settings stack in `ForgeSettings`.

/**
 * Devices and data sources: everything that feeds NOOP, and which source each of today's values uses. The iOS page
 * also lists Apple Health and Mi Band. Health Connect and the Mi Band import are cards of Data sources on Android, so
 * they have no row of their own here.
 */
@Composable
internal fun DevicesSourcesSettings(onOpen: (ForgeSettingsSub) -> Unit) {
    val indigo = ForgeTokens.Color.systemIndigo.resolve()
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
        HubRow(Icons.Rounded.DeviceHub, indigo, stringResource(R.string.nav_devices),
               stringResource(R.string.fsp2_dev_row_detail)) { onOpen(ForgeSettingsSub.Devices) }
        HubDivider()
        HubRow(Icons.Rounded.CallSplit, indigo, stringResource(R.string.fsp2_ds_title),
               stringResource(R.string.fsp2_ds_detail)) { onOpen(ForgeSettingsSub.DataSources) }
    }
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
        HubRow(Icons.Rounded.Layers, ForgeTokens.Color.systemPurple.resolve(), stringResource(R.string.fsp2_values_title),
               stringResource(R.string.fsp2_values_detail)) { onOpen(ForgeSettingsSub.FusedRecord) }
    }
    StepsFromCard()
}

/**
 * Where the daily steps come from: automatically (the strap's count, then the phone's), the strap alone, or Health
 * Connect alone. The one steps reader in the core follows `steps.source`, so every screen shows the same count.
 */
@Composable
private fun StepsFromCard() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var chosen by remember { mutableStateOf("automatic") }
    LaunchedEffect(Unit) {
        chosen = withContext(Dispatchers.IO) { CorePrefs.read(context).optString(CorePrefs.STEPS_SOURCE, "automatic") }
            .ifEmpty { "automatic" }
    }
    SettingsCard(title = stringResource(R.string.forge_steps_from), blurb = stringResource(R.string.forge_steps_auto_note)) {
        listOf("automatic" to stringResource(R.string.forge_steps_auto), "strap" to stringResource(R.string.forge_steps_strap),
               "phone" to stringResource(R.string.today_source_health_connect)).forEachIndexed { i, (key, label) ->
            if (i > 0) RowDivider()
            Row(Modifier.fillMaxWidth().selectable(selected = chosen == key, role = Role.RadioButton) {
                    if (chosen == key) return@selectable
                    chosen = key
                    scope.launch { withContext(Dispatchers.IO) { CorePrefs.setStepsSource(context, key) } }
                }.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(label, style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
                if (chosen == key) Icon(Icons.Rounded.Check, contentDescription = null, tint = Forge.colors.accent)
            }
        }
    }
}

/**
 * The Devices screen under a Forge back bar. "Add device" opens the Forge pairing in place of the page, and every
 * other kind of device the classic wizard, as the More tab does.
 */
@Composable
internal fun DevicesSettingsPage(viewModel: AppViewModel, onBack: () -> Unit, title: String) {
    var pairing by remember { mutableStateOf(false) }
    var classicWizard by remember { mutableStateOf(false) }
    if (pairing) {
        BackHandler { pairing = false }
        ForgePairing(viewModel, onClose = { pairing = false }, onOtherDevice = { pairing = false; classicWizard = true })
    } else {
        Hosted(title, onBack) { DevicesScreen(viewModel, onAddDevice = { pairing = true }) }
    }
    if (classicWizard) {
        // Heart-rate straps, gym equipment and rings keep the classic wizard; it runs on the same view model.
        Dialog(onDismissRequest = { classicWizard = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Surface(Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                AddDeviceWizard(viewModel = viewModel, onClose = { classicWizard = false })
            }
        }
    }
}

/** Which device each of today's values comes from, the fused record under a Forge back bar. */
@Composable
internal fun ValuesBySourcePage(viewModel: AppViewModel, onBack: () -> Unit, title: String) {
    Hosted(title, onBack) { FusedRecordRoute(viewModel) }
}
