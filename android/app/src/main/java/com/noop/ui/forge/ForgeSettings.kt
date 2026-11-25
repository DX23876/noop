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
import com.noop.ui.AutomationsScope
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

private const val ISSUES_URL = "https://github.com/DX23876/noop/issues"

/**
 * The Forge Settings pages, as the iOS hub lists them (`SettingsPage`): title, subtitle and icon. [hosted] marks the
 * pages that are a classic screen of their own, as iOS marks `isStandaloneScreen` (Strap hosts the classic Strap
 * card, which keeps its Bluetooth controls in one place).
 */
enum class ForgeSettingsPage(val titleRes: Int, val subtitleRes: Int, val icon: ImageVector, val hosted: Boolean = false) {
    Roadmap(R.string.project_page_title, R.string.fsp6_sub_roadmap, Icons.Rounded.Map),
    Profile(R.string.l10n_settings_screen_profile_ff4fc027, R.string.forge_settings_profile_subtitle, Icons.Rounded.AccountCircle),
    Goals(R.string.forge_goals_more_title, R.string.forge_sg_goals_subtitle, Icons.Rounded.TrackChanges),
    Strap(R.string.l10n_settings_screen_strap_02b88eeb, R.string.fsp6_sub_strap, Icons.Rounded.SettingsInputAntenna),
    BatteryRecording(R.string.forge_settings_battery, R.string.fsp6_sub_battery, Icons.Rounded.Battery5Bar),
    StrapActions(R.string.forge_settings_actions, R.string.fsp6_sub_actions, Icons.Rounded.TouchApp),
    Training(R.string.forge_training, R.string.forge_st_subtitle, Icons.Rounded.FitnessCenter),
    TodayTrends(R.string.forge_settings_today_trends, R.string.fsp6_sub_today, Icons.Rounded.Dashboard),
    Notifications(R.string.fsp6_alerts_title, R.string.fsp6_alerts_subtitle, Icons.Rounded.NotificationsActive),
    Coach(R.string.forge_settings_coach, R.string.fsp6_sub_coach, Icons.Rounded.AutoAwesome, hosted = true),
    LanguageUnits(R.string.forge_settings_language_units, R.string.fsp6_sub_language, Icons.Rounded.Language),
    Appearance(R.string.l10n_settings_screen_appearance_41def7a0, R.string.fsp6_sub_appearance, Icons.Rounded.Contrast),
    Calculations(R.string.forge_settings_calculations, R.string.forge_settings_calculations_subtitle, Icons.Rounded.Functions),
    DataBackup(R.string.forge_settings_data_backup, R.string.fsp6_sub_data, Icons.Rounded.Storage),
    Help(R.string.forge_settings_help, R.string.forge_settings_help_subtitle, Icons.AutoMirrored.Rounded.Help),
    Lab(R.string.forge_settings_lab, R.string.forge_settings_lab_subtitle, Icons.Rounded.Science),
    About(R.string.l10n_settings_screen_about_6b21fb79, R.string.forge_settings_about_subtitle, Icons.Rounded.Info),
}

/**
 * The hub's groups in iOS order (`SettingsHubLayout`). Siri has no Android counterpart, so its row is left out;
 * Today & Trends carries only its cards.
 */
internal val HUB_GROUPS = listOf(
    // Its own card above everything else, with no heading: the quickest reach in Settings, as on iOS.
    0 to listOf(ForgeSettingsPage.Roadmap),
    R.string.forge_settings_group_you to listOf(ForgeSettingsPage.Profile, ForgeSettingsPage.Goals),
    R.string.forge_settings_group_strap to listOf(ForgeSettingsPage.Strap, ForgeSettingsPage.BatteryRecording,
                                                  ForgeSettingsPage.StrapActions),
    R.string.forge_settings_group_training to listOf(ForgeSettingsPage.Training, ForgeSettingsPage.TodayTrends, ForgeSettingsPage.Notifications,
                                                     ForgeSettingsPage.Coach),
    R.string.forge_settings_group_display to listOf(ForgeSettingsPage.LanguageUnits, ForgeSettingsPage.Appearance),
    R.string.forge_settings_group_data to listOf(ForgeSettingsPage.Calculations, ForgeSettingsPage.DataBackup),
    R.string.forge_settings_group_help to listOf(ForgeSettingsPage.Help, ForgeSettingsPage.Lab, ForgeSettingsPage.About),
)

/**
 * The screens a page opens one level further down. [cards] hosts those cards of the classic Settings under a Forge
 * title; [closes] marks the classic screens that draw their own close button and fill the page.
 */
enum class ForgeSettingsSub(val titleRes: Int, val cards: Set<ClassicSettingsCard>? = null, val closes: Boolean = false) {
    StepsCalibration(R.string.l10n_settings_screen_steps_estimate_ce7a604d, closes = true),
    StrapConnection(R.string.l10n_settings_screen_strap_02b88eeb),
    HeartRateSharing(R.string.fsp2_hrs_title),
    Devices(R.string.nav_devices),
    DevicesSources(R.string.forge_set_devices_sources),
    FusedRecord(R.string.fsp2_values_title),
    Charge(R.string.l10n_settings_screen_charge_d4e1aee4, cards = setOf(ClassicSettingsCard.Charge)),
    BackupSync(R.string.l10n_settings_screen_automatic_backups_8a772f3c),
    DataSources(R.string.nav_data_sources),
    SelfHostedPush(R.string.nav_self_hosted_push),
    Storage(R.string.fsp5_storage_title),
    HowNoopWorks(R.string.l10n_settings_screen_how_noop_works_3396b27a, closes = true),
    ScoringGuide(R.string.l10n_settings_screen_how_your_scores_work_21a0e2be, closes = true),
    HowScores(R.string.forge_set_how_scores),
    ModelComparison(R.string.l10n_settings_screen_whoop_4_0_vs_5_0_2babb05a, closes = true),
    Limitations(R.string.nav_noop_limitations),
    TestCentre(R.string.nav_test_centre),
    HealthWellness(R.string.l10n_settings_screen_health_wellness_93475778, cards = setOf(ClassicSettingsCard.HealthWellness)),
    Advanced(R.string.l10n_settings_screen_advanced_4d064726, cards = setOf(ClassicSettingsCard.Advanced)),
    WhatsNew(R.string.l10n_settings_screen_what_s_new_4d8dc5fe, closes = true),
    Acknowledgements(R.string.forge_provider_acknowledgements),
    ExerciseMedia(R.string.forge_st_manage_media),
    HrZones(R.string.fsp1_hz_title),
    Equipment(R.string.fsp1_equipment_title),
    ProjectRoadmap(R.string.forge_roadmap_title),
    ProjectProblems(R.string.project_card_problems_title),
    ProjectWishes(R.string.project_card_wishes_title),
    RawDonation(R.string.donation_title, closes = false),
    AllSettings(R.string.forge_settings_all),
    // Settings parity, package 3: the screens the Strap Actions and Notifications pages open one level down.
    WristAlerts(R.string.fsp3_wrist_apps, closes = false),
    NapDetection(R.string.l10n_automations_screen_nap_detection_ca2dedf5),
    Rhythm(R.string.forge_more_heart_rhythm),
}

/** One step of the Settings stack: a hub page or a screen below it. */
private sealed interface Route {
    data class Page(val page: ForgeSettingsPage) : Route
    data class Sub(val sub: ForgeSettingsSub) : Route
}

/** The stack as one saveable string, so a rotation or a process restart keeps the open page. */
private fun List<Route>.encode(): String = joinToString(",") {
    when (it) {
        is Route.Page -> "p:${it.page.name}"
        is Route.Sub -> "s:${it.sub.name}"
    }
}

private fun decodeRoutes(raw: String): List<Route> = raw.split(",").mapNotNull { part ->
    val name = part.substringAfter(":")
    when (part.substringBefore(":")) {
        "p" -> ForgeSettingsPage.entries.firstOrNull { it.name == name }?.let { Route.Page(it) }
        "s" -> ForgeSettingsSub.entries.firstOrNull { it.name == name }?.let { Route.Sub(it) }
        else -> null
    }
}

/** The tile colour of a page's icon, the iOS system colour `AppleInspiredColors` gives its colour key. */
@Composable
internal fun ForgeSettingsPage.tint(): Color {
    // iOS `SettingsPage.forgeTint`: four system colours, one per kind of page, the same on the index row and
    // on the page's own head, so no area shouts louder than another; alerts keep red.
    val token = when (this) {
        ForgeSettingsPage.Profile, ForgeSettingsPage.Goals, ForgeSettingsPage.Strap, ForgeSettingsPage.BatteryRecording,
        ForgeSettingsPage.TodayTrends, ForgeSettingsPage.Calculations -> ForgeTokens.Color.systemGreen
        ForgeSettingsPage.StrapActions, ForgeSettingsPage.Help, ForgeSettingsPage.Training -> ForgeTokens.Color.systemOrange
        ForgeSettingsPage.Notifications -> ForgeTokens.Color.systemRed
        ForgeSettingsPage.Roadmap, ForgeSettingsPage.Coach, ForgeSettingsPage.Appearance, ForgeSettingsPage.LanguageUnits,
        ForgeSettingsPage.DataBackup, ForgeSettingsPage.Lab, ForgeSettingsPage.About -> ForgeTokens.Color.systemIndigo
    }
    return token.resolve()
}

@Composable
internal fun ForgeColor.resolve(): Color = Color(if (Forge.colors.dark) dark else light)

/**
 * Fork (DX23876), Android plan E-3 (D15 lists settings in the first testing build): Forge Settings as the iOS
 * hub has them, groups of pages with an icon tile, title and subtitle, each opening its own page. The native pages
 * read and write the same stores the classic Settings use (`ProfileStore`, `AppLanguagePrefs`, `ClockPrefs`,
 * `NoopPrefs`, `UnitPrefs`, `AppearancePrefs`, `PuffinExperiment`, `UpdateWatch`) and the same view-model calls, so
 * the two never disagree. The pages iOS keeps as screens of their own host the classic Android screens, and the
 * last row hosts the whole classic Settings, so no Android setting is out of reach from here.
 */
@Composable
fun ForgeSettings(viewModel: AppViewModel, onClose: () -> Unit, initialPage: ForgeSettingsPage? = null,
                  onSearch: (() -> Unit)? = null) {
    // Opened on one page (More's profile row, as iOS opens `SettingsView(initialPage: .profile)`), Back from it closes.
    var stackRaw by rememberSaveable { mutableStateOf(initialPage?.let { listOf<Route>(Route.Page(it)).encode() } ?: "") }
    val stack = decodeRoutes(stackRaw)
    // Each page on the stack keeps its own saved state, its scroll position above all, while a page above it is
    // shown, so Back returns to where the wearer left it, as a navigation stack does. A popped page's state goes.
    val pageStates = rememberSaveableStateHolder()
    fun push(route: Route) { stackRaw = (stack + route).encode() }
    fun pop() {
        if (initialPage != null && stack.size == 1) onClose()
        else { pageStates.removeState(stack.encode()); stackRaw = stack.dropLast(1).encode() }
    }
    BackHandler(enabled = stack.isNotEmpty()) { pop() }
    ForgeSceneBackdrop(ForgeBackdrop.Sky) {
        AnimatedContent(
            targetState = stack,
            transitionSpec = {
                // A push slides in from the end, back slides out to it, as a navigation stack does.
                val forward = targetState.size > initialState.size
                (slideInHorizontally { w -> if (forward) w else -w / 3 } + fadeIn()) togetherWith
                    (slideOutHorizontally { w -> if (forward) -w / 3 else w } + fadeOut())
            },
        ) { shown ->
            pageStates.SaveableStateProvider(shown.encode()) {
            when (val top = shown.lastOrNull()) {
                null -> if (ForgeDesign.preview) NewDesignHub(onClose, onOpen = { push(Route.Page(it)) },
                                                         onSub = { push(Route.Sub(it)) }, onSearch = onSearch)
                        else Hub(onClose, onOpen = { push(Route.Page(it)) }, onAll = { push(Route.Sub(ForgeSettingsSub.AllSettings)) })
                is Route.Page ->
                    if (top.page.hosted) HostedPage(top.page, viewModel, onBack = ::pop)
                    else Page(top.page, viewModel, onBack = ::pop, onOpen = { push(Route.Sub(it)) },
                              onOpenPage = { push(Route.Page(it)) })
                is Route.Sub -> SubScreen(top.sub, viewModel, onBack = ::pop, onOpen = { push(Route.Sub(it)) })
            }
            }
        }
    }
}

@Composable
private fun Hub(onClose: () -> Unit, onOpen: (ForgeSettingsPage) -> Unit, onAll: () -> Unit) {
    val context = LocalContext.current
    // The classic pages under "All settings" write the same background keys; the hub re-reads them on return.
    LaunchedEffect(Unit) { ForgeBackground.load(context) }
    SettingsColumn {
        Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.l10n_settings_screen_settings_c7f73bb5), style = Forge.type.title1,
                 color = Forge.sceneInk.text, modifier = Modifier.weight(1f))
            IconButton(onClick = onClose) {
                Icon(Icons.Rounded.Close, stringResource(R.string.forge_cancel), tint = Forge.sceneInk.text)
            }
        }
        HUB_GROUPS.forEach { (titleRes, pages) ->
            if (titleRes != 0) SectionHeader(stringResource(titleRes))
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
                pages.forEachIndexed { i, p ->
                    HubRow(p.icon, p.tint(), stringResource(p.titleRes), stringResource(p.subtitleRes)) { onOpen(p) }
                    if (i < pages.lastIndex) HubDivider()
                }
            }
        }
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
            HubRow(Icons.Rounded.Tune, ForgeTokens.Color.systemGray.resolve(), stringResource(R.string.forge_settings_all),
                   stringResource(R.string.forge_settings_all_detail), onAll)
        }
    }
}

/**
 * The new design's Settings, as iOS `ForgeSettingsView` opens them from the profile photo: the profile first, the one
 * search, then the pages in the prototype's groups. The strap keeps its three Android pages in its group, and
 * "All settings" stays last, since the classic screen still holds settings no page has.
 */
@Composable
private fun NewDesignHub(onClose: () -> Unit, onOpen: (ForgeSettingsPage) -> Unit, onSub: (ForgeSettingsSub) -> Unit,
                         onSearch: (() -> Unit)?) {
    val context = LocalContext.current
    val colors = Forge.colors
    LaunchedEffect(Unit) { ForgeBackground.load(context) }
    @Composable
    fun group(title: Int?, rows: List<@Composable () -> Unit>) {
        if (title != null) SettingsGroupHeader(stringResource(title))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
            rows.forEachIndexed { i, row -> row(); if (i < rows.lastIndex) HubDivider() }
        }
    }
    fun page(p: ForgeSettingsPage): @Composable () -> Unit = {
        HubRow(p.icon, p.tint(), stringResource(p.titleRes), stringResource(p.subtitleRes)) { onOpen(p) }
    }
    SettingsColumn {
        Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.l10n_settings_screen_settings_c7f73bb5), style = Forge.type.title1,
                 color = Forge.sceneInk.text, modifier = Modifier.weight(1f))
            androidx.compose.material3.TextButton(onClick = onClose) {
                Text(stringResource(R.string.forge_set_done), style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold),
                     color = colors.accent)
            }
        }
        Row(Modifier.fillMaxWidth().clickable(role = Role.Button) { onOpen(ForgeSettingsPage.Profile) }
                .padding(horizontal = ForgeMetrics.space1, vertical = ForgeMetrics.space2),
            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            com.noop.ui.ProfileAvatar(size = 64.dp, contentDescription = null)
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.forge_set_your_profile), style = Forge.type.title2.copy(fontWeight = FontWeight.Bold),
                     color = Forge.sceneInk.text)
                Text(stringResource(R.string.forge_set_profile_detail), style = Forge.type.caption, color = Forge.sceneInk.secondary)
            }
        }
        if (onSearch != null) {
            Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).background(colors.surfaceTop, RoundedCornerShape(ForgeMetrics.groupedRadius))
                    .clickable(role = Role.Button, onClick = onSearch).padding(horizontal = ForgeMetrics.space3),
                horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Search, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(20.dp))
                Text(stringResource(R.string.forge_set_search), style = Forge.type.body, color = colors.textSecondary)
            }
        }
        // One card above the groups, without a heading: one tap from the top, and quiet enough that
        // someone who does not care never notices it.
        group(null, listOf(page(ForgeSettingsPage.Roadmap)))
        group(R.string.forge_settings_group_you, listOf(page(ForgeSettingsPage.Goals)))
        // As iOS `ForgeSettingsView`: the Strap page (which holds the connection, recording and battery and double-tap
        // pages) and Devices and data sources.
        group(R.string.forge_set_strap_devices, listOf(
            page(ForgeSettingsPage.Strap),
            { HubRow(Icons.Rounded.DeviceHub, ForgeTokens.Color.systemIndigo.resolve(), stringResource(R.string.forge_set_devices_sources),
                     stringResource(R.string.forge_set_devices_sources_detail)) { onSub(ForgeSettingsSub.DevicesSources) } },
        ))
        group(R.string.forge_set_alerts, listOf(page(ForgeSettingsPage.Notifications)))
        group(R.string.forge_set_app, listOf(page(ForgeSettingsPage.Appearance), page(ForgeSettingsPage.LanguageUnits),
                                             page(ForgeSettingsPage.TodayTrends), page(ForgeSettingsPage.Training),
                                             page(ForgeSettingsPage.Coach)))
        group(R.string.forge_set_data_help, listOf(
            page(ForgeSettingsPage.DataBackup), page(ForgeSettingsPage.Calculations),
            { HubRow(Icons.Rounded.Speed, ForgeTokens.Color.systemGreen.resolve(), stringResource(R.string.forge_set_how_scores),
                     stringResource(R.string.forge_set_how_scores_detail)) { onSub(ForgeSettingsSub.HowScores) } },
            page(ForgeSettingsPage.Help),
        ))
        group(null, listOf(page(ForgeSettingsPage.Lab), page(ForgeSettingsPage.About),
            { HubRow(Icons.Rounded.Tune, ForgeTokens.Color.systemGray.resolve(), stringResource(R.string.forge_settings_all),
                     stringResource(R.string.forge_settings_all_detail)) { onSub(ForgeSettingsSub.AllSettings) } }))
    }
}

/** A page title with its back arrow, as the pages and the hosted screens open. */
@Composable
internal fun PageTitle(title: String?, onBack: () -> Unit, trailing: (@Composable () -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) {
            Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.forge_settings_back),
                 tint = Forge.sceneInk.text)
        }
        if (title != null) {
            Text(title, style = Forge.type.title1, color = Forge.sceneInk.text,
                 maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        } else {
            Spacer(Modifier.weight(1f))
        }
        if (trailing != null) trailing()
    }
}

@Composable
private fun Page(page: ForgeSettingsPage, viewModel: AppViewModel, onBack: () -> Unit, onOpen: (ForgeSettingsSub) -> Unit,
                 onOpenPage: (ForgeSettingsPage) -> Unit) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.from(context) }
    // The stores are plain preferences; one counter re-reads them after a change, as the classic screen does.
    var revision by remember { mutableIntStateOf(0) }
    fun change(block: () -> Unit) { block(); revision++ }
    // Outside the revision key, so a change made while editing the profile keeps the page in edit mode.
    var profileEditing by remember { mutableStateOf(false) }
    SettingsColumn {
        PageTitle(stringResource(page.titleRes), onBack)
        // The profile opens on the wearer, every other page on its head (iOS `SettingsPageBanner`).
        // The Strap page opens on the device row, as iOS's grouped Strap page does.
        if (page != ForgeSettingsPage.Profile && page != ForgeSettingsPage.Strap) SettingsPageHead(page)
        key(revision) {
            when (page) {
                ForgeSettingsPage.Roadmap -> ProjectHubSection(
                    onRoadmap = { onOpen(ForgeSettingsSub.ProjectRoadmap) },
                    onProblems = { onOpen(ForgeSettingsSub.ProjectProblems) },
                    onWishes = { onOpen(ForgeSettingsSub.ProjectWishes) },
                    onDonation = { onOpen(ForgeSettingsSub.RawDonation) },
                )
                ForgeSettingsPage.Profile -> ProfileSection(profile, viewModel, ::change, onOpen, profileEditing) { profileEditing = it }
                ForgeSettingsPage.Goals -> GoalsSettingsSection(viewModel)
                ForgeSettingsPage.Strap -> StrapSettingsPage(viewModel, onOpenPage, onOpen)
                ForgeSettingsPage.BatteryRecording -> BatteryRecordingSettings(viewModel)
                ForgeSettingsPage.StrapActions -> StrapActionsSection(viewModel, onOpen)
                ForgeSettingsPage.Notifications -> NotificationsSection(viewModel, onOpen)
                ForgeSettingsPage.Training -> {
                    TrainingSettingsSection(onOpenMedia = { onOpen(ForgeSettingsSub.ExerciseMedia) },
                                            onOpenEquipment = { onOpen(ForgeSettingsSub.Equipment) },
                                            onOpenDonation = { onOpen(ForgeSettingsSub.RawDonation) })
                }
                ForgeSettingsPage.LanguageUnits -> LanguageUnitsSection(context, ::change)
                ForgeSettingsPage.Appearance -> AppearanceSection(::change)
                // The dashboard styles were the Today screens under the old design; with no way back to it
                // they would only offer a Today nobody reaches. The Mac still has them, where there is no
                // new design (iOS `todayLayoutCard`, macOS only since the same day).
                ForgeSettingsPage.TodayTrends -> TodayCardsSection(::change)
                ForgeSettingsPage.Calculations -> CalculationsSection(viewModel, ::change, onOpen)
                ForgeSettingsPage.DataBackup -> DataBackupSection(viewModel, onOpen)
                ForgeSettingsPage.Help -> HelpSection(viewModel, onOpen)
                ForgeSettingsPage.Lab -> LabSection(viewModel, onOpen)
                ForgeSettingsPage.About -> AboutSection(onOpen)
                else -> Unit
            }
        }
    }
}

/** A classic screen under a Forge back bar. Screens that carry their own title get the bar without one. */
@Composable
internal fun Hosted(title: String?, onBack: () -> Unit, head: ForgeSettingsPage? = null, content: @Composable () -> Unit) {
    // Every Settings page has one look, as on iOS: the classic screen takes the Forge colours (no beige canvas),
    // draws nothing behind itself so the backdrop runs through, and puts the Forge title at the top of its own
    // scroll instead of under a fixed bar.
    val colors = Forge.colors
    val ink = Forge.sceneInk
    val tokens = remember(colors) { hostedTokens(colors) }
    val chrome = remember(title, onBack, ink, head) {
        HostedChrome(
            horizontalPadding = ForgeMetrics.screenPadding, maxContentWidth = ForgeMetrics.maxContentWidth,
            rowSpacing = ForgeMetrics.gap, cardRadius = ForgeMetrics.groupedRadius,
        ) { pageTitle, subtitle, trailing ->
            Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
                PageTitle(title ?: pageTitle, onBack, trailing)
                // A Settings page says what it is for in its head, which replaces the classic subtitle.
                if (head != null) {
                    SettingsPageHead(head)
                } else if (subtitle != null) {
                    Text(subtitle, style = Forge.type.subhead, color = ink.secondary,
                         modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
                }
            }
        }
    }
    HostedPalette(tokens, colors.dark) {
        CompositionLocalProvider(LocalHostedChrome provides chrome) {
            Box(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) { content() }
        }
    }
}

/**
 * A classic screen drawn in the Forge colours on its own, outside any Forge page: the terms gate and the onboarding
 * run before the Forge shell exists, and without this they showed ryanbr's warm-paper palette (2026-11-14, the owner:
 * that beige must not appear any more).
 */
@Composable
fun ForgeHostedClassic(content: @Composable () -> Unit) {
    ForgeTheme {
        val colors = Forge.colors
        val tokens = remember(colors) { hostedTokens(colors) }
        HostedPalette(tokens, colors.dark) { content() }
    }
}

/**
 * The classic palette as iOS colours it, for a classic screen in the Settings: the Forge surfaces, text and accent,
 * Effort and Rest in the colours of their rings, and every other token (Charge, status, sleep stages, zones) from
 * the iOS palette of the same name, so a page reads like its iOS twin. Tokens iOS has no twin for keep the classic
 * value.
 */
internal fun hostedTokens(c: ForgeColors): PaletteTokens {
    fun ios(color: ForgeColor) = Color(if (c.dark) color.dark else color.light)
    with(ForgeTokens.StrandPalette) {
        return (if (c.dark) DarkTokens else LightTokens).copy(
            surfaceBase = c.canvas,
            surfaceRaised = c.surface,
            surfaceOverlay = c.surfaceTop,
            surfaceInset = c.inset,
            hairline = c.divider,
            hairlineStrong = c.border,
            textPrimary = c.text,
            textSecondary = c.textSecondary,
            textTertiary = c.textTertiary,
            accent = c.accent,
            recovery000 = ios(recovery000),
            recovery030 = ios(recovery030),
            recovery055 = ios(recovery055),
            recovery078 = ios(recovery078),
            recovery100 = ios(recovery100),
            strain000 = ios(strain000),
            strain033 = ios(strain033),
            strain066 = ios(strain066),
            strain100 = ios(strain100),
            sleepAwake = ios(sleepAwake),
            sleepLight = ios(sleepLight),
            sleepDeep = ios(sleepDeep),
            sleepREM = ios(sleepREM),
            zone1 = ios(zone1),
            zone2 = ios(zone2),
            zone3 = ios(zone3),
            zone4 = ios(zone4),
            zone5 = ios(zone5),
            statusPositive = ios(statusPositive),
            statusWarning = ios(statusWarning),
            statusCritical = ios(statusCritical),
            metricCyan = ios(metricCyan),
            metricPurple = ios(metricPurple),
            metricAmber = ios(metricAmber),
            metricRose = ios(metricRose),
            chargeColor = ios(chargeColor),
            chargeDeep = ios(chargeDeep),
            chargeBright = ios(chargeBright),
            effortColor = c.effort,
            effortDeep = c.effort,
            effortBright = c.effort,
            restColor = c.rest,
            restDeep = c.rest,
            restBright = c.rest,
            restGlow = c.rest,
            stressColor = ios(stressColor),
            stressDeep = ios(stressDeep),
            stressBright = ios(stressBright),
            scenicCenter = ios(scenicCenter),
            scenicEdge = ios(scenicEdge),
            scenicStar = ios(scenicStar),
            cardFillTop = ios(cardFillTop),
            cardFillBottom = ios(cardFillBottom),
            gold = ios(gold),
            goldLight = ios(goldLight),
            goldDeep = ios(goldDeep),
            goldDeepText = ios(goldDeepText),
            signalYellow = ios(signalYellow),
            titaniumTop = ios(titaniumTop),
            titaniumMid = ios(titaniumMid),
            titaniumLow = ios(titaniumLow),
            titaniumDeep = ios(titaniumDeep),
            tipCore = ios(tipCore),
            heroFill = c.heroFill,
            heroBorder = c.heroBorder,
            chargeGlow = ios(chargeColor), effortGlow = c.effort, stressGlow = ios(stressColor),
            accentHover = c.accent, accentMuted = c.accent.copy(alpha = 0.16f), focusRing = c.accent,
        )
    }
}

@Composable
private fun HostedPage(page: ForgeSettingsPage, viewModel: AppViewModel, onBack: () -> Unit) {
    when (page) {
        ForgeSettingsPage.Coach -> CoachSettingsPages(stringResource(page.titleRes), onBack, headPage = page)
        else -> Unit
    }
}

@Composable
private fun SubScreen(sub: ForgeSettingsSub, viewModel: AppViewModel, onBack: () -> Unit, onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    when (sub) {
        ForgeSettingsSub.StepsCalibration -> Hosted(stringResource(sub.titleRes), onBack) {
            val profile = remember { ProfileStore.from(context) }
            var revision by remember { mutableIntStateOf(0) }
            key(revision) {
                StepsCalibrationScreen(vm = viewModel, profile = profile, onProfileChanged = { revision++ }, onClose = onBack)
            }
        }
        ForgeSettingsSub.StrapConnection -> SettingsColumn {
            PageTitle(stringResource(sub.titleRes), onBack)
            SettingsPageHead(ForgeSettingsPage.Strap)
            StrapConnectionSettings(viewModel, onOpen)
        }
        ForgeSettingsSub.HeartRateSharing -> SettingsColumn {
            PageTitle(stringResource(sub.titleRes), onBack)
            HeartRateSharingSettings(viewModel)
        }
        ForgeSettingsSub.Devices -> DevicesSettingsPage(viewModel, onBack, stringResource(sub.titleRes))
        ForgeSettingsSub.DevicesSources -> SettingsColumn {
            PageTitle(stringResource(sub.titleRes), onBack)
            DevicesSourcesSettings(onOpen)
        }
        ForgeSettingsSub.FusedRecord -> ValuesBySourcePage(viewModel, onBack, stringResource(sub.titleRes))
        ForgeSettingsSub.HowNoopWorks -> Hosted(stringResource(sub.titleRes), onBack) { HowNoopWorksScreen(onClose = onBack) }
        ForgeSettingsSub.ScoringGuide -> Hosted(stringResource(sub.titleRes), onBack) { ScoringGuideScreen(onClose = onBack) }
        ForgeSettingsSub.HowScores -> HowScoresPage(viewModel, onBack, stringResource(sub.titleRes))
        ForgeSettingsSub.ModelComparison -> Hosted(stringResource(sub.titleRes), onBack) { WhoopModelComparisonScreen(onClose = onBack) }
        ForgeSettingsSub.WhatsNew -> Hosted(stringResource(sub.titleRes), onBack) { WhatsNewSheet(onClose = onBack) }
        ForgeSettingsSub.BackupSync -> Hosted(stringResource(sub.titleRes), onBack) { BackupSyncScreen() }
        ForgeSettingsSub.DataSources -> Hosted(stringResource(sub.titleRes), onBack) { DataSourcesScreen(viewModel) }
        ForgeSettingsSub.SelfHostedPush -> Hosted(stringResource(sub.titleRes), onBack) { SelfHostedPushScreen() }
        ForgeSettingsSub.Limitations -> Hosted(stringResource(sub.titleRes), onBack) { NoopLimitationsScreen() }
        ForgeSettingsSub.TestCentre -> Hosted(stringResource(sub.titleRes), onBack) { TestCentreScreen(viewModel) }
        ForgeSettingsSub.Acknowledgements -> AcknowledgementsPage(onBack)
        ForgeSettingsSub.ExerciseMedia -> ForgeExerciseMediaSettings(onBack)
        ForgeSettingsSub.HrZones -> HrZonesSettingsPage(onBack)
        ForgeSettingsSub.Equipment -> EquipmentSettingsPage(onBack)
        ForgeSettingsSub.Storage -> StorageSettingsPage(onBack)
        ForgeSettingsSub.ProjectRoadmap -> SettingsColumn {
            PageTitle(stringResource(R.string.forge_roadmap_title), onBack)
            RoadmapPlanSection()
        }
        ForgeSettingsSub.ProjectProblems -> SettingsColumn {
            PageTitle(stringResource(R.string.project_card_problems_title), onBack)
            ProblemsSection(
                onOpenTestCentre = { onOpen(ForgeSettingsSub.TestCentre) },
                onOpenTracker = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(ISSUES_URL))) },
                viewModel = viewModel,
            )
        }
        ForgeSettingsSub.ProjectWishes -> SettingsColumn {
            PageTitle(stringResource(R.string.project_card_wishes_title), onBack)
            WishesSection()
        }
        ForgeSettingsSub.RawDonation -> SettingsColumn {
            PageTitle(stringResource(R.string.donation_title), onBack)
            RawDonationSection()
        }
        ForgeSettingsSub.WristAlerts -> Hosted(stringResource(sub.titleRes), onBack) { NotificationsSettingsScreen(viewModel) }
        ForgeSettingsSub.NapDetection -> Hosted(stringResource(sub.titleRes), onBack) { AutomationsScreen(viewModel, AutomationsScope.NapDetection) }
        ForgeSettingsSub.Rhythm -> Hosted(stringResource(sub.titleRes), onBack) { com.noop.ui.RhythmRoute(viewModel) }
        ForgeSettingsSub.AllSettings -> Hosted(stringResource(sub.titleRes), onBack) {
            SettingsScreen(
                viewModel,
                onOpenTestCentre = { onOpen(ForgeSettingsSub.TestCentre) },
                onOpenBackupSync = { onOpen(ForgeSettingsSub.BackupSync) },
                onOpenSelfHostedPush = { onOpen(ForgeSettingsSub.SelfHostedPush) },
                onOpenStepsCalibration = { onOpen(ForgeSettingsSub.StepsCalibration) },
                // Backups live in Data & Backup alone; the classic card would be a second set of the same buttons.
                cards = ClassicSettingsCard.entries.toSet() - ClassicSettingsCard.Backup,
            )
        }
        ForgeSettingsSub.Charge, ForgeSettingsSub.HealthWellness, ForgeSettingsSub.Advanced ->
            Hosted(stringResource(sub.titleRes), onBack) {
                SettingsScreen(viewModel, onOpenSelfHostedPush = { onOpen(ForgeSettingsSub.SelfHostedPush) },
                               cards = sub.cards)
            }
    }
}
