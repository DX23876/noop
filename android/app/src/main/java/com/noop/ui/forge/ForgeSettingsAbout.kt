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

// Settings › Help, Lab and About.

private const val SOURCE_URL = "https://github.com/DX23876/noop"

@Composable
internal fun HelpSection(viewModel: AppViewModel, onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    val sharing by viewModel.strapLogSharing.collectAsStateWithLifecycle()
    SettingsCard(title = stringResource(R.string.forge_settings_guides), blurb = null) {
        LinkRow(stringResource(R.string.l10n_settings_screen_how_noop_works_3396b27a),
                stringResource(R.string.l10n_settings_screen_sleep_sorting_scores_recording_and_where_832378b5)) {
            onOpen(ForgeSettingsSub.HowNoopWorks)
        }
        RowDivider()
        LinkRow(stringResource(R.string.l10n_settings_screen_how_your_scores_work_21a0e2be),
                stringResource(R.string.l10n_settings_screen_charge_effort_and_rest_and_how_d2c423a4)) {
            onOpen(ForgeSettingsSub.ScoringGuide)
        }
        RowDivider()
        LinkRow(stringResource(R.string.l10n_settings_screen_whoop_4_0_vs_5_0_2babb05a),
                stringResource(R.string.l10n_settings_screen_what_each_strap_can_read_and_51e7d3fc)) {
            onOpen(ForgeSettingsSub.ModelComparison)
        }
        RowDivider()
        LinkRow(stringResource(R.string.nav_noop_limitations), null) { onOpen(ForgeSettingsSub.Limitations) }
    }
    SettingsCard(title = stringResource(R.string.forge_settings_diagnostics), blurb = null) {
        LinkRow(stringResource(R.string.nav_test_centre), stringResource(R.string.forge_settings_test_centre_detail)) {
            onOpen(ForgeSettingsSub.TestCentre)
        }
        RowDivider()
        LinkRow(stringResource(R.string.forge_strap_log_share), stringResource(R.string.forge_strap_log_detail),
                busy = sharing) {
            viewModel.shareStrapLog(context)
        }
    }
}

@Composable
internal fun LabSection(viewModel: AppViewModel, onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    SettingsCard(title = stringResource(R.string.forge_experimental_section), blurb = null) {
        // The redesign's switch stood here until 2026-11-20. It is gone, not hidden: the design ships to
        // everyone and the screens under it are not maintained any more, so a way back only produces
        // reports from pages nobody is looking at (`ForgeDesign.retireTheOldDesign`).
        // The two Lab passes of the shared core, as on iOS: off by default, scored at the next analysis.
        var ageless by remember { mutableStateOf(com.noop.core.CoreFeatures.healthspan(context)) }
        ToggleRow(stringResource(R.string.forge_lab_ageless), stringResource(R.string.forge_lab_ageless_detail), ageless) {
            ageless = it
            com.noop.core.CoreFeatures.setHealthspan(context, it)
        }
        RowDivider()
        var rhythm by remember { mutableStateOf(com.noop.core.CoreFeatures.rhythmAge(context)) }
        ToggleRow(stringResource(R.string.forge_lab_rhythm), stringResource(R.string.forge_lab_rhythm_detail), rhythm) {
            rhythm = it
            com.noop.core.CoreFeatures.setRhythmAge(context, it)
        }
        RowDivider()
        var exerciseVO2max by remember { mutableStateOf(com.noop.core.CoreFeatures.exerciseVO2max(context)) }
        ToggleRow(stringResource(R.string.forge_lab_xvo2), stringResource(R.string.forge_lab_xvo2_detail), exerciseVO2max) {
            exerciseVO2max = it
            com.noop.core.CoreFeatures.setExerciseVO2max(context, it)
        }
        RowDivider()
        // #2438: rated strength sessions add to Effort, as iOS's Lab switch; the flip rescores the whole history.
        var strengthEffort by remember { mutableStateOf(com.noop.core.CoreFeatures.effortStrengthBonus(context)) }
        ToggleRow(stringResource(R.string.forge_lab_strength_effort),
                  stringResource(R.string.forge_lab_strength_effort_detail), strengthEffort) {
            strengthEffort = it
            viewModel.setEffortStrengthBonus(it)
        }
        RowDivider()
        // Parity plan 1.3: the check that the classic screens' rows and the core's agree. Since Android has no
        // Room store the classic rows come from the core as well (CORE-ONLY-PLAN), so the switch is gone.
        val scope = rememberCoroutineScope()
        var comparison by remember { mutableStateOf<String?>(null) }
        val same = stringResource(R.string.forge_lab_compare_same)
        val unavailable = stringResource(R.string.forge_lab_compare_none)
        val res = LocalContext.current.resources
        TextButton(onClick = {
            scope.launch {
                // The daily rows first, then the workout list: one count over both, naming the first difference.
                val days = viewModel.compareDailyRowsWithCore()
                val workouts = viewModel.compareWorkoutsWithCore()
                val found = if (days == null || workouts == null) null
                    else days.map { listOf(it.day, it.field, it.room, it.core) } +
                         workouts.map { listOf(it.session, it.field, it.room, it.core) }
                comparison = when {
                    found == null -> unavailable
                    found.isEmpty() -> same
                    else -> found.first().let { (where, field, room, core) ->
                        res.getString(R.string.forge_lab_compare_diff, found.size,
                                      res.getString(R.string.forge_join_dot, where,
                                                    res.getString(R.string.forge_join_arrow, res.getString(R.string.forge_join_space, field, room), core)))
                    }
                }
            }
        }) { Text(stringResource(R.string.forge_lab_compare)) }
        comparison?.let { Text(it, style = Forge.type.caption, color = Forge.colors.textSecondary) }
    }
    SettingsCard(title = null, blurb = null) {
        LinkRow(stringResource(R.string.l10n_settings_screen_health_wellness_93475778),
                stringResource(R.string.forge_settings_wellness_detail)) { onOpen(ForgeSettingsSub.HealthWellness) }
        RowDivider()
        LinkRow(stringResource(R.string.l10n_settings_screen_advanced_4d064726),
                stringResource(R.string.forge_settings_advanced_detail)) { onOpen(ForgeSettingsSub.Advanced) }
    }
}

@Composable
internal fun AboutSection(onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var checking by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<UpdateCheck.Result?>(null) }
    var automatic by remember { mutableStateOf(UpdateWatch.isEnabled(context)) }
    SettingsCard(title = null, blurb = null) {
        SettingRow(stringResource(R.string.forge_version, BuildIdentity.uiVersion)) {}
        RowDivider()
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.l10n_settings_screen_check_automatically_7cd229d2), style = Forge.type.body,
                     color = Forge.colors.text)
                Text(stringResource(R.string.l10n_settings_screen_once_a_day_noop_asks_github_5683aad3),
                     style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
            Switch(checked = automatic, onCheckedChange = { automatic = it; UpdateWatch.setEnabled(context, it) },
                   colors = forgeSwitchColors())
        }
        RowDivider()
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(enabled = !checking, onClick = {
                checking = true; result = null
                scope.launch { result = UpdateCheck.check(BuildConfig.VERSION_NAME); checking = false }
            }) {
                Text(stringResource(if (checking) R.string.l10n_settings_screen_checking_820d6004
                                    else R.string.l10n_settings_screen_check_for_updates_736b9062),
                     color = Forge.colors.accent)
            }
            Text(
                when (val r = result) {
                    is UpdateCheck.Result.UpToDate -> stringResource(R.string.l10n_settings_screen_you_re_on_the_latest_r_027a82be, r.version)
                    is UpdateCheck.Result.Available -> stringResource(R.string.forge_settings_update_available, r.version)
                    UpdateCheck.Result.Failed -> stringResource(R.string.l10n_settings_screen_couldn_t_check_try_again_b3c885d9)
                    null -> ""
                },
                style = Forge.type.caption, color = Forge.colors.textSecondary, modifier = Modifier.weight(1f),
            )
        }
        (result as? UpdateCheck.Result.Available)?.let { available ->
            TextButton(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(available.url))) }) {
                Text(stringResource(R.string.forge_settings_update_open), color = Forge.colors.accent)
            }
        }
        RowDivider()
        TextButton(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(SOURCE_URL))) }) {
            Text(stringResource(R.string.forge_settings_source), color = Forge.colors.accent)
        }
    }
    SettingsCard(title = null, blurb = null) {
        LinkRow(stringResource(R.string.forge_provider_acknowledgements),
                stringResource(R.string.forge_provider_acknowledgements_detail)) { onOpen(ForgeSettingsSub.Acknowledgements) }
        RowDivider()
        LinkRow(stringResource(R.string.l10n_settings_screen_what_s_new_4d8dc5fe),
                stringResource(R.string.l10n_settings_screen_recent_changes_and_what_to_expect_3ceb660b)) {
            onOpen(ForgeSettingsSub.WhatsNew)
        }
    }
    SettingsCard(title = null, blurb = null) {
        // The classic screens stay one switch away for what the Forge screens do not cover; their Settings switch back.
        LinkRow(stringResource(R.string.forge_classic_screens), stringResource(R.string.forge_classic_screens_detail)) {
            ForgeUi.setEnabled(context, false)
            ForgeUi.restart(context)
        }
    }
}
