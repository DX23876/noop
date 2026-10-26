package com.noop.ui.forge

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
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Help
import androidx.compose.material.icons.rounded.AccountCircle
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Battery5Bar
import androidx.compose.material.icons.rounded.Functions
import androidx.compose.material.icons.rounded.NotificationsActive
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
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.AlertDialog
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
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.BuildConfig
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
import com.noop.ui.LogExport
import com.noop.ui.NoopLimitationsScreen
import com.noop.ui.NotificationsSettingsScreen
import com.noop.ui.Palette
import com.noop.ui.PowerSavingScreen
import com.noop.ui.ScoringGuideScreen
import com.noop.ui.SettingsScreen
import com.noop.ui.StepsCalibrationScreen
import com.noop.ui.StrapLogBuffer
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

/** The sex choices the profile stores, by tag, with the onboarding's labels. */
private val SEX_CHOICES = listOf("male" to R.string.onboarding_male, "female" to R.string.onboarding_female,
                                 "nonbinary" to R.string.onboarding_other)

private const val SOURCE_URL = "https://github.com/DX23876/noop"

/**
 * The Forge Settings pages, as the iOS hub lists them (`SettingsPage`): title, subtitle and icon. [hosted] marks the
 * pages that are a classic screen of their own, as iOS marks `isStandaloneScreen` (Strap hosts the classic Strap
 * card, which keeps its Bluetooth controls in one place).
 */
enum class ForgeSettingsPage(val titleRes: Int, val subtitleRes: Int, val icon: ImageVector, val hosted: Boolean = false) {
    Profile(R.string.l10n_settings_screen_profile_ff4fc027, R.string.forge_settings_profile_subtitle, Icons.Rounded.AccountCircle),
    Strap(R.string.l10n_settings_screen_strap_02b88eeb, R.string.forge_settings_strap_subtitle, Icons.Rounded.SettingsInputAntenna, hosted = true),
    BatteryRecording(R.string.forge_settings_battery, R.string.forge_settings_battery_subtitle, Icons.Rounded.Battery5Bar, hosted = true),
    StrapActions(R.string.forge_settings_actions, R.string.forge_settings_actions_subtitle, Icons.Rounded.TouchApp, hosted = true),
    Notifications(R.string.forge_settings_notifications, R.string.forge_settings_notifications_subtitle, Icons.Rounded.NotificationsActive, hosted = true),
    Coach(R.string.forge_settings_coach, R.string.forge_settings_coach_subtitle, Icons.Rounded.AutoAwesome, hosted = true),
    LanguageUnits(R.string.forge_settings_language_units, R.string.forge_settings_language_units_subtitle, Icons.Rounded.Language),
    Appearance(R.string.l10n_settings_screen_appearance_41def7a0, R.string.forge_settings_appearance_subtitle, Icons.Rounded.Contrast),
    Calculations(R.string.forge_settings_calculations, R.string.forge_settings_calculations_subtitle, Icons.Rounded.Functions),
    DataBackup(R.string.forge_settings_data_backup, R.string.forge_settings_data_backup_subtitle, Icons.Rounded.Storage),
    Help(R.string.forge_settings_help, R.string.forge_settings_help_subtitle, Icons.AutoMirrored.Rounded.Help),
    Lab(R.string.forge_settings_lab, R.string.forge_settings_lab_subtitle, Icons.Rounded.Science),
    About(R.string.l10n_settings_screen_about_6b21fb79, R.string.forge_settings_about_subtitle, Icons.Rounded.Info),
}

/**
 * The hub's groups in iOS order (`SettingsHubLayout`). Goals, Training, Today & Trends and Siri have no Android
 * feature behind them yet, so their rows are left out rather than opening an empty page.
 */
internal val HUB_GROUPS = listOf(
    R.string.forge_settings_group_you to listOf(ForgeSettingsPage.Profile),
    R.string.forge_settings_group_strap to listOf(ForgeSettingsPage.Strap, ForgeSettingsPage.BatteryRecording,
                                                  ForgeSettingsPage.StrapActions),
    R.string.forge_settings_group_training to listOf(ForgeSettingsPage.Notifications, ForgeSettingsPage.Coach),
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
    Charge(R.string.l10n_settings_screen_charge_d4e1aee4, cards = setOf(ClassicSettingsCard.Charge)),
    BackupSync(R.string.l10n_settings_screen_automatic_backups_8a772f3c),
    DataSources(R.string.nav_data_sources),
    SelfHostedPush(R.string.nav_self_hosted_push),
    HowNoopWorks(R.string.l10n_settings_screen_how_noop_works_3396b27a, closes = true),
    ScoringGuide(R.string.l10n_settings_screen_how_your_scores_work_21a0e2be, closes = true),
    ModelComparison(R.string.l10n_settings_screen_whoop_4_0_vs_5_0_2babb05a, closes = true),
    Limitations(R.string.nav_noop_limitations),
    TestCentre(R.string.nav_test_centre),
    HealthWellness(R.string.l10n_settings_screen_health_wellness_93475778, cards = setOf(ClassicSettingsCard.HealthWellness)),
    Advanced(R.string.l10n_settings_screen_advanced_4d064726, cards = setOf(ClassicSettingsCard.Advanced)),
    WhatsNew(R.string.l10n_settings_screen_what_s_new_4d8dc5fe, closes = true),
    AllSettings(R.string.forge_settings_all),
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
private fun ForgeSettingsPage.tint(): Color {
    val token = when (this) {
        ForgeSettingsPage.Profile, ForgeSettingsPage.DataBackup -> ForgeTokens.Color.systemBlue
        ForgeSettingsPage.Strap -> ForgeTokens.Color.systemGreen
        ForgeSettingsPage.BatteryRecording -> ForgeTokens.Color.systemYellow
        ForgeSettingsPage.StrapActions, ForgeSettingsPage.Notifications, ForgeSettingsPage.Coach,
        ForgeSettingsPage.Appearance -> ForgeTokens.Color.systemPurple
        ForgeSettingsPage.LanguageUnits -> ForgeTokens.Color.systemOrange
        ForgeSettingsPage.Calculations, ForgeSettingsPage.Lab -> ForgeTokens.Color.systemIndigo
        ForgeSettingsPage.Help -> ForgeTokens.Color.systemTeal
        ForgeSettingsPage.About -> ForgeTokens.Color.systemGray
    }
    return token.resolve()
}

@Composable
private fun ForgeColor.resolve(): Color = Color(if (Forge.colors.dark) dark else light)

/**
 * Fork (DX23876), Android plan E-3 (D15 lists settings in the first testing build): Forge Settings as the iOS
 * hub has them, groups of pages with an icon tile, title and subtitle, each opening its own page. The native pages
 * read and write the same stores the classic Settings use (`ProfileStore`, `AppLanguagePrefs`, `ClockPrefs`,
 * `NoopPrefs`, `UnitPrefs`, `AppearancePrefs`, `PuffinExperiment`, `UpdateWatch`) and the same view-model calls, so
 * the two never disagree. The pages iOS keeps as screens of their own host the classic Android screens, and the
 * last row hosts the whole classic Settings, so no Android setting is out of reach from here.
 */
@Composable
fun ForgeSettings(viewModel: AppViewModel, onClose: () -> Unit) {
    var stackRaw by rememberSaveable { mutableStateOf("") }
    val stack = decodeRoutes(stackRaw)
    fun push(route: Route) { stackRaw = (stack + route).encode() }
    fun pop() { stackRaw = stack.dropLast(1).encode() }
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
            when (val top = shown.lastOrNull()) {
                null -> Hub(onClose, onOpen = { push(Route.Page(it)) }, onAll = { push(Route.Sub(ForgeSettingsSub.AllSettings)) })
                is Route.Page ->
                    if (top.page.hosted) HostedPage(top.page, viewModel, onBack = ::pop)
                    else Page(top.page, viewModel, onBack = ::pop, onOpen = { push(Route.Sub(it)) })
                is Route.Sub -> SubScreen(top.sub, viewModel, onBack = ::pop, onOpen = { push(Route.Sub(it)) })
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
            SectionHeader(stringResource(titleRes))
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

/** A page title with its back arrow, as the pages and the hosted screens open. */
@Composable
private fun PageTitle(title: String?, onBack: () -> Unit, trailing: (@Composable () -> Unit)? = null) {
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
private fun Page(page: ForgeSettingsPage, viewModel: AppViewModel, onBack: () -> Unit, onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.from(context) }
    // The stores are plain preferences; one counter re-reads them after a change, as the classic screen does.
    var revision by remember { mutableIntStateOf(0) }
    fun change(block: () -> Unit) { block(); revision++ }
    SettingsColumn {
        PageTitle(stringResource(page.titleRes), onBack)
        key(revision) {
            when (page) {
                ForgeSettingsPage.Profile -> ProfileSection(profile, viewModel, ::change, onOpen)
                ForgeSettingsPage.LanguageUnits -> LanguageUnitsSection(context, ::change)
                ForgeSettingsPage.Appearance -> AppearanceSection(::change)
                ForgeSettingsPage.Calculations -> CalculationsSection(viewModel, ::change, onOpen)
                ForgeSettingsPage.DataBackup -> DataBackupSection(onOpen)
                ForgeSettingsPage.Help -> HelpSection(onOpen)
                ForgeSettingsPage.Lab -> LabSection(onOpen)
                ForgeSettingsPage.About -> AboutSection(onOpen)
                else -> Unit
            }
        }
    }
}

/** A classic screen under a Forge back bar. Screens that carry their own title get the bar without one. */
@Composable
private fun Hosted(title: String?, onBack: () -> Unit, content: @Composable () -> Unit) {
    // Every Settings page has one look, as on iOS: the classic screen takes the Forge colours (no beige canvas),
    // draws nothing behind itself so the backdrop runs through, and puts the Forge title at the top of its own
    // scroll instead of under a fixed bar.
    val colors = Forge.colors
    val ink = Forge.sceneInk
    val tokens = remember(colors) { hostedTokens(colors) }
    val chrome = remember(title, onBack, ink) {
        HostedChrome(
            horizontalPadding = ForgeMetrics.screenPadding, maxContentWidth = ForgeMetrics.maxContentWidth,
            rowSpacing = ForgeMetrics.gap, cardRadius = ForgeMetrics.groupedRadius,
        ) { pageTitle, subtitle, trailing ->
            Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
                PageTitle(title ?: pageTitle, onBack, trailing)
                if (subtitle != null) {
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
        ForgeSettingsPage.Strap -> Hosted(stringResource(page.titleRes), onBack) {
            SettingsScreen(viewModel, cards = setOf(ClassicSettingsCard.Strap))
        }
        ForgeSettingsPage.BatteryRecording -> Hosted(stringResource(page.titleRes), onBack) { PowerSavingScreen(viewModel) }
        ForgeSettingsPage.StrapActions -> Hosted(stringResource(page.titleRes), onBack) { AutomationsScreen(viewModel) }
        ForgeSettingsPage.Notifications -> Hosted(stringResource(page.titleRes), onBack) { NotificationsSettingsScreen(viewModel) }
        ForgeSettingsPage.Coach -> Hosted(stringResource(page.titleRes), onBack) { CoachSettingsScreen(viewModel<CoachViewModel>()) }
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
        ForgeSettingsSub.HowNoopWorks -> Hosted(stringResource(sub.titleRes), onBack) { HowNoopWorksScreen(onClose = onBack) }
        ForgeSettingsSub.ScoringGuide -> Hosted(stringResource(sub.titleRes), onBack) { ScoringGuideScreen(onClose = onBack) }
        ForgeSettingsSub.ModelComparison -> Hosted(stringResource(sub.titleRes), onBack) { WhoopModelComparisonScreen(onClose = onBack) }
        ForgeSettingsSub.WhatsNew -> Hosted(stringResource(sub.titleRes), onBack) { WhatsNewSheet(onClose = onBack) }
        ForgeSettingsSub.BackupSync -> Hosted(stringResource(sub.titleRes), onBack) { BackupSyncScreen() }
        ForgeSettingsSub.DataSources -> Hosted(stringResource(sub.titleRes), onBack) { DataSourcesScreen(viewModel) }
        ForgeSettingsSub.SelfHostedPush -> Hosted(stringResource(sub.titleRes), onBack) { SelfHostedPushScreen() }
        ForgeSettingsSub.Limitations -> Hosted(stringResource(sub.titleRes), onBack) { NoopLimitationsScreen() }
        ForgeSettingsSub.TestCentre -> Hosted(stringResource(sub.titleRes), onBack) { TestCentreScreen(viewModel) }
        ForgeSettingsSub.AllSettings -> Hosted(stringResource(sub.titleRes), onBack) {
            SettingsScreen(
                viewModel,
                onOpenTestCentre = { onOpen(ForgeSettingsSub.TestCentre) },
                onOpenBackupSync = { onOpen(ForgeSettingsSub.BackupSync) },
                onOpenSelfHostedPush = { onOpen(ForgeSettingsSub.SelfHostedPush) },
                onOpenStepsCalibration = { onOpen(ForgeSettingsSub.StepsCalibration) },
            )
        }
        ForgeSettingsSub.Charge, ForgeSettingsSub.HealthWellness, ForgeSettingsSub.Advanced ->
            Hosted(stringResource(sub.titleRes), onBack) {
                SettingsScreen(viewModel, onOpenSelfHostedPush = { onOpen(ForgeSettingsSub.SelfHostedPush) },
                               cards = sub.cards)
            }
    }
}

/** The scrolling column every Settings screen sits in, clear of the system bars. */
@Composable
internal fun SettingsColumn(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState())
            .padding(horizontal = ForgeMetrics.screenPadding).widthIn(max = ForgeMetrics.maxContentWidth)
            .navigationBarsPadding().padding(bottom = ForgeMetrics.space4),
        verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap),
        content = content,
    )
}

/** One hub row as iOS draws it (`SettingsHubRow`): icon tile, title over subtitle, chevron. */
@Composable
private fun HubRow(icon: ImageVector, tint: Color, title: String, subtitle: String, onClick: () -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = ForgeMetrics.space4, vertical = ForgeMetrics.space3),
        verticalAlignment = Alignment.CenterVertically) {
        // `appleInspiredMenuIcon`: a 30 pt tile, corner 0.28 of its size, the white symbol at half its size.
        Box(Modifier.size(30.dp).background(tint, RoundedCornerShape(8.4.dp)), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(15.dp))
        }
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
            Text(title, style = Forge.type.body, color = colors.text)
            Text(subtitle, style = Forge.type.subhead, color = colors.textSecondary)
        }
        Spacer(Modifier.width(ForgeMetrics.space2))
        Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun HubDivider() {
    HorizontalDivider(color = Forge.colors.divider.copy(alpha = 0.5f), modifier = Modifier.padding(start = ForgeMetrics.space6))
}

/**
 * One settings card as iOS draws it (`SettingsSection`): a title over its blurb, then the rows. A page with one
 * card leaves the title out, since the page title already names it.
 */
@Composable
internal fun SettingsCard(title: String?, blurb: String?, icon: ImageVector? = null, tint: Color? = null,
                          active: Boolean = false, content: @Composable ColumnScope.() -> Unit) {
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = ForgeMetrics.space5) {
        // `Section2` on iOS: an active automation says ON above its title.
        if (active) {
            Text(stringResource(R.string.forge_sp_on).uppercase(), style = Forge.type.overline, color = Forge.colors.accent)
        }
        if (title != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (icon != null) {
                    Box(Modifier.size(26.dp).background(tint ?: Forge.colors.accent, RoundedCornerShape(7.dp)),
                        contentAlignment = Alignment.Center) {
                        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(15.dp))
                    }
                    Spacer(Modifier.width(ForgeMetrics.space2))
                }
                Text(title, style = Forge.type.title2, color = Forge.colors.text)
            }
        }
        if (blurb != null) {
            Text(blurb, style = Forge.type.footnote, color = Forge.colors.textSecondary,
                 modifier = Modifier.padding(top = if (title != null) ForgeMetrics.space1 else 0.dp))
        }
        if (title != null || blurb != null) Spacer(Modifier.height(ForgeMetrics.space3))
        content()
    }
}

@Composable
private fun ProfileSection(profile: ProfileStore, viewModel: AppViewModel, change: (() -> Unit) -> Unit,
                           onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val imperial = UnitPrefs.system(context) == UnitSystem.IMPERIAL
    SettingsCard(title = null, blurb = stringResource(R.string.forge_settings_profile_detail)) {
        SettingRow(stringResource(R.string.l10n_settings_screen_age_ff9f1ff3)) {
            Stepper("${profile.age}", onMinus = { change { profile.setAge(profile.age - 1) } },
                    onPlus = { change { profile.setAge(profile.age + 1) } })
        }
        RowDivider()
        SettingRow(stringResource(R.string.l10n_settings_screen_sex_e301dd60)) {
            Segmented(SEX_CHOICES.map { it.first }, profile.sex,
                      label = { tag -> stringResource(SEX_CHOICES.first { it.first == tag }.second) },
                      onSelect = { tag -> change { profile.sex = tag } })
        }
        RowDivider()
        // With "Use weight from Health Connect" on, the synced reading owns the value (classic Settings).
        val fromHealthConnect = profile.useHealthConnectWeight
        SettingRow(stringResource(R.string.l10n_settings_screen_weight_69c0b815)) {
            if (imperial) {
                val lb = UnitFormatter.kgToPounds(profile.weightKg)
                Stepper("%.0f lb".format(lb), enabled = !fromHealthConnect,
                        onMinus = { change { profile.weightKg = (lb - 1) / UnitFormatter.POUNDS_PER_KILOGRAM } },
                        onPlus = { change { profile.weightKg = (lb + 1) / UnitFormatter.POUNDS_PER_KILOGRAM } })
            } else {
                Stepper("%.1f kg".format(profile.weightKg), enabled = !fromHealthConnect,
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
                Stepper("$ft′ $inch″",
                        onMinus = { change { profile.heightCm = (inches - 1) * UnitFormatter.CENTIMETERS_PER_INCH } },
                        onPlus = { change { profile.heightCm = (inches + 1) * UnitFormatter.CENTIMETERS_PER_INCH } })
            } else {
                Stepper("%.0f cm".format(profile.heightCm),
                        onMinus = { change { profile.heightCm -= 1 } }, onPlus = { change { profile.heightCm += 1 } })
            }
        }
        RowDivider()
        // Waist is optional; the first step from "Add" starts at the classic default, as its stepper does.
        val hasWaist = profile.waistCm > 0.0
        SettingRow(stringResource(R.string.l10n_settings_screen_waist_optional_d5356703)) {
            if (imperial) {
                val inches = UnitFormatter.cmToInches(profile.waistCm).roundToInt()
                Stepper(if (hasWaist) "$inches″" else stringResource(R.string.forge_settings_add),
                        onMinus = { change { profile.waistCm = waistInchesStep(profile.waistCm, up = false) } },
                        onPlus = { change { profile.waistCm = waistInchesStep(profile.waistCm, up = true) } })
            } else {
                Stepper(if (hasWaist) "%.0f cm".format(profile.waistCm) else stringResource(R.string.forge_settings_add),
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
            Stepper(if (override > 0) "$override bpm" else stringResource(R.string.forge_settings_hr_auto, profile.hrMaxAuto),
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

@Composable
private fun LanguageUnitsSection(context: Context, change: (() -> Unit) -> Unit) {
    val language = AppLanguagePrefs.selected(context)
    var picking by remember { mutableStateOf(false) }
    SettingsCard(title = stringResource(R.string.settings_language), blurb = null) {
        SettingRow(stringResource(R.string.settings_language)) {
            Text(if (language == AppLanguage.SYSTEM) stringResource(R.string.settings_language_system) else language.autonym,
                 style = Forge.type.body, color = Forge.colors.accent,
                 modifier = Modifier.clickable(role = Role.Button) { picking = true }.padding(vertical = 8.dp))
        }
        RowDivider()
        SettingRow(stringResource(R.string.l10n_settings_screen_clock_04f6b3ea)) {
            Segmented(listOf(ClockFormatPreference.SYSTEM, ClockFormatPreference.TWELVE_HOUR,
                             ClockFormatPreference.TWENTY_FOUR_HOUR), ClockPrefs.preference(context),
                      label = {
                          when (it) {
                              ClockFormatPreference.TWELVE_HOUR -> stringResource(R.string.l10n_settings_screen_12_hour_41c18ba0)
                              ClockFormatPreference.TWENTY_FOUR_HOUR -> stringResource(R.string.l10n_settings_screen_24_hour_18e86819)
                              else -> stringResource(R.string.settings_language_system)
                          }
                      },
                      onSelect = { change { ClockPrefs.setPreference(context, it) } })
        }
    }
    SettingsCard(title = stringResource(R.string.l10n_settings_screen_units_12748281),
                 blurb = stringResource(R.string.forge_settings_units_blurb)) {
        SettingRow(stringResource(R.string.units_body_measurements)) {
            Segmented(listOf(UnitSystem.METRIC, UnitSystem.IMPERIAL), UnitPrefs.system(context),
                      label = {
                          stringResource(if (it == UnitSystem.METRIC) R.string.onboarding_metric else R.string.onboarding_imperial)
                      },
                      onSelect = { change { NoopPrefs.setUnitSystem(context, it) } })
        }
        RowDivider()
        SettingRow(stringResource(R.string.units_exercise_distance_pace)) {
            Segmented(listOf(UnitSystem.METRIC, UnitSystem.IMPERIAL), UnitPrefs.distanceSystem(context),
                      label = { stringResource(if (it == UnitSystem.METRIC) R.string.units_kilometres else R.string.units_miles) },
                      onSelect = { change { NoopPrefs.setDistanceUnitSystem(context, it) } })
        }
        RowDivider()
        // Unset follows the body measurements, which is what the first choice says.
        val temperatureRaw = NoopPrefs.of(context).getString(NoopPrefs.KEY_TEMPERATURE_UNIT, null)
            ?.takeIf { raw -> TemperatureUnit.entries.any { it.raw == raw } } ?: ""
        SettingRow(stringResource(R.string.l10n_settings_screen_temperature_0a9062a9)) {
            Segmented(listOf("", TemperatureUnit.CELSIUS.raw, TemperatureUnit.FAHRENHEIT.raw), temperatureRaw,
                      label = {
                          when (it) {
                              TemperatureUnit.CELSIUS.raw -> "°C"
                              TemperatureUnit.FAHRENHEIT.raw -> "°F"
                              else -> stringResource(R.string.units_follow_body)
                          }
                      },
                      onSelect = { change { NoopPrefs.setTemperatureUnit(context, TemperatureUnit.fromRaw(it)) } })
        }
        RowDivider()
        SettingRow(stringResource(R.string.l10n_settings_screen_skin_temperature_fc103030)) {
            Segmented(listOf(SkinTempDisplay.Kind.ABSOLUTE, SkinTempDisplay.Kind.DEVIATION), UnitPrefs.skinTempPreferred(context),
                      label = {
                          stringResource(if (it == SkinTempDisplay.Kind.ABSOLUTE) R.string.l10n_settings_screen_temperature_0a9062a9
                                         else R.string.skin_temp_vs_baseline)
                      },
                      onSelect = { change { NoopPrefs.setSkinTempDisplay(context, it) } })
        }
        RowDivider()
        SettingRow(stringResource(R.string.l10n_settings_screen_effort_scale_81afa9ef)) {
            Segmented(listOf(EffortScale.HUNDRED, EffortScale.WHOOP), UnitPrefs.effortScale(context),
                      label = { if (it == EffortScale.HUNDRED) "0–100" else "0–21" },
                      onSelect = { change { UnitPrefs.setEffortScale(context, it) } })
        }
    }
    if (picking) {
        AlertDialog(
            onDismissRequest = { picking = false },
            title = { Text(stringResource(R.string.settings_choose_language)) },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    AppLanguage.entries.forEach { option ->
                        Text(if (option == AppLanguage.SYSTEM) stringResource(R.string.settings_language_system) else option.autonym,
                             style = Forge.type.body,
                             color = if (option == language) Forge.colors.accent else Forge.colors.text,
                             modifier = Modifier.fillMaxWidth().clickable(role = Role.Button) {
                                 picking = false
                                 if (option != language) {
                                     // Every string switches at once by recreating the activity, as the classic row does.
                                     AppLanguagePrefs.set(context, option)
                                     context.hostingActivity()?.recreate()
                                 }
                             }.padding(vertical = 12.dp))
                    }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { picking = false }) { Text(stringResource(R.string.forge_cancel)) } },
        )
    }
}

@Composable
private fun AppearanceSection(change: (() -> Unit) -> Unit) {
    val context = LocalContext.current
    SettingsCard(title = null, blurb = null) {
        SettingRow(stringResource(R.string.l10n_settings_screen_theme_a797e309)) {
            Segmented(listOf(AppearanceMode.SYSTEM, AppearanceMode.LIGHT, AppearanceMode.DARK), AppearancePrefs.mode,
                      label = {
                          when (it) {
                              AppearanceMode.LIGHT -> stringResource(R.string.settings_theme_light)
                              AppearanceMode.DARK -> stringResource(R.string.settings_theme_dark)
                              AppearanceMode.SYSTEM -> stringResource(R.string.settings_language_system)
                          }
                      },
                      onSelect = { change { AppearancePrefs.set(context, it) } })
        }
        RowDivider()
        // The launcher icon swaps manifest aliases through the classic helper; the launcher may take a moment.
        SettingRow(stringResource(R.string.l10n_settings_screen_app_icon_abde7a74)) {
            Segmented(listOf(false, true), NoopPrefs.appIconNavy(context),
                      label = { stringResource(if (it) R.string.forge_settings_icon_blue else R.string.forge_settings_icon_titanium) },
                      onSelect = { navy -> change { setAppIcon(context, navy) } })
        }
    }
    BackgroundCard()
}

/** The iOS Appearance "Background" card: time-of-day sky, sky behind cards and card transparency. */
@Composable
private fun BackgroundCard() {
    val context = LocalContext.current
    val opacityPercent = (CardAppearance.opacity * 100).roundToInt()
    SettingsCard(title = stringResource(R.string.forge_settings_background), blurb = null) {
        ToggleRow(stringResource(R.string.forge_settings_day_sky), stringResource(R.string.forge_settings_day_sky_detail),
                  ForgeBackground.dayCycle) { ForgeBackground.setDayCycle(context, it) }
        if (ForgeBackground.dayCycle) {
            RowDivider()
            ToggleRow(stringResource(R.string.forge_settings_sky_behind_cards),
                      stringResource(R.string.forge_settings_sky_behind_cards_detail),
                      ForgeBackground.behindCards) { ForgeBackground.setBehindCards(context, it) }
        }
        RowDivider()
        // The switch is a shortcut over the same percentage, as on iOS: on starts at 70 % unless already set lower.
        ToggleRow(stringResource(R.string.forge_settings_transparent_cards),
                  stringResource(R.string.forge_settings_transparent_cards_detail), opacityPercent < 100) { on ->
            ForgeBackground.setCardOpacity(context, if (on) (if (opacityPercent >= 100) 70 else opacityPercent) else 100)
        }
        if (opacityPercent < 100) {
            RowDivider()
            SettingRow(stringResource(R.string.forge_settings_card_transparency)) {
                Text(stringResource(R.string.forge_percent, 100 - opacityPercent), style = Forge.type.bodyNumber, color = Forge.colors.accent)
            }
            Slider(value = (100 - opacityPercent).toFloat(), valueRange = 0f..100f,
                   onValueChange = { ForgeBackground.setCardOpacity(context, 100 - it.roundToInt()) },
                   colors = SliderDefaults.colors(thumbColor = Forge.colors.accent, activeTrackColor = Forge.colors.accent))
            Text(stringResource(R.string.forge_settings_card_transparency_detail), style = Forge.type.caption,
                 color = Forge.colors.textTertiary)
        }
    }
}

@Composable
private fun CalculationsSection(viewModel: AppViewModel, change: (() -> Unit) -> Unit, onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    val experiment = remember { PuffinExperiment.from(context) }
    // Day start and the effort model rescore at once through the view model, as the classic rows do.
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
        ToggleRow(stringResource(R.string.l10n_settings_screen_effort_exponential_scale),
                  stringResource(R.string.l10n_settings_screen_effort_exponential_scale_desc),
                  NoopPrefs.banisterEffort(context)) { on -> change { viewModel.setBanisterEffort(on) } }
        RowDivider()
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
        ToggleRow(stringResource(R.string.l10n_settings_screen_sleep_staging_v2_a4176770),
                  stringResource(R.string.l10n_settings_screen_a_transparent_cardiorespiratory_recipe_that_recovers_eebe00c2),
                  experiment.experimentalSleepV2) { on -> change { experiment.experimentalSleepV2 = on } }
        RowDivider()
        ToggleRow(stringResource(R.string.l10n_settings_screen_motion_aware_wake_refinement_67a91e47),
                  stringResource(R.string.l10n_settings_screen_reviews_each_scored_wake_block_for_537924ea),
                  experiment.motionAwareWake) { on -> change { experiment.motionAwareWake = on } }
    }
    SettingsCard(title = null, blurb = null) {
        LinkRow(stringResource(R.string.l10n_settings_screen_charge_d4e1aee4), stringResource(R.string.forge_settings_charge_detail)) {
            onOpen(ForgeSettingsSub.Charge)
        }
    }
}

@Composable
private fun DataBackupSection(onOpen: (ForgeSettingsSub) -> Unit) {
    val backup = rememberBackupActions()
    SettingsCard(title = stringResource(R.string.forge_backup_section), blurb = null) {
        LinkRow(stringResource(R.string.forge_backup_export), stringResource(R.string.forge_backup_export_detail), backup.export)
        RowDivider()
        LinkRow(stringResource(R.string.forge_backup_import), stringResource(R.string.forge_backup_import_detail), backup.import)
        RowDivider()
        LinkRow(stringResource(R.string.l10n_settings_screen_automatic_backups_8a772f3c),
                stringResource(R.string.forge_settings_auto_backup_detail)) { onOpen(ForgeSettingsSub.BackupSync) }
    }
    SettingsCard(title = stringResource(R.string.forge_settings_imports), blurb = null) {
        LinkRow(stringResource(R.string.nav_data_sources), stringResource(R.string.forge_settings_data_sources_detail)) {
            onOpen(ForgeSettingsSub.DataSources)
        }
        RowDivider()
        LinkRow(stringResource(R.string.nav_self_hosted_push), stringResource(R.string.push_settings_row_detail)) {
            onOpen(ForgeSettingsSub.SelfHostedPush)
        }
    }
}

@Composable
private fun HelpSection(onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
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
        LinkRow(stringResource(R.string.forge_strap_log_share), stringResource(R.string.forge_strap_log_detail)) {
            scope.launch { LogExport.shareStrapLog(context, StrapLogBuffer.snapshot()) }
        }
    }
}

@Composable
private fun LabSection(onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    var confirms by remember { mutableStateOf(CoreShadow.confirmsHistoryAck(context)) }
    SettingsCard(title = stringResource(R.string.forge_experimental_section), blurb = null) {
        ToggleRow(stringResource(R.string.forge_core_ack), stringResource(R.string.forge_core_ack_detail), confirms) {
            confirms = it
            CoreShadow.setConfirmsHistoryAck(context, it)
        }
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
private fun AboutSection(onOpen: (ForgeSettingsSub) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var checking by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<UpdateCheck.Result?>(null) }
    var automatic by remember { mutableStateOf(UpdateWatch.isEnabled(context)) }
    SettingsCard(title = null, blurb = null) {
        SettingRow(stringResource(R.string.forge_version, BuildConfig.VERSION_NAME)) {}
        RowDivider()
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.l10n_settings_screen_check_automatically_7cd229d2), style = Forge.type.body,
                     color = Forge.colors.text)
                Text(stringResource(R.string.l10n_settings_screen_once_a_day_noop_asks_github_5683aad3),
                     style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
            Switch(checked = automatic, onCheckedChange = { automatic = it; UpdateWatch.setEnabled(context, it) },
                   colors = SwitchDefaults.colors(checkedTrackColor = Forge.colors.accent))
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
        LinkRow(stringResource(R.string.l10n_settings_screen_what_s_new_4d8dc5fe),
                stringResource(R.string.l10n_settings_screen_recent_changes_and_what_to_expect_3ceb660b)) {
            onOpen(ForgeSettingsSub.WhatsNew)
        }
    }
}

/** A labelled row: the label on the left, its control on the right. */
@Composable
internal fun SettingRow(label: String, control: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = Forge.type.body, color = Forge.colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.weight(1f).padding(end = ForgeMetrics.space2))
        control()
    }
}

/** A row that opens something: title over an optional detail line, then a chevron. */
@Composable
internal fun LinkRow(title: String, detail: String?, onClick: () -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget).clickable(role = Role.Button, onClick = onClick)
            .padding(vertical = ForgeMetrics.space2),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Forge.type.body, color = colors.text)
            if (detail != null) Text(detail, style = Forge.type.caption, color = colors.textSecondary)
        }
        Spacer(Modifier.width(ForgeMetrics.space2))
        Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
    }
}

/** A switch with its title and the line that explains it. */
@Composable
internal fun ToggleRow(title: String, detail: String?, checked: Boolean, enabled: Boolean = true,
                       onChange: (Boolean) -> Unit) {
    // The whole row flips the switch, as a SwiftUI Toggle's label does.
    Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
            .toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onChange)
            .alpha(if (enabled) 1f else 0.45f)
            .padding(vertical = ForgeMetrics.space1),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = ForgeMetrics.space2), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Forge.type.body, color = Forge.colors.text)
            if (detail != null) Text(detail, style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
        Switch(checked = checked, onCheckedChange = null, enabled = enabled,
               colors = SwitchDefaults.colors(checkedTrackColor = Forge.colors.accent))
    }
}

@Composable
internal fun RowDivider() {
    HorizontalDivider(color = Forge.colors.divider.copy(alpha = 0.4f), modifier = Modifier.padding(vertical = 2.dp))
}

/** Minus, the value, plus: the iOS stepper the classic Settings mirror. */
@Composable
internal fun Stepper(value: String, enabled: Boolean = true, onMinus: () -> Unit, onPlus: () -> Unit) {
    val colors = Forge.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        StepButton(Icons.Rounded.Remove, stringResource(R.string.forge_settings_less), enabled, onMinus)
        Text(value, style = Forge.type.bodyNumber, color = if (enabled) colors.text else colors.textTertiary,
             textAlign = TextAlign.Center, maxLines = 1, modifier = Modifier.widthIn(min = 72.dp).padding(horizontal = 6.dp))
        StepButton(Icons.Rounded.Add, stringResource(R.string.forge_settings_more_step), enabled, onPlus)
    }
}

@Composable
private fun StepButton(icon: androidx.compose.ui.graphics.vector.ImageVector, description: String, enabled: Boolean,
                       onClick: () -> Unit) {
    val colors = Forge.colors
    Box(Modifier.size(36.dp).background(colors.inset, CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = null, tint = if (enabled) colors.text else colors.textTertiary,
             modifier = Modifier.size(18.dp))
    }
}

/** A segmented pill: one choice of a few, the chosen one raised. */
@Composable
internal fun <T> Segmented(options: List<T>, selected: T, label: @Composable (T) -> String, onSelect: (T) -> Unit) {
    val colors = Forge.colors
    Row(Modifier.background(colors.inset, RoundedCornerShape(10.dp)).padding(2.dp)) {
        options.forEach { option ->
            val chosen = option == selected
            Text(label(option), style = Forge.type.footnote, color = if (chosen) colors.text else colors.textSecondary,
                 maxLines = 1,
                 modifier = Modifier
                     .background(if (chosen) colors.surface else colors.inset, RoundedCornerShape(8.dp))
                     .clickable(role = Role.RadioButton) { onSelect(option) }
                     .padding(horizontal = 10.dp, vertical = 7.dp))
        }
    }
}


private fun Context.hostingActivity(): Activity? {
    var current: Context = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}
