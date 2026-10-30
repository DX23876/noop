package com.noop.ui.forge

import android.text.format.DateFormat
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Air
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.DirectionsWalk
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.WaterDrop
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.R
import kotlinx.coroutines.launch
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.rememberCoroutineScope
import com.noop.core.CoreGoals
import com.noop.core.CoreRead
import com.noop.ui.AppViewModel
import com.noop.ui.TodayLayoutPrefs
import com.noop.ui.TodaySection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

/** Date patterns: CLDR skeletons and symbols, not text. */
private const val WEEKDAY_PATTERN = "EEEE"
/** The disclosure mark after a score label; a symbol, not text. */
private const val CHEVRON = " ›"
internal const val DAY_MONTH_SKELETON = "EEEdMMM"

/** One day's values as the Today screen shows them; [CoreRead.Day] or nothing. */
data class TodayModel(val date: LocalDate, val day: CoreRead.Day?, val baselines: Map<CoreRead.Metric, Double> = emptyMap())

/** The metrics whose tile shows a change against the week before: the scores and vitals iOS compares to normal. */
internal val baselineMetrics = listOf(CoreRead.Metric.Charge, CoreRead.Metric.Rest, CoreRead.Metric.Hrv,
                                      CoreRead.Metric.RestingHr, CoreRead.Metric.RespRate)

/** A tile's change against its baseline: "±0" inside the rounding step, else an arrow and the signed change. */
fun deltaText(value: Double?, baseline: Double?, decimals: Int): String? {
    if (value == null || baseline == null) return null
    val step = if (decimals == 0) 0.5 else 0.05
    val d = value - baseline
    if (kotlin.math.abs(d) < step) return "±0"
    val number = if (decimals == 0) d.roundToInt().toString() else "%.${decimals}f".format(d)
    return if (d > 0) "↗ +$number" else "↘ $number"
}

/**
 * Fork (DX23876), Android plan E-3: Today on the shared core. The hero card with Charge, Effort and Rest as
 * glowing rings, then the key metrics. Values come from [CoreRead]; a value the store does not have says so.
 */
@Composable
fun ForgeTodayScreen(padding: PaddingValues, width: ForgeWidth, viewModel: AppViewModel) {
    val context = LocalContext.current
    var date by rememberSaveable { mutableStateOf(LocalDate.now().toEpochDay()) }
    var model by remember { mutableStateOf<TodayModel?>(null) }
    LaunchedEffect(date) {
        val d = LocalDate.ofEpochDay(date)
        model = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val from = d.minusDays(7).toString(); val to = d.minusDays(1).toString()
            val baselines = baselineMetrics.mapNotNull { m ->
                CoreRead.series(m, from, to).map { it.value }.takeIf { it.isNotEmpty() }?.let { m to it.average() }
            }.toMap()
            TodayModel(d, CoreRead.day(d.toString()), baselines)
        }
    }
    val today = LocalDate.now()
    val shown = LocalDate.ofEpochDay(date)
    var customizing by remember { mutableStateOf<TodayCustomizationDestination?>(null) }
    var layoutRevision by remember { mutableIntStateOf(0) }
    val sections = remember(layoutRevision) {
        TodayLayoutDefaults.visibleSections(TodayLayoutPrefs.orderRaw(context), TodayLayoutPrefs.hiddenRaw(context))
    }
    var quickActions by remember { mutableStateOf(false) }
    var settingsOpen by remember { mutableStateOf(false) }
    var startWorkout by remember { mutableStateOf(false) }
    var liveWorkout by remember { mutableStateOf(false) }
    var liveSession by remember { mutableStateOf(false) }
    var arranging by remember { mutableStateOf<String?>(null) }
    var updatesOpen by remember { mutableStateOf(false) }
    var dayPicker by remember { mutableStateOf(false) }
    val more = rememberMoreNavigator()
    val selectTab = LocalForgeTabSelect.current
    if (quickActions) {
        ForgeQuickActionSheet(viewModel, onDismiss = { quickActions = false }) { action ->
            quickActions = false
            when (action) {
                QuickAction.Battery -> selectTab(ForgeTab.More)
                QuickAction.Live -> more.push(MoreRoute.Dest(MoreDest.Live))
                QuickAction.Workout -> startWorkout = true
                QuickAction.Journal -> more.push(MoreRoute.Dest(MoreDest.Journal))
                QuickAction.Breathe -> more.push(MoreRoute.Dest(MoreDest.Breathe))
                QuickAction.Goals -> more.push(MoreRoute.Dest(MoreDest.Goals))
                QuickAction.LiveSession -> liveSession = true
                QuickAction.CustomizeToday -> customizing = TodayCustomizationDestination.Today
            }
        }
    }
    if (liveSession) ForgeLiveSessionCover(viewModel, onClose = { liveSession = false })
    MoreOverlay(more, viewModel, onOpenSettings = { settingsOpen = true })
    if (settingsOpen) {
        ForgeOverlayPage(onDismiss = { settingsOpen = false }) { ForgeSettings(viewModel, onClose = { settingsOpen = false }) }
    }
    // The workout picker, then the live workout once one runs, as the Training tab opens them.
    if (startWorkout) {
        com.noop.ui.StartWorkoutSheet(vm = viewModel, onDismiss = {
            startWorkout = false
            if (viewModel.activeWorkout.value != null) liveWorkout = true
        })
    }
    if (liveWorkout) {
        androidx.compose.ui.window.Dialog(onDismissRequest = { liveWorkout = false },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
            com.noop.ui.LiveWorkoutScreen(vm = viewModel, onClose = { liveWorkout = false })
        }
    }
    if (dayPicker) ForgeDayPicker(shown, onPick = { date = it.toEpochDay() }, onDismiss = { dayPicker = false })
    if (updatesOpen) {
        ForgeOverlayPage(onDismiss = { updatesOpen = false }) {
            com.noop.ui.UpdatesInboxScreen(store = com.noop.ui.UpdateStore.from(context), onClose = { updatesOpen = false },
                                           onDeepLink = { updatesOpen = false }, onRestore = {})
        }
    }
    arranging?.let { dashboard ->
        ForgeOverlayPage(onDismiss = { arranging = null }) { ForgeDashboardArrange(dashboard) { saved -> arranging = null; if (saved) layoutRevision++ } }
    }
    customizing?.let { destination ->
        ForgeOverlayPage(onDismiss = { customizing = null }) {
            ForgeTodayCustomization(destination) { saved -> customizing = null; if (saved) layoutRevision++ }
        }
    }
    val drawSection: @Composable (TodaySection) -> Unit = { section ->
            when (section) {
                TodaySection.HERO -> Hero(model?.day, width)
                TodaySection.SYNTHESIS -> if (shown == today) {
                    // The status pills sit above the Momentum card, as in `LiquidTodayView.synthesisSection`.
                    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                        var breakdown by remember { mutableStateOf(false) }
                        TodayStatusPills(onReadiness = { breakdown = true })
                        ForgeTodayMomentum(viewModel)
                        if (breakdown) ChargeBreakdownHost(viewModel, onDismiss = { breakdown = false })
                    }
                }
                TodaySection.GOALS -> if (shown == today) TodayGoals()
                TodaySection.COACH -> if (shown == today) ForgeTodayCoach(viewModel)
                TodaySection.HEART_RATE -> HeartCard(viewModel, shown, live = shown == today)
                TodaySection.KEY_METRICS -> ForgeKeyMetrics(model, revision = layoutRevision,
                                                            onEdit = { customizing = TodayCustomizationDestination.KeyMetrics })
                TodaySection.ENERGY -> if (shown == today) TodayEnergy()
                // The sections ryanbr's Today drew and Forge Today had dropped (E-3f), as `LiquidTodayView` shows them.
                TodaySection.TRAINING_LOAD -> if (shown == today) TodayTrainingLoadForge { more.push(MoreRoute.Dest(MoreDest.TrainingLoad)) }
                TodaySection.WORKOUTS -> TodayWorkoutsForge(viewModel)
                TodaySection.RECOVERY_VITALS -> TodayRecoveryVitalsForge(viewModel) { more.push(MoreRoute.Dest(MoreDest.Health)) }
                TodaySection.YOUR_CARDS -> if (shown == today) TodayYourCardsForge(viewModel,
                    onOpenMetric = { more.push(MoreRoute.Dest(MoreDest.Health)) }, onOpenSleep = { selectTab(ForgeTab.Sleep) },
                    onOpenStress = { more.push(MoreRoute.Dest(MoreDest.Stress)) },
                    onOpenHydration = { more.push(MoreRoute.Dest(MoreDest.Journal)) },
                    onOpenCoach = { more.push(MoreRoute.Dest(MoreDest.Coach)) },
                    onCustomise = { customizing = TodayCustomizationDestination.Today })
                TodaySection.MENSTRUAL_CYCLE -> if (shown == today) TodayCycleForge(viewModel)
                TodaySection.JOURNAL -> if (shown == today) TodayJournalForge(viewModel) { more.push(MoreRoute.Dest(MoreDest.Journal)) }
                TodaySection.ADDED_CARDS -> if (shown == today) TodayAddedCardsForge(viewModel,
                    onOpenMetric = { more.push(MoreRoute.Dest(MoreDest.Health)) }, onOpenSleep = { selectTab(ForgeTab.Sleep) },
                    onOpenStress = { more.push(MoreRoute.Dest(MoreDest.Stress)) })
                // As on iOS: the guided session starts from the quick actions, Data Sources lives in Settings.
                TodaySection.LIVE_SESSION, TodaySection.DATA_SOURCES -> Unit
            }
    }
    val previousLabel = stringResource(R.string.forge_previous_day)
    val nextLabel = stringResource(R.string.forge_next_day)
    var drag by remember { mutableStateOf(0f) }
    Column(
        Modifier.fillMaxSize()
            // Swipe sideways for another day, as on iOS; screen readers get the same as two actions.
            .pointerInput(Unit) {
                detectHorizontalDragGestures(
                    onDragStart = { drag = 0f },
                    onDragEnd = {
                        if (drag > 120f) date -= 1
                        else if (drag < -120f && date < LocalDate.now().toEpochDay()) date += 1
                    },
                    onHorizontalDrag = { _, amount -> drag += amount },
                )
            }
            .semantics {
                customActions = listOf(
                    CustomAccessibilityAction(previousLabel) { date -= 1; true },
                    CustomAccessibilityAction(nextLabel) {
                        if (date < LocalDate.now().toEpochDay()) { date += 1; true } else false
                    },
                )
            }
            .verticalScroll(rememberScrollState()).padding(padding)
            .padding(horizontal = ForgeMetrics.screenPadding),
        verticalArrangement = Arrangement.spacedBy(ForgeMetrics.sectionGap),
    ) {
        val style = remember(layoutRevision) { DashboardStylePrefs.style(context) }
        if (style != "liquid") {
            // The Trends and Overview styles (Settings › Dashboard) draw their own header and blocks.
            val live by viewModel.live.collectAsState()
            val updateStore = remember { com.noop.ui.UpdateStore.from(context) }
            val coachOn = com.noop.ui.NoopPrefs.coachEnabled(context) && com.noop.ui.CoachTodayPrefs.shown(context)
            DashboardHeader(shown, isToday = shown == today,
                            battery = live.batteryPct?.let { stringResource(R.string.forge_percent, kotlin.math.round(it).toInt()) },
                            unread = updateStore.unreadCount, onBattery = { selectTab(ForgeTab.More) },
                            onQuickActions = { quickActions = true }, onUpdates = { updatesOpen = true },
                            onCoach = if (coachOn) ({ more.push(MoreRoute.Dest(MoreDest.Coach)) }) else null,
                            onArrange = { arranging = style }, onPickDay = { dayPicker = true })
            if (shown == today) ForgeMorningSuggestion()
            ForgeStyledDashboard(style, layoutRevision, shown, model?.day, viewModel,
                onSection = { drawSection(it) },
                onHealth = { more.push(MoreRoute.Dest(MoreDest.Health)) },
                onSleep = { selectTab(ForgeTab.Sleep) },
                onStress = { more.push(MoreRoute.Dest(MoreDest.Stress)) },
                onCoach = { more.push(MoreRoute.Dest(MoreDest.Coach)) },
                onActivity = { more.push(MoreRoute.Dest(MoreDest.Workouts)) })
        } else {
        Header(shown, isToday = shown == today, onProfile = { settingsOpen = true }, onQuickActions = { quickActions = true })
        // Pinned above the arranged sections, as on iOS (`MorningSuggestionCard` before the `ForEach`).
        if (shown == today) ForgeMorningSuggestion()
        // Every drawn section in the saved order (`TodayLayoutDefaults`); a hidden one keeps its stored place.
        sections.forEach { drawSection(it) }
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
    }
}

@Composable
private fun Header(date: LocalDate, isToday: Boolean, onProfile: () -> Unit, onQuickActions: () -> Unit) {
    val colors = Forge.colors
    val locale = Locale.getDefault()
    // The iOS header row: the title and its date on the left, the wordmark centred on the same line. Over a dark
    // scene a soft shadow keeps the light ink readable where it crosses the moon or a bright cloud.
    val sceneShadow = if (Forge.sceneInk.dark) Shadow(Color.Black.copy(alpha = 0.55f), Offset(0f, 1f), 8f) else null
    Box(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space8)) {
        Column(Modifier.fillMaxWidth(0.34f)) {
            Text(
                if (isToday) stringResource(R.string.nav_today)
                else date.format(DateTimeFormatter.ofPattern(WEEKDAY_PATTERN, locale)).replaceFirstChar { it.titlecase(locale) },
                style = Forge.type.title2.copy(fontWeight = FontWeight.Bold, shadow = sceneShadow), color = Forge.sceneInk.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(date.format(DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, DAY_MONTH_SKELETON), locale)),
                 style = Forge.type.subhead.copy(shadow = sceneShadow), color = Forge.sceneInk.secondary, maxLines = 1)
        }
        ForgeWordmark(Modifier.align(Alignment.TopCenter).padding(top = ForgeMetrics.space2))
        // Profile and quick actions trailing, as on iOS.
        TodayHeaderButtons(onProfile, onQuickActions, Modifier.align(Alignment.TopEnd))
    }
}

@Composable
private fun Hero(day: CoreRead.Day?, width: ForgeWidth) {
    val colors = Forge.colors
    // Each ring opens its trend, as iOS's `HeroScoreCell` pushes its `detailRoute`.
    var open by remember { mutableStateOf<CoreRead.Metric?>(null) }
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.heroRadius, glass = true, contentPadding = 0.dp) {
        Box(Modifier.fillMaxWidth()) {
            BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = HeroRingLayout.horizontalPadding,
                                                               vertical = HeroRingLayout.verticalPadding)) {
                val diameter = HeroRingLayout.diameter(maxWidth)
                Row(Modifier.fillMaxWidth()) {
                    ScoreSlot(R.string.forge_charge, day?.charge, day?.charge?.let { colors.chargeRing(it) } ?: colors.charge,
                              diameter, OrganicMetric.Charge, Modifier.weight(1f)) { open = CoreRead.Metric.Charge }
                    ScoreSlot(R.string.forge_effort, day?.effort, colors.effort, diameter, OrganicMetric.Effort, Modifier.weight(1f),
                          format = rememberEffortFormat()) { open = CoreRead.Metric.Effort }
                    ScoreSlot(R.string.forge_rest, day?.rest, colors.rest, diameter, OrganicMetric.Rest, Modifier.weight(1f)) { open = CoreRead.Metric.Rest }
                }
            }
            // The hero's provenance, a quiet caption in its top corner as on iOS: who supplied the inputs, from the
            // core's resolver (`ScoreProvenance`). Each ring already speaks its value, so screen readers skip it.
            heroSourceLabel(day?.heroSource.orEmpty())?.let { label ->
                Text(label.uppercase(), style = Forge.type.overline, color = colors.textTertiary, maxLines = 1,
                     modifier = Modifier.align(Alignment.TopEnd)
                         .padding(top = ForgeMetrics.space2, end = ForgeMetrics.space4)
                         .clearAndSetSemantics {})
            }
        }
    }
    ForgeMetricDetail(open) { open = null }
}

/** The hero's source caption: the names joined with " + ", the translated words resolved; null without any. */
@Composable
internal fun heroSourceLabel(tokens: List<String>): String? {
    if (tokens.isEmpty()) return null
    return tokens.map { token ->
        when (token) {
            "#workoutFiles" -> stringResource(R.string.forge_source_workout_files)
            "#nutrition" -> stringResource(R.string.forge_source_nutrition)
            "#cached" -> stringResource(R.string.forge_source_cached)
            else -> token
        }
    }.joinToString(" + ")
}

@Composable
private fun ScoreSlot(labelRes: Int, score: Double?, tint: Color, diameter: androidx.compose.ui.unit.Dp,
                      metric: OrganicMetric, modifier: Modifier = Modifier, format: (Double) -> String = WHOLE_NUMBER,
                      onOpen: () -> Unit) {
    val label = stringResource(labelRes)
    val spoken = if (score == null) stringResource(R.string.forge_score_missing, label, stringResource(R.string.forge_no_data))
                 else stringResource(R.string.forge_score_spoken, label, score.roundToInt())
    Column(horizontalAlignment = Alignment.CenterHorizontally,
           modifier = modifier.clickable(role = Role.Button, onClick = onOpen)
               .semantics(mergeDescendants = true) { contentDescription = spoken }) {
        // The drawn ring may be a little wider than its slot; its glow overlaps the neighbour's, as on iOS.
        Box(Modifier.fillMaxWidth().height(diameter), contentAlignment = Alignment.Center) {
            OrganicRing(score, tint, diameter, metric, Modifier.requiredSize(diameter), format)
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Text(label.uppercase() + CHEVRON, style = Forge.type.overline, color = Forge.colors.textSecondary, maxLines = 1,
             overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
    }
}

/**
 * The heart rate card, as the iOS Today shows it: live with the last two minutes as a trace while the strap
 * streams (today only), otherwise the day's banked five-minute trace from the core with its latest value. The live
 * rate is collected here, so the once-a-second updates redraw this card and not the whole screen. Hidden when the
 * day has neither.
 */
@Composable
private fun HeartCard(viewModel: AppViewModel, date: LocalDate, live: Boolean) {
    val colors = Forge.colors
    val context = LocalContext.current
    val bpm by viewModel.bpm.collectAsState()
    val liveTrace = remember { mutableStateListOf<Int>() }
    LaunchedEffect(viewModel) {
        viewModel.bpm.collect { value ->
            if (value == null) liveTrace.clear() else { liveTrace.add(value); if (liveTrace.size > 120) liveTrace.removeAt(0) }
        }
    }
    var day by remember(date) { mutableStateOf<List<CoreRead.HeartPoint>>(emptyList()) }
    LaunchedEffect(date) {
        val zone = java.time.ZoneId.systemDefault()
        val from = date.atStartOfDay(zone).toEpochSecond()
        day = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreRead.heartRate(from, from + 86_400 - 1)
        }
    }
    val streaming = live && bpm != null
    val latest = day.lastOrNull()
    if (!streaming && latest == null) return
    val clockFormat = rememberClockFormatter()
    val at = latest?.let {
        java.time.Instant.ofEpochSecond(it.ts).atZone(java.time.ZoneId.systemDefault()).format(clockFormat)
    }
    val value = if (streaming) bpm!! else latest!!.bpm.roundToInt()
    val spoken = if (streaming) stringResource(R.string.forge_live_hr_spoken, value)
                 else stringResource(R.string.forge_hr_spoken_at, value, at ?: "")
    val points: List<Float> = if (streaming) liveTrace.map { it.toFloat() } else day.map { it.bpm.toFloat() }
    // The whole day opens over the tabs, live or not: the card's trace is only the last two minutes while live.
    var open by remember { mutableStateOf(false) }
    if (open) {
        ForgeOverlayPage(onDismiss = { open = false }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) { ForgeDayHeartRatePage(date, onBack = { open = false }) }
        }
    }
    ForgeCard(Modifier.fillMaxWidth().clickable { open = true }.semantics(mergeDescendants = true) { contentDescription = spoken }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.Favorite, contentDescription = null, tint = colors.heart, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(stringResource(R.string.forge_heart_rate).uppercase(), style = Forge.type.overline,
                 color = colors.textSecondary, modifier = Modifier.weight(1f))
            Text(if (streaming) stringResource(R.string.forge_live).uppercase()
                 else stringResource(R.string.forge_hr_at, at ?: ""),
                 style = Forge.type.overline, color = if (streaming) colors.heart else colors.textTertiary)
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value.toString(), style = Forge.type.title1.copy(fontSize = Forge.type.heroNumber.fontSize),
                 color = colors.text)
            Spacer(Modifier.width(ForgeMetrics.space1))
            Text(stringResource(R.string.forge_unit_bpm), style = Forge.type.subhead, color = colors.textSecondary,
                 modifier = Modifier.padding(bottom = 6.dp))
            Spacer(Modifier.width(ForgeMetrics.space4))
            Canvas(Modifier.weight(1f).height(44.dp)) {
                if (points.size < 2) return@Canvas
                val lo = points.min() - 3f; val hi = points.max() + 3f
                // Live: two minutes fill the width from the right. A day: its own span fills it.
                val slots = if (streaming) 120 else points.size
                val step = size.width / (slots - 1)
                val start = size.width - step * (points.size - 1)
                val path = Path()
                points.forEachIndexed { i, v ->
                    val x = start + i * step
                    val y = size.height - (v - lo) / (hi - lo) * size.height
                    if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
                }
                drawPath(path, colors.heart, style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round))
            }
        }
    }
}

/**
 * The hero's ring sizing, as `LiquidHeroRingLayout` on iOS: each ring owns a third of the row and is drawn 8 %
 * larger than its slot, between 100 and 150 dp, inside 8 dp of side padding and 24 dp above and below.
 */
object HeroRingLayout {
    val horizontalPadding = 8.dp
    val verticalPadding = 24.dp
    private const val OVERDRAW = 1.08f
    private val minDiameter = 100.dp
    private val maxDiameter = 150.dp

    fun diameter(rowWidth: androidx.compose.ui.unit.Dp): androidx.compose.ui.unit.Dp =
        (rowWidth / 3 * OVERDRAW).coerceIn(minDiameter, maxDiameter)
}

/** The Energy card after `EnergyCard`: today's total so far, resting, active and projected; tap opens the detail. */
@Composable
internal fun TodayEnergy() {
    val context = LocalContext.current
    var summary by remember { mutableStateOf<com.noop.core.CoreEnergyDetail.Summary?>(null) }
    var open by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        summary = withContext(Dispatchers.IO) {
            CoreRead.open(context); com.noop.core.CoreEnergyDetail.today(context, dismissedTrainingWorkouts(context))
        }
    }
    val s = summary ?: return
    val whole = java.text.NumberFormat.getIntegerInstance(Locale.getDefault())
    fun kcal(v: Double?) = v?.let { whole.format(kotlin.math.round(it).toLong()) } ?: "—"
    ForgeCard(Modifier.fillMaxWidth().clickable { open = true }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.forge_ed_title).uppercase(), style = Forge.type.overline, color = Forge.colors.textSecondary,
                 modifier = Modifier.weight(1f))
            Text(stringResource(when (s.confidence) {
                "solid" -> R.string.forge_et_measured
                "building" -> R.string.forge_et_partly
                else -> R.string.forge_et_estimated
            }), style = Forge.type.footnote, color = Forge.colors.textSecondary)
        }
        if (s.total != null) {
            Text(stringResource(R.string.forge_ed_kcal, kcal(s.total)), style = Forge.type.title1, color = Forge.colors.text)
            Text(stringResource(R.string.forge_ed_so_far), style = Forge.type.caption, color = Forge.colors.textSecondary)
        }
        Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space2)) {
            listOf(
                stringResource(if (s.basal == null) R.string.forge_ed_basal_day else R.string.forge_et_resting) to kcal(s.basal ?: s.bmr24h),
                stringResource(R.string.forge_ed_active) to kcal(s.active),
                stringResource(R.string.forge_et_projected) to kcal(s.projected),
            ).forEach { (label, value) ->
                Column(Modifier.weight(1f)) {
                    Text(label, style = Forge.type.caption, color = Forge.colors.textSecondary)
                    Text(value, style = Forge.type.headline, color = Forge.colors.text)
                }
            }
        }
    }
    if (open) {
        ForgeOverlayPage(onDismiss = { open = false }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) { ForgeEnergyDetailPage(onBack = { open = false }) }
        }
    }
}

/** Today's goals card, read from the shared core; it opens the goals page over the tabs. */
@Composable
internal fun TodayGoals() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var output by remember { mutableStateOf<CoreGoals.Output?>(null) }
    var revision by remember { mutableIntStateOf(0) }
    var open by remember { mutableStateOf(false) }
    LaunchedEffect(revision) {
        output = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreGoals.snapshot(context, dismissedTrainingWorkouts(context))
        }
    }
    PublishGoalsWidget(output)
    // No goal yet: the invitation, as `GoalsTodaySection` shows `GoalsInviteCard`.
    output?.let { if (!it.hasAnyGoal()) ForgeGoalsInvite(onCreated = { revision++ }, onOtherGoals = { open = true }) }
    ForgeTodayGoalsCard(output, onOpen = { open = true }, onToggle = { action ->
        scope.launch {
            withContext(Dispatchers.IO) { CoreGoals.toggleAction(action.actionId, action.day) }
            revision++
        }
    })
    if (open) {
        ForgeOverlayPage(onDismiss = { open = false; revision++ }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) { ForgeGoalsPage(onBack = { open = false; revision++ }) }
        }
    }
}

/** The day's heart rate in five-minute means from midnight to midnight, with its average, lowest and highest. */
@Composable
internal fun ForgeDayHeartRatePage(date: LocalDate, onBack: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    var points by remember(date) { mutableStateOf<List<CoreRead.HeartPoint>?>(null) }
    val zone = java.time.ZoneId.systemDefault()
    val from = date.atStartOfDay(zone).toEpochSecond()
    LaunchedEffect(date) {
        // Refreshed every five minutes, so a day still in progress keeps growing while the page is open.
        while (true) {
            points = withContext(Dispatchers.IO) { CoreRead.open(context); CoreRead.heartRate(from, from + 86_400 - 1) }
            kotlinx.coroutines.delay(300_000)
        }
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_heart_rate), onBack)
        val p = points ?: return@SettingsColumn
        if (p.isEmpty()) {
            Text(stringResource(R.string.forge_no_data), style = Forge.type.body, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth()) {
                listOf(R.string.forge_hr_avg to p.map { it.bpm }.average(), R.string.forge_hr_low to p.minOf { it.bpm },
                       R.string.forge_hr_high to p.maxOf { it.bpm }).forEach { (label, v) ->
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(label), style = Forge.type.caption, color = colors.textSecondary)
                        Row(verticalAlignment = Alignment.Bottom) {
                            Text(v.roundToInt().toString(), style = Forge.type.title2, color = colors.text)
                            Spacer(Modifier.width(ForgeMetrics.space1))
                            Text(stringResource(R.string.forge_unit_bpm), style = Forge.type.caption, color = colors.textTertiary,
                                 modifier = Modifier.padding(bottom = 3.dp))
                        }
                    }
                }
            }
            Spacer(Modifier.height(ForgeMetrics.space3))
            val grid = colors.divider
            Canvas(Modifier.fillMaxWidth().height(200.dp)) {
                val lo = p.minOf { it.bpm } - 5; val hi = p.maxOf { it.bpm } + 5
                for (h in listOf(6, 12, 18)) {
                    val x = size.width * h / 24f
                    drawLine(grid, androidx.compose.ui.geometry.Offset(x, 0f), androidx.compose.ui.geometry.Offset(x, size.height))
                }
                val path = Path()
                var last: Long? = null
                p.forEach { pt ->
                    val x = ((pt.ts - from).toFloat() / 86_400f) * size.width
                    val y = (size.height - (pt.bpm - lo) / (hi - lo) * size.height).toFloat()
                    // A gap of more than fifteen minutes (strap off) breaks the line rather than bridging it.
                    if (last == null || pt.ts - last!! > 900) path.moveTo(x, y) else path.lineTo(x, y)
                    last = pt.ts
                }
                drawPath(path, colors.heart, style = Stroke(width = 1.5.dp.toPx(), cap = StrokeCap.Round))
            }
            Row(Modifier.fillMaxWidth()) {
                val clock = rememberClockFormatter()
                listOf(0, 6, 12, 18).forEach { h ->
                    Text(java.time.LocalTime.of(h, 0).format(clock), style = Forge.type.caption, color = colors.textTertiary,
                         modifier = Modifier.weight(1f))
                }
            }
        }
    }
}
