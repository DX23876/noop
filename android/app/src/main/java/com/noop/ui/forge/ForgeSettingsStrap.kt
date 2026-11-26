package com.noop.ui.forge

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Battery5Bar
import androidx.compose.material.icons.rounded.DeviceHub
import androidx.compose.material.icons.rounded.SettingsInputAntenna
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.ble.BackgroundHealth
import com.noop.ble.PuffinExperiment
import com.noop.testcentre.TestCentre
import com.noop.testcentre.TestDomain
import com.noop.ui.AppViewModel
import com.noop.ui.ProfileStore
import com.noop.ui.StrandTone
import com.noop.ui.batteryTone
import com.noop.ui.rememberRequestAdvertise
import com.noop.ui.rememberRequestScan
import com.noop.ui.strapTone
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

// Settings package 2 (Strap and devices): the grouped Strap page, its connection page, heart-rate sharing, Battery
// and Recording, and Devices and data sources, built from the shared Forge Settings rows after iOS
// `ForgeStrapSettingsView`, `SettingsView.strapCard`, `stepsCard`, `HeartRateSharingView`,
// `ContinuousHrvSettingsCard`, `PowerSavingView` and `ForgeDevicesSourcesView`.

/** The five states a strap link can be in, as the Strap card words them (iOS `strapStatusTitle` and detail). */
internal enum class StrapLinkState { Streaming, Idle, LiveOnly, Connected, Disconnected }

/** The state behind the Strap card's pill, decided from the same three facts `strapStatusTitle` reads. */
internal fun strapLinkState(encryptedBond: Boolean, bonded: Boolean, connected: Boolean): StrapLinkState = when {
    encryptedBond && connected -> StrapLinkState.Streaming
    encryptedBond -> StrapLinkState.Idle
    bonded && connected -> StrapLinkState.LiveOnly
    connected -> StrapLinkState.Connected
    else -> StrapLinkState.Disconnected
}

internal fun strapLinkTitleRes(state: StrapLinkState): Int = when (state) {
    StrapLinkState.Streaming -> R.string.fsp2_status_streaming
    StrapLinkState.Idle -> R.string.fsp2_status_idle
    StrapLinkState.LiveOnly -> R.string.fsp2_status_live_only
    StrapLinkState.Connected -> R.string.fsp2_status_connected
    StrapLinkState.Disconnected -> R.string.fsp2_status_disconnected
}

/** The sentence under the pills: searching first, then one for each way a link can stand (iOS `strapStatusDetail`). */
internal fun strapLinkDetailRes(encryptedBond: Boolean, bonded: Boolean, connected: Boolean, scanning: Boolean): Int = when {
    scanning -> R.string.fsp2_detail_searching
    encryptedBond && connected -> R.string.fsp2_detail_paired
    bonded && connected -> R.string.fsp2_detail_live_only
    connected -> R.string.fsp2_detail_finishing
    bonded -> R.string.fsp2_detail_previous
    else -> R.string.fsp2_detail_none
}

internal fun strapConfidenceRes(confidence: Double): Int = when {
    confidence < 0.34 -> R.string.fsp2_confidence_low
    confidence < 0.67 -> R.string.fsp2_confidence_medium
    else -> R.string.fsp2_confidence_high
}

private fun StrandTone.badge(): ForgeBadgeTone = when (this) {
    StrandTone.Positive -> ForgeBadgeTone.Good
    StrandTone.Neutral, StrandTone.Accent -> ForgeBadgeTone.Neutral
    else -> ForgeBadgeTone.Attention
}

/**
 * The Strap page as iOS `ForgeStrapSettingsView` has it: the device row, then one row each for the connection page,
 * recording and battery, and double-tap and buzz, then Devices. Each row opens the page that holds those controls.
 */
@Composable
internal fun StrapSettingsPage(viewModel: AppViewModel, onOpenPage: (ForgeSettingsPage) -> Unit,
                               onOpenSub: (ForgeSettingsSub) -> Unit) {
    val live by viewModel.live.collectAsStateWithLifecycle()
    val name by viewModel.activeDeviceName.collectAsStateWithLifecycle()
    val syncing = rememberDebouncedSyncing(live.backfilling)
    val status = when (StrapRowStatus.of(named = name != null, onAir = live.connected, syncing = syncing,
                                         charging = null, batteryPct = live.batteryPct)) {
        StrapRow.None -> stringResource(R.string.forge_more_device_none)
        StrapRow.Disconnected -> stringResource(R.string.forge_strap_disconnected)
        StrapRow.Syncing -> stringResource(R.string.forge_qa_syncing)
        StrapRow.Battery -> stringResource(R.string.forge_qa_connected_battery, live.batteryPct!!.roundToInt())
        else -> stringResource(R.string.forge_strap_connected)
    }
    val green = ForgeTokens.Color.systemGreen.resolve()
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
        HubRow(Icons.Rounded.SettingsInputAntenna, green, name ?: stringResource(R.string.nav_devices), status) {
            onOpenSub(ForgeSettingsSub.Devices)
        }
    }
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
        HubRow(Icons.Rounded.SettingsInputAntenna, green, stringResource(R.string.fsp2_strap_conn_title),
               stringResource(R.string.fsp2_strap_conn_detail)) { onOpenSub(ForgeSettingsSub.StrapConnection) }
        HubDivider()
        HubRow(Icons.Rounded.Battery5Bar, green, stringResource(R.string.fsp2_strap_rec_title),
               stringResource(R.string.fsp2_strap_rec_detail)) { onOpenPage(ForgeSettingsPage.BatteryRecording) }
        HubDivider()
        HubRow(Icons.Rounded.TouchApp, ForgeTokens.Color.systemOrange.resolve(), stringResource(R.string.fsp2_strap_actions_title),
               stringResource(R.string.fsp2_strap_actions_detail)) { onOpenPage(ForgeSettingsPage.StrapActions) }
    }
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
        HubRow(Icons.Rounded.DeviceHub, ForgeTokens.Color.systemIndigo.resolve(), stringResource(R.string.nav_devices),
               stringResource(R.string.fsp2_devices_detail)) { onOpenSub(ForgeSettingsSub.Devices) }
    }
}

/** A full-width action in the card, filled in the accent for the main one and quiet for the other. */
@Composable
private fun RowScope.StrapAction(text: String, primary: Boolean, enabled: Boolean = true, onClick: () -> Unit) {
    val colors = Forge.colors
    Box(Modifier.weight(1f).heightIn(min = 44.dp).alpha(if (enabled) 1f else 0.45f)
            .background(if (primary) colors.accent else colors.inset, RoundedCornerShape(12.dp))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick).padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center) {
        Text(text, style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), maxLines = 1, textAlign = TextAlign.Center,
             color = if (primary) Color.White else colors.accent)
    }
}

/**
 * The connection page behind the Strap page (iOS `SettingsPage.strap`): the Strap card, the steps card and the
 * way to heart-rate sharing. The Android-only controls that keep the link alive sit in their own card below.
 */
@Composable
internal fun StrapConnectionSettings(viewModel: AppViewModel, onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    val live by viewModel.live.collectAsStateWithLifecycle()
    val advertisingNameProbe by viewModel.advertisingNameProbe.collectAsStateWithLifecycle()
    val requestScan = rememberRequestScan { viewModel.connect() }
    val colors = Forge.colors

    val state = strapLinkState(live.encryptedBond, live.bonded, live.connected)
    // No header: "Strap" under the Strap page head would only repeat it (iOS hides it the same way).
    SettingsCard(title = null, blurb = stringResource(R.string.fsp2_strap_blurb)) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
                ForgeBadgePill(stringResource(strapLinkTitleRes(state)),
                               strapTone(live.encryptedBond, live.bonded, live.connected).badge())
                live.batteryPct?.let { pct ->
                    val charging = live.charging == true
                    ForgeBadgePill(
                        stringResource(if (charging) R.string.fsp2_battery_pill_charging else R.string.fsp2_battery_pill,
                                       pct.roundToInt()),
                        when (batteryTone(pct)) { StrandTone.Positive -> ForgeBadgeTone.Good; else -> ForgeBadgeTone.Attention })
                }
            }
            Text(stringResource(strapLinkDetailRes(live.encryptedBond, live.bonded, live.connected, live.scanning)),
                 style = Forge.type.subhead, color = colors.textSecondary)
            Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                StrapAction(stringResource(if (live.scanning) R.string.cx_searching else R.string.cx_re_scan), primary = true,
                            enabled = !live.scanning) { requestScan() }
                StrapAction(stringResource(R.string.l10n_settings_screen_disconnect_ed28e068), primary = false,
                            enabled = live.connected || live.bonded) { viewModel.disconnect() }
            }
        }
        RowDivider()
        LinkRow(stringResource(R.string.fsp2_diag_title), stringResource(R.string.fsp2_diag_detail)) {
            onOpen(ForgeSettingsSub.TestCentre)
        }
        // Rename the strap's Bluetooth name. A WHOOP 4.0 does it from here, connected; a 5/MG carries the experimental
        // rename and the read-only check (#2338), the controls behind Test Centre › Connection.
        if (live.connected && !live.whoop5Detected) {
            RowDivider()
            var draft by remember(live.advertisingName) { mutableStateOf(live.advertisingName ?: "") }
            Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2), modifier = Modifier.padding(vertical = ForgeMetrics.space1)) {
                Text(stringResource(R.string.l10n_settings_screen_strap_name_350de547), style = Forge.type.body, color = colors.text)
                Text(stringResource(R.string.fsp2_name_current, live.advertisingName ?: "—"), style = Forge.type.footnote,
                     color = colors.textSecondary)
                OutlinedTextField(value = draft, onValueChange = { draft = it.take(24) }, singleLine = true,
                                  placeholder = { Text(stringResource(R.string.fsp2_name_field), style = Forge.type.body, color = colors.textTertiary) },
                                  modifier = Modifier.fillMaxWidth(), colors = forgeFieldColors(),
                                  shape = RoundedCornerShape(10.dp))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                    StrapAction(stringResource(R.string.l10n_settings_screen_rename_d3f4cb89), primary = true,
                                enabled = live.bonded && draft.isNotBlank()) { viewModel.ble.renameStrap(draft) }
                }
                live.renameStatus?.let { Text(it, style = Forge.type.footnote, color = colors.textSecondary) }
                Text(stringResource(R.string.fsp2_name_note), style = Forge.type.footnote, color = colors.textSecondary)
            }
        }
        if (live.connected && live.whoop5Detected) {
            RowDivider()
            val unlocked = TestCentre.from(context).active(TestDomain.CONNECTION)
            var draft5 by remember(live.advertisingName) { mutableStateOf(live.advertisingName ?: "") }
            Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2), modifier = Modifier.padding(vertical = ForgeMetrics.space1)) {
                Text(stringResource(R.string.l10n_settings_screen_strap_name_350de547), style = Forge.type.body, color = colors.text)
                Text(stringResource(if (unlocked) R.string.l10n_settings_screen_experimental_on_a_whoop_5_0_711d5341
                                    else R.string.l10n_settings_screen_renaming_is_not_supported_on_a_02f7af2c),
                     style = Forge.type.footnote, color = colors.textSecondary)
                if (unlocked) {
                    OutlinedTextField(value = draft5, onValueChange = { draft5 = it.take(24) }, singleLine = true,
                                      placeholder = { Text(stringResource(R.string.l10n_settings_screen_whoop_a3650379), style = Forge.type.body, color = colors.textTertiary) },
                                      modifier = Modifier.fillMaxWidth(), colors = forgeFieldColors(),
                                      shape = RoundedCornerShape(10.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                        StrapAction(stringResource(R.string.l10n_settings_screen_rename_d3f4cb89), primary = true,
                                    enabled = live.bonded && draft5.isNotBlank()) { viewModel.ble.renameStrap(draft5) }
                        // Read-only (GET_ADVERTISING_NAME): nothing is written, it shows whether the rename did anything.
                        StrapAction(stringResource(R.string.l10n_settings_screen_check_current_name_read_only_acb2f01a), primary = false,
                                    enabled = live.bonded) { viewModel.ble.probeAdvertisingName() }
                    }
                    (live.renameStatus ?: advertisingNameProbe)?.let { Text(it, style = Forge.type.footnote, color = colors.textSecondary) }
                }
            }
        }
    }

    KeepConnectedCard(viewModel)
    StepsCard(onOpen)
    SettingsCard(title = stringResource(R.string.fsp2_hrs_title), blurb = stringResource(R.string.fsp2_hrs_blurb)) {
        LinkRow(stringResource(R.string.fsp2_hrs_title), null) { onOpen(ForgeSettingsSub.HeartRateSharing) }
    }
}

/**
 * The controls that keep the link to the strap alive on Android: the foreground service, the two sync-speed
 * experiments and the battery-optimisation prompt. iOS has "Keep screen on while syncing" and Live notifications
 * here instead. Same preferences and view-model calls as the classic Strap card.
 */
@Composable
private fun KeepConnectedCard(viewModel: AppViewModel) {
    val context = LocalContext.current
    var background by remember { mutableStateOf(com.noop.ui.NoopPrefs.backgroundConnection(context)) }
    var fastHistory by remember { mutableStateOf(com.noop.ui.NoopPrefs.fastHistorySync(context)) }
    var fastLink by remember { mutableStateOf(com.noop.ui.NoopPrefs.fastLinkPhy(context)) }
    SettingsCard(title = stringResource(R.string.fsp2_keep_title), blurb = null) {
        ToggleRow(stringResource(R.string.l10n_settings_screen_keep_connected_in_the_background_44499d45),
                  stringResource(R.string.l10n_settings_screen_keeps_streaming_from_your_strap_with_d31b4af9), background) {
            background = it
            viewModel.setBackgroundConnection(it)
        }
        RowDivider()
        ToggleRow(stringResource(R.string.fast_history_sync), stringResource(R.string.fast_history_sync_desc), fastHistory) {
            fastHistory = it
            viewModel.setFastHistorySync(it)
        }
        RowDivider()
        ToggleRow(stringResource(R.string.fast_link_phy), stringResource(R.string.fast_link_phy_desc), fastLink) {
            fastLink = it
            viewModel.setFastLinkPhy(it)
        }
        // "Keep NOOP alive overnight" (#386): a one-way prompt, shown only where it can change the outcome (a ROM
        // known to kill background work, background connection on, the exemption not yet granted), and gone once
        // granted. Android lets an app ask for this exemption and never hand it back, so it is an action, not a switch.
        val aggressiveVendor = remember { BackgroundHealth.isAggressiveVendor() }
        if (background && aggressiveVendor) {
            val owner = LocalLifecycleOwner.current
            var exempt by remember { mutableStateOf(BackgroundHealth.isBatteryExempt(context)) }
            DisposableEffect(owner) {
                val observer = LifecycleEventObserver { _, event ->
                    if (event == Lifecycle.Event.ON_RESUME) exempt = BackgroundHealth.isBatteryExempt(context)
                }
                owner.lifecycle.addObserver(observer)
                onDispose { owner.lifecycle.removeObserver(observer) }
            }
            val autostart = remember { BackgroundHealth.oemAutostartIntent(context) }
            if (!exempt) {
                RowDivider()
                LinkRow(stringResource(R.string.l10n_settings_screen_keep_noop_alive_overnight_e43b2fba),
                        stringResource(R.string.keep_alive_needed_vendor, android.os.Build.MANUFACTURER)) {
                    // Exactly one system dialog per tap; the vendor's auto-start screen stays a separate row.
                    runCatching { context.startActivity(BackgroundHealth.batteryExemptionIntent(context)) }.onFailure {
                        runCatching { context.startActivity(BackgroundHealth.appBatterySettingsIntent(context)) }
                    }
                }
                if (autostart != null) {
                    RowDivider()
                    LinkRow(stringResource(R.string.l10n_settings_screen_some_phones_also_need_auto_start_79b7147b), null) {
                        runCatching { context.startActivity(autostart) }
                    }
                }
            }
        }
    }
}

/** Step correction and the step estimate (iOS `stepsCard`): only needed when the step count looks wrong. */
@Composable
private fun StepsCard(onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.from(context) }
    var revision by remember { mutableIntStateOf(0) }
    @Suppress("UNUSED_EXPRESSION") revision
    val summary = when {
        profile.stepsManualCoefficient > 0 -> stringResource(R.string.fsp2_step_manual)
        profile.stepsCalibrationCoefficient > 0 ->
            stringResource(R.string.fsp2_step_auto, stringResource(strapConfidenceRes(profile.stepsCalibrationConfidence)))
        else -> stringResource(R.string.fsp2_step_none)
    }
    SettingsCard(title = stringResource(R.string.fsp2_steps_title), blurb = stringResource(R.string.fsp2_steps_blurb)) {
        SettingRow(stringResource(R.string.fsp2_step_correction)) {
            Stepper("%.1f".format(profile.stepTicksPerStep),
                    onMinus = { profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up = false); revision++ },
                    onPlus = { profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up = true); revision++ })
        }
        Text(stringResource(R.string.fsp2_step_correction_note), style = Forge.type.footnote, color = Forge.colors.textSecondary)
        RowDivider()
        LinkRow(stringResource(R.string.fsp2_step_estimate), summary) { onOpen(ForgeSettingsSub.StepsCalibration) }
        Text(stringResource(R.string.fsp2_step_estimate_note), style = Forge.type.footnote, color = Forge.colors.textSecondary)
    }
}

/**
 * Heart rate sharing (iOS `HeartRateSharingView`): this phone as a Bluetooth heart-rate sensor, and the 5/MG strap
 * sending its own. The strap card states what the strap says, never what the switch says. Unverified without a strap:
 * the Bluetooth side has not run on a device.
 */
@Composable
internal fun HeartRateSharingSettings(viewModel: AppViewModel) {
    val context = LocalContext.current
    val live by viewModel.live.collectAsStateWithLifecycle()
    val colors = Forge.colors
    val sharing by viewModel.hrBroadcast.collectAsStateWithLifecycle()
    val advertising by viewModel.hrBroadcastAdvertising.collectAsStateWithLifecycle()
    val readers by viewModel.hrBroadcastSubscribers.collectAsStateWithLifecycle()
    val note by viewModel.hrBroadcastStatus.collectAsStateWithLifecycle()
    val requestAdvertise = rememberRequestAdvertise(onGranted = { viewModel.setHrBroadcast(true) })

    val experiment = remember { PuffinExperiment.from(context) }
    var strapOn by remember { mutableStateOf(experiment.broadcastHr) }
    DisposableEffect(Unit) {
        val prefs = context.getSharedPreferences(PuffinExperiment.PREFS, Context.MODE_PRIVATE)
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == null || key == PuffinExperiment.KEY_BROADCAST_HR) strapOn = experiment.broadcastHr
        }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        onDispose { prefs.unregisterOnSharedPreferenceChangeListener(listener) }
    }
    val selectedModel = remember {
        context.getSharedPreferences(com.noop.ui.NoopPrefs.NAME, Context.MODE_PRIVATE).getString("noop.selectedWhoopModel", null)
    }
    // The same gate Settings uses for 5/MG-only controls: only that family broadcasts from the strap.
    val strapCanBroadcast = selectedModel == com.noop.ble.WhoopModel.WHOOP5_MG.name || live.whoop5Detected
    // Ask the strap what it is doing, here and when the bond lands. A read changes no setting.
    LaunchedEffect(live.bonded, live.connected, strapCanBroadcast) {
        if (strapCanBroadcast && live.connected && live.bonded) viewModel.ble.readStrapSharingState()
    }

    SettingsCard(title = stringResource(R.string.fsp2_hrs_phone_title), blurb = stringResource(R.string.fsp2_hrs_phone_blurb)) {
        ToggleRow(stringResource(R.string.fsp2_hrs_phone_title), null, sharing) { on ->
            // Turning on asks for Bluetooth advertising first; the view model flips on once it is granted.
            if (on) requestAdvertise() else viewModel.setHrBroadcast(false)
        }
        if (sharing) {
            val warning = ForgeTokens.Color.systemOrange.resolve()
            when {
                note != null -> Text(note!!, style = Forge.type.footnote, color = warning)
                !advertising -> Text(stringResource(R.string.fsp2_hrs_starting), style = Forge.type.footnote, color = colors.textSecondary)
                readers == 1 -> Text(stringResource(R.string.fsp2_hrs_one_device), style = Forge.type.footnote, color = colors.textSecondary)
                readers > 1 -> Text(stringResource(R.string.fsp2_hrs_n_devices, readers), style = Forge.type.footnote, color = colors.textSecondary)
                live.heartRate != null -> Text(stringResource(R.string.fsp2_hrs_waiting, live.heartRate!!), style = Forge.type.footnote,
                                               color = colors.textTertiary)
                else -> Text(stringResource(R.string.fsp2_hrs_no_hr), style = Forge.type.footnote, color = colors.textTertiary)
            }
            // #573: leaving the broadcast on keeps the radio advertising, which drains the battery faster.
            Text(stringResource(R.string.l10n_data_sources_screen_broadcast_hr_is_on_your_strap_0ad5368a),
                 style = Forge.type.caption, color = warning)
        }
    }
    if (strapCanBroadcast) {
        val strapSharing by viewModel.ble.strapSharingOn.collectAsStateWithLifecycle()
        SettingsCard(title = stringResource(R.string.fsp2_hrs_strap_title), blurb = stringResource(R.string.fsp2_hrs_strap_blurb)) {
            ToggleRow(stringResource(R.string.fsp2_hrs_strap_title), stringResource(R.string.fsp2_hrs_strap_note), strapOn) { on ->
                strapOn = on
                experiment.broadcastHr = on
                viewModel.ble.setBroadcastHr(on)
            }
            // What the STRAP says: the flag lives on the strap and survives a reinstall or an off that never reached it.
            Text(stringResource(when (strapSharing) {
                true -> R.string.strap_sharing_status_on
                false -> R.string.strap_sharing_status_off
                null -> R.string.strap_sharing_status_unknown
            }), style = Forge.type.footnote,
                 color = if (strapSharing == true) ForgeTokens.Color.systemOrange.resolve() else colors.textTertiary)
            // Hidden only once the strap itself says it is not sharing; while that is unknown, a stranded strap needs it.
            if (strapSharing != false) {
                Row { StrapAction(stringResource(R.string.strap_sharing_stop_button), primary = false) { viewModel.ble.stopStrapSharingOnStrap() } }
                Text(stringResource(R.string.strap_sharing_stop_caption), style = Forge.type.footnote, color = colors.textSecondary)
            }
        }
    }
}

/**
 * Battery and Recording (iOS `PowerSavingView`): Continuous HRV with its nights-only refinement, then Power saving.
 * Same preferences and view-model calls as the classic Strap and Power saving screens.
 */
@Composable
internal fun BatteryRecordingSettings(viewModel: AppViewModel) {
    val context = LocalContext.current
    var continuous by remember { mutableStateOf(com.noop.ui.NoopPrefs.continuousHrv(context)) }
    var nightsOnly by remember { mutableStateOf(com.noop.ui.NoopPrefs.continuousHrvOvernight(context)) }
    // iOS `forgeGroup`: the switch and its Nights-only option alone on the card, what they do as the footer under it
    // (the paragraphs in the order of the rows; Android's own background-link note last).
    val chrvFooter = listOfNotNull(
        stringResource(R.string.fsp2_chrv_blurb),
        if (continuous) stringResource(R.string.fsp2_chrv_nights_note) else null,
        stringResource(R.string.fsp2_chrv_needs_background), // Android keeps the stream on the background link, so the switch does nothing without it.
    ).joinToString("\n\n")
    SettingsCard(title = null, blurb = chrvFooter) {
        ToggleRow(stringResource(R.string.fsp2_chrv_title), null, continuous) {
            continuous = it
            viewModel.setContinuousHrv(it)
        }
        if (continuous) {
            RowDivider()
            ToggleRow(stringResource(R.string.fsp2_chrv_nights), null, nightsOnly) {
                nightsOnly = it
                viewModel.setContinuousHrvOvernight(it)
            }
        }
    }

    var powerSaving by remember { mutableStateOf(com.noop.ui.NoopPrefs.powerSaving(context)) }
    var pct by remember { mutableIntStateOf(com.noop.ui.NoopPrefs.powerSavingBatteryPct(context)) }
    var pauseHrv by remember { mutableStateOf(com.noop.ui.NoopPrefs.pauseHrvOnPowerSave(context)) }
    var lowRefresh by remember { mutableStateOf(com.noop.ui.NoopPrefs.lowRefresh(context)) }
    val colors = Forge.colors
    // iOS `powerSavingGroup`: the master switch and its sub-options on one card, the page's note and then each
    // explanation, in the order of the rows, as the footer under it.
    val powerFooter = listOfNotNull(
        stringResource(R.string.fsp2_power_blurb),
        stringResource(R.string.power_saving_mode_desc),
        if (powerSaving) stringResource(R.string.power_saving_hrv_pause_desc) else null,
        if (powerSaving) stringResource(R.string.power_saving_low_refresh_desc) else null,
    ).joinToString("\n\n")
    SettingsCard(title = null, blurb = powerFooter) {
        ToggleRow(stringResource(R.string.power_saving_mode), null, powerSaving) {
            powerSaving = it
            viewModel.setPowerSaving(it)
        }
        // The master gates the rest: the threshold, the HRV pause and low refresh only show, and only apply, while it is on.
        if (powerSaving) {
            RowDivider()
            SettingRow(stringResource(R.string.power_saving_kick_in)) {
                Text(stringResource(R.string.power_saving_pct, pct), style = Forge.type.body, color = colors.accent)
            }
            // 10 to 35 in steps of 5: the four stops between the ends.
            Slider(value = pct.toFloat(), onValueChange = { pct = it.roundToInt() },
                   onValueChangeFinished = { viewModel.setPowerSavingBatteryPct(pct) },
                   valueRange = 10f..35f, steps = 4,
                   colors = SliderDefaults.colors(thumbColor = colors.accent, activeTrackColor = colors.accent,
                                                  inactiveTrackColor = colors.inset))
            RowDivider()
            ToggleRow(stringResource(R.string.power_saving_hrv_pause), null, pauseHrv) {
                pauseHrv = it
                viewModel.setPauseHrvOnPowerSave(it)
            }
            RowDivider()
            ToggleRow(stringResource(R.string.power_saving_low_refresh), null, lowRefresh) {
                lowRefresh = it
                viewModel.setLowRefresh(it)
            }
        }
    }
}
