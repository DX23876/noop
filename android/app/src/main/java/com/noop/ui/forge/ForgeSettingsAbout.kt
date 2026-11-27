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
import androidx.compose.material.icons.rounded.Code
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.HelpOutline
import androidx.compose.material.icons.rounded.ListAlt
import androidx.compose.material.icons.rounded.LocalCafe
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Contrast
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Map
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.Warning
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

/** The fork's optional donation page, opened in the browser (iOS `ProjectLinks.support`); the app never contacts it. */
private const val SUPPORT_URL = "https://ko-fi.com/dx23876"

@Composable
internal fun HelpSection(viewModel: AppViewModel, onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    val sharing by viewModel.strapLogSharing.collectAsStateWithLifecycle()
    SettingsCard(title = stringResource(R.string.forge_settings_guides), blurb = null) {
        TileLinkRow(Icons.Rounded.HelpOutline, ForgeTokens.Color.systemIndigo.resolve(),
                stringResource(R.string.l10n_settings_screen_how_noop_works_3396b27a),
                stringResource(R.string.l10n_settings_screen_sleep_sorting_scores_recording_and_where_832378b5)) {
            onOpen(ForgeSettingsSub.HowNoopWorks)
        }
        RowDivider()
        TileLinkRow(Icons.Rounded.HelpOutline, ForgeTokens.Color.systemIndigo.resolve(),
                stringResource(R.string.l10n_settings_screen_how_your_scores_work_21a0e2be),
                stringResource(R.string.l10n_settings_screen_charge_effort_and_rest_and_how_d2c423a4)) {
            onOpen(ForgeSettingsSub.ScoringGuide)
        }
        RowDivider()
        TileLinkRow(Icons.Rounded.ListAlt, ForgeTokens.Color.systemGray.resolve(),
                stringResource(R.string.l10n_settings_screen_whoop_4_0_vs_5_0_2babb05a),
                stringResource(R.string.l10n_settings_screen_what_each_strap_can_read_and_51e7d3fc)) {
            onOpen(ForgeSettingsSub.ModelComparison)
        }
        RowDivider()
        TileLinkRow(Icons.Rounded.Info, ForgeTokens.Color.systemGray.resolve(), stringResource(R.string.nav_noop_limitations),
                    null) { onOpen(ForgeSettingsSub.Limitations) }
    }
    // iOS `testCentreCard`: one row into the Test Centre. Sharing the strap log stays here too (Android-only, A-08).
    SettingsCard(title = stringResource(R.string.nav_test_centre), blurb = stringResource(R.string.fsp6_help_tc_blurb)) {
        LinkRow(stringResource(R.string.fsp6_help_open_tc), null) { onOpen(ForgeSettingsSub.TestCentre) }
        RowDivider()
        LinkRow(stringResource(R.string.forge_strap_log_share), stringResource(R.string.forge_strap_log_detail),
                busy = sharing) {
            viewModel.shareStrapLog(context)
        }
    }
    // iOS `rawSensorDiagnosticsCard` (HLP-06): the last 24 hours of decoded sensor streams as one CSV, read-only.
    val scope = rememberCoroutineScope()
    var exporting by remember { mutableStateOf(false) }
    SettingsCard(title = stringResource(R.string.forge_settings_diagnostics), blurb = stringResource(R.string.fsp6_help_diag_blurb)) {
        LinkRow(stringResource(R.string.l10n_settings_screen_export_raw_sensor_data_csv_a171b81e),
                stringResource(R.string.l10n_settings_screen_saves_the_last_24h_of_decoded_f7026f47), busy = exporting) {
            exporting = true
            scope.launch {
                runCatching { com.noop.ingest.RawSensorExport.export(context, viewModel.repo, viewModel.activeStrapId) }
                exporting = false
            }
        }
    }
}

@Composable
internal fun LabSection(viewModel: AppViewModel, onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    // iOS `labGroups`: the page's note first, then one group per feature, its switch on the card and what it does as
    // the footer under it, as iOS Settings lists independent switches.
    // The redesign's switch stood here until 2026-11-20. It is gone, not hidden: the design ships to everyone and the
    // screens under it are not maintained any more, so a way back only produces reports from pages nobody is looking at
    // (`ForgeDesign.retireTheOldDesign`). iOS order: the personal stress baseline (display only, one home since
    // 2026-11-25: Calculations no longer carries it), the training-based VO2max, strength in Effort, AgeLess, the daily rhythm.
    Text(stringResource(R.string.fsp6_lab_blurb), style = Forge.type.footnote, color = Forge.colors.textSecondary,
         modifier = Modifier.padding(horizontal = ForgeMetrics.space4))
    var stressBaseline by remember { mutableStateOf(com.noop.ui.NoopPrefs.stressPersonalBaseline(context)) }
    SettingsCard(title = null, blurb = stringResource(R.string.forge_lab_stress_baseline_note)) {
        ToggleRow(stringResource(R.string.forge_lab_stress_baseline), null, stressBaseline) { on ->
            stressBaseline = on; com.noop.ui.NoopPrefs.setStressPersonalBaseline(context, on)
        }
    }
    var exerciseVO2max by remember { mutableStateOf(com.noop.core.CoreFeatures.exerciseVO2max(context)) }
    SettingsCard(title = null, blurb = stringResource(R.string.forge_lab_xvo2_detail)) {
        ToggleRow(stringResource(R.string.forge_lab_xvo2), null, exerciseVO2max) {
            exerciseVO2max = it
            com.noop.core.CoreFeatures.setExerciseVO2max(context, it)
        }
    }
    // #2438: rated strength sessions add to Effort, as iOS's Lab switch; the flip rescores the whole history.
    var strengthEffort by remember { mutableStateOf(com.noop.core.CoreFeatures.effortStrengthBonus(context)) }
    SettingsCard(title = null, blurb = stringResource(R.string.forge_lab_strength_effort_detail)) {
        ToggleRow(stringResource(R.string.forge_lab_strength_effort), null, strengthEffort) {
            strengthEffort = it
            viewModel.setEffortStrengthBonus(it)
        }
    }
    // Lab "Sleep stages (test)", as on iOS: which recipe stages a night. The flip restages the whole history; the
    // recorded streams and corrected bed and wake times stay.
    var sleepRecipe by remember { mutableStateOf(com.noop.ble.PuffinExperiment.from(context).sleepStagingRecipe) }
    SettingsCard(title = null, blurb = stringResource(R.string.forge_lab_sleep_recipe_detail)) {
        val names = mapOf(
            "standard" to stringResource(R.string.forge_lab_sleep_recipe_standard),
            "restless" to stringResource(R.string.forge_lab_sleep_recipe_restless),
            "trained" to stringResource(R.string.forge_lab_sleep_recipe_trained))
        val explanations = mapOf(
            "standard" to stringResource(R.string.forge_lab_sleep_recipe_standard_detail),
            "restless" to stringResource(R.string.forge_lab_sleep_recipe_restless_detail),
            "trained" to stringResource(R.string.forge_lab_sleep_recipe_trained_detail))
        SettingRow(stringResource(R.string.forge_lab_sleep_recipe)) {
            MenuPicker(names.getValue(sleepRecipe),
                       com.noop.ble.PuffinExperiment.SLEEP_RECIPES,
                       label = { names.getValue(it) }, onSelect = { recipe ->
                           sleepRecipe = recipe
                           viewModel.setSleepStagingRecipe(recipe)
                       })
        }
        // What the chosen recipe does, in plain words, under the menu as on iOS.
        Text(explanations.getValue(sleepRecipe), style = Forge.type.footnote, color = Forge.colors.textSecondary,
             modifier = Modifier.padding(bottom = ForgeMetrics.space2))
    }
    // The two Lab passes of the shared core, as on iOS: off by default, scored at the next analysis.
    var ageless by remember { mutableStateOf(com.noop.core.CoreFeatures.healthspan(context)) }
    SettingsCard(title = null, blurb = stringResource(R.string.forge_lab_ageless_detail)) {
        ToggleRow(stringResource(R.string.forge_lab_ageless), null, ageless) {
            ageless = it
            com.noop.core.CoreFeatures.setHealthspan(context, it)
        }
    }
    var rhythm by remember { mutableStateOf(com.noop.core.CoreFeatures.rhythmAge(context)) }
    SettingsCard(title = null, blurb = stringResource(R.string.forge_lab_rhythm_detail)) {
        ToggleRow(stringResource(R.string.forge_lab_rhythm), null, rhythm) {
            rhythm = it
            com.noop.core.CoreFeatures.setRhythmAge(context, it)
        }
    }
    // Parity plan 1.3: the check that the classic screens' rows and the core's agree. Since Android has no Room store
    // the classic rows come from the core as well (CORE-ONLY-PLAN), so the switch is gone.
    SettingsCard(title = null, blurb = null) {
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
    val colors = Forge.colors
    fun open(url: String) = context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    SettingsCard(title = null, blurb = stringResource(R.string.fsp6_about_blurb)) {
        // iOS `aboutCard`: the name with the version pill, then What's new. The flavour names (a testing build is
        // "NOOP Forge Staging") are too long to share one line with the button, which a Row squeezed to nothing.
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Text(stringResource(R.string.app_name), style = Forge.type.title2, color = colors.text,
                 modifier = Modifier.weight(1f, fill = false))
            ForgeBadgePill(stringResource(R.string.fsp6_about_pill, BuildConfig.VERSION_NAME), ForgeBadgeTone.Neutral)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
            PillButton(Icons.Rounded.AutoAwesome, stringResource(R.string.l10n_settings_screen_what_s_new_4d8dc5fe)) {
                onOpen(ForgeSettingsSub.WhatsNew)
            }
        }
        // Which build this is (#47): the commit and date of the testing build, to read back beside a strap log.
        BuildIdentity.stamp?.let { stamp ->
            androidx.compose.foundation.text.selection.SelectionContainer {
                Text(stamp, style = Forge.type.footnote, color = colors.textTertiary)
            }
        }
        RowDivider()
        TileLinkRow(Icons.Rounded.Description, ForgeTokens.Color.systemIndigo.resolve(),
                    stringResource(R.string.forge_provider_acknowledgements), stringResource(R.string.fsp6_ack_detail)) {
            onOpen(ForgeSettingsSub.Acknowledgements)
        }
        RowDivider()
        // Check for updates: a single, user-initiated read of GitHub's public releases API.
        Row(verticalAlignment = Alignment.CenterVertically) {
            PillButton(Icons.Rounded.Sync,
                       stringResource(if (checking) R.string.l10n_settings_screen_checking_820d6004
                                      else R.string.l10n_settings_screen_check_for_updates_736b9062),
                       enabled = !checking) {
                checking = true; result = null
                scope.launch { result = UpdateCheck.check(BuildConfig.VERSION_NAME); checking = false }
            }
            Spacer(Modifier.width(ForgeMetrics.space3))
            Text(
                when (val r = result) {
                    is UpdateCheck.Result.UpToDate -> stringResource(R.string.l10n_settings_screen_you_re_on_the_latest_r_027a82be, r.version)
                    UpdateCheck.Result.Failed -> stringResource(R.string.l10n_settings_screen_couldn_t_check_try_again_b3c885d9)
                    else -> ""
                },
                style = Forge.type.footnote, modifier = Modifier.weight(1f),
                color = if (result == UpdateCheck.Result.Failed) ForgeTokens.StrandPalette.statusWarningForeground.resolve()
                        else colors.textSecondary,
            )
        }
        // #1659: the automatic half.
        ToggleRow(stringResource(R.string.l10n_settings_screen_check_automatically_7cd229d2),
                  stringResource(R.string.l10n_settings_screen_once_a_day_noop_asks_github_5683aad3), automatic) {
            automatic = it; UpdateWatch.setEnabled(context, it)
        }
        // An update is available: what is new, with a download straight to the release.
        (result as? UpdateCheck.Result.Available)?.let { available ->
            Column(Modifier.fillMaxWidth().background(colors.inset, RoundedCornerShape(10.dp)).padding(ForgeMetrics.space3),
                   verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.forge_settings_update_available, available.version), style = Forge.type.body,
                         color = colors.text, modifier = Modifier.weight(1f))
                    TextButton(onClick = { open(available.url) }) {
                        Text(stringResource(R.string.l10n_settings_screen_download_a479c9c3), color = colors.accent)
                    }
                }
                if (available.notes.isNotEmpty()) {
                    Column(Modifier.fillMaxWidth().heightIn(max = 150.dp).verticalScroll(rememberScrollState())) {
                        Text(available.notes, style = Forge.type.footnote, color = colors.textSecondary)
                    }
                }
            }
        }
        Text(stringResource(R.string.fsp6_about_check_note), style = Forge.type.footnote, color = colors.textSecondary)
        RowDivider()
        TileLinkRow(Icons.Rounded.Code, ForgeTokens.Color.systemGray.resolve(),
                    stringResource(R.string.l10n_settings_screen_project_home_source_994627c1),
                    stringResource(R.string.l10n_settings_screen_github_code_releases_issues_and_the_50b41e25),
                    external = true) { open(SOURCE_URL) }
        RowDivider()
        // Optional donation link (Ko-fi): a plain browser link, no request from the app (iOS `ProjectLinks.support`).
        TileLinkRow(Icons.Rounded.LocalCafe, ForgeTokens.Color.systemGray.resolve(), stringResource(R.string.fsp6_about_support),
                    stringResource(R.string.fsp6_about_support_detail), external = true) { open(SUPPORT_URL) }
        Text(stringResource(R.string.fsp6_about_intro), style = Forge.type.subhead, color = colors.textSecondary)
        // The medical disclaimer, on the inset with a warning mark as iOS draws it.
        Row(Modifier.fillMaxWidth().background(colors.inset, RoundedCornerShape(10.dp)).padding(ForgeMetrics.space3),
            horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Icon(Icons.Rounded.Warning, contentDescription = null, modifier = Modifier.size(16.dp),
                 tint = ForgeTokens.StrandPalette.statusWarningForeground.resolve())
            Text(stringResource(R.string.l10n_settings_screen_noop_is_not_a_medical_device_ab32ef7e),
                 style = Forge.type.footnote, color = colors.textSecondary)
        }
        RowDivider()
        Text(stringResource(R.string.fsp6_about_built_on).uppercase(), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold),
             color = colors.textSecondary)
        Text(stringResource(R.string.fsp6_about_proto4),
             style = Forge.type.footnote, color = colors.text)
        Text(stringResource(R.string.fsp6_about_proto5),
             style = Forge.type.footnote, color = colors.text)
        Text(stringResource(R.string.l10n_settings_screen_open_source_ble_reverse_engineering_work_40062271),
             style = Forge.type.footnote, color = colors.textSecondary)
    }
    SettingsCard(title = null, blurb = null) {
        // The classic screens stay one switch away for what the Forge screens do not cover; their Settings switch back.
        LinkRow(stringResource(R.string.forge_classic_screens), stringResource(R.string.forge_classic_screens_detail)) {
            ForgeUi.setEnabled(context, false)
            ForgeUi.restart(context)
        }
    }
}
