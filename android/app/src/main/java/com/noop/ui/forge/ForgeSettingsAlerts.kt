package com.noop.ui.forge

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberTimePickerState
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.analytics.ClockFormat
import com.noop.notif.CyclePagePrefs
import com.noop.notif.TrainingLoadNotifier
import com.noop.ui.AppViewModel
import com.noop.ui.BiofeedbackPrefs
import com.noop.ui.ClockPrefs
import com.noop.ui.DoubleTapAction
import com.noop.ui.HapticPrefs
import com.noop.ui.HrCeilingPrefs
import com.noop.ui.InactivityPrefs
import com.noop.ui.MomentsStore
import com.noop.ui.NoopPrefs
import com.noop.ui.NotifPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.RhythmConsent
import com.noop.ui.cycleOptInApplies
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.Date
import java.util.Locale

// Fork (DX23876), Android Settings parity, package 3: the two Settings pages iOS builds from `AutomationsView`, Strap
// Actions and Notifications, as Forge pages made of the shared Settings blocks. Every control of the classic
// Automations screen has a home here, on the page iOS puts it on; the per-app wrist alerts (Android only) stay one row
// away. The rules behind the heart-rate ceiling and the Training Load alert are the core's (`CoreAlerts`).

// MARK: - Strap Actions

/** Strap Actions: Double-tap, Haptics and Haptic coaching, as iOS orders them, then Android's nap detection. */
@Composable
internal fun StrapActionsSection(viewModel: AppViewModel, onOpen: (ForgeSettingsSub) -> Unit) {
    DoubleTapCard(viewModel)
    HapticsCard()
    HapticCoachingCard(viewModel)
    // Android only (A-11): the nap review list has no iOS twin, so it keeps its own screen one row away.
    SettingsCard(stringResource(R.string.l10n_automations_screen_nap_detection_ca2dedf5), null) {
        LinkRow(stringResource(R.string.l10n_automations_screen_nap_detection_ca2dedf5),
                stringResource(R.string.fsp3_nap_detail)) { onOpen(ForgeSettingsSub.NapDetection) }
    }
}

@Composable
private fun HapticsCard() {
    val context = LocalContext.current
    var breathing by remember { mutableStateOf(HapticPrefs.enabled(context, HapticPrefs.BREATHING)) }
    var intervals by remember { mutableStateOf(HapticPrefs.enabled(context, HapticPrefs.INTERVALS)) }
    var live by remember { mutableStateOf(HapticPrefs.enabled(context, HapticPrefs.LIVE_SESSION)) }
    var workout by remember { mutableStateOf(HapticPrefs.enabled(context, HapticPrefs.WORKOUT)) }
    SettingsCard(stringResource(R.string.fsw5_haptics), stringResource(R.string.fsp3_haptics_blurb),
                 active = breathing || intervals || live || workout) {
        ToggleRow(stringResource(R.string.haptics_breathing_label), stringResource(R.string.fsp3_haptics_breathing_help), breathing) {
            breathing = it; HapticPrefs.setEnabled(context, HapticPrefs.BREATHING, it)
        }
        RowDivider()
        ToggleRow(stringResource(R.string.haptics_intervals_label), stringResource(R.string.fsp3_haptics_intervals_help), intervals) {
            intervals = it; HapticPrefs.setEnabled(context, HapticPrefs.INTERVALS, it)
        }
        RowDivider()
        ToggleRow(stringResource(R.string.haptics_live_session_label), stringResource(R.string.fsp3_haptics_live_help), live) {
            live = it; HapticPrefs.setEnabled(context, HapticPrefs.LIVE_SESSION, it)
        }
        RowDivider()
        ToggleRow(stringResource(R.string.haptics_workout_label), stringResource(R.string.fsp3_haptics_workout_help), workout) {
            workout = it; HapticPrefs.setEnabled(context, HapticPrefs.WORKOUT, it)
        }
    }
}

@Composable
private fun doubleTapLabel(action: DoubleTapAction): String = stringResource(when (action) {
    DoubleTapAction.NONE -> R.string.fsp3_dt_none
    DoubleTapAction.BUZZ_BACK -> R.string.fsp3_dt_buzz_back
    DoubleTapAction.MARK_MOMENT -> R.string.fsp3_dt_mark_moment
    DoubleTapAction.SLEEP_MARK -> R.string.fsp3_dt_sleep_mark
    DoubleTapAction.HAPTIC_CLOCK -> R.string.fsp3_dt_haptic_clock
})

@Composable
private fun DoubleTapCard(viewModel: AppViewModel) {
    val context = LocalContext.current
    val live by viewModel.live.collectAsStateWithLifecycle()
    val action by viewModel.doubleTapAction.collectAsStateWithLifecycle()
    var moments by remember { mutableStateOf(MomentsStore.all(context)) }
    SettingsCard(stringResource(R.string.l10n_automations_screen_double_tap_8d2f1646), stringResource(R.string.fsp3_dt_blurb),
                 active = action != DoubleTapAction.NONE) {
        SettingRow(stringResource(R.string.l10n_automations_screen_when_i_double_tap_a1f1e04d)) {
            MenuPicker(doubleTapLabel(action), DoubleTapAction.entries.toList(), label = { doubleTapLabel(it) },
                       onSelect = { viewModel.setDoubleTapAction(it) })
        }
        RowDivider()
        val bonded = live.bonded
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            val canTest = bonded && action != DoubleTapAction.NONE
            TextButton(onClick = { viewModel.testDoubleTapAction() }, enabled = canTest) {
                Text(stringResource(R.string.l10n_automations_screen_test_action_266df314),
                     color = if (canTest) Forge.colors.accent else Forge.colors.textSecondary.copy(alpha = 0.5f))
            }
            Spacer(Modifier.weight(1f))
            Box(Modifier.size(8.dp).background(if (bonded) ForgeTokens.Color.systemGreen.resolve() else ForgeTokens.Color.systemOrange.resolve(), CircleShape))
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(stringResource(if (bonded) R.string.fsp3_dt_bonded else R.string.forge_w_strap_not_connected),
                 style = Forge.type.footnote, color = Forge.colors.textSecondary)
        }
        if (moments.isNotEmpty()) {
            RowDivider()
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.fsp3_dt_moments).uppercase(), style = Forge.type.footnote, color = Forge.colors.textSecondary,
                     modifier = Modifier.weight(1f))
                TextButton(onClick = { MomentsStore.clear(context); moments = emptyList() }) {
                    Text(stringResource(R.string.l10n_workouts_screen_clear_719ea396), color = Forge.colors.accent)
                }
            }
            val pattern = "EEE d MMM · " + ClockFormat.hourMinutePattern(ClockPrefs.uses24Hour(context))
            val format = remember(pattern) { java.text.SimpleDateFormat(pattern, Locale.getDefault()) }
            moments.takeLast(5).reversed().forEach {
                Text(format.format(Date(it)), style = Forge.type.footnote, color = Forge.colors.textSecondary)
            }
        }
    }
}

@Composable
private fun HapticCoachingCard(viewModel: AppViewModel) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.from(context.applicationContext) }
    val ceilingOn by viewModel.zoneCoaching.collectAsStateWithLifecycle()
    val confirmRecovery by viewModel.zoneCoachRecovery.collectAsStateWithLifecycle()
    // The ceiling settings are plain preferences; one counter re-reads them after a change.
    var revision by remember { mutableIntStateOf(0) }
    fun change(block: () -> Unit) { block(); revision++ }
    var stress by remember { mutableStateOf(BiofeedbackPrefs.checkInEnabled(context)) }
    var nudge by remember { mutableStateOf(BiofeedbackPrefs.autoNudge(context)) }
    var quiet by remember { mutableStateOf(BiofeedbackPrefs.quietHoursEnabled(context)) }
    var resonance by remember { mutableStateOf(BiofeedbackPrefs.useResonancePace(context)) }
    SettingsCard(stringResource(R.string.l10n_automations_screen_haptic_coaching_e2fab286), stringResource(R.string.fsp3_hc_blurb),
                 active = ceilingOn || stress) {
        ToggleRow(stringResource(R.string.fsp3_hc_ceiling), stringResource(R.string.fsp3_hc_ceiling_help), ceilingOn) {
            viewModel.setZoneCoaching(it)
        }
        if (ceilingOn) {
            val mode = HrCeilingPrefs.mode(context)
            val zone = HrCeilingPrefs.allowedZone(context)
            val fixed = HrCeilingPrefs.fixedBpm(context)
            RowDivider()
            SettingRow(stringResource(R.string.fsp3_hc_source)) {
                MenuPicker(stringResource(if (mode == HrCeilingPrefs.BPM) R.string.fsp3_hc_source_bpm else R.string.fsp3_hc_source_zone),
                           listOf(HrCeilingPrefs.ZONE, HrCeilingPrefs.BPM),
                           label = { stringResource(if (it == HrCeilingPrefs.BPM) R.string.fsp3_hc_source_bpm else R.string.fsp3_hc_source_zone) },
                           onSelect = { m -> change { HrCeilingPrefs.setMode(context, m) } })
            }
            Help(stringResource(R.string.fsp3_hc_source_help))
            RowDivider()
            if (mode == HrCeilingPrefs.ZONE) {
                SettingRow(stringResource(R.string.fsp3_hc_max_zone)) {
                    MenuPicker(stringResource(R.string.fsp1_hz_zone, zone), (1..4).toList(),
                               label = { stringResource(R.string.fsp1_hz_zone, it) },
                               onSelect = { z -> change { HrCeilingPrefs.setAllowedZone(context, z) } })
                }
                Help(stringResource(R.string.fsp3_hc_max_zone_help))
            } else {
                SettingRow(stringResource(R.string.fsp3_hc_ceiling)) {
                    Stepper("$fixed ${stringResource(R.string.fsp3_hc_bpm)}",
                            onMinus = { change { HrCeilingPrefs.setFixedBpm(context, fixed - 1) } },
                            onPlus = { change { HrCeilingPrefs.setFixedBpm(context, fixed + 1) } })
                }
                Help(stringResource(R.string.fsp3_hc_fixed_help))
            }
            RowDivider()
            val reminder = HrCeilingPrefs.reminderMode(context)
            SettingRow(stringResource(R.string.fsp3_hc_frequency)) {
                MenuPicker(stringResource(if (reminder == HrCeilingPrefs.EVERY_TWO_SECONDS) R.string.fsp3_hc_frequency_two else R.string.fsp1_hz_standard),
                           listOf(HrCeilingPrefs.STANDARD, HrCeilingPrefs.EVERY_TWO_SECONDS),
                           label = { stringResource(if (it == HrCeilingPrefs.EVERY_TWO_SECONDS) R.string.fsp3_hc_frequency_two else R.string.fsp1_hz_standard) },
                           onSelect = { m -> change { HrCeilingPrefs.setReminderMode(context, m) } })
            }
            Help(stringResource(R.string.fsp3_hc_frequency_help))
            RowDivider()
            val scope = HrCeilingPrefs.scope(context)
            SettingRow(stringResource(R.string.fsp3_hc_monitor)) {
                MenuPicker(stringResource(if (scope == HrCeilingPrefs.WORKOUT) R.string.fsp3_hc_monitor_workout else R.string.forge_rating_reminder_always),
                           listOf(HrCeilingPrefs.ALWAYS, HrCeilingPrefs.WORKOUT),
                           label = { stringResource(if (it == HrCeilingPrefs.WORKOUT) R.string.fsp3_hc_monitor_workout else R.string.forge_rating_reminder_always) },
                           onSelect = { m -> change { HrCeilingPrefs.setScope(context, m) } })
            }
            Help(stringResource(R.string.fsp3_hc_monitor_help))
            RowDivider()
            // Android only (A-22): the switch that used to read "Recovery buzz" keeps the wearer's choice. The iPhone
            // always confirms a recovery.
            ToggleRow(stringResource(R.string.fsp3_hc_recovery), stringResource(R.string.fsp3_hc_recovery_help), confirmRecovery) {
                viewModel.setZoneCoachRecovery(it)
            }
            RowDivider()
            // The value the wearer crosses comes from the core, from the zones in force or the fixed value.
            var buzzAt by remember { mutableStateOf<Int?>(null) }
            val zoneKey = profile.hrZoneSet.zones.map { it.lower }
            LaunchedEffect(mode, zone, fixed, profile.hrMax, zoneKey) {
                buzzAt = withContext(Dispatchers.Default) { HrCeilingPrefs.buzzAtBpm(context, profile) }
            }
            buzzAt?.let {
                Text(stringResource(R.string.fsp3_hc_buzz_at, it), style = Forge.type.bodyNumber, color = Forge.colors.accent,
                     modifier = Modifier.padding(vertical = ForgeMetrics.space1))
            }
            Text(stringResource(R.string.fsp3_hc_disclaimer), style = Forge.type.footnote, color = Forge.colors.textSecondary,
                 modifier = Modifier.padding(vertical = ForgeMetrics.space1))
        }
        RowDivider()
        ToggleRow(stringResource(R.string.l10n_settings_screen_stress_check_ins_haptic_bf2746ba), stringResource(R.string.fsp3_hc_stress_help), stress) {
            stress = it
            BiofeedbackPrefs.setCheckInEnabled(context, it)
            // Turning the master off also disarms the auto-nudge, so it cannot fire.
            if (!it) { nudge = false; BiofeedbackPrefs.setAutoNudge(context, false) }
        }
        if (stress) {
            RowDivider()
            ToggleRow(stringResource(R.string.fsp3_hc_nudge), stringResource(R.string.fsp3_hc_nudge_help), nudge) {
                nudge = it; BiofeedbackPrefs.setAutoNudge(context, it)
            }
            RowDivider()
            ToggleRow(stringResource(R.string.fsp3_hc_quiet), stringResource(R.string.fsp3_hc_quiet_help), quiet) {
                quiet = it; BiofeedbackPrefs.setQuietHoursEnabled(context, it)
            }
            RowDivider()
            ToggleRow(stringResource(R.string.fsp3_hc_resonance), stringResource(R.string.fsp3_hc_resonance_help), resonance) {
                resonance = it; BiofeedbackPrefs.setUseResonancePace(context, it)
            }
        }
    }
}

/** The explaining line under a picker or stepper row, as iOS prints it beneath the row's label. */
@Composable
private fun Help(text: String) {
    Text(text, style = Forge.type.footnote, color = Forge.colors.textTertiary, modifier = Modifier.padding(bottom = ForgeMetrics.space1))
}

// MARK: - Notifications

/** Notifications: Wrist alerts, Inactivity, Illness, Health insights, Battery, Strain target and Training load, as iOS orders them. */
@Composable
internal fun NotificationsSection(viewModel: AppViewModel, onOpen: (ForgeSettingsSub) -> Unit) {
    WristAlertsCard(onOpen)
    InactivityCard()
    IllnessCard(viewModel)
    HealthInsightsCard(viewModel, onOpen)
    BatteryCard(viewModel)
    StrainTargetCard()
    TrainingLoadCard()
}

@Composable
private fun WristAlertsCard(onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    var master by remember { mutableStateOf(NotifPrefs.getBool(context, NotifPrefs.MASTER, false)) }
    SettingsCard(stringResource(R.string.l10n_notifications_settings_screen_wrist_alerts_75581d51), stringResource(R.string.fsp3_wrist_blurb),
                 active = master) {
        ToggleRow(stringResource(R.string.l10n_notifications_settings_screen_enable_wrist_alerts_462b9e0f),
                  stringResource(R.string.fsp3_wrist_master_help), master) {
            master = it; NotifPrefs.setBool(context, NotifPrefs.MASTER, it)
        }
        // Android only (A-09): which apps, calls and timers buzz, quiet hours and the daily reports.
        RowDivider()
        LinkRow(stringResource(R.string.fsp3_wrist_apps), stringResource(R.string.fsp3_wrist_apps_detail)) {
            onOpen(ForgeSettingsSub.WristAlerts)
        }
    }
}

@Composable
private fun InactivityCard() {
    val context = LocalContext.current
    var enabled by remember { mutableStateOf(InactivityPrefs.enabled(context)) }
    var threshold by remember { mutableIntStateOf(InactivityPrefs.thresholdMinutes(context)) }
    var reNudge by remember { mutableIntStateOf(InactivityPrefs.reNudgeMinutes(context)) }
    var loops by remember { mutableIntStateOf(InactivityPrefs.buzzLoops(context)) }
    var activeHours by remember { mutableStateOf(InactivityPrefs.activeHoursEnabled(context)) }
    var start by remember { mutableIntStateOf(InactivityPrefs.activeStartMinutes(context)) }
    var end by remember { mutableIntStateOf(InactivityPrefs.activeEndMinutes(context)) }
    // The reminder also needs the wrist-alerts master; say so rather than leave a switch that does nothing.
    val masterOn = NotifPrefs.getBool(context, NotifPrefs.MASTER, false)
    val min = stringResource(R.string.forge_unit_min)
    SettingsCard(stringResource(R.string.l10n_automations_screen_inactivity_reminder_ca49b1ba), stringResource(R.string.fsp3_in_blurb), active = enabled) {
        ToggleRow(stringResource(R.string.l10n_automations_screen_enable_inactivity_reminder_468c3017),
                  stringResource(R.string.fsp3_in_enable_help), enabled) {
            enabled = it; InactivityPrefs.setBool(context, InactivityPrefs.ENABLED, it)
        }
        if (enabled) {
            if (!masterOn) {
                Text(stringResource(R.string.fsp3_in_master_off), style = Forge.type.footnote, color = ForgeTokens.Color.systemOrange.resolve(),
                     modifier = Modifier.padding(vertical = ForgeMetrics.space1))
            }
            RowDivider()
            SettingRow(stringResource(R.string.l10n_automations_screen_sitting_for_e464c472)) {
                Stepper("$threshold $min",
                        onMinus = { threshold = (threshold - 15).coerceAtLeast(15); InactivityPrefs.setInt(context, InactivityPrefs.THRESHOLD_MIN, threshold) },
                        onPlus = { threshold = (threshold + 15).coerceAtMost(120); InactivityPrefs.setInt(context, InactivityPrefs.THRESHOLD_MIN, threshold) })
            }
            Help(stringResource(R.string.fsp3_in_sitting_help))
            RowDivider()
            SettingRow(stringResource(R.string.l10n_automations_screen_re_nudge_every_646023cd)) {
                Stepper("$reNudge $min",
                        onMinus = { reNudge = (reNudge - 15).coerceAtLeast(15); InactivityPrefs.setInt(context, InactivityPrefs.RENUDGE_MIN, reNudge) },
                        onPlus = { reNudge = (reNudge + 15).coerceAtMost(120); InactivityPrefs.setInt(context, InactivityPrefs.RENUDGE_MIN, reNudge) })
            }
            Help(stringResource(R.string.fsp3_in_renudge_help))
            RowDivider()
            SettingRow(stringResource(R.string.l10n_automations_screen_buzz_strength_e895f99e)) {
                Stepper("$loops×",
                        onMinus = { loops = (loops - 1).coerceAtLeast(1); InactivityPrefs.setInt(context, InactivityPrefs.BUZZ_LOOPS, loops) },
                        onPlus = { loops = (loops + 1).coerceAtMost(4); InactivityPrefs.setInt(context, InactivityPrefs.BUZZ_LOOPS, loops) })
            }
            Help(stringResource(R.string.fsp3_in_strength_help))
            RowDivider()
            ToggleRow(stringResource(R.string.l10n_automations_screen_only_during_active_hours_29c53fc9),
                      stringResource(R.string.fsp3_in_active_help), activeHours) {
                activeHours = it; InactivityPrefs.setBool(context, InactivityPrefs.ACTIVE_HOURS_ENABLED, it)
            }
            if (activeHours) {
                RowDivider()
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.l10n_automations_screen_from_3f66052a), style = Forge.type.body, color = Forge.colors.text)
                    Spacer(Modifier.weight(1f))
                    TimeChip(start, stringResource(R.string.fsp3_in_start_a11y)) { start = it; InactivityPrefs.setInt(context, InactivityPrefs.ACTIVE_START_MIN, it) }
                    Text(stringResource(R.string.fsp3_in_to), style = Forge.type.body, color = Forge.colors.textSecondary,
                         modifier = Modifier.padding(horizontal = ForgeMetrics.space2))
                    TimeChip(end, stringResource(R.string.fsp3_in_end_a11y)) { end = it; InactivityPrefs.setInt(context, InactivityPrefs.ACTIVE_END_MIN, it) }
                }
            }
        }
    }
}

/** A time of day as a chip that opens the clock picker (iOS's compact `DatePicker`), in the wearer's 12 or 24 hour clock. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TimeChip(minutes: Int, description: String, onPicked: (Int) -> Unit) {
    val context = LocalContext.current
    val uses24 = ClockPrefs.uses24Hour(context)
    var open by remember { mutableStateOf(false) }
    val text = LocalTime.of(minutes / 60, minutes % 60).format(DateTimeFormatter.ofPattern(ClockFormat.hourMinutePattern(uses24)))
    Text(text, style = Forge.type.bodyNumber, color = Forge.colors.accent,
         modifier = Modifier.background(Forge.colors.inset, RoundedCornerShape(8.dp))
             .clickable(role = Role.Button) { open = true }
             .padding(horizontal = 12.dp, vertical = 8.dp)
             .semantics { contentDescription = description })
    if (open) {
        val state = rememberTimePickerState(minutes / 60, minutes % 60, uses24)
        AlertDialog(
            onDismissRequest = { open = false },
            title = { Text(description) },
            text = { TimePicker(state) },
            confirmButton = {
                TextButton(onClick = { open = false; onPicked(state.hour * 60 + state.minute) }) { Text(stringResource(R.string.forge_library_ok)) }
            },
            dismissButton = { TextButton(onClick = { open = false }) { Text(stringResource(R.string.l10n_backup_sync_screen_cancel_77dfd213)) } },
        )
    }
}

@Composable
private fun IllnessCard(viewModel: AppViewModel) {
    // One preference behind this switch and the classic Health & wellness one: both go through the view model.
    val watch by viewModel.illnessWatchEnabled.collectAsStateWithLifecycle()
    SettingsCard(stringResource(R.string.l10n_automations_screen_illness_early_warning_453ab477), stringResource(R.string.fsp3_il_blurb), active = watch) {
        ToggleRow(stringResource(R.string.l10n_automations_screen_watch_for_early_illness_signs_4c22e127),
                  stringResource(R.string.fsp3_il_toggle_help), watch) { viewModel.setIllnessWatchEnabled(it) }
    }
}

@Composable
private fun HealthInsightsCard(viewModel: AppViewModel, onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.from(context.applicationContext) }
    val hidden by viewModel.cycleAwarenessHidden.collectAsStateWithLifecycle()
    val tracking by viewModel.cycleTrackingEnabled.collectAsStateWithLifecycle()
    var rhythm by remember { mutableStateOf(RhythmConsent.isEnabled(context)) }
    SettingsCard(stringResource(R.string.fsp3_hi_title), stringResource(R.string.fsp3_hi_blurb), active = tracking || rhythm) {
        // Not offered on a male profile (the cycle awareness reads a menstrual temperature shift); still shown while on,
        // so it can be turned off, as the Health tab gates its own offer.
        if (tracking || cycleOptInApplies(profile.sex)) {
            ToggleRow(stringResource(R.string.l10n_settings_screen_show_cycle_awareness_59709019), stringResource(R.string.fsp3_hi_show_help), !hidden) { show ->
                viewModel.setCycleAwarenessHidden(!show)
            }
            RowDivider()
            if (!hidden) {
                ToggleRow(stringResource(R.string.l10n_settings_screen_cycle_awareness_ffb94783), stringResource(R.string.fsp3_hi_cycle_help), tracking) {
                    viewModel.setCycleTrackingEnabled(it)
                }
                RowDivider()
                if (tracking) {
                    // The same switches as on the cycle page (same keys), so a reminder can be found where every
                    // other reminder lives.
                    FertileReminderToggles()
                    RowDivider()
                }
            }
        }
        ToggleRow(stringResource(R.string.fsp3_hi_rhythm), stringResource(R.string.fsp3_hi_rhythm_help), rhythm) {
            // Enabling only un-gates the experimental item; the screen still shows its consent note on first open.
            rhythm = it
            NoopPrefs.of(context).edit().putBoolean(RhythmConsent.KEY_ENABLED, it).apply()
        }
        if (rhythm) {
            RowDivider()
            SettingRow(stringResource(R.string.fsp3_hi_open)) {
                TextButton(onClick = { onOpen(ForgeSettingsSub.Rhythm) }) {
                    Text(stringResource(R.string.l10n_workout_start_open_cf9b7706), color = Forge.colors.accent)
                }
            }
        }
    }
}

@Composable
private fun BatteryCard(viewModel: AppViewModel) {
    val alerts by viewModel.batteryAlertsEnabled.collectAsStateWithLifecycle()
    val predictive by viewModel.predictiveBatteryAlertsEnabled.collectAsStateWithLifecycle()
    SettingsCard(stringResource(R.string.l10n_automations_screen_battery_alerts_f3679d60), stringResource(R.string.fsp3_ba_blurb), active = alerts) {
        ToggleRow(stringResource(R.string.l10n_automations_screen_notify_on_low_and_full_battery_d1903bb8),
                  stringResource(R.string.fsp3_ba_toggle_help), alerts) { viewModel.setBatteryAlertsEnabled(it) }
        if (alerts) {
            RowDivider()
            ToggleRow(stringResource(R.string.l10n_automations_screen_predictive_runtime_warning_4d85f5a6),
                      stringResource(R.string.fsp3_ba_predictive_help), predictive) { viewModel.setPredictiveBatteryAlertsEnabled(it) }
        }
    }
}

@Composable
private fun StrainTargetCard() {
    val context = LocalContext.current
    // The same preference as the classic wrist-alerts screen's "Optimal strain reached" (daily reports).
    var on by remember { mutableStateOf(NoopPrefs.strainTargetEnabled(context)) }
    SettingsCard(stringResource(R.string.fsp3_st_title), stringResource(R.string.fsp3_st_blurb), active = on) {
        ToggleRow(stringResource(R.string.fsp3_st_toggle), stringResource(R.string.fsp3_st_toggle_help), on) {
            on = it; NoopPrefs.setStrainTargetEnabled(context, it)
        }
    }
}

@Composable
private fun TrainingLoadCard() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var on by remember { mutableStateOf(TrainingLoadNotifier.enabled(context)) }
    fun turn(value: Boolean) {
        on = value
        if (value) scope.launch(Dispatchers.IO) { TrainingLoadNotifier.enable(context) } else TrainingLoadNotifier.disable(context)
    }
    // Android 13 and later ask before the first notification.
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted -> turn(granted) }
    SettingsCard(stringResource(R.string.fsp3_tl_title), stringResource(R.string.fsp3_tl_blurb), active = on) {
        ToggleRow(stringResource(R.string.fsp3_tl_toggle), stringResource(R.string.fsp3_tl_toggle_help), on) { value ->
            if (value && needsNotificationPermission(context)) ask.launch(Manifest.permission.POST_NOTIFICATIONS) else turn(value)
        }
    }
}

private fun needsNotificationPermission(context: Context): Boolean =
    Build.VERSION.SDK_INT >= 33 &&
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
