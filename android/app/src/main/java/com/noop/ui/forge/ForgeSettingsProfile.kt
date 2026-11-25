package com.noop.ui.forge

import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import com.noop.ingest.WhoopCsvExporter
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.material.icons.rounded.Dashboard
import androidx.compose.runtime.CompositionLocalProvider
import com.noop.ui.LightTokens
import com.noop.ui.DarkTokens
import com.noop.ui.PaletteTokens
import com.noop.ui.HostedPalette
import com.noop.ui.LocalHostedChrome
import com.noop.ui.HostedChrome
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.DeviceHub
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.TrackChanges
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Help
import androidx.compose.material.icons.rounded.AccountCircle
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Battery5Bar
import androidx.compose.material.icons.rounded.Functions
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material.icons.rounded.School
import androidx.compose.material.icons.rounded.Science
import androidx.compose.material.icons.rounded.SettingsInputAntenna
import androidx.compose.material.icons.rounded.Storage
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Contrast
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Map
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.UnfoldMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.rounded.Check
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.BuildConfig
import com.noop.BuildIdentity
import com.noop.R
import android.widget.Toast
import androidx.lifecycle.viewmodel.compose.viewModel
import com.noop.analytics.ClockFormatPreference
import com.noop.analytics.DayCycleMode
import com.noop.analytics.SkinTempDisplay
import com.noop.ble.PuffinExperiment
import com.noop.core.CoreShadow
import com.noop.push.SelfHostedPushScreen
import com.noop.ui.AppViewModel
import com.noop.ui.AutomationsScreen
import com.noop.ui.CardAppearance
import com.noop.ui.BackupSyncScreen
import com.noop.ui.ClassicSettingsCard
import com.noop.ui.CoachSettingsScreen
import com.noop.ui.CoachViewModel
import com.noop.ui.DataSourcesScreen
import com.noop.ui.HealthConnectWeightSync
import com.noop.ui.HowNoopWorksScreen
import com.noop.ui.HrvWindow
import com.noop.ui.NoopLimitationsScreen
import com.noop.ui.NotificationsSettingsScreen
import com.noop.ui.Palette
import com.noop.ui.PowerSavingScreen
import com.noop.ui.ScoringGuideScreen
import com.noop.ui.SettingsScreen
import com.noop.ui.StepsCalibrationScreen
import com.noop.ui.TemperatureUnit
import com.noop.ui.TestCentreScreen
import com.noop.ui.WhatsNewSheet
import com.noop.ui.WhoopModelComparisonScreen
import com.noop.ui.setAppIcon
import com.noop.ui.waistCmStep
import com.noop.ui.waistInchesStep
import com.noop.ui.AppLanguage
import com.noop.ui.AppLanguagePrefs
import com.noop.ui.AppearanceMode
import com.noop.ui.AppearancePrefs
import com.noop.ui.ClockPrefs
import com.noop.ui.EffortScale
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.UnitFormatter
import com.noop.ui.UnitPrefs
import com.noop.ui.UnitSystem
import com.noop.update.UpdateCheck
import com.noop.update.UpdateWatch
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

// Settings › Profile: the wearer's profile, its steppers and the birthday picker.

/** The sex choices the profile stores, by tag, with the onboarding's labels. */
private val SEX_CHOICES = listOf("male" to R.string.onboarding_male, "female" to R.string.onboarding_female,
                                 "nonbinary" to R.string.onboarding_other)

@Composable
internal fun ProfileSection(profile: ProfileStore, viewModel: AppViewModel, change: (() -> Unit) -> Unit,
                           onOpen: (ForgeSettingsSub) -> Unit, editing: Boolean, onEditing: (Boolean) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val imperial = UnitPrefs.system(context) == UnitSystem.IMPERIAL
    // iOS keeps the fields still until "Edit" (`profileEditing`): plain values, then steppers and pickers.
    SettingsCard(title = null, blurb = stringResource(R.string.forge_settings_profile_detail)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(onClick = { onEditing(!editing) }) {
                Text(stringResource(if (editing) R.string.forge_profile_done else R.string.forge_profile_edit),
                     style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.accent)
            }
        }
        // The photo first, as iOS's `profilePhotoRow`: the avatar, Choose or Change, and Remove once one is set. On this
        // phone only (`ProfileAvatarStore`).
        val photoPicker = androidx.activity.compose.rememberLauncherForActivityResult(
            androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia()) { uri ->
            if (uri != null) scope.launch { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { com.noop.ui.ProfileAvatarStore.setAvatarFromUri(context, uri) } }
        }
        Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space4)) {
            com.noop.ui.ProfileAvatar(size = 56.dp, contentDescription = null)
            Box(Modifier.weight(1f).heightIn(min = 48.dp).background(Forge.colors.inset, RoundedCornerShape(14.dp))
                    .clickable {
                        photoPicker.launch(androidx.activity.result.PickVisualMediaRequest(
                            androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageOnly))
                    }, contentAlignment = Alignment.Center) {
                Text(stringResource(if (com.noop.ui.ProfileAvatarStore.hasAvatar) R.string.forge_profile_change_photo
                                    else R.string.forge_profile_choose_photo),
                     style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.accent)
            }
            if (com.noop.ui.ProfileAvatarStore.hasAvatar) {
                TextButton(onClick = { com.noop.ui.ProfileAvatarStore.clearAvatar(context) }) {
                    Text(stringResource(R.string.l10n_settings_screen_remove_photo_c8f5eda8), color = Forge.colors.textSecondary)
                }
            }
        }
        RowDivider()
        // The name More's profile row shows (iOS `ProfileStore.name`); saved as typed, blank clears it. No frame, as iOS.
        var name by remember { mutableStateOf(profile.name) }
        SettingRow(stringResource(R.string.forge_profile_name)) {
            androidx.compose.foundation.text.BasicTextField(
                value = name, onValueChange = { name = it; profile.name = it }, singleLine = true, enabled = editing,
                textStyle = Forge.type.bodyNumber.copy(color = Forge.colors.text, textAlign = TextAlign.End),
                cursorBrush = androidx.compose.ui.graphics.SolidColor(Forge.colors.accent),
                decorationBox = { inner ->
                    Box(Modifier.widthIn(min = 120.dp), contentAlignment = Alignment.CenterEnd) {
                        if (name.isEmpty()) Text(stringResource(R.string.forge_profile_name_hint), style = Forge.type.bodyNumber,
                                                 color = Forge.colors.textTertiary)
                        inner()
                    }
                })
        }
        RowDivider()
        // The date of birth is what is stored; the age shown beside it is derived and advances on its own (#146).
        var pickingBirthday by remember { mutableStateOf(false) }
        SettingRow(stringResource(R.string.forge_profile_birthday)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.clickable(enabled = editing) { pickingBirthday = true }) {
                Text(profile.age.toString(), style = Forge.type.bodyNumber, color = Forge.colors.text)
                Text(java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(java.util.Date(profile.dateOfBirthMillis)),
                     style = Forge.type.bodyNumber, color = if (editing) Forge.colors.accent else Forge.colors.text)
            }
        }
        if (pickingBirthday) BirthdayPicker(profile.dateOfBirthMillis, onPick = { ms -> change { profile.dateOfBirthMillis = ms } },
                                            onDismiss = { pickingBirthday = false })
        RowDivider()
        SettingRow(stringResource(R.string.l10n_settings_screen_sex_e301dd60)) {
            var open by remember { mutableStateOf(false) }
            Box {
                Row(Modifier.clickable(enabled = editing) { open = true }, verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(SEX_CHOICES.first { it.first == profile.sex }.second), style = Forge.type.bodyNumber,
                         color = if (editing) Forge.colors.accent else Forge.colors.text)
                    if (editing) Icon(Icons.Rounded.UnfoldMore, null, tint = Forge.colors.textTertiary, modifier = Modifier.size(18.dp))
                }
                androidx.compose.material3.DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                    SEX_CHOICES.forEach { (tag, label) ->
                        androidx.compose.material3.DropdownMenuItem(text = { Text(stringResource(label)) },
                            onClick = { open = false; change { profile.sex = tag } })
                    }
                }
            }
        }
        RowDivider()
        // With "Use weight from Health Connect" on, the synced reading owns the value (classic Settings).
        val fromHealthConnect = profile.useHealthConnectWeight
        SettingRow(stringResource(R.string.l10n_settings_screen_weight_69c0b815)) {
            if (imperial) {
                val lb = UnitFormatter.kgToPounds(profile.weightKg)
                ProfileStepper(editing, "%.0f lb".format(lb), enabled = !fromHealthConnect,
                        onMinus = { change { profile.weightKg = (lb - 1) / UnitFormatter.POUNDS_PER_KILOGRAM } },
                        onPlus = { change { profile.weightKg = (lb + 1) / UnitFormatter.POUNDS_PER_KILOGRAM } })
            } else {
                ProfileStepper(editing, "%.1f kg".format(profile.weightKg), enabled = !fromHealthConnect,
                        onMinus = { change { profile.weightKg -= 0.5 } }, onPlus = { change { profile.weightKg += 0.5 } })
            }
        }
        if (fromHealthConnect) {
            Text(stringResource(R.string.forge_settings_weight_health_connect), style = Forge.type.caption,
                 color = Forge.colors.textTertiary)
        }
        RowDivider()
        ToggleRow(stringResource(R.string.l10n_settings_screen_use_weight_from_health_connect_c1fe3e2a),
                  stringResource(R.string.l10n_settings_screen_use_weight_from_health_connect_detail_40238f8a),
                  fromHealthConnect) { on ->
            change { profile.useHealthConnectWeight = on }
            // The classic switch pulls the newest reading at once, so the row shows it without waiting for a sync.
            if (on) scope.launch { HealthConnectWeightSync.syncFromRepository(context, viewModel.repo); change {} }
        }
        RowDivider()
        SettingRow(stringResource(R.string.l10n_settings_screen_height_3f608b49)) {
            if (imperial) {
                val (ft, inch) = UnitFormatter.cmToFeetInches(profile.heightCm)
                val inches = UnitFormatter.cmToInches(profile.heightCm).roundToInt()
                ProfileStepper(editing, "$ft′ $inch″",
                        onMinus = { change { profile.heightCm = (inches - 1) * UnitFormatter.CENTIMETERS_PER_INCH } },
                        onPlus = { change { profile.heightCm = (inches + 1) * UnitFormatter.CENTIMETERS_PER_INCH } })
            } else {
                ProfileStepper(editing, "%.0f cm".format(profile.heightCm),
                        onMinus = { change { profile.heightCm -= 1 } }, onPlus = { change { profile.heightCm += 1 } })
            }
        }
        RowDivider()
        // Waist is optional; the first step from "Add" starts at the classic default, as its stepper does.
        val hasWaist = profile.waistCm > 0.0
        SettingRow(stringResource(R.string.l10n_settings_screen_waist_optional_d5356703)) {
            if (imperial) {
                val inches = UnitFormatter.cmToInches(profile.waistCm).roundToInt()
                ProfileStepper(editing, if (hasWaist) "$inches″" else stringResource(if (editing) R.string.forge_settings_add else R.string.forge_profile_not_set),
                        onMinus = { change { profile.waistCm = waistInchesStep(profile.waistCm, up = false) } },
                        onPlus = { change { profile.waistCm = waistInchesStep(profile.waistCm, up = true) } })
            } else {
                ProfileStepper(editing, if (hasWaist) "%.0f cm".format(profile.waistCm) else stringResource(if (editing) R.string.forge_settings_add else R.string.forge_profile_not_set),
                        onMinus = { change { profile.waistCm = waistCmStep(profile.waistCm, up = false) } },
                        onPlus = { change { profile.waistCm = waistCmStep(profile.waistCm, up = true) } })
            }
        }
        Text(stringResource(if (hasWaist) R.string.settings_waist_footnote_set else R.string.settings_waist_footnote_unset),
             style = Forge.type.caption, color = Forge.colors.textTertiary)
        RowDivider()
        // Auto is Tanaka's estimate from the age; a step from Auto starts at that estimate, as iOS does.
        val override = profile.hrMaxOverride
        SettingRow(stringResource(R.string.l10n_settings_screen_max_heart_rate_3d4ed858)) {
            ProfileStepper(editing, if (override > 0) "$override bpm" else stringResource(R.string.forge_settings_hr_auto, profile.hrMaxAuto),
                    onMinus = { change { profile.hrMaxOverride = (if (override > 0) override else profile.hrMaxAuto) - 1 } },
                    onPlus = { change { profile.hrMaxOverride = (if (override > 0) override else profile.hrMaxAuto) + 1 } })
        }
        if (override > 0) {
            TextButton(onClick = { change { profile.hrMaxOverride = 0 } }) {
                Text(stringResource(R.string.forge_settings_hr_use_auto), color = Forge.colors.accent)
            }
        }
    }
    SettingsCard(title = stringResource(R.string.l10n_settings_screen_custom_hr_zones_84736ca5), blurb = null) {
        ToggleRow(stringResource(R.string.l10n_settings_screen_custom_hr_zones_84736ca5),
                  stringResource(R.string.l10n_settings_screen_custom_hr_zones_hint_f7fa3bae),
                  profile.hasCustomHrZones) { change { profile.setCustomHrZonesEnabled(it) } }
        profile.hrZoneThresholds?.forEachIndexed { index, value ->
            RowDivider()
            SettingRow(stringResource(R.string.l10n_settings_screen_zone_starts_a0a60d45, index + 1)) {
                Stepper("$value bpm", onMinus = { change { profile.stepHrZoneThreshold(index, up = false) } },
                        onPlus = { change { profile.stepHrZoneThreshold(index, up = true) } })
            }
        }
    }
}

/** A profile value: plain text while the page is locked, the stepper once "Edit" is on (iOS `profileEditing`). */
@Composable
private fun ProfileStepper(editing: Boolean, value: String, enabled: Boolean = true, onMinus: () -> Unit, onPlus: () -> Unit) {
    if (editing) Stepper(value, enabled, onMinus, onPlus)
    else Text(value, style = Forge.type.bodyNumber, color = Forge.colors.text)
}

/** The date of birth picker: any day from 1900 up to today. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun BirthdayPicker(currentMillis: Long, onPick: (Long) -> Unit, onDismiss: () -> Unit) {
    val utc = java.time.ZoneOffset.UTC
    val local = java.time.ZoneId.systemDefault()
    val initial = java.time.Instant.ofEpochMilli(currentMillis).atZone(local).toLocalDate().atStartOfDay(utc).toInstant().toEpochMilli()
    val state = androidx.compose.material3.rememberDatePickerState(initialSelectedDateMillis = initial,
        yearRange = 1900..java.time.LocalDate.now().year,
        selectableDates = object : androidx.compose.material3.SelectableDates {
            override fun isSelectableDate(utcTimeMillis: Long) = utcTimeMillis <= System.currentTimeMillis()
        })
    androidx.compose.material3.DatePickerDialog(onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = {
                state.selectedDateMillis?.let { ms ->
                    val day = java.time.Instant.ofEpochMilli(ms).atZone(utc).toLocalDate()
                    onPick(day.atStartOfDay(local).toInstant().toEpochMilli())
                }
                onDismiss()
            }) { Text(stringResource(R.string.forge_lay_save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.forge_lay_cancel)) } },
    ) { androidx.compose.material3.DatePicker(state = state) }
}
