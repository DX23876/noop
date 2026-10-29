package com.noop.ui.forge

import androidx.compose.material.icons.rounded.Accessibility
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Air
import androidx.compose.material.icons.rounded.Alarm
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Build
import androidx.compose.material.icons.rounded.CompareArrows
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.compose.material.icons.rounded.Forum
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Layers
import androidx.compose.material.icons.rounded.MenuBook
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.Psychology
import androidx.compose.material.icons.rounded.Science
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material.icons.rounded.TrackChanges
import androidx.compose.material.icons.rounded.Waves
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.History
import androidx.compose.material3.IconButton
import androidx.compose.foundation.layout.Row
import androidx.compose.runtime.remember
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.HourglassBottom
import androidx.compose.material.icons.rounded.WbTwilight
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import com.noop.R
import com.noop.ui.AppViewModel
import com.noop.ui.BreatheScreen
import com.noop.ui.CoachScreen
import com.noop.ui.CoachIdentityEditor
import com.noop.ui.CoachSettingsScreen
import com.noop.ui.CoachViewModel
import com.noop.ui.CompareScreen
import com.noop.ui.FusedRecordRoute
import com.noop.ui.HealthScreen
import com.noop.ui.InsightsHubScreen
import com.noop.ui.InsightsScreen
import com.noop.ui.IntelligenceScreen
import com.noop.ui.IntervalsScreen
import com.noop.ui.LabBookScreen
import com.noop.ui.LiveScreen
import com.noop.ui.RhythmRoute
import com.noop.ui.SmartAlarmScreen
import com.noop.ui.StressScreen
import com.noop.ui.TrendsExploreScreen
import com.noop.ui.WorkoutsScreen

/** The More categories, as iOS groups them (`MoreCategory`). */
enum class MoreCategory(val titleRes: Int, val subtitleRes: Int, val icon: ImageVector) {
    Analysis(R.string.forge_more_analysis, R.string.forge_more_analysis_sub, Icons.Rounded.AutoAwesome),
    HealthBody(R.string.forge_more_health_body, R.string.forge_more_health_body_sub, Icons.Rounded.Favorite),
    Tools(R.string.forge_more_tools, R.string.forge_more_tools_sub, Icons.Rounded.Build),
}

/**
 * Every place More opens, as iOS has them (`MoreCatalog`): the category whose tint the row takes (null for the
 * root rows), its title, icon and search words. Which rows each category page lists, and in what order, is
 * [MORE_GROUPS]; [searchOnly] destinations are found by the search but have no row, as iOS's `searchOnlyEntries`.
 */
enum class MoreDest(val category: MoreCategory?, val titleRes: Int, val icon: ImageVector, val keywords: List<String>,
                    val searchOnly: Boolean = false) {
    Momentum(MoreCategory.Analysis, R.string.forge_momentum_title, Icons.Rounded.Bolt,
             listOf("today", "priority", "what matters", "insights", "goals")),
    Insights(MoreCategory.Analysis, R.string.forge_more_insights, Icons.Rounded.AutoAwesome,
             listOf("correlations", "weekly review", "patterns")),
    Scoring(MoreCategory.Analysis, R.string.forge_more_scoring, Icons.Rounded.Psychology,
            listOf("scoring", "charge", "effort", "rest", "on-device")),
    Goals(null, R.string.forge_goals_more_title, Icons.Rounded.TrackChanges,
          listOf("goals", "weekly goal", "monthly goal", "journey", "plan", "progress", "coach")),
    Journal(MoreCategory.Analysis, R.string.forge_more_journal, Icons.Rounded.MenuBook,
            listOf("log", "behaviour", "experiments", "caffeine", "alcohol")),
    Explore(MoreCategory.Analysis, R.string.nav_explore, Icons.Rounded.GridView,
            listOf("metrics", "trends", "history", "every signal")),
    Compare(MoreCategory.Analysis, R.string.nav_compare, Icons.Rounded.CompareArrows,
            listOf("two metrics", "overlay", "correlation")),
    Fused(MoreCategory.Analysis, R.string.nav_fused_record, Icons.Rounded.Layers,
          listOf("merged record", "all sources", "one timeline")),
    Training(MoreCategory.HealthBody, R.string.forge_training, Icons.Rounded.FitnessCenter,
             listOf("workouts", "strength", "cardio", "training load", "sessions", "exercise")),
    Body(MoreCategory.HealthBody, R.string.forge_body_title, Icons.Rounded.Accessibility,
         listOf("weight", "body fat", "waist", "measurements", "tape", "navy", "circumference", "composition", "scale")),
    Energy(MoreCategory.HealthBody, R.string.forge_energy_title, Icons.Rounded.LocalFireDepartment,
           listOf("calories", "tdee", "maintenance", "deficit", "intake", "bmr", "planning", "kcal", "diet", "surplus")),
    Health(MoreCategory.HealthBody, R.string.nav_health, Icons.Rounded.Favorite,
           listOf("biometrics", "fitness age", "vitality", "skin temperature")),
    AgeLess(MoreCategory.HealthBody, R.string.forge_ageless_title, Icons.Rounded.HourglassBottom,
            listOf("healthspan", "biological age", "age", "levers")),
    RhythmAge(MoreCategory.HealthBody, R.string.forge_rhythm_title, Icons.Rounded.WbTwilight,
              listOf("rhythm age", "CosinorAge", "circadian", "movement", "day and night")),
    Biomarkers(MoreCategory.HealthBody, R.string.forge_more_biomarkers, Icons.Rounded.Science,
               listOf("blood", "blood pressure", "lab results", "body composition")),
    Stress(MoreCategory.HealthBody, R.string.nav_stress, Icons.Rounded.Bolt, listOf("strain", "load", "tension")),
    BeatRhythm(MoreCategory.HealthBody, R.string.forge_more_beat_rhythm, Icons.Rounded.Waves,
               listOf("beat-to-beat", "R-R", "regularity", "experimental")),
    Ecg(MoreCategory.HealthBody, R.string.forge_ecg_title, Icons.Rounded.MonitorHeart,
        listOf("ECG", "EKG", "electrocardiogram", "WHOOP MG", "atrial fibrillation", "experimental")),
    Live(MoreCategory.Tools, R.string.nav_live, Icons.Rounded.MonitorHeart, listOf("heart rate", "BPM", "live console", "now")),
    Breathe(MoreCategory.Tools, R.string.nav_breathe, Icons.Rounded.Air,
            listOf("breathing", "box breathing", "calm", "biofeedback")),
    Intervals(MoreCategory.Tools, R.string.nav_intervals, Icons.Rounded.Timer, listOf("interval timer", "rounds", "HIIT")),
    Settings(null, R.string.nav_settings, Icons.Rounded.Settings, listOf("preferences", "options", "configuration")),
    Alarms(null, R.string.nav_alarms, Icons.Rounded.Alarm, listOf("smart alarm", "wake", "wake-up window")),
    // Found by the search only. iOS reaches the coach through its button and Today card, and its settings
    // under Settings › AI Coach; the training reports sit behind Training.
    Coach(MoreCategory.Analysis, R.string.nav_coach, Icons.Rounded.Forum,
          listOf("ai", "coach", "chat", "ask", "plan"), searchOnly = true),
    Workouts(MoreCategory.HealthBody, R.string.forge_more_workouts, Icons.Rounded.DirectionsRun,
             listOf("training", "sessions", "exercise", "activities"), searchOnly = true),
    Strength(MoreCategory.HealthBody, R.string.forge_more_strength, Icons.Rounded.FitnessCenter,
             listOf("lifting", "hevy", "sets", "reps", "volume", "1rm", "gym"), searchOnly = true),
    Cardio(MoreCategory.HealthBody, R.string.forge_more_cardio, Icons.Rounded.DirectionsRun,
           listOf("running", "cycling", "swimming", "pace", "distance", "endurance", "km", "speed", "rowing"),
           searchOnly = true),
    TrainingLoad(MoreCategory.HealthBody, R.string.forge_more_training_load, Icons.Rounded.BarChart,
                 listOf("strength load", "cardio load", "session RPE", "sRPE", "acute", "chronic", "training stress"),
                 searchOnly = true),
}

/** Each category page's rows in iOS order (`MoreCatalog.groups`); Goals is listed in Analysis as well as at the root. */
internal val MORE_GROUPS: Map<MoreCategory, List<MoreDest>> = mapOf(
    MoreCategory.Analysis to listOf(MoreDest.Momentum, MoreDest.Insights, MoreDest.Scoring, MoreDest.Goals,
                                    MoreDest.Journal, MoreDest.Explore, MoreDest.Compare, MoreDest.Fused),
    MoreCategory.HealthBody to listOf(MoreDest.Training, MoreDest.Body, MoreDest.Energy, MoreDest.Health,
                                      MoreDest.AgeLess, MoreDest.RhythmAge, MoreDest.Biomarkers, MoreDest.Stress,
                                      MoreDest.BeatRhythm, MoreDest.Ecg),
    MoreCategory.Tools to listOf(MoreDest.Live, MoreDest.Breathe, MoreDest.Intervals),
)

/** The "Quick access" rows under the categories (`MoreCatalog.rootEntries`). */
internal val MORE_QUICK_ACCESS = listOf(MoreDest.Settings, MoreDest.Alarms)

/** Lab features appear only while switched on, as iOS lists them. */
internal fun MoreDest.shown(context: android.content.Context): Boolean =
    when (this) {
        MoreDest.AgeLess -> com.noop.core.CoreFeatures.healthspan(context)
        MoreDest.RhythmAge -> com.noop.core.CoreFeatures.rhythmAge(context)
        // "Enable AI Coach" off hides the coach, as on iOS; Settings → AI Coach keeps the switch to bring it back.
        MoreDest.Coach -> com.noop.ui.BottomBarStyleStore.coachEnabled
        else -> true
    }

/** One step of the More stack: a category page or a destination. */
internal sealed interface MoreRoute {
    data class Category(val category: MoreCategory) : MoreRoute
    data class Dest(val dest: MoreDest) : MoreRoute
}

private fun List<MoreRoute>.encode(): String = joinToString(",") {
    when (it) {
        is MoreRoute.Category -> "c:${it.category.name}"
        is MoreRoute.Dest -> "d:${it.dest.name}"
    }
}

private fun decodeMoreRoutes(raw: String): List<MoreRoute> = raw.split(",").filter { it.isNotEmpty() }.mapNotNull {
    val (kind, name) = it.split(":", limit = 2).let { p -> p[0] to p.getOrElse(1) { "" } }
    when (kind) {
        "c" -> MoreCategory.entries.firstOrNull { c -> c.name == name }?.let(MoreRoute::Category)
        "d" -> MoreDest.entries.firstOrNull { d -> d.name == name }?.let(MoreRoute::Dest)
        else -> null
    }
}

/** The More stack (category pages and destinations over the tab), kept across rotation. */
class MoreNavigator internal constructor(private val raw: () -> String, private val set: (String) -> Unit) {
    internal val stack: List<MoreRoute> get() = decodeMoreRoutes(raw())
    internal fun push(route: MoreRoute) = set((stack + route).encode())
    internal fun pop() = set(stack.dropLast(1).encode())
}

@Composable
fun rememberMoreNavigator(): MoreNavigator {
    var raw by rememberSaveable { mutableStateOf("") }
    return MoreNavigator({ raw }, { raw = it })
}

/**
 * Fork (DX23876), Android parity plan 2.1: the More index as iOS draws it (`RootTabView.moreTab`): a search over every
 * destination, Goals on its own card, the three categories under "Browse", each a card of its own opening its page,
 * and Settings and Alarms under "Quick access". Destinations Android has as classic screens open in the Forge frame
 * (`Hosted`), so every page has one look. Drawn inside the More tab's column; [MoreOverlay] shows the pages.
 */
@Composable
fun MoreIndexSections(nav: MoreNavigator, onOpenSettings: () -> Unit,
                      onOpenSettingsPage: (ForgeSettingsPage) -> Unit = { onOpenSettings() }) {
    val context = LocalContext.current
    var query by rememberSaveable { mutableStateOf("") }
    fun open(dest: MoreDest) = if (dest == MoreDest.Settings) onOpenSettings() else nav.push(MoreRoute.Dest(dest))
    SearchField(query) { query = it }
    if (query.isNotBlank()) {
        val hits = MoreDest.entries.filter { it.shown(context) }.filter { d ->
            (listOf(context.getString(d.titleRes)) + d.keywords).any { it.contains(query.trim(), ignoreCase = true) }
        }
        // Settings pages come after the screens, as iOS lists `SettingsSearchCatalog` hits under "Settings".
        val q = query.trim()
        val pages = HUB_GROUPS.flatMap { it.second }.filter { p ->
            (listOf(context.getString(p.titleRes), context.getString(p.subtitleRes)) + SETTINGS_SEARCH_WORDS[p].orEmpty())
                .any { it.contains(q, ignoreCase = true) }
        }
        if (hits.isEmpty() && pages.isEmpty()) {
            Text(stringResource(R.string.forge_more_no_results), style = Forge.type.subhead,
                 color = Forge.sceneInk.secondary, modifier = Modifier.padding(ForgeMetrics.space2))
            return
        }
        if (hits.isNotEmpty()) DestCard(hits, ::open)
        if (pages.isNotEmpty()) {
            SectionHeader(stringResource(R.string.nav_settings))
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
                pages.forEachIndexed { i, p ->
                    HubRow(p.icon, p.tint(), stringResource(p.titleRes), stringResource(p.subtitleRes)) { onOpenSettingsPage(p) }
                    if (i < pages.lastIndex) HubDivider()
                }
            }
        }
        return
    }
    DestCard(listOf(MoreDest.Goals), ::open)
    SectionHeader(stringResource(R.string.forge_more_browse))
    MoreCategory.entries.forEach { c ->
        LargeRow(c.icon, categoryTint(c), stringResource(c.titleRes), stringResource(c.subtitleRes)) {
            nav.push(MoreRoute.Category(c))
        }
    }
    SectionHeader(stringResource(R.string.forge_more_quick_access))
    DestCard(MORE_QUICK_ACCESS, ::open)
}

/**
 * A row that is a card of its own, as iOS draws the categories, the profile and the device on More
 * (`MoreCategoryRow`): a 42 pt icon tile or [leading], the headline over a two-line footnote, the chevron.
 */
@Composable
internal fun LargeRow(icon: ImageVector?, tint: Color, title: String, subtitle: String,
                      leading: (@Composable () -> Unit)? = null, detail: (@Composable () -> Unit)? = null,
                      onClick: () -> Unit) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth().clip(RoundedCornerShape(ForgeMetrics.groupedRadius))
                  .clickable(role = Role.Button, onClick = onClick),
              radius = ForgeMetrics.groupedRadius, contentPadding = ForgeMetrics.space4) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (leading != null) leading() else if (icon != null) {
                Box(Modifier.size(42.dp).background(tint, RoundedCornerShape(11.76.dp)), contentAlignment = Alignment.Center) {
                    Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(21.dp))
                }
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(title, style = Forge.type.headline, color = colors.text)
                if (detail != null) detail()
                else Text(subtitle, style = Forge.type.subhead, color = colors.textSecondary, maxLines = 2,
                          overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.width(ForgeMetrics.space2))
            Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
        }
    }
}

/** The More pages over the tab: a category's list or a destination, with Back walking the stack. */
@Composable
fun MoreOverlay(nav: MoreNavigator, viewModel: AppViewModel, onOpenSettings: () -> Unit) {
    val stack = nav.stack
    if (stack.isEmpty()) return
    fun open(dest: MoreDest) = if (dest == MoreDest.Settings) onOpenSettings() else nav.push(MoreRoute.Dest(dest))
    ForgeOverlayPage(onDismiss = nav::pop) {
        BackHandler { nav.pop() }
        ForgeSceneBackdrop(ForgeBackdrop.Sky) {
            AnimatedContent(
                targetState = stack,
                transitionSpec = {
                    val forward = targetState.size > initialState.size
                    (slideInHorizontally { w -> if (forward) w else -w / 3 } + fadeIn()) togetherWith
                        (slideOutHorizontally { w -> if (forward) -w / 3 else w } + fadeOut())
                },
            ) { shown ->
                when (val top = shown.lastOrNull()) {
                    is MoreRoute.Category -> CategoryPage(top.category, onBack = nav::pop, onOpen = ::open)
                    is MoreRoute.Dest -> MoreDestination(top.dest, viewModel, onBack = nav::pop, onOpen = ::open)
                    null -> Unit
                }
            }
        }
    }
}

@Composable
private fun CategoryPage(category: MoreCategory, onBack: () -> Unit, onOpen: (MoreDest) -> Unit) {
    SettingsColumn {
        PageTitle(stringResource(category.titleRes), onBack)
        val context = LocalContext.current
        DestCard(MORE_GROUPS.getValue(category).filter { it.shown(context) }, onOpen)
    }
}

/** A grouped card of destination rows: icon tile and title, as the iOS More list draws them. */
@Composable
private fun DestCard(dests: List<MoreDest>, onOpen: (MoreDest) -> Unit) {
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
        dests.forEachIndexed { i, d ->
            HubRow(d.icon, destTint(d), stringResource(d.titleRes), "") { onOpen(d) }
            if (i < dests.lastIndex) HubDivider()
        }
    }
}

@Composable
private fun SearchField(query: String, onChange: (String) -> Unit) {
    val colors = Forge.colors
    OutlinedTextField(
        value = query, onValueChange = onChange, singleLine = true,
        placeholder = { Text(stringResource(R.string.forge_more_search)) },
        leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null) },
        shape = RoundedCornerShape(ForgeMetrics.groupedRadius),
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = colors.surface, unfocusedContainerColor = colors.surface,
            focusedBorderColor = Color.Transparent, unfocusedBorderColor = Color.Transparent,
            focusedTextColor = colors.text, unfocusedTextColor = colors.text,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun categoryTint(c: MoreCategory): Color = when (c) {
    MoreCategory.Analysis -> ForgeTokens.Color.systemPurple.resolve()
    MoreCategory.HealthBody -> ForgeTokens.Color.systemRed.resolve()
    MoreCategory.Tools -> ForgeTokens.Color.systemCyan.resolve()
}

@Composable
private fun destTint(d: MoreDest): Color = d.category?.let { categoryTint(it) }
    ?: if (d == MoreDest.Goals) ForgeTokens.Color.systemOrange.resolve() else ForgeTokens.Color.systemGray.resolve()

/** Opens one destination: Android's own screen for it, in the Forge frame. */
@Composable
private fun MoreDestination(dest: MoreDest, viewModel: AppViewModel, onBack: () -> Unit, onOpen: (MoreDest) -> Unit) {
    val title = stringResource(dest.titleRes)
    // Goals is a Forge page of its own (the shared core's goals), not a classic screen in the frame.
    if (dest == MoreDest.Goals) {
        ForgeGoalsPage(onBack)
        return
    }
    if (dest == MoreDest.Body) {
        ForgeBodyPage(onBack)
        return
    }
    when (dest) {
        // iOS pushes the Training hub onto More's stack; Android shows its Training tab there with a way back.
        MoreDest.Training -> {
            Column(Modifier.fillMaxSize().statusBarsPadding()) {
                Box(Modifier.padding(horizontal = ForgeMetrics.screenPadding)) { PageTitle(null, onBack) }
                Box(Modifier.weight(1f)) { ForgeTrainingScreen(PaddingValues(0.dp), viewModel) }
            }
            return
        }
        MoreDest.Strength -> { ForgeStrengthPage(onBack); return }
        MoreDest.Cardio -> { ForgeCardioPage(onBack); return }
        MoreDest.TrainingLoad -> { ForgeTrainingLoadPage(onBack); return }
        else -> Unit
    }
    if (dest == MoreDest.Ecg) {
        ForgeEcgPage(onBack)
        return
    }
    if (dest == MoreDest.Coach) {
        ForgeCoachDestination(title, onBack, onOpen)
        return
    }
    if (dest == MoreDest.Energy) {
        var detail by remember { mutableStateOf(false) }
        androidx.activity.compose.BackHandler(enabled = detail) { detail = false }
        if (detail) ForgeEnergyDetailPage(onBack = { detail = false }) else ForgeEnergyPlanPage(onBack, onDetail = { detail = true })
        return
    }
    if (dest == MoreDest.RhythmAge) {
        ForgeRhythmAgePage(onBack)
        return
    }
    if (dest == MoreDest.AgeLess) {
        ForgeAgeLessPage(onBack)
        return
    }
    if (dest == MoreDest.Momentum) {
        var plan by remember { mutableStateOf(false) }
        androidx.activity.compose.BackHandler(enabled = plan) { plan = false }
        if (plan) ForgeCoachPlanPage(onBack = { plan = false })
        else ForgeMomentumPage(onBack, onDestination = { d ->
            when (d) {
                "goalJourney" -> onOpen(MoreDest.Goals)
                "liveSession" -> onOpen(MoreDest.Live)
                "plan" -> plan = true
            }
        })
        return
    }
    Hosted(title, onBack) {
        when (dest) {
            MoreDest.Insights -> InsightsHubScreen(viewModel)
            MoreDest.Scoring -> IntelligenceScreen(viewModel)
            MoreDest.Journal -> InsightsScreen(viewModel, onOpenInsightsHub = { onOpen(MoreDest.Insights) })
            MoreDest.Explore -> TrendsExploreScreen(viewModel)
            MoreDest.Compare -> CompareScreen(viewModel)
            MoreDest.Fused -> FusedRecordRoute(viewModel)
            MoreDest.Health -> HealthScreen(viewModel, onOpenLabBook = { onOpen(MoreDest.Biomarkers) },
                                            onOpenFusedRecord = { onOpen(MoreDest.Fused) })
            MoreDest.Biomarkers -> LabBookScreen(viewModel)
            MoreDest.Stress -> StressScreen(viewModel, onBreathe = { onOpen(MoreDest.Breathe) })
            MoreDest.BeatRhythm -> RhythmRoute(viewModel)
            MoreDest.Live -> LiveScreen(viewModel)
            MoreDest.Breathe -> BreatheScreen(viewModel)
            MoreDest.Intervals -> IntervalsScreen(viewModel)
            MoreDest.Alarms -> SmartAlarmScreen(viewModel)
            MoreDest.Workouts -> WorkoutsScreen(viewModel)
            MoreDest.Settings, MoreDest.Goals, MoreDest.Momentum, MoreDest.AgeLess, MoreDest.RhythmAge, MoreDest.Energy, MoreDest.Body, MoreDest.Coach, MoreDest.Ecg, MoreDest.Training,
            MoreDest.Strength, MoreDest.Cardio, MoreDest.TrainingLoad -> Unit
        }
    }
}

/** The coach chat with its history and plan book a tap away, as the chat header offers them on iOS. */
@Composable
internal fun ForgeCoachDestination(title: String, onBack: () -> Unit, onOpen: (MoreDest) -> Unit) {
    val vm = viewModel<CoachViewModel>()
    var sub by remember { mutableStateOf<String?>(null) }
    var draftId by remember { mutableStateOf<String?>(null) }
    androidx.activity.compose.BackHandler(enabled = sub != null) { sub = if (sub == "identity" || sub == "memory" || sub == "info") "settings" else null }
    when (sub) {
        "history" -> ForgeCoachHistoryPage(onBack = { sub = null }, onPicked = { vm.showCoreConversation(); sub = null })
        "plan" -> ForgeCoachPlanPage(onBack = { sub = null })
        "goals" -> ForgeGoalsPage(onBack = { sub = null })
        "onboarding" -> GoalOnboardingPage(onClose = { sub = null })
        "reviewRoutine" -> RoutineReviewPage(onClose = { sub = null })
        "reviewWorkout" -> WorkoutReviewPage(onClose = { sub = null })
        "reviewGoal" -> draftId?.let { GoalDraftReviewPage(it, onClose = { sub = null }) }
        "settings" -> Hosted(stringResource(R.string.coach_settings), { sub = null }) {
            CoachSettingsScreen(vm, onOpenIdentity = { sub = "identity" }, onOpenMemory = { sub = "memory" },
                                onOpenInfo = { sub = "info" }, onOpenGoals = { sub = "goals" })
        }
        "identity" -> Hosted(stringResource(R.string.coach_identity), { sub = "settings" }) { CoachIdentityEditor(vm) }
        "memory" -> Hosted(stringResource(R.string.coach_memory), { sub = "settings" }) { com.noop.ui.CoachMemoryPage() }
        "info" -> Hosted(vm.info.collectAsStateWithLifecycle().value?.infoTitle.orEmpty(), { sub = "settings" }) {
            com.noop.ui.CoachInfoPage(vm)
        }
        // As the iOS chat: only a way back up here; the plan book sits in the chat's own header row and the
        // history in its overflow menu.
        else -> Hosted("", onBack) {
            CoachScreen(vm, onGoalOnboarding = { sub = "onboarding" },
                        onReviewDraft = { kind, id -> if (kind == "goal") { draftId = id; sub = "reviewGoal" } else sub = "review" + kind.replaceFirstChar { it.uppercase() } }, onOpenSettings = { sub = "settings" }, onOpenPlan = { sub = "plan" },
                        onOpenHistory = { sub = "history" }, onOpenBreathe = { onOpen(MoreDest.Breathe) },
                        onOpenLive = { onOpen(MoreDest.Live) }, onOpenGoals = { sub = "goals" })
        }
    }
}
