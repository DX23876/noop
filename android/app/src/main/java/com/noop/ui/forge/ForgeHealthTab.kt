package com.noop.ui.forge

import android.text.format.DateFormat
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.runtime.collectAsState
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Lightbulb
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.ShowChart
import androidx.compose.material3.Icon
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.analytics.VitalBands
import com.noop.ui.AppViewModel
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileAvatar
import com.noop.ui.Sparkline
import com.noop.ui.UnitPrefs
import com.noop.ui.Vital
import com.noop.ui.latestVitals
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Fork (DX23876), Forge parity 2026-11: the Health tab of the new iOS design (`ForgeHealthView`). Last night's
 * vitals against the wearer's own range first, then heart and stress, body and energy, and the long-term views
 * (Trends moved here from its own tab, as on iOS).
 *
 * The vitals come from [latestVitals], the same resolver the Health monitor draws its tiles from and the Kotlin
 * twin of iOS's `BodyVitalSigns.readings`, so the two screens always agree on what is in range.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ForgeHealthTab(padding: PaddingValues, width: ForgeWidth, viewModel: AppViewModel) {
    val context = LocalContext.current
    val colors = Forge.colors
    val days by viewModel.recentDays.collectAsStateWithLifecycle()
    val spo2CandidateByDay by viewModel.spo2CandidateByDay.collectAsStateWithLifecycle()
    val hrvOverCountByDay by viewModel.hrvOverCountByDay.collectAsStateWithLifecycle()
    var settingsOpen by remember { mutableStateOf(false) }
    // Read again when Settings closes, so a unit or SpO₂ choice made there shows without a restart.
    val tempUnit = remember(settingsOpen) { UnitPrefs.temperature(context) }
    val spo2Toggle = remember(settingsOpen) { NoopPrefs.spo2CandidateDisplay(context) }
    val vitals = remember(days, spo2CandidateByDay, hrvOverCountByDay, tempUnit, spo2Toggle) {
        latestVitals(days, tempUnit, spo2CandidateByDay, spo2Toggle, hrvOverCountByDay = hrvOverCountByDay)
            // The raw optical reading is an experimental instrument; an empty one is noise on this tab.
            .filter { !(it.key == "spo2raw" && it.value == null) }
            .sortedBy { listOf("hrv", "rhr", "spo2", "resp", "skin", "spo2raw").indexOf(it.key).let { i -> if (i < 0) 99 else i } }
    }
    val scored = vitals.filter { it.banding.band != VitalBands.Band.NO_DATA && it.key != "spo2raw" }
    val inRange = scored.count { it.banding.band == VitalBands.Band.IN_RANGE }

    val more = rememberMoreNavigator()
    var trendsOpen by remember { mutableStateOf(false) }
    androidx.compose.runtime.LaunchedEffect(ForgeDesign.openTrends) {
        if (ForgeDesign.openTrends) { ForgeDesign.openTrends = false; trendsOpen = true }
    }
    fun open(dest: MoreDest) = more.push(MoreRoute.Dest(dest))
    var editingTiles by remember { mutableStateOf(false) }
    var chosenTiles by remember { mutableStateOf(VitalTilePrefs.chosen(context)) }
    // The tile the picker swaps ("" adds one), null while the picker is closed.
    var tilePick by remember { mutableStateOf<String?>(null) }
    fun openMeasure(key: String) = when (key) {
        "ageless" -> open(MoreDest.AgeLess); "weight" -> open(MoreDest.Body); "stress" -> open(MoreDest.Stress)
        else -> open(MoreDest.Explore)
    }
    var tileColumns by remember { mutableStateOf(VitalTilePrefs.columns(context, if (width == ForgeWidth.Compact) 2 else 3)) }
    var weeklyOpen by remember { mutableStateOf(false) }
    var cycleOpen by remember { mutableStateOf(false) }
    var cycleLogFirst by remember { mutableStateOf(false) }
    var focus by remember { mutableStateOf<FocusArea?>(null) }
    val selectTab = LocalForgeTabSelect.current

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding)
            .padding(horizontal = ForgeMetrics.screenPadding),
        verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3),
    ) {
        val openMore = LocalForgeOpenMore.current
        TabHeader(stringResource(R.string.nav_health), onProfile = { openMore?.invoke() ?: run { settingsOpen = true } },
                  onSearch = rememberOpenSearch())

        // The tab's answer: how many of last night's vitals sat in the wearer's own range, then each by name.
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Text(stringResource(R.string.forge_health_vitals_last_night), style = Forge.type.subhead,
                 color = Forge.sceneInk.secondary)
            Text(if (scored.isEmpty()) stringResource(R.string.forge_health_no_readings)
                 else stringResource(R.string.forge_health_in_range, inRange, scored.size),
                 style = Forge.type.title2.copy(fontWeight = FontWeight.Bold), color = Forge.sceneInk.text)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                scored.forEach { v -> RangeChip(v) }
            }
        }
        // The first vital outside the range, told in a card of its own under the chips, as iOS's `offRangeCard`.
        scored.firstOrNull { it.banding.band == VitalBands.Band.OUT_OF_RANGE }?.let { OffRangeCard(it) }

        // Vitals with "Edit", as iOS: the tiles the wearer keeps, in their order, two or three to a row.
        Row(verticalAlignment = Alignment.Bottom) {
            Box(Modifier.weight(1f)) { Heading(stringResource(R.string.forge_health_vitals)) }
            if (!editingTiles) Text(stringResource(R.string.forge_hv_edit), style = Forge.type.subhead, color = colors.accent,
                                    modifier = Modifier.clickable(role = Role.Button) { editingTiles = true }.padding(4.dp))
        }
        val columns = tileColumns.coerceIn(2, 3)
        if (editingTiles) VitalsEditHeader(columns, onColumns = { tileColumns = it; VitalTilePrefs.setColumns(context, it) },
                                           onDone = { editingTiles = false })
        // The wearer's tiles in their order (iOS `ForgeVitalTileStore`): until edited, the night's vitals as before.
        val placed = (chosenTiles ?: vitals.map { it.key }).take(VitalTilePrefs.MAX)
        fun save(list: List<String>) { chosenTiles = list.distinct().take(VitalTilePrefs.MAX); VitalTilePrefs.setChosen(context, chosenTiles!!) }
        placed.chunked(columns).forEachIndexed { rowIndex, row ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                row.forEachIndexed { col, key ->
                    val index = rowIndex * columns + col
                    Box(Modifier.weight(1f)) {
                        val vital = vitals.firstOrNull { it.key == key }
                        val tap = { if (editingTiles) tilePick = key else if (vital != null) open(MoreDest.Health) else openMeasure(key) }
                        if (vital != null) VitalTile(vital, Modifier.fillMaxWidth()) { tap() }
                        else MeasureTile(viewModel, key, Modifier.fillMaxWidth()) { tap() }
                        if (editingTiles) {
                            RemoveBadge(Modifier.align(Alignment.TopEnd)) { save(placed - key) }
                            Row(Modifier.align(Alignment.BottomEnd).padding(4.dp)) {
                                if (index > 0) MoveButton(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.forge_vt_earlier)) {
                                    save(placed.toMutableList().apply { add(index - 1, removeAt(index)) })
                                }
                                if (index < placed.lastIndex) MoveButton(Icons.AutoMirrored.Rounded.ArrowForward, stringResource(R.string.forge_vt_later)) {
                                    save(placed.toMutableList().apply { add(index + 1, removeAt(index)) })
                                }
                            }
                        }
                    }
                }
                repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
        if (editingTiles && placed.size < VitalTilePrefs.MAX) {
            Row(Modifier.fillMaxWidth().background(colors.surface, androidx.compose.foundation.shape.RoundedCornerShape(22.dp))
                    .clickable(role = Role.Button) { tilePick = "" }.padding(vertical = 16.dp),
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.AddCircle, contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(6.dp))
                Text(stringResource(R.string.forge_hv_add), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.accent)
            }
        }
        tilePick?.let { replacing ->
            VitalTilePicker(replacing.ifEmpty { null }, placed, vitals, onPick = { picked ->
                save(if (replacing.isEmpty()) placed + picked else placed.map { if (it == replacing) picked else it })
                tilePick = null
            }, onDismiss = { tilePick = null })
        }

        // The cycle at a glance, only while cycle tracking is on and a period is logged (iOS `ForgeCycleSummaryCard`).
        val cycleOn by viewModel.cycleTrackingEnabled.collectAsStateWithLifecycle()
        val periodStarts by viewModel.periodStarts.collectAsStateWithLifecycle()
        if (cycleOn && periodStarts.isNotEmpty()) {
            if (ForgeDesign.preview) ForgeCycleSummaryCard(viewModel, onOpen = { cycleOpen = true }, onLog = { cycleLogFirst = true; cycleOpen = true })
            else TodayCycleForge(viewModel)
        }

        // Today's food log, one tap from the page, as iOS's `FoodHealthCard`.
        FoodTodayCard(onOpen = { open(MoreDest.Food) }, onAdd = { FoodArrival.requestAdd(); open(MoreDest.Food) })

        // The focus areas as six tiles, as iOS: each lists its pages; Sleep opens the Sleep tab.
        Heading(stringResource(R.string.forge_hf_focus))
        HealthFocusGrid { area -> focus = area }

        Heading(stringResource(R.string.forge_health_long_term))
        val longTerm = listOf(MoreDest.AgeLess, MoreDest.RhythmAge).filter { it.shown(context) }
        if (longTerm.isNotEmpty()) DestCard(longTerm) { open(it) }
        HealthWeekInRings(days) { trendsOpen = true }
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
            // The week read back, as iOS's first row of the group (`ForgeRoute.weeklyReport`).
            HubRow(Icons.Rounded.CalendarMonth, colors.accent, stringResource(R.string.forge_hv_weekly),
                   stringResource(R.string.forge_hv_weekly_sub)) { weeklyOpen = true }
            HubDivider()
            HubRow(Icons.Rounded.ShowChart, colors.charge, stringResource(R.string.nav_trends),
                   stringResource(R.string.forge_health_trends_sub)) { trendsOpen = true }
            HubDivider()
            // What works sits between them, as iOS's Long term group lists it.
            if (MoreDest.Insights.shown(context)) {
                HubRow(Icons.Rounded.Lightbulb, ForgeTokens.Color.systemYellow.resolve(), stringResource(R.string.forge_health_what_works),
                       stringResource(R.string.forge_health_what_works_sub)) { open(MoreDest.Insights) }
                HubDivider()
            }
            HubRow(Icons.Rounded.GridView, colors.accent, stringResource(R.string.forge_health_all_metrics),
                   stringResource(R.string.forge_health_all_metrics_sub)) {
                open(MoreDest.Explore)
            }
        }
        Spacer(Modifier.height(ForgeMetrics.space4))
    }

    focus?.let { area ->
        ForgeOverlayPage(onDismiss = { focus = null }) {
            ForgeSceneBackdrop(ForgeBackdrop.Canvas) {
                androidx.activity.compose.BackHandler { focus = null }
                FocusAreaPage(area, viewModel, onBack = { focus = null }, onOpen = { focus = null; open(it) },
                              onAction = { a -> focus = null; when (a) { "sleep" -> selectTab(ForgeTab.Sleep); "trends" -> trendsOpen = true
                                  "cycle" -> cycleOpen = true } })
            }
        }
    }
    if (weeklyOpen) {
        ForgeOverlayPage(onDismiss = { weeklyOpen = false }) {
            ForgeSceneBackdrop(ForgeBackdrop.Canvas) {
                androidx.activity.compose.BackHandler { weeklyOpen = false }
                ForgeWeeklyReportPage(viewModel, onBack = { weeklyOpen = false },
                    onAsk = if (com.noop.ui.BottomBarStyleStore.coachEnabled) { prompt ->
                        com.noop.ui.CoachHandoff.pendingPrompt = prompt; weeklyOpen = false; selectTab(ForgeTab.Coach)
                    } else null)
            }
        }
    }
    // The cycle, from a focus link or the cycle card: the new design's cycle page, the classic tracker otherwise.
    if (cycleOpen && ForgeDesign.preview) {
        ForgeCycleOverlay(viewModel, logFirst = cycleLogFirst, onDismiss = { cycleOpen = false; cycleLogFirst = false })
    } else if (cycleOpen) {
        val v5 by viewModel.v5Signals.collectAsStateWithLifecycle()
        val starts by viewModel.periodStarts.collectAsStateWithLifecycle()
        v5?.cycle?.let { cycle ->
            com.noop.ui.CycleTrackerDialog(result = cycle, starts = starts, onLog = viewModel::logPeriodStart,
                onDelete = viewModel::deletePeriodStart, onDeleteAll = viewModel::deleteAllPeriodStarts,
                onDismiss = { cycleOpen = false })
        } ?: run { cycleOpen = false }
    }
    MoreOverlay(more, viewModel, onOpenSettings = { settingsOpen = true })
    if (trendsOpen) {
        // On a backdrop of its own, clear of the system bars, with a way back: drawn bare, the Health tab and the
        // tab bar showed through it.
        ForgeOverlayPage(onDismiss = { trendsOpen = false }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) {
                ForgeTrendsScreen(WindowInsets.systemBars.asPaddingValues(), width, viewModel, onBack = { trendsOpen = false })
            }
        }
    }
    if (settingsOpen) {
        ForgeOverlayPage(onDismiss = { settingsOpen = false }) { ForgeSettings(viewModel, onClose = { settingsOpen = false }) }
    }
}

/** A tab's own header row, as iOS's `ForgeLargeHeader`: the title with today's date, the profile at the end. */
@Composable
internal fun TabHeader(title: String, onProfile: () -> Unit, onSearch: (() -> Unit)? = null) {
    val locale = Locale.getDefault()
    Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space4), verticalAlignment = Alignment.CenterVertically) {
        Text(
            buildAnnotatedString {
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(title) }
                withStyle(Forge.type.subhead.toSpanStyle().copy(color = Forge.sceneInk.secondary)) {
                    append("  ")
                    append(LocalDate.now().format(DateTimeFormatter.ofPattern(
                        DateFormat.getBestDateTimePattern(locale, "EEEMMMd"), locale)))
                }
            },
            style = Forge.type.title2, color = Forge.sceneInk.text, maxLines = 1, modifier = Modifier.weight(1f),
        )
        // The magnifier before the profile, as iOS's `ForgeSearchButton` in each tab's header.
        if (onSearch != null) {
            Box(Modifier.size(ForgeMetrics.minHitTarget).clickable(role = Role.Button, onClick = onSearch),
                contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.Search, contentDescription = stringResource(R.string.forge_more_search),
                     tint = Forge.sceneInk.text, modifier = Modifier.size(22.dp))
            }
            Spacer(Modifier.size(ForgeMetrics.space1))
        }
        ProfileAvatar(size = 36.dp, contentDescription = stringResource(R.string.forge_qa_profile_settings),
                      modifier = Modifier.clickable(role = Role.Button, onClick = onProfile))
    }
}

/** The magnifier's action in the new design: the More page, its search focused. Null in the shipped design. */
@Composable
internal fun rememberOpenSearch(): (() -> Unit)? {
    val openMore = LocalForgeOpenMore.current ?: return null
    return { ForgeDesign.focusSearch = true; openMore() }
}

/** A section's title above its card, as iOS's `ForgeSectionHeading`: bold, sentence case. */
@Composable
private fun Heading(text: String) {
    Text(text, style = Forge.type.headline.copy(fontWeight = FontWeight.Bold), color = Forge.sceneInk.text,
         modifier = Modifier.padding(top = ForgeMetrics.space3))
}

@Composable
private fun RangeChip(v: Vital) {
    val colors = Forge.colors
    val ok = v.banding.band == VitalBands.Band.IN_RANGE
    Row(
        Modifier.heightIn(min = 30.dp)
            .background(if (ok) colors.surface.copy(alpha = 0.75f) else colors.effort.copy(alpha = 0.16f), CircleShape)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(if (ok) Icons.Rounded.CheckCircle else Icons.Rounded.Error, contentDescription = null,
             tint = if (ok) colors.charge else colors.effort, modifier = Modifier.size(16.dp))
        Spacer(Modifier.size(6.dp))
        Text(v.label, style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold),
             color = if (ok) colors.text else colors.effort)
    }
}

/** A vital outside the wearer's range: which, last night's figure with the yardstick's word, and its course. */
@Composable
private fun OffRangeCard(v: Vital) {
    val colors = Forge.colors
    val state = stringResource(if (v.banding.basis == VitalBands.Basis.PERSONAL) R.string.forge_h_off_baseline
                               else R.string.forge_h_off_typical)
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = 16.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.MonitorHeart, contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
            Spacer(Modifier.size(6.dp))
            Text(stringResource(R.string.forge_h_off_label), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = colors.accent)
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Text(stringResource(R.string.forge_h_off_title, v.label), style = Forge.type.title2.copy(fontWeight = FontWeight.Bold),
             color = colors.text)
        v.value?.let { value ->
            val figure = v.format(value)
            val sentence = stringResource(R.string.forge_h_off_last_night, figure, v.unit, state)
            // The figure and its unit bold, wherever the language puts them in the sentence.
            val bold = "$figure ${v.unit}".trim()
            val at = sentence.indexOf(bold)
            Spacer(Modifier.height(ForgeMetrics.space1))
            Text(buildAnnotatedString {
                append(sentence)
                if (at >= 0) addStyle(SpanStyle(fontWeight = FontWeight.Bold, color = colors.text), at, at + bold.length)
            }, style = Forge.type.body, color = colors.textSecondary)
        }
        if (v.sparkline.size > 1) {
            Spacer(Modifier.height(ForgeMetrics.space3))
            Sparkline(v.sparkline, color = colors.effort)
        }
    }
}

/** One vital: its name, the figure large with the unit small beside it, and its recent course. */
@Composable
private fun VitalTile(v: Vital, modifier: Modifier, onClick: () -> Unit) {
    val colors = Forge.colors
    ForgeCard(modifier.clickable(role = Role.Button, onClick = onClick), contentPadding = 14.dp) {
        Text(v.label, style = Forge.type.subhead, color = colors.textSecondary, maxLines = 1)
        Spacer(Modifier.height(ForgeMetrics.space1))
        Text(
            buildAnnotatedString {
                append(v.value?.let(v.format) ?: "–")
                if (v.value != null && v.unit.isNotEmpty()) {
                    withStyle(Forge.type.footnote.toSpanStyle().copy(color = colors.textSecondary)) { append(" " + v.unit) }
                }
            },
            style = Forge.type.heroNumber, color = colors.text, maxLines = 1,
        )
        Spacer(Modifier.height(ForgeMetrics.space2))
        if (v.sparkline.size > 1) Sparkline(v.sparkline, color = v.metricColor)
        VitalBadge(v)
    }
}

/**
 * The judgement under a vital tile, as iOS's `ForgeBadge`: in the wearer's range or the typical one, off it,
 * or "Estimated" for the strap's blood-oxygen figure. Nothing for an empty tile or the raw optical reading.
 */
@Composable
private fun VitalBadge(v: Vital) {
    if (v.banding.band == VitalBands.Band.NO_DATA || v.key == "spo2raw") return
    val colors = Forge.colors
    val personal = v.banding.basis == VitalBands.Basis.PERSONAL
    val inRange = v.banding.band == VitalBands.Band.IN_RANGE
    val (text, tint) = when {
        v.isEstimate -> stringResource(R.string.forge_h_badge_estimated) to colors.textSecondary
        inRange -> stringResource(if (personal) R.string.forge_h_badge_in_range else R.string.forge_h_badge_typical) to colors.charge
        else -> stringResource(if (personal) R.string.forge_h_off_baseline else R.string.forge_h_off_typical) to colors.effort
    }
    Spacer(Modifier.height(ForgeMetrics.space2))
    Text(text, style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = tint, maxLines = 1,
         modifier = Modifier.background(tint.copy(alpha = 0.14f), CircleShape).padding(horizontal = 10.dp, vertical = 3.dp))
}

/** The wearer's vital tiles in order and the tiles per row, as iOS's `ForgeVitalTileStore` keeps them (same keys). */
internal object VitalTilePrefs {
    private const val CHOSEN = "forge.health.vitalTiles"
    private const val COLUMNS = "forge.health.vitalColumns"
    const val MAX = 9
    /** Every tile the grid can show, as iOS's `ForgeVitalTile`: the nightly vitals, then the measures beside them. */
    val vitalKeys = listOf("hrv", "rhr", "spo2", "resp", "skin", "spo2raw")
    val measureKeys = listOf("ageless", "vo2max", "weight", "stress", "steps")
    /** Null until the wearer edits the tiles. */
    fun chosen(context: android.content.Context): List<String>? =
        NoopPrefs.of(context).getString(CHOSEN, null)?.split(",")?.filter { it in vitalKeys || it in measureKeys }
    fun setChosen(context: android.content.Context, keys: List<String>) =
        NoopPrefs.of(context).edit().putString(CHOSEN, keys.joinToString(",")).apply()
    fun columns(context: android.content.Context, fallback: Int): Int = NoopPrefs.of(context).getInt(COLUMNS, fallback)
    fun setColumns(context: android.content.Context, n: Int) = NoopPrefs.of(context).edit().putInt(COLUMNS, n).apply()
}

@Composable
private fun measureTitle(key: String): String = when (key) {
    "ageless" -> "AgeLess"; "vo2max" -> stringResource(R.string.forge_vt_vo2); "weight" -> stringResource(R.string.forge_vt_weight)
    "stress" -> stringResource(R.string.forge_vt_stress); else -> stringResource(R.string.forge_vt_steps)
}

/** A measure beside the vitals, its latest value and two months as a line (iOS `ForgeHealthMeasureTile`). */
@Composable
private fun MeasureTile(viewModel: AppViewModel, key: String, modifier: Modifier, onClick: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val revision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val values by androidx.compose.runtime.produceState(emptyList<Double>(), key, revision) {
        value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            if (key == "ageless") runCatching { com.noop.core.CoreAgeLess.snapshot(context)?.weeks?.map { it.age } }.getOrNull().orEmpty()
            else {
                val (k, src) = when (key) { "vo2max" -> "vo2max_est" to "my-whoop"; "weight" -> "weight" to "noop-weight"
                                            "stress" -> "stress" to "my-whoop"; else -> "steps" to "my-whoop" }
                val today = LocalDate.now()
                runCatching { viewModel.repo.resolvedSeries(k, src, today.minusDays(60).toString(), today.toString(), viewModel.activeStrapId).points.map { it.value } }
                    .getOrDefault(emptyList())
            }
        }
    }
    val last = values.lastOrNull()
    val text = last?.let { v -> when (key) {
        "stress" -> stringResource(when { v < 1.0 -> R.string.forge_vt_low; v < 2.0 -> R.string.forge_vt_medium; else -> R.string.forge_vt_high })
        "steps" -> java.text.NumberFormat.getIntegerInstance().format(Math.round(v))
        "ageless" -> Math.round(v).toString()
        else -> "%.1f".format(java.util.Locale.getDefault(), v)
    } }
    val unit = when (key) { "weight" -> "kg"; "ageless" -> stringResource(R.string.forge_vt_years); else -> null }
    val tint = when (key) { "vo2max" -> colors.charge; "weight" -> colors.rest; "stress" -> colors.effort; "ageless" -> colors.accent; else -> colors.charge }
    MetricTile(Icons.Rounded.MonitorHeart, tint, measureTitle(key), text, unit, stringResource(R.string.forge_no_data),
               modifier.clickable(role = Role.Button, onClick = onClick),
               below = values.takeIf { it.size > 1 }?.let { v -> @Composable { KeyTileSpark(v.takeLast(60), tint) } })
}

@Composable
private fun MoveButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.padding(2.dp).size(26.dp).background(Forge.colors.textSecondary, CircleShape).clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = Forge.colors.surface, modifier = Modifier.size(14.dp))
    }
}

/** The tiles to add or to swap [replacing] for, as iOS's picker: Vitals, then Measures; placed ones are ticked. */
@Composable
private fun VitalTilePicker(replacing: String?, placed: List<String>, vitals: List<Vital>, onPick: (String) -> Unit, onDismiss: () -> Unit) {
    val colors = Forge.colors
    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
        Column(Modifier.background(colors.surface, androidx.compose.foundation.shape.RoundedCornerShape(20.dp)).padding(20.dp)
                   .verticalScroll(rememberScrollState())) {
            Text(replacing?.let { r -> stringResource(R.string.forge_vt_swap, vitals.firstOrNull { it.key == r }?.label ?: measureTitle(r)) }
                     ?: stringResource(R.string.forge_hv_add), style = Forge.type.headline, color = colors.text)
            listOf(R.string.forge_vt_vitals to VitalTilePrefs.vitalKeys.filter { k -> vitals.any { it.key == k } },
                   R.string.forge_vt_measures to VitalTilePrefs.measureKeys.filter { it != "ageless" || MoreDest.AgeLess.shown(LocalContext.current) })
                .forEach { (header, keys) ->
                    Text(stringResource(header).uppercase(), style = Forge.type.overline, color = colors.textSecondary,
                         modifier = Modifier.padding(top = ForgeMetrics.space4, bottom = ForgeMetrics.space2))
                    keys.forEach { k ->
                        val isPlaced = k in placed
                        Row(Modifier.fillMaxWidth().clickable(enabled = !isPlaced, role = Role.Button) { onPick(k) }.padding(vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            Text(vitals.firstOrNull { it.key == k }?.label ?: measureTitle(k), style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold),
                                 color = colors.text, modifier = Modifier.weight(1f))
                            Icon(if (isPlaced) Icons.Rounded.CheckCircle else Icons.Rounded.AddCircle, contentDescription = null,
                                 tint = if (isPlaced) colors.textTertiary else colors.accent)
                        }
                    }
                }
            Text(stringResource(R.string.forge_hv_done), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.accent,
                 modifier = Modifier.align(Alignment.End).clickable(role = Role.Button, onClick = onDismiss).padding(top = ForgeMetrics.space3))
        }
    }
}

/** "Edit Vitals" with Done and the tiles per row, as iOS's editing header. */
@Composable
private fun VitalsEditHeader(columns: Int, onColumns: (Int) -> Unit, onDone: () -> Unit) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.forge_hv_edit_vitals), style = Forge.type.headline, color = colors.text, modifier = Modifier.weight(1f))
            Text(stringResource(R.string.forge_hv_done), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = androidx.compose.ui.graphics.Color.White,
                 modifier = Modifier.background(colors.accent, CircleShape).clickable(role = Role.Button, onClick = onDone)
                     .padding(horizontal = 16.dp, vertical = 8.dp))
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        Text(stringResource(R.string.forge_hv_per_row), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
        Spacer(Modifier.height(ForgeMetrics.space1))
        Row(Modifier.fillMaxWidth().background(colors.inset, androidx.compose.foundation.shape.RoundedCornerShape(9.dp)).padding(2.dp)) {
            listOf(2, 3).forEach { n ->
                Text(n.toString(), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = colors.text,
                     textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                     modifier = Modifier.weight(1f).background(if (n == columns) colors.surface else androidx.compose.ui.graphics.Color.Transparent,
                                                               androidx.compose.foundation.shape.RoundedCornerShape(7.dp))
                         .clickable(role = Role.Tab) { onColumns(n) }.padding(vertical = 6.dp))
            }
        }
    }
}

/** The small cross in a tile's corner while editing. */
@Composable
private fun RemoveBadge(modifier: Modifier, onClick: () -> Unit) {
    Box(modifier.padding(4.dp).size(26.dp).background(Forge.colors.textSecondary, CircleShape)
            .clickable(role = Role.Button, onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(Icons.Rounded.Close, stringResource(R.string.forge_hv_remove), tint = Forge.colors.surface, modifier = Modifier.size(14.dp))
    }
}
