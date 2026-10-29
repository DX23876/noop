package com.noop.ui.forge

import android.text.format.DateUtils
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.IosShare
import androidx.compose.material.icons.rounded.Upload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.noop.BuildConfig
import com.noop.R
import com.noop.core.CoreBackup
import androidx.activity.compose.BackHandler
import androidx.compose.material.icons.rounded.SettingsInputAntenna
import com.noop.ui.AddDeviceWizard
import com.noop.ui.DevicesScreen
import com.noop.ui.ProfileAvatar
import com.noop.ui.ProfileStore
import com.noop.ui.AppViewModel
import com.noop.ui.LogExport
import com.noop.ui.Palette
import com.noop.ui.StrapLogBuffer
import com.noop.ui.rememberRequestScan
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import kotlin.math.roundToInt

/**
 * Fork (DX23876), Android plan E-3e/E-3f: the More tab. The strap (link state, battery, last sync, connect and
 * pairing through the app's view model), `.noopbak` export and import of the core's store (the same format
 * and checks as the Apple apps), sharing the strap log for a bug report, the version and the way back to the
 * classic screens for what the Forge screens do not cover yet.
 */
@Composable
fun ForgeMoreScreen(padding: PaddingValues, viewModel: AppViewModel) {
    val context = LocalContext.current
    var pairing by remember { mutableStateOf(false) }
    var settings by remember { mutableStateOf(false) }
    var profilePage by remember { mutableStateOf(false) }
    var settingsPage by remember { mutableStateOf<ForgeSettingsPage?>(null) }
    var devices by remember { mutableStateOf(false) }
    var classicWizard by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val more = rememberMoreNavigator()

    val colors = Forge.colors
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding)
            .padding(horizontal = ForgeMetrics.screenPadding),
        verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap),
    ) {
        Row(Modifier.padding(top = ForgeMetrics.space4), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.nav_more), style = Forge.type.title1, color = Forge.sceneInk.text)
                Text(stringResource(R.string.forge_more_subtitle), style = Forge.type.subhead,
                     color = Forge.sceneInk.secondary)
            }
            // D9: the Android build says it is in testing until three testers have confirmed it.
            Text(stringResource(R.string.forge_testing).uppercase(), style = Forge.type.overline, color = colors.effort,
                 modifier = Modifier.background(colors.effort.copy(alpha = 0.16f), CircleShape)
                     .padding(horizontal = 10.dp, vertical = 4.dp))
        }
        Spacer(Modifier.height(ForgeMetrics.space2))

        ProfileRow(open = profilePage, onClick = { profilePage = true })
        DeviceRow(viewModel, onClick = { devices = true })

        MoreIndexSections(more, onOpenSettings = { settings = true }, onOpenSettingsPage = { settingsPage = it })
        Text(stringResource(R.string.forge_version, BuildConfig.VERSION_NAME), style = Forge.type.caption,
             color = Forge.sceneInk.tertiary, modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        Text(stringResource(R.string.forge_privacy), style = Forge.type.caption, color = Forge.sceneInk.tertiary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        Spacer(Modifier.height(ForgeMetrics.space2))
    }

    MoreOverlay(more, viewModel, onOpenSettings = { settings = true })
    if (settings) {
        ForgeOverlayPage(onDismiss = { settings = false }) {
            ForgeSettings(viewModel, onClose = { settings = false })
        }
    }
    if (profilePage) {
        ForgeOverlayPage(onDismiss = { profilePage = false }) {
            ForgeSettings(viewModel, onClose = { profilePage = false }, initialPage = ForgeSettingsPage.Profile)
        }
    }
    settingsPage?.let { page ->
        ForgeOverlayPage(onDismiss = { settingsPage = null }) {
            ForgeSettings(viewModel, onClose = { settingsPage = null }, initialPage = page)
        }
    }
    if (devices) {
        ForgeOverlayPage(onDismiss = { devices = false }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) {
                BackHandler { devices = false }
                Hosted(stringResource(R.string.nav_devices), onBack = { devices = false }) {
                    DevicesScreen(viewModel, onAddDevice = { pairing = true })
                }
            }
        }
    }
    if (pairing) {
        ForgeOverlayPage(onDismiss = { pairing = false }) {
            ForgePairing(viewModel, onClose = { pairing = false },
                         onOtherDevice = { pairing = false; classicWizard = true })
        }
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

/** The profile on top of More, as iOS draws it (`MoreProfileRow`): the photo, the name or a nudge to set it up. */
@Composable
private fun ProfileRow(open: Boolean, onClick: () -> Unit) {
    val context = LocalContext.current
    // Read again whenever the profile page closes, so a name typed there shows at once.
    val name = remember(open) { ProfileStore.from(context).name }
    LargeRow(null, Color.Transparent,
             name.ifBlank { stringResource(R.string.forge_more_profile_setup) },
             stringResource(R.string.forge_more_profile_detail),
             leading = { ProfileAvatar(64.dp) }, onClick = onClick)
}

/**
 * The active wearable, as iOS draws it (`MoreDeviceRow`): its name, a dot and the link state with the battery. Opens
 * Devices, where it connects, disconnects and pairs.
 */
@Composable
private fun DeviceRow(viewModel: AppViewModel, onClick: () -> Unit) {
    val colors = Forge.colors
    val live by viewModel.live.collectAsState()
    val name by viewModel.activeDeviceName.collectAsState()
    val connected = live.connected
    val status = when {
        name == null -> stringResource(R.string.forge_more_device_none)
        !connected -> stringResource(R.string.forge_strap_disconnected)
        live.batteryPct != null -> stringResource(R.string.forge_qa_connected_battery, live.batteryPct!!.roundToInt())
        else -> stringResource(R.string.forge_strap_connected)
    }
    LargeRow(Icons.Rounded.SettingsInputAntenna, ForgeTokens.Color.systemGreen.resolve(),
             name ?: stringResource(R.string.nav_devices), status,
             detail = {
                 Row(verticalAlignment = Alignment.CenterVertically) {
                     Box(Modifier.size(7.dp).background(if (connected) colors.charge else colors.textTertiary, CircleShape))
                     Spacer(Modifier.width(5.dp))
                     Text(status, style = Forge.type.subhead, color = colors.textSecondary)
                 }
             }, onClick = onClick)
}

@Composable
private fun MoreRow(icon: ImageVector, tint: Color, title: String, detail: String, onClick: () -> Unit) {
    val colors = Forge.colors
    Row(
        Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget).clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = ForgeMetrics.cardPadding, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(ForgeMetrics.space4))
        Column(Modifier.weight(1f)) {
            Text(title, style = Forge.type.headline, color = colors.text)
            Text(detail, style = Forge.type.subhead, color = colors.textSecondary)
        }
        Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary)
    }
}

