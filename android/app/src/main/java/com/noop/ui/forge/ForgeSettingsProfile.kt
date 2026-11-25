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
import androidx.compose.material.icons.rounded.PhotoCamera
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
import com.noop.core.CoreProfile
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

/** The sex choices the profile stores, by tag, with iOS's labels (the third is "Non-binary"). */
private val SEX_CHOICES = listOf("male" to R.string.onboarding_male, "female" to R.string.onboarding_female,
                                 "nonbinary" to R.string.fsp1_sex_nonbinary)

@Composable
internal fun ProfileSection(profile: ProfileStore, viewModel: AppViewModel, change: (() -> Unit) -> Unit,
                           onOpen: (ForgeSettingsSub) -> Unit, editing: Boolean, onEditing: (Boolean) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val imperial = UnitPrefs.system(context) == UnitSystem.IMPERIAL
    // The maximum heart rate is the core's (the level measured in workouts, else the age formula): ask it once for this
    // age, off the main thread, and redraw only if the answer is not the one already kept.
    LaunchedEffect(profile.age) {
        val before = profile.hrMaxAuto to profile.hrMaxAutoSource
        withContext(Dispatchers.IO) { CoreProfile.refreshMaxHeartRate(profile) }
        if (before != (profile.hrMaxAuto to profile.hrMaxAutoSource)) change {}
    }
    // The photo and the figures under it, as iOS's `forgeProfileHead`: the avatar large with a camera badge, tap it to change.
    ProfileHead(profile)
    // iOS keeps the fields still until "Edit" (`profileEditing`): plain values, then steppers and pickers.
    SettingsCard(title = null, blurb = stringResource(R.string.fsp1_profile_blurb)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(onClick = { onEditing(!editing) }) {
                Text(stringResource(if (editing) R.string.forge_profile_done else R.string.forge_profile_edit),
                     style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.accent)
            }
        }
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
            ProfileChoice(editing, stringResource(SEX_CHOICES.first { it.first == profile.sex }.second),
                          SEX_CHOICES.map { stringResource(it.second) }) { change { profile.sex = SEX_CHOICES[it].first } }
        }
        // Only when the sex above cannot choose an equation by itself: the body-fat method was fitted on a male and a
        // female group and takes different measurements, so there is nothing to average. Asked here, once.
        if (profile.sex == "nonbinary") {
            RowDivider()
            val formulas = listOf("" to R.string.forge_profile_not_set, "male" to R.string.fsp1_formula_male,
                                  "female" to R.string.fsp1_formula_female)
            SettingRow(stringResource(R.string.fsp1_body_formula)) {
                ProfileChoice(editing, stringResource(formulas.first { it.first == profile.bodyFormulaSex }.second),
                              formulas.map { stringResource(it.second) }) { change { profile.bodyFormulaSex = formulas[it].first } }
            }
            Text(stringResource(R.string.fsp1_formula_note), style = Forge.type.caption, color = Forge.colors.textSecondary)
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
        // Waist is optional; the first step from "Add" starts at the classic default, as its stepper does. iOS's new
        // design leaves the waist to the Body page; Android keeps the field (it is sent to the core), see SETTINGS-PARITY PRO-09.
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
        // The number is always shown: the value in force, muted while it is automatic, with the line that says where it
        // comes from. A step starts from the value on screen, and below 120 it returns to automatic (iOS `hrMaxField`).
        val override = profile.hrMaxOverride
        SettingRow(stringResource(R.string.l10n_settings_screen_max_heart_rate_3d4ed858)) {
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                val label = "${profile.hrMax} ${stringResource(R.string.fsp1_hz_bpm_unit)}"
                if (editing) {
                    Stepper(label, onMinus = { change { profile.hrMaxOverride = if (profile.hrMax - 1 < 120) 0 else profile.hrMax - 1 } },
                            onPlus = { change { profile.hrMaxOverride = minOf(230, profile.hrMax + 1) } })
                } else {
                    Text(label, style = Forge.type.bodyNumber, color = if (override > 0) Forge.colors.text else Forge.colors.textTertiary)
                }
                Text(maxHeartRateCaption(profile), style = Forge.type.footnote,
                     color = if (override > 0) Forge.colors.accent else Forge.colors.textTertiary)
            }
        }
        RowDivider()
        // The aerobic capacity the energy model scales workouts to. Empty is the normal state: a fresh reading or the
        // estimate from resting heart rate then applies. The pass picks an entered value up from the next sync.
        val vo2 = profile.vo2maxManual
        val vo2Set = vo2 > 0
        SettingRow(stringResource(R.string.fsp1_vo2max)) {
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                val label = if (vo2Set) "%.1f %s".format(vo2, stringResource(R.string.fsp1_vo2_unit)) else stringResource(R.string.fsp1_auto)
                if (editing) {
                    Stepper(label, onMinus = { val next = vo2 - 0.5; change { profile.setManualVO2max(if (next < 10) null else next) } },
                            onPlus = { change { profile.setManualVO2max(minOf(90.0, if (vo2Set) vo2 + 0.5 else 25.0)) } })
                } else {
                    Text(label, style = Forge.type.bodyNumber, color = if (vo2Set) Forge.colors.text else Forge.colors.textTertiary)
                }
                if (vo2Set) {
                    Text(stringResource(R.string.fsp1_vo2_entered, profileDate(profile.vo2maxManualDay)), style = Forge.type.footnote,
                         color = Forge.colors.accent)
                }
            }
        }
        // A formula the energy model used for a body beyond its range reads high: say so, and what would be better.
        var formulaAdvised by remember { mutableStateOf(false) }
        LaunchedEffect(vo2, profile.heightCm, profile.weightKg) {
            formulaAdvised = !vo2Set && withContext(Dispatchers.IO) { CoreProfile.vo2FormulaAdvised(profile.weightKg, profile.heightCm) }
        }
        if (formulaAdvised) {
            Text(stringResource(R.string.fsp1_vo2_hint), style = Forge.type.caption, color = ForgeTokens.Color.systemOrange.resolve())
        }
        RowDivider()
        val levels = (0..5).map { if (it == 0) stringResource(R.string.fsp1_auto) else stringResource(R.string.fsp1_activity_level, it) }
        SettingRow(stringResource(R.string.fsp1_activity)) {
            ProfileChoice(editing, levels[profile.activityLevelOverride], levels) { change { profile.activityLevelOverride = it } }
        }
        Text(stringResource(R.string.fsp1_activity_note), style = Forge.type.caption, color = Forge.colors.textSecondary)
        RowDivider()
        // Where each zone starts: its own page (the editor), with what is in force on the row.
        var zoneSummary by remember { mutableStateOf<CoreProfile.ZoneDraft?>(null) }
        LaunchedEffect(profile.hrZoneMode, profile.hrZoneBpms, profile.hrZonePercents, profile.hrMax) {
            zoneSummary = withContext(Dispatchers.IO) {
                CoreProfile.zones(profile.hrZoneMode, profile.hrZonePercents, profile.hrZoneBpms, profile.hrMax,
                                  if (override > 0) "manual" else profile.hrMaxAutoSource.ifEmpty { "gellish" })
            }
        }
        val summary = zoneSummary
        LinkRow(stringResource(R.string.fsp1_zones_row),
                if (summary != null && summary.custom) stringResource(R.string.fsp1_zones_custom, summary.bounds)
                else stringResource(R.string.fsp1_zones_standard)) { onOpen(ForgeSettingsSub.HrZones) }
        Text(stringResource(R.string.fsp1_zones_note), style = Forge.type.caption, color = Forge.colors.textSecondary)
    }
}

/** The new design's profile head: the photo large with a camera badge (tap it to change it), and the figures under it in one line. */
@Composable
private fun ProfileHead(profile: ProfileStore) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val photoPicker = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) scope.launch { withContext(Dispatchers.IO) { com.noop.ui.ProfileAvatarStore.setAvatarFromUri(context, uri) } }
    }
    val hasAvatar = com.noop.ui.ProfileAvatarStore.hasAvatar
    Column(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2), horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.clickable(role = androidx.compose.ui.semantics.Role.Button,
                               onClickLabel = stringResource(if (hasAvatar) R.string.forge_profile_change_photo else R.string.forge_profile_choose_photo)) {
            photoPicker.launch(androidx.activity.result.PickVisualMediaRequest(
                androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageOnly))
        }) {
            com.noop.ui.ProfileAvatar(size = 104.dp, contentDescription = null)
            Box(Modifier.align(Alignment.BottomEnd).size(32.dp).background(Forge.colors.surface, CircleShape),
                contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.PhotoCamera, null, tint = Forge.colors.text, modifier = Modifier.size(16.dp))
            }
        }
        Text(listOf(androidx.compose.ui.res.pluralStringResource(R.plurals.fsp1_profile_years, profile.age, profile.age), stringResource(R.string.forge_body_cm, profile.heightCm.roundToInt().toString()),
                    UnitFormatter.massFromKilograms(profile.weightKg, UnitSystem.METRIC)).joinToString(" · "),
             style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.sceneInk.secondary)
        // The photo can also be taken off again: Android keeps iOS's classic remove action, which the new head lacks.
        if (hasAvatar) {
            TextButton(onClick = { com.noop.ui.ProfileAvatarStore.clearAvatar(context) }) {
                Text(stringResource(R.string.l10n_settings_screen_remove_photo_c8f5eda8), color = Forge.sceneInk.secondary)
            }
        }
    }
}

/** A choice that is plain text while the page is locked and a menu once "Edit" is on (iOS `Picker(.menu)`). */
@Composable
private fun ProfileChoice(editing: Boolean, current: String, options: List<String>, onPick: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.clickable(enabled = editing) { open = true }, verticalAlignment = Alignment.CenterVertically) {
            Text(current, style = Forge.type.bodyNumber, color = if (editing) Forge.colors.accent else Forge.colors.text)
            if (editing) Icon(Icons.Rounded.UnfoldMore, null, tint = Forge.colors.textTertiary, modifier = Modifier.size(18.dp))
        }
        androidx.compose.material3.DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEachIndexed { index, label ->
                androidx.compose.material3.DropdownMenuItem(text = { Text(label) }, onClick = { open = false; onPick(index) })
            }
        }
    }
}

/** Where the maximum heart rate in use comes from, so the number beside it is never unexplained (iOS `maxHeartRateCaption`). */
@Composable
private fun maxHeartRateCaption(profile: ProfileStore): String = when {
    profile.hrMaxOverride > 0 -> stringResource(R.string.fsp1_maxhr_manual)
    profile.hrMaxAutoSource == "measured" ->
        stringResource(R.string.fsp1_maxhr_measured, profileDate(profile.hrMaxMeasuredOn))
    profile.hrMaxAutoSource == "default" -> stringResource(R.string.fsp1_maxhr_auto)
    else -> stringResource(R.string.fsp1_maxhr_age)
}

/** A `yyyy-MM-dd` day as a short local date; the text itself when it is not one. */
private fun profileDate(day: String): String = runCatching {
    java.time.LocalDate.parse(day).format(java.time.format.DateTimeFormatter.ofLocalizedDate(java.time.format.FormatStyle.MEDIUM))
}.getOrDefault(day)

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
