package com.noop.ui.forge

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
import com.noop.R
import com.noop.ui.AppViewModel
import com.noop.ui.BreatheScreen
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

/** The More categories, as iOS groups them (`MoreCategory`). */
enum class MoreCategory(val titleRes: Int, val subtitleRes: Int, val icon: ImageVector) {
    Analysis(R.string.forge_more_analysis, R.string.forge_more_analysis_sub, Icons.Rounded.AutoAwesome),
    HealthBody(R.string.forge_more_health_body, R.string.forge_more_health_body_sub, Icons.Rounded.Favorite),
    Tools(R.string.forge_more_tools, R.string.forge_more_tools_sub, Icons.Rounded.Build),
}

/**
 * Every place More opens, in iOS order (`MoreCatalog`): the category it is listed in (null for a root row), its
 * title, icon and search words. A destination iOS has and Android does not yet is left out rather than opening an
 * empty page; the parity plan adds each one with its screen.
 */
enum class MoreDest(val category: MoreCategory?, val titleRes: Int, val icon: ImageVector, val keywords: List<String>) {
    Insights(MoreCategory.Analysis, R.string.forge_more_insights, Icons.Rounded.AutoAwesome,
             listOf("correlations", "weekly review", "patterns")),
    Scoring(MoreCategory.Analysis, R.string.forge_more_scoring, Icons.Rounded.Psychology,
            listOf("scoring", "charge", "effort", "rest", "on-device")),
    Journal(MoreCategory.Analysis, R.string.forge_more_journal, Icons.Rounded.MenuBook,
            listOf("log", "behaviour", "experiments", "caffeine", "alcohol")),
    Explore(MoreCategory.Analysis, R.string.nav_explore, Icons.Rounded.GridView, listOf("metrics", "trends", "history")),
    Compare(MoreCategory.Analysis, R.string.nav_compare, Icons.Rounded.CompareArrows,
            listOf("two metrics", "overlay", "correlation")),
    Fused(MoreCategory.Analysis, R.string.nav_fused_record, Icons.Rounded.Layers,
          listOf("merged record", "all sources", "one timeline")),
    Health(MoreCategory.HealthBody, R.string.nav_health, Icons.Rounded.Favorite,
           listOf("biometrics", "fitness age", "vitality", "skin temperature")),
    Biomarkers(MoreCategory.HealthBody, R.string.forge_more_biomarkers, Icons.Rounded.Science,
               listOf("blood", "blood pressure", "lab results", "body composition")),
    Stress(MoreCategory.HealthBody, R.string.nav_stress, Icons.Rounded.Bolt, listOf("strain", "load", "tension")),
    BeatRhythm(MoreCategory.HealthBody, R.string.forge_more_beat_rhythm, Icons.Rounded.Waves,
               listOf("beat-to-beat", "R-R", "regularity", "experimental")),
    Live(MoreCategory.Tools, R.string.nav_live, Icons.Rounded.MonitorHeart, listOf("heart rate", "BPM", "now")),
    Breathe(MoreCategory.Tools, R.string.nav_breathe, Icons.Rounded.Air, listOf("breathing", "calm", "biofeedback")),
    Intervals(MoreCategory.Tools, R.string.nav_intervals, Icons.Rounded.Timer, listOf("interval timer", "rounds", "HIIT")),
    Alarms(null, R.string.nav_alarms, Icons.Rounded.Alarm, listOf("smart alarm", "wake", "wake-up window")),
    Settings(null, R.string.nav_settings, Icons.Rounded.Settings, listOf("preferences", "options", "configuration")),
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
 * Fork (DX23876), Android parity plan 2.1: the More index as iOS draws it (`MoreCatalog`): a search over every
 * destination, the root rows (Settings, Alarms), then the three categories, each opening its page of destinations.
 * Destinations Android has as classic screens open in the Forge frame (`Hosted`), so every page has one look.
 * Drawn inside the More tab's column; [MoreOverlay] shows the pages.
 */
@Composable
fun MoreIndexSections(nav: MoreNavigator, onOpenSettings: () -> Unit) {
    val context = LocalContext.current
    var query by rememberSaveable { mutableStateOf("") }
    fun open(dest: MoreDest) = if (dest == MoreDest.Settings) onOpenSettings() else nav.push(MoreRoute.Dest(dest))
    SearchField(query) { query = it }
    if (query.isNotBlank()) {
        val hits = MoreDest.entries.filter { d ->
            (listOf(context.getString(d.titleRes)) + d.keywords).any { it.contains(query.trim(), ignoreCase = true) }
        }
        if (hits.isEmpty()) {
            Text(stringResource(R.string.forge_more_no_results), style = Forge.type.subhead,
                 color = Forge.sceneInk.secondary, modifier = Modifier.padding(ForgeMetrics.space2))
        } else DestCard(hits, ::open)
        return
    }
    DestCard(MoreDest.entries.filter { it.category == null }, ::open)
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
        MoreCategory.entries.forEachIndexed { i, c ->
            HubRow(c.icon, categoryTint(c), stringResource(c.titleRes), stringResource(c.subtitleRes)) {
                nav.push(MoreRoute.Category(c))
            }
            if (i < MoreCategory.entries.lastIndex) HubDivider()
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
        DestCard(MoreDest.entries.filter { it.category == category }, onOpen)
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
    MoreCategory.Analysis -> ForgeTokens.Color.systemIndigo.resolve()
    MoreCategory.HealthBody -> ForgeTokens.Color.systemPink.resolve()
    MoreCategory.Tools -> ForgeTokens.Color.systemOrange.resolve()
}

@Composable
private fun destTint(d: MoreDest): Color = d.category?.let { categoryTint(it) } ?: ForgeTokens.Color.systemGray.resolve()

/** Opens one destination: Android's own screen for it, in the Forge frame. */
@Composable
private fun MoreDestination(dest: MoreDest, viewModel: AppViewModel, onBack: () -> Unit, onOpen: (MoreDest) -> Unit) {
    val title = stringResource(dest.titleRes)
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
            MoreDest.Settings -> Unit
        }
    }
}
