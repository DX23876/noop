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

// Settings › Calculations and Data and backup.

@Composable
internal fun CalculationsSection(viewModel: AppViewModel, change: (() -> Unit) -> Unit, onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    val experiment = remember { PuffinExperiment.from(context) }
    // Day start rescores at once through the view model, as the classic row does.
    val dayCycle = NoopPrefs.dayCycleMode(context)
    SettingsCard(title = stringResource(R.string.settings_day_cycle_title), blurb = stringResource(R.string.settings_day_cycle_description)) {
        SettingRow(stringResource(R.string.settings_day_cycle_starts)) {
            Segmented(listOf(DayCycleMode.SLEEP_ONSET, DayCycleMode.MIDNIGHT), dayCycle,
                      label = {
                          stringResource(if (it == DayCycleMode.SLEEP_ONSET) R.string.settings_day_cycle_sleep
                                         else R.string.settings_day_cycle_midnight)
                      },
                      onSelect = { change { viewModel.setDayCycleMode(it) } })
        }
        Text(stringResource(if (dayCycle == DayCycleMode.SLEEP_ONSET) R.string.settings_day_cycle_sleep_description
                            else R.string.settings_day_cycle_midnight_description),
             style = Forge.type.caption, color = Forge.colors.textTertiary)
    }
    SettingsCard(title = stringResource(R.string.forge_settings_scores), blurb = null) {
        // No Effort-model switch: the shared core scores Effort with one fitted curve since #2438 and ignores the
        // former Banister preference (`CoreAnalysis.Settings.effortBanister`), as iOS removed its row.
        SettingRow(stringResource(R.string.l10n_settings_screen_hrv_window_e74320b8)) {
            Segmented(listOf(HrvWindow.WHOLE_NIGHT, HrvWindow.DEEP_SLEEP), UnitPrefs.hrvWindow(context),
                      label = { stringResource(if (it == HrvWindow.DEEP_SLEEP) R.string.forge_settings_hrv_deep else R.string.forge_settings_hrv_night) },
                      onSelect = {
                          // The classic row clears the analysis watermark and syncs, so recent nights are scored again.
                          change {
                              UnitPrefs.setHrvWindow(context, it)
                              NoopPrefs.setAnalyzeWatermark(context, "")
                              viewModel.syncNow()
                          }
                          Toast.makeText(context, context.getString(R.string.forge_settings_hrv_rescoring), Toast.LENGTH_LONG).show()
                      })
        }
        Text(stringResource(R.string.l10n_settings_screen_whole_night_is_noop_s_default_fbfff434),
             style = Forge.type.caption, color = Forge.colors.textTertiary)
    }
    SettingsCard(title = stringResource(R.string.forge_settings_sleep), blurb = null) {
        // V3 runs in the shared Swift core; the optional legacy Kotlin screen keeps its V1/V2 choice.
        if (com.noop.core.CoreDailyRows.coreReads(context)) {
            Text(stringResource(R.string.sleep_stager_method), style = Forge.type.body,
                 color = Forge.colors.text)
            Segmented(com.noop.ble.PuffinExperiment.SLEEP_METHODS, experiment.sleepStagerMethod,
                      label = { it.uppercase(java.util.Locale.ROOT) }, onSelect = { method ->
                          change {
                              viewModel.setSleepStagerMethod(method)
                          }
                      })
            Text(stringResource(R.string.sleep_stager_method_detail), style = Forge.type.caption,
                 color = Forge.colors.textTertiary)
        } else {
            ToggleRow(stringResource(R.string.l10n_settings_screen_sleep_staging_v2_a4176770),
                      stringResource(R.string.l10n_settings_screen_a_transparent_cardiorespiratory_recipe_that_recovers_eebe00c2),
                      experiment.experimentalSleepV2) { on -> change { viewModel.setSleepStagerMethod(if (on) "v2" else "v1") } }
        }
        RowDivider()
        ToggleRow(stringResource(R.string.l10n_settings_screen_motion_aware_wake_refinement_67a91e47),
                  stringResource(R.string.l10n_settings_screen_reviews_each_scored_wake_block_for_537924ea),
                  experiment.motionAwareWake) { on -> change { experiment.motionAwareWake = on } }
        // iOS's Lab switch beside the wake check: hourly stress against the wearer's usual days (display only).
        RowDivider()
        val stressContext = androidx.compose.ui.platform.LocalContext.current
        var stressBaseline by remember { mutableStateOf(com.noop.ui.NoopPrefs.stressPersonalBaseline(stressContext)) }
        ToggleRow(stringResource(R.string.forge_lab_stress_baseline), stringResource(R.string.forge_lab_stress_baseline_note),
                  stressBaseline) { on -> stressBaseline = on; com.noop.ui.NoopPrefs.setStressPersonalBaseline(stressContext, on) }
    }
    // "If scores look wrong" (iOS `AnalysisMaintenanceSettingsCard`): the status of the engine, Refresh today,
    // Recalculate the last 21 days and Reset Charge baseline, in `ForgeSettingsScoreRepair.kt`. The Charge row that
    // opened the classic card is gone: its one button lives here, with the confirmation, as on iOS.
    ScoreRepairSection(viewModel)
}

@Composable
internal fun DataBackupSection(viewModel: AppViewModel, onOpen: (ForgeSettingsSub) -> Unit) {
    val backup = rememberBackupActions()
    // The WHOOP-format CSV export, moved here from the classic Backup card, which All settings no longer shows:
    // this card is the one place for backups (CORE-ONLY-PLAN).
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val csvExport = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { WhoopCsvExporter.exportZip(context, uri, viewModel.repo, viewModel.activeStrapId) }
            }
            result.fold(
                onSuccess = { msg ->
                    Toast.makeText(context, "$msg Re-import it via Data sources → WHOOP import, on Android or Mac.",
                                   Toast.LENGTH_LONG).show()
                },
                onFailure = { e -> Toast.makeText(context, "CSV export problem: ${e.message}", Toast.LENGTH_LONG).show() },
            )
        }
    }
    SettingsCard(title = stringResource(R.string.forge_backup_section), blurb = null) {
        LinkRow(stringResource(R.string.forge_backup_export), stringResource(R.string.forge_backup_export_detail), onClick = backup.export)
        RowDivider()
        LinkRow(stringResource(R.string.forge_backup_import), stringResource(R.string.forge_backup_import_detail), onClick = backup.import)
        RowDivider()
        LinkRow(stringResource(R.string.l10n_settings_screen_export_csv_6bce63a3), null) {
            csvExport.launch("noop-export-${java.time.LocalDate.now()}.zip")
        }
        // The two notes the iOS card carries under its buttons: what an import does and that the file is not
        // encrypted (#644). Both sentences are the classic Backup card's strings, which iOS shares word for word.
        Text(stringResource(R.string.l10n_settings_screen_importing_overwrites_everything_currently_on_this_297b76ae),
             style = Forge.type.caption, color = Forge.colors.textSecondary)
        Text(stringResource(R.string.l10n_settings_screen_this_is_a_plain_unencrypted_archive_b0dfe63d),
             style = Forge.type.caption, color = ForgeTokens.StrandPalette.statusWarningForeground.resolve())
        RowDivider()
        LinkRow(stringResource(R.string.l10n_settings_screen_automatic_backups_8a772f3c),
                stringResource(R.string.forge_settings_auto_backup_detail)) { onOpen(ForgeSettingsSub.BackupSync) }
    }
    SettingsCard(title = stringResource(R.string.forge_settings_imports), blurb = null) {
        LinkRow(stringResource(R.string.nav_data_sources), stringResource(R.string.forge_settings_data_sources_detail)) {
            onOpen(ForgeSettingsSub.DataSources)
        }
        RowDivider()
        // Where the space goes and a one-tap clean-up (iOS `StorageView`), after Data sources as on iOS.
        LinkRow(stringResource(R.string.fsp5_storage_title), stringResource(R.string.fsp5_storage_subtitle)) {
            onOpen(ForgeSettingsSub.Storage)
        }
        RowDivider()
        LinkRow(stringResource(R.string.nav_self_hosted_push), stringResource(R.string.push_settings_row_detail)) {
            onOpen(ForgeSettingsSub.SelfHostedPush)
        }
    }
    StepsSourceCard()
}

/**
 * Where daily steps come from, as iOS's Devices and data sources picker (`StepsSource`): automatically (the strap's
 * count, then the phone's, then the 4.0's estimate), the strap alone, or Health Connect alone. The one steps reader
 * in the core follows it, so the Today tile, the steps page and AgeLess show the same count.
 */
@Composable
internal fun StepsSourceCard() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var chosen by remember { mutableStateOf("automatic") }
    LaunchedEffect(Unit) {
        chosen = withContext(Dispatchers.IO) { com.noop.core.CorePrefs.read(context).optString(com.noop.core.CorePrefs.STEPS_SOURCE, "automatic") }
            .ifEmpty { "automatic" }
    }
    SettingsCard(title = stringResource(R.string.forge_steps_from), blurb = stringResource(R.string.forge_steps_auto_note)) {
        listOf("automatic" to stringResource(R.string.forge_steps_auto), "strap" to stringResource(R.string.forge_steps_strap),
               "phone" to stringResource(R.string.today_source_health_connect)).forEachIndexed { i, (key, label) ->
            if (i > 0) RowDivider()
            Row(Modifier.fillMaxWidth().selectable(selected = chosen == key, role = androidx.compose.ui.semantics.Role.RadioButton) {
                    if (chosen == key) return@selectable
                    chosen = key
                    scope.launch { withContext(Dispatchers.IO) { com.noop.core.CorePrefs.setStepsSource(context, key) } }
                }.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(label, style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
                if (chosen == key) Icon(Icons.Rounded.Check, contentDescription = null, tint = Forge.colors.accent)
            }
        }
    }
}
