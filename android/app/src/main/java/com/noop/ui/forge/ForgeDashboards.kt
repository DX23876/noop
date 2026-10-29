package com.noop.ui.forge

import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.BatteryFull
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.CheckCircleOutline
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.DirectionsWalk
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Schedule
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.noop.core.CoreBody
import com.noop.core.CoreEnergyDetail
import com.noop.core.CorePrefs
import com.noop.ui.TodaySection
import com.noop.ui.EffortScale
import com.noop.ui.UnitPrefs
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.noop.R
import com.noop.analytics.Baselines
import com.noop.analytics.VitalBands
import com.noop.core.CoreRead
import com.noop.ui.AppViewModel
import com.noop.ui.DashboardCard
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.roundToInt

/*
 * Fork (DX23876), Android parity: the two other Today styles iOS offers under Settings › Dashboard
 * (`TodayDashboardStyle.trends` / `.overview`, `TrendsDashboardView`, `OverviewDashboardView`). Their own blocks are
 * drawn here; the opt-in extras reuse the Liquid Today sections, as the iOS dashboards reuse theirs.
 */

private const val WORDMARK = "N O O P"
private const val LONG_DAY_PATTERN = "EEEE, d. MMMM"
private const val SHORT_DAY_PATTERN = "d MMM"
private const val DASH = "—"

/** iOS `TodayDashboardStyle` under its key; Android draws Liquid, Trends and Overview. */
internal object DashboardStylePrefs {
    const val KEY = "noop.todayDashboardStyle"
    val STYLES = listOf("classic", "liquid", "trends", "overview")
    fun style(c: Context): String = NoopPrefs.of(c).getString(KEY, "liquid")?.takeIf { it in STYLES } ?: "liquid"
    fun set(c: Context, style: String) = NoopPrefs.of(c).edit().putString(KEY, style).apply()
}

/** iOS `DashboardLayoutSection`: each dashboard's blocks, then the opt-in extras, which start hidden. */
internal enum class DashboardSection(val raw: String, val extra: Boolean, val titleRes: Int) {
    COACH("coach", false, R.string.forge_db_coach), HERO("hero", false, R.string.forge_db_hero),
    TRENDS_CHART("trendsChart", false, R.string.forge_db_trends), METRIC_STRIP("metricStrip", false, R.string.forge_db_metrics),
    ACTIVITY("activity", false, R.string.forge_db_activity), OVERVIEW("overview", false, R.string.forge_db_glance),
    FOCUS("focus", false, R.string.forge_db_focus), HEALTH("health", false, R.string.forge_db_health),
    LIVE_SESSION("liveSession", true, R.string.forge_db_live), MOMENTUM("momentum", false, R.string.forge_db_momentum),
    GOALS("goals", false, R.string.forge_db_goals), KEY_METRICS("keyMetrics", true, R.string.forge_db_more_metrics),
    ENERGY_DETAIL("energyDetail", true, R.string.forge_db_energy), WORKOUTS_LIST("workoutsList", true, R.string.forge_db_workouts),
    HEART_RATE("heartRate", true, R.string.forge_db_heart), RECOVERY_VITALS("recoveryVitals", true, R.string.forge_db_vitals),
    YOUR_CARDS("yourCards", true, R.string.forge_db_cards), MENSTRUAL_CYCLE("menstrualCycle", true, R.string.forge_db_cycle),
    JOURNAL("journal", true, R.string.forge_db_journal), DATA_SOURCES("dataSources", true, R.string.forge_db_sources),
    ADDED_CARDS("addedCards", true, R.string.forge_db_added);

    companion object {
        private val EXTRAS = listOf(LIVE_SESSION, KEY_METRICS, ENERGY_DETAIL, WORKOUTS_LIST, HEART_RATE, RECOVERY_VITALS,
                                    YOUR_CARDS, MENSTRUAL_CYCLE, JOURNAL, DATA_SOURCES, ADDED_CARDS)
        fun defaultOrder(dashboard: String): List<DashboardSection> =
            if (dashboard == "trends") listOf(COACH, HERO, TRENDS_CHART, METRIC_STRIP, ACTIVITY, GOALS, MOMENTUM) + EXTRAS
            else listOf(COACH, OVERVIEW, FOCUS, GOALS, HEALTH, MOMENTUM) + EXTRAS
        fun of(raw: String) = entries.firstOrNull { it.raw == raw }
    }
}

/** iOS `DashboardLayoutPrefs`: the saved order and hidden set per dashboard, under the Apple keys. */
internal object DashboardLayoutPrefs {
    private const val NONE_HIDDEN = "__none__"
    fun orderKey(d: String) = "$d.dashboard.sectionOrder"
    fun hiddenKey(d: String) = "$d.dashboard.hiddenSections"
    fun order(raw: String?, dashboard: String): List<DashboardSection> {
        val defaults = DashboardSection.defaultOrder(dashboard)
        val decoded = raw.orEmpty().split(',').mapNotNull(DashboardSection::of).filter { it in defaults }.distinct()
        return decoded + defaults.filter { it !in decoded }
    }
    fun hidden(raw: String?, dashboard: String): Set<DashboardSection> = when {
        raw == NONE_HIDDEN -> emptySet()
        raw.isNullOrEmpty() -> DashboardSection.defaultOrder(dashboard).filter { it.extra }.toSet()
        else -> raw.split(',').mapNotNull(DashboardSection::of).toSet()
    }
    fun visible(c: Context, dashboard: String): List<DashboardSection> {
        val p = NoopPrefs.of(c)
        val hidden = hidden(p.getString(hiddenKey(dashboard), null), dashboard)
        return order(p.getString(orderKey(dashboard), null), dashboard).filter { it !in hidden }
    }
    fun save(c: Context, dashboard: String, order: List<DashboardSection>, hidden: Set<DashboardSection>) {
        NoopPrefs.of(c).edit().putString(orderKey(dashboard), order.joinToString(",") { it.raw })
            .putString(hiddenKey(dashboard), if (hidden.isEmpty()) NONE_HIDDEN else order.filter { it in hidden }.joinToString(",") { it.raw })
            .apply()
    }
}

/** iOS `TrendsMetricSlotsPrefs`: the metric strip's four cards, chosen in Settings › Dashboard only. */
internal object TrendsMetricSlots {
    val KEYS = listOf("trendsDashboard.slot1", "trendsDashboard.slot2", "trendsDashboard.slot3", "trendsDashboard.slot4")
    val DEFAULTS = listOf(DashboardCard.HRV, DashboardCard.RESTING_HR, DashboardCard.STEPS, DashboardCard.BLOOD_OXYGEN)
    fun slots(c: Context): List<DashboardCard> = KEYS.mapIndexed { i, k ->
        DashboardCard.entries.firstOrNull { it.raw == NoopPrefs.of(c).getString(k, null) } ?: DEFAULTS[i]
    }
}

/** iOS `OverviewFocusPrefs` and `OverviewHealthCardsPrefs`. */
internal object OverviewPrefs {
    val FOCUS_KEYS = listOf("overview.focus.slot1", "overview.focus.slot2", "overview.focus.slot3")
    val FOCUS_DEFAULTS = listOf("hrv", "restingHr", "steps")
    const val HEALTH_KEY = "overview.healthCards"
    val HEALTH_DEFAULTS = listOf(DashboardCard.RESTING_HR, DashboardCard.HRV, DashboardCard.RESPIRATORY,
                                 DashboardCard.FITNESS_AGE, DashboardCard.CALORIES, DashboardCard.WEIGHT)
    fun focus(c: Context) = FOCUS_KEYS.mapIndexed { i, k -> NoopPrefs.of(c).getString(k, null) ?: FOCUS_DEFAULTS[i] }
    fun health(c: Context): List<DashboardCard> {
        val raw = NoopPrefs.of(c).getString(HEALTH_KEY, null).orEmpty()
        val ids = raw.trim('[', ']').split(',').map { it.trim().trim('"') }
        val cards = ids.mapNotNull { id -> DashboardCard.entries.firstOrNull { it.raw == id } }.distinct()
        return cards.ifEmpty { HEALTH_DEFAULTS }
    }
}

/** The figures both dashboards read for the shown day. */
internal class DashboardDay(
    val day: CoreRead.Day?, val isToday: Boolean, val date: LocalDate,
    val weightKg: Double?, val caloriesKcal: Double?, val fitnessAge: Double?, val vo2max: Double?, val vitality: Double?,
)

/** The header both dashboards share: the spaced wordmark, quick actions and Settings, and the day under it. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun DashboardHeader(date: LocalDate, isToday: Boolean, battery: String?, unread: Int, onBattery: () -> Unit,
                             onQuickActions: () -> Unit, onUpdates: () -> Unit, onCoach: (() -> Unit)?, onArrange: () -> Unit) {
    val colors = Forge.colors
    val ink = Forge.sceneInk
    Column(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space6), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            // Long-pressing the wordmark arranges the sections, the dashboards' one shortcut (iOS `onLongPressGesture`).
            Text(WORDMARK, style = Forge.type.title2.copy(fontWeight = FontWeight.Bold), color = ink.text,
                 modifier = Modifier.combinedClickable(onClick = {}, onLongClick = onArrange))
            Spacer(Modifier.weight(1f))
            // The strap's battery, "+" for the quick actions, the updates bell and (while the coach is on) the coach.
            if (battery != null) {
                Row(Modifier.height(36.dp).background(colors.inset, CircleShape).clickable(onClick = onBattery)
                        .padding(horizontal = 10.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(Icons.Rounded.BatteryFull, null, tint = colors.text, modifier = Modifier.size(16.dp))
                    Text(battery, style = Forge.type.footnote, color = colors.text)
                }
                Spacer(Modifier.width(ForgeMetrics.space2))
            }
            HeaderIcon(Icons.Rounded.Add, stringResource(R.string.forge_db_quick_actions), onQuickActions)
            Spacer(Modifier.width(ForgeMetrics.space2))
            Box {
                HeaderIcon(if (unread > 0) Icons.Rounded.NotificationsActive else Icons.Rounded.Notifications,
                           stringResource(R.string.forge_db_updates), onUpdates)
                if (unread > 0) {
                    Box(Modifier.align(Alignment.TopEnd).size(16.dp).background(ForgeTokens.Color.systemRed.resolve(), CircleShape),
                        contentAlignment = Alignment.Center) {
                        Text(minOf(unread, 99).toString(), style = Forge.type.caption.copy(fontSize = 9.sp, fontWeight = FontWeight.Bold),
                             color = Color.White)
                    }
                }
            }
            if (onCoach != null) {
                Spacer(Modifier.width(ForgeMetrics.space2))
                HeaderIcon(Icons.Rounded.Person, stringResource(R.string.forge_db_coach), onCoach)
            }
        }
        val locale = Locale.getDefault()
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(if (isToday) stringResource(R.string.nav_today)
                 else date.format(DateTimeFormatter.ofPattern(LONG_DAY_PATTERN, locale)).replaceFirstChar { it.titlecase(locale) },
                 style = Forge.type.caption, color = ink.secondary)
            Text("·", style = Forge.type.caption, color = ink.secondary)
            Text(stringResource(R.string.forge_db_swipe), style = Forge.type.caption, color = ink.secondary)
            Icon(Icons.Rounded.CalendarMonth, null, tint = ink.secondary, modifier = Modifier.size(11.dp))
        }
    }
}

@Composable
private fun HeaderIcon(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(36.dp).background(Forge.colors.inset, CircleShape).clickable(onClick = onClick),
        contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = Forge.colors.text, modifier = Modifier.size(18.dp))
    }
}

// MARK: - Trends dashboard

/** Charge, Effort and Rest as three rings with their symbol and name (iOS `heroRings`). */
@Composable
internal fun DashboardHeroRings(day: CoreRead.Day?, effortFormat: (Double) -> String, onOpen: (CoreRead.Metric) -> Unit) {
    val colors = Forge.colors
    // On a card, as Liquid's hero is: bare numbers are unreadable over the sky photo.
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.heroRadius, glass = true) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
        HeroRing(stringResource(R.string.forge_charge).uppercase(), Icons.Rounded.Favorite, day?.charge, day?.charge?.roundToInt()?.toString(), colors.charge) { onOpen(CoreRead.Metric.Charge) }
        HeroRing(stringResource(R.string.forge_effort).uppercase(), Icons.Rounded.DirectionsRun, day?.effort, day?.effort?.let(effortFormat), colors.effort) { onOpen(CoreRead.Metric.Effort) }
        HeroRing(stringResource(R.string.forge_rest).uppercase(), Icons.Rounded.Bedtime, day?.rest, day?.rest?.roundToInt()?.toString(), colors.rest) { onOpen(CoreRead.Metric.Rest) }
    }
    }
}

@Composable
private fun HeroRing(label: String, icon: ImageVector, score: Double?, text: String?, color: Color, onClick: () -> Unit) {
    Column(Modifier.clickable(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(92.dp), contentAlignment = Alignment.Center) {
            ScoreRing(score, color, 9.dp)
            if (score != null) Icon(icon, null, tint = color, modifier = Modifier.align(Alignment.TopCenter).padding(top = 16.dp).size(13.dp))
            Text(text ?: "—", style = Forge.type.title1.copy(fontWeight = FontWeight.Bold, fontFeatureSettings = "tnum"),
                 color = if (text == null) Forge.colors.textTertiary else Forge.colors.text)
        }
        Text(label, style = Forge.type.overline, color = Forge.colors.textSecondary)
    }
}

/** A round-capped ring on a faint track, filled to [score] of 100. */
@Composable
private fun ScoreRing(score: Double?, color: Color, stroke: androidx.compose.ui.unit.Dp) {
    val track = Forge.colors.text.copy(alpha = 0.10f)
    Canvas(Modifier.fillMaxWidth().fillMaxHeight()) {
        val w = stroke.toPx()
        val inset = w / 2
        val size = androidx.compose.ui.geometry.Size(this.size.width - w, this.size.height - w)
        drawArc(track, 0f, 360f, false, Offset(inset, inset), size, style = Stroke(w))
        if (score != null) drawArc(color, -90f, (score.coerceIn(0.0, 100.0) / 100 * 360).toFloat(), false,
                                   Offset(inset, inset), size, style = Stroke(w, cap = StrokeCap.Round))
    }
}

/** "Your trends": the shown day's three values beside a 14-day line each (iOS `trendsCard`). */
@Composable
internal fun DashboardTrendsCard(date: LocalDate, isToday: Boolean, effortFormat: (Double) -> String, onOpen: () -> Unit) {
    val colors = Forge.colors
    val from = date.minusDays(13)
    val series by produceState<Map<CoreRead.Metric, List<CoreRead.Point>>>(emptyMap(), date) {
        value = withContext(Dispatchers.IO) {
            listOf(CoreRead.Metric.Charge, CoreRead.Metric.Effort, CoreRead.Metric.Rest)
                .associateWith { CoreRead.series(it, from.toString(), date.toString()) }
        }
    }
    fun last(m: CoreRead.Metric) = series[m]?.lastOrNull { it.day == date.toString() }?.value
    ForgeCard(Modifier.fillMaxWidth().clickable(onClick = onOpen)) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(stringResource(R.string.forge_db_trends), style = Forge.type.headline, color = colors.text, modifier = Modifier.weight(1f))
                Text(stringResource(R.string.forge_db_14day), style = Forge.type.footnote, color = colors.textSecondary)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(Modifier.width(92.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    LegendRow(colors.charge, "Charge", last(CoreRead.Metric.Charge)?.roundToInt()?.toString())
                    LegendRow(colors.effort, "Effort", last(CoreRead.Metric.Effort)?.let(effortFormat))
                    LegendRow(colors.rest, "Rest", last(CoreRead.Metric.Rest)?.roundToInt()?.toString())
                }
                MultiLine(series, from, date, Modifier.weight(1f).height(100.dp))
            }
            val locale = Locale.getDefault()
            Row(Modifier.padding(start = 104.dp)) {
                Text(from.format(DateTimeFormatter.ofPattern(SHORT_DAY_PATTERN, locale)), style = Forge.type.caption, color = colors.textTertiary)
                Spacer(Modifier.weight(1f))
                Text(if (isToday) stringResource(R.string.nav_today) else date.format(DateTimeFormatter.ofPattern(SHORT_DAY_PATTERN, locale)),
                     style = Forge.type.caption, color = colors.textTertiary)
            }
        }
    }
}

@Composable
private fun LegendRow(color: Color, label: String, value: String?) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(8.dp).background(color, CircleShape))
        Text(label, style = Forge.type.footnote, color = Forge.colors.textSecondary, modifier = Modifier.weight(1f))
        Text(value ?: "—", style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
    }
}

/** Three lines on one 0-100 scale over the 14 days; a missing day breaks its line rather than inventing one. */
@Composable
private fun MultiLine(series: Map<CoreRead.Metric, List<CoreRead.Point>>, from: LocalDate, to: LocalDate, modifier: Modifier) {
    val colors = Forge.colors
    val tints = mapOf(CoreRead.Metric.Charge to colors.charge, CoreRead.Metric.Effort to colors.effort, CoreRead.Metric.Rest to colors.rest)
    val span = (to.toEpochDay() - from.toEpochDay()).coerceAtLeast(1).toFloat()
    Canvas(modifier) {
        series.forEach { (metric, points) ->
            val color = tints[metric] ?: return@forEach
            val xy = points.mapNotNull { p ->
                val d = runCatching { LocalDate.parse(p.day) }.getOrNull() ?: return@mapNotNull null
                val x = (d.toEpochDay() - from.toEpochDay()) / span * size.width
                val y = size.height - (p.value.coerceIn(0.0, 100.0) / 100.0).toFloat() * size.height
                Triple(d.toEpochDay(), x, y)
            }
            xy.zipWithNext().forEach { (a, b) ->
                if (b.first - a.first == 1L) drawLine(color, Offset(a.second, a.third), Offset(b.second, b.third), 2.dp.toPx(), StrokeCap.Round)
            }
            xy.forEach { drawCircle(color, 2.5.dp.toPx(), Offset(it.second, it.third)) }
        }
    }
}

/** The four chosen metrics side by side (iOS `TrendsMetricStrip`). */
@Composable
internal fun DashboardMetricStrip(cards: List<DashboardCard>, d: DashboardDay, onOpen: (DashboardCard) -> Unit) {
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth()) {
            cards.forEach { card ->
                Column(Modifier.weight(1f).clickable { onOpen(card) }, horizontalAlignment = Alignment.CenterHorizontally,
                       verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Icon(card.icon, null, tint = cardTint(card), modifier = Modifier.size(11.dp))
                        Text(stringResource(card.titleRes), style = Forge.type.caption, color = Forge.colors.textSecondary, maxLines = 1)
                    }
                    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(cardValue(card, d), style = Forge.type.title2.copy(fontSize = 20.sp, fontFeatureSettings = "tnum"),
                             color = Forge.colors.text, maxLines = 1)
                        if (card.unit.isNotEmpty()) Text(card.unit, style = Forge.type.caption, color = Forge.colors.textTertiary)
                    }
                }
            }
        }
    }
}

/** iOS `TrendsMetricStrip.tint`. */
@Composable
internal fun cardTint(card: DashboardCard): Color = with(ForgeTokens.StrandPalette) {
    when (card) {
        DashboardCard.HRV -> metricPurple.resolve()
        DashboardCard.RESTING_HR, DashboardCard.WEIGHT -> metricRose.resolve()
        DashboardCard.SKIN_TEMP, DashboardCard.CALORIES -> metricAmber.resolve()
        DashboardCard.SLEEP -> Forge.colors.rest
        DashboardCard.STRESS -> Forge.colors.effort
        DashboardCard.FITNESS_AGE, DashboardCard.VO2MAX, DashboardCard.VITALITY -> Forge.colors.charge
        else -> metricCyan.resolve()
    }
}

/** The card's figure for the shown day, as `TrendsMetricStrip.valueText` and the dashboards' resolver give it. */
@Composable
internal fun cardValue(card: DashboardCard, d: DashboardDay): String {
    val day = d.day
    val whole = java.text.NumberFormat.getIntegerInstance()
    return when (card) {
        DashboardCard.HRV -> day?.hrv?.roundToInt()?.toString()
        DashboardCard.RESTING_HR -> day?.restingHr?.toString()
        DashboardCard.RESPIRATORY -> day?.respRate?.let { String.format(Locale.getDefault(), "%.1f", it) }
        DashboardCard.STEPS -> day?.steps?.let { whole.format(it.toLong()) }
        DashboardCard.BLOOD_OXYGEN -> day?.spo2?.let { "${it.roundToInt()}%" }
        DashboardCard.SKIN_TEMP -> day?.skinTempDev?.let { String.format(Locale.getDefault(), "%+.1f°", it) }
        DashboardCard.SLEEP -> day?.sleepMinutes?.let { stringResource(R.string.forge_db_hm, it.toInt() / 60, it.toInt() % 60) }
        DashboardCard.CALORIES -> d.caloriesKcal?.let { whole.format(Math.round(it)) }
        DashboardCard.WEIGHT -> d.weightKg?.let { String.format(Locale.getDefault(), "%.1f", it) }
        DashboardCard.FITNESS_AGE -> d.fitnessAge?.roundToInt()?.toString()
        DashboardCard.VO2MAX -> d.vo2max?.roundToInt()?.toString()
        DashboardCard.VITALITY -> d.vitality?.roundToInt()?.toString()
        DashboardCard.STRESS -> day?.effort?.roundToInt()?.toString()
        else -> null
    } ?: "—"
}

/** "Recent activity": the latest workout as one row, with View all (iOS `activitySection`). */
@Composable
internal fun DashboardActivity(viewModel: AppViewModel, onViewAll: () -> Unit) {
    val workouts by viewModel.workouts.collectAsState()
    val latest = workouts.maxByOrNull { it.startTs }
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.forge_db_activity), style = Forge.type.headline, color = Forge.sceneInk.text, modifier = Modifier.weight(1f))
            Text(stringResource(R.string.forge_db_view_all), style = Forge.type.footnote, color = Forge.colors.accent,
                 modifier = Modifier.clickable(onClick = onViewAll))
        }
        if (latest == null) {
            Text(stringResource(R.string.forge_db_no_workouts), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
        } else ForgeCard(Modifier.fillMaxWidth().clickable(onClick = onViewAll)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(40.dp).background(Forge.colors.charge.copy(alpha = 0.12f), CircleShape), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.DirectionsRun, null, tint = Forge.colors.charge, modifier = Modifier.size(18.dp))
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(latest.sport, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
                    val minutes = ((latest.endTs - latest.startTs) / 60).toInt()
                    Text(stringResource(R.string.forge_db_minutes, minutes), style = Forge.type.footnote, color = Forge.colors.textSecondary)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                        Icon(Icons.Rounded.Schedule, null, tint = Forge.colors.textTertiary, modifier = Modifier.size(10.dp))
                        Text(java.time.Instant.ofEpochSecond(latest.startTs).atZone(java.time.ZoneId.systemDefault())
                                 .format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT).withLocale(Locale.getDefault())),
                             style = Forge.type.caption, color = Forge.colors.textTertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Overview dashboard

/** iOS `ChargeBand` thresholds, read as the state words Momentum uses (`MomentumCopy.stateWord`). */
private fun chargeWordRes(score: Double): Int = when {
    score < 25 -> R.string.forge_db_w_depleted; score < 50 -> R.string.forge_db_w_low
    score < 70 -> R.string.forge_db_w_steady; score < 88 -> R.string.forge_db_w_strong
    else -> R.string.forge_db_w_peak
}

/** "Today at a glance": recovery, strain and sleep with a word and a sentence each, and the day's verdict. */
@Composable
internal fun DashboardGlanceCard(day: CoreRead.Day?, effortFormat: (Double) -> String, effortMax: String,
                                 onOpen: (CoreRead.Metric) -> Unit, onHealth: () -> Unit) {
    val colors = Forge.colors
    val charge = day?.charge; val effort = day?.effort; val rest = day?.rest
    // `overviewTone`: a depleted Charge or a maxed-out day is critical, a low Charge or a short night a warning.
    val critical = (charge != null && charge < 25) || (effort ?: 0.0) >= 90
    val warning = (charge != null && charge < 50) || (rest ?: 0.0) < 70
    ForgeCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(R.string.forge_db_glance).uppercase(), style = Forge.type.overline, color = colors.textSecondary)
            Row(Modifier.height(IntrinsicSize.Min)) {
                GlanceRing(stringResource(R.string.forge_db_recovery), charge, charge?.roundToInt()?.toString(), "%", null, colors.charge,
                    charge?.let { stringResource(chargeWordRes(it)) },
                    stringResource(when {
                        charge == null -> R.string.forge_db_no_score
                        charge >= 70 -> R.string.forge_db_recovered
                        charge >= 50 -> R.string.forge_db_moderate_training
                        else -> R.string.forge_db_easy_day
                    })) { onOpen(CoreRead.Metric.Charge) }
                VerticalHairline()
                GlanceRing(stringResource(R.string.forge_db_strain), effort, effort?.let(effortFormat), "", effortMax, colors.effort,
                    effort?.let { stringResource(if (it < 30) R.string.forge_db_w_light else if (it < 60) R.string.forge_db_w_moderate else R.string.forge_db_w_high) },
                    stringResource(when {
                        effort == null -> R.string.forge_db_no_load
                        effort < 60 -> R.string.forge_db_optimal_training
                        else -> R.string.forge_db_demanding
                    })) { onOpen(CoreRead.Metric.Effort) }
                VerticalHairline()
                GlanceRing(stringResource(R.string.forge_db_sleep), rest, rest?.roundToInt()?.toString(), "%", null, colors.rest,
                    rest?.let { stringResource(if (it >= 80) R.string.forge_db_w_good else if (it >= 60) R.string.forge_db_w_fair else R.string.forge_db_w_low) },
                    day?.sleepMinutes?.let { m ->
                        stringResource(R.string.forge_db_sleep_detail, m.toInt() / 60, m.toInt() % 60,
                            stringResource(when { rest == null -> R.string.forge_db_unscored; rest >= 70 -> R.string.forge_db_good; else -> R.string.forge_db_limited }),
                            stringResource(if ((rest ?: 0.0) >= 70) R.string.forge_db_regen_ok else R.string.forge_db_regen_catching))
                    } ?: stringResource(R.string.forge_db_no_sleep)) { onOpen(CoreRead.Metric.Rest) }
            }
            HorizontalDivider(color = colors.divider)
            val tone = when { critical -> ForgeTokens.StrandPalette.statusCritical.resolve(); warning -> ForgeTokens.StrandPalette.statusWarning.resolve()
                              else -> ForgeTokens.StrandPalette.statusPositive.resolve() }
            Row(Modifier.fillMaxWidth().clickable(onClick = onHealth), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(if (!critical && !warning) Icons.Rounded.CheckCircleOutline else Icons.Rounded.WarningAmber, null, tint = tone,
                     modifier = Modifier.size(16.dp))
                Text(stringResource(when { critical -> R.string.forge_db_several; warning -> R.string.forge_db_one_two; else -> R.string.forge_db_all_green }),
                     style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = colors.text, modifier = Modifier.weight(1f))
                Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = colors.textTertiary, modifier = Modifier.size(14.dp))
            }
        }
    }
}

@Composable
private fun VerticalHairline() =
    Box(Modifier.width(1.dp).fillMaxHeight().padding(top = 22.dp, bottom = 4.dp).background(Forge.colors.divider))

@Composable
private fun androidx.compose.foundation.layout.RowScope.GlanceRing(
    label: String, value: Double?, main: String?, suffix: String, denominator: String?, color: Color,
    word: String?, detail: String, onClick: () -> Unit,
) {
    Column(Modifier.weight(1f).clickable(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(label, style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = color)
        Box(Modifier.size(74.dp), contentAlignment = Alignment.Center) {
            ScoreRing(value, color, 6.dp)
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(main ?: "—", style = Forge.type.title2.copy(fontWeight = FontWeight.Bold, fontSize = 25.sp, fontFeatureSettings = "tnum"),
                         color = if (main == null) Forge.colors.textTertiary else Forge.colors.text)
                    if (main != null && suffix.isNotEmpty()) Text(suffix, style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
                }
                if (main != null && denominator != null) Text(denominator, style = Forge.type.caption, color = Forge.colors.textSecondary)
            }
        }
        if (word != null) Text(word, style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = color,
                               modifier = Modifier.background(color.copy(alpha = 0.16f), RoundedCornerShape(50)).padding(horizontal = 6.dp, vertical = 1.dp))
        Text(detail, style = Forge.type.footnote, color = Forge.colors.textSecondary, textAlign = TextAlign.Center)
    }
}

/** "Today's focus": three small cards from the chosen slots (iOS `importantRow`). */
@Composable
internal fun DashboardFocusRow(items: List<String>, d: DashboardDay, stepGoal: Int, onOpen: (DashboardCard) -> Unit,
                               onSleep: () -> Unit, onCoach: () -> Unit) {
    val colors = Forge.colors
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        Text(stringResource(R.string.forge_db_focus).uppercase(), style = Forge.type.overline, color = Forge.sceneInk.secondary)
        Row(Modifier.height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            items.forEach { item ->
                val card = DashboardCard.entries.firstOrNull { it.raw == item }
                when {
                    item == "steps" -> MiniCard(Icons.Rounded.DirectionsWalk, colors.charge, stringResource(R.string.forge_db_w_activity), { card?.let(onOpen) }) {
                        Text(d.day?.steps?.let { java.text.NumberFormat.getIntegerInstance().format(it.toLong()) } ?: "—",
                             style = Forge.type.headline.copy(fontFeatureSettings = "tnum"), color = colors.text)
                        Text(stringResource(R.string.forge_db_steps), style = Forge.type.footnote, color = colors.textSecondary)
                        if (stepGoal > 0) {
                            val f = ((d.day?.steps ?: 0).toFloat() / stepGoal).coerceIn(0f, 1f)
                            Box(Modifier.fillMaxWidth().height(5.dp).background(colors.charge.copy(alpha = 0.18f), RoundedCornerShape(50))) {
                                Box(Modifier.fillMaxWidth(f).height(5.dp).background(colors.charge, RoundedCornerShape(50)))
                            }
                            Text(stringResource(R.string.forge_db_step_goal, stepGoal), style = Forge.type.footnote, color = colors.textSecondary)
                        }
                    }
                    item == "sleep" -> MiniCard(Icons.Rounded.Bedtime, colors.rest, stringResource(R.string.forge_db_sleep_insight), onSleep) {
                        Text(d.day?.rest?.let { stringResource(R.string.forge_percent, it.roundToInt()) } ?: DASH, style = Forge.type.headline, color = colors.text)
                        Text(stringResource(R.string.forge_db_sleep_quality), style = Forge.type.footnote, color = colors.textSecondary)
                    }
                    item == "coach" -> MiniCard(Icons.Rounded.Person, colors.accent, stringResource(R.string.forge_db_coach), onCoach) {
                        Text(d.day?.charge?.let { stringResource(chargeWordRes(it)) } ?: "—", style = Forge.type.footnote.copy(fontWeight = FontWeight.Bold), color = colors.text)
                    }
                    card != null -> MiniCard(card.icon, cardTint(card), stringResource(card.titleRes), { onOpen(card) }) {
                        Text(cardValue(card, d), style = Forge.type.headline.copy(fontFeatureSettings = "tnum"), color = colors.text)
                        if (card.unit.isNotEmpty()) Text(card.unit, style = Forge.type.footnote, color = colors.textSecondary)
                    }
                }
            }
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.MiniCard(icon: ImageVector, tint: Color, title: String, onClick: () -> Unit,
                                                               content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit) {
    ForgeCard(Modifier.weight(1f).fillMaxHeight().clickable(onClick = onClick), radius = ForgeMetrics.groupedRadius) {
        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Box(Modifier.size(20.dp).background(tint.copy(alpha = 0.16f), CircleShape), contentAlignment = Alignment.Center) {
                    Icon(icon, null, tint = tint, modifier = Modifier.size(10.dp))
                }
                Text(title, style = Forge.type.footnote, color = Forge.colors.textSecondary, maxLines = 1)
            }
            content()
        }
    }
}

/** "Your health": the chosen metrics with their status against the wearer's own range (iOS `healthList`). */
@Composable
internal fun DashboardHealthList(cards: List<DashboardCard>, d: DashboardDay, history: List<CoreRead.Day>,
                                 onOpen: (DashboardCard) -> Unit, onAll: () -> Unit) {
    val colors = Forge.colors
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        Text(stringResource(R.string.forge_db_health).uppercase(), style = Forge.type.overline, color = Forge.sceneInk.secondary)
        ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
            Column {
                cards.forEachIndexed { i, card ->
                    if (i > 0) HorizontalDivider(color = colors.divider, modifier = Modifier.padding(start = 40.dp))
                    Row(Modifier.fillMaxWidth().clickable { onOpen(card) }.padding(horizontal = 10.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(Modifier.size(22.dp).background(cardTint(card).copy(alpha = 0.16f), CircleShape), contentAlignment = Alignment.Center) {
                            Icon(card.icon, null, tint = cardTint(card), modifier = Modifier.size(10.dp))
                        }
                        Text(stringResource(card.titleRes), style = Forge.type.footnote, color = colors.text, modifier = Modifier.weight(1f))
                        Text(cardValue(card, d), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
                        if (card.unit.isNotEmpty()) Text(card.unit, style = Forge.type.footnote, color = colors.textTertiary)
                        healthStatus(card, d.day, history)?.let { (word, tone) ->
                            Box(Modifier.size(5.dp).background(tone, CircleShape))
                            Text(word, style = Forge.type.footnote, color = tone)
                        }
                        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = colors.textTertiary, modifier = Modifier.size(12.dp))
                    }
                }
                HorizontalDivider(color = colors.divider)
                Row(Modifier.fillMaxWidth().clickable(onClick = onAll).padding(vertical = 10.dp), horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.forge_db_show_all), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = colors.accent)
                    Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = colors.accent, modifier = Modifier.size(12.dp))
                }
            }
        }
    }
}

/** iOS `OverviewHealthStatus`: in or out of the wearer's own range, from `VitalBands`; null where it does not apply. */
@Composable
private fun healthStatus(card: DashboardCard, day: CoreRead.Day?, history: List<CoreRead.Day>): Pair<String, Color>? {
    val result = when (card) {
        DashboardCard.HRV -> VitalBands.band(day?.hrv, history.map { it.hrv }, 40.0..120.0, Baselines.hrvCfg)
        DashboardCard.RESTING_HR -> VitalBands.band(day?.restingHr?.toDouble(), history.map { it.restingHr?.toDouble() }, 40.0..60.0, Baselines.restingHRCfg)
        DashboardCard.RESPIRATORY -> VitalBands.band(day?.respRate, history.map { it.respRate }, 12.0..20.0, Baselines.respCfg)
        DashboardCard.BLOOD_OXYGEN -> VitalBands.band(day?.spo2, emptyList(), 95.0..100.0, null)
        DashboardCard.SKIN_TEMP -> VitalBands.band(day?.skinTempDev, history.map { it.skinTempDev }, -0.6..0.6, VitalBands.skinTempDeviationCfg)
        else -> return null
    }
    return when (result.band) {
        VitalBands.Band.IN_RANGE -> stringResource(R.string.forge_db_optimal) to ForgeTokens.StrandPalette.statusPositive.resolve()
        VitalBands.Band.OUT_OF_RANGE -> stringResource(R.string.forge_db_attention) to ForgeTokens.StrandPalette.statusWarning.resolve()
        else -> null
    }
}

/** Today's Trends and Overview styles: their blocks in the saved order, then the opt-in extras (iOS `dashboardSection`). */
@Composable
internal fun ForgeStyledDashboard(
    style: String, revision: Int, date: LocalDate, day: CoreRead.Day?, viewModel: AppViewModel,
    onSection: @Composable (TodaySection) -> Unit,
    onHealth: () -> Unit, onSleep: () -> Unit, onStress: () -> Unit, onCoach: () -> Unit, onActivity: () -> Unit,
) {
    val context = LocalContext.current
    val isToday = date == LocalDate.now()
    val sections = remember(revision, style) { DashboardLayoutPrefs.visible(context, style) }
    val effortFormat = rememberEffortFormat()
    val effortMax = if (UnitPrefs.effortScale(context) == EffortScale.WHOOP) "21" else "100"
    val figures by produceState(DashboardDay(day, isToday, date, null, null, null, null, null), day, date) {
        value = withContext(Dispatchers.IO) {
            val weight = CoreBody.snapshot(context)?.weight?.lastOrNull { it.day <= date.toString() }?.value
            val kcal = if (isToday) CoreEnergyDetail.today(context, dismissedTrainingWorkouts(context))?.total else null
            // `latestBanked`: the newest value of the banked series on or before the shown day.
            suspend fun banked(key: String): Double? = runCatching {
                viewModel.repo.resolvedSeries(key, "my-whoop", date.minusDays(120).toString(), date.toString(),
                    strapDeviceId = viewModel.activeStrapId).points
                    .filter { it.day <= date.toString() }.maxByOrNull { it.day }?.value
            }.getOrNull()
            DashboardDay(day, isToday, date, weight, kcal, banked("fitness_age"), banked("vo2max_est"), banked("vitality"))
        }
    }
    val history by produceState(emptyList<CoreRead.Day>(), date) {
        value = withContext(Dispatchers.IO) {
            (1..14).mapNotNull { CoreRead.day(date.minusDays(it.toLong()).toString()) }
        }
    }
    val stepGoal = remember(revision) { CorePrefs.read(context).optInt(CorePrefs.STEP_GOAL, 0) }
    fun open(card: DashboardCard) = when (card) {
        DashboardCard.SLEEP -> onSleep()
        DashboardCard.STRESS -> onStress()
        DashboardCard.COACH -> onCoach()
        else -> onHealth()
    }
    ForgeArrangeHint(style)
    sections.forEach { section ->
        when (section) {
            DashboardSection.COACH -> if (isToday) onSection(TodaySection.COACH)
            DashboardSection.HERO -> DashboardHeroRings(day, effortFormat) { onHealth() }
            DashboardSection.TRENDS_CHART -> DashboardTrendsCard(date, isToday, effortFormat, onOpen = onHealth)
            DashboardSection.METRIC_STRIP -> DashboardMetricStrip(TrendsMetricSlots.slots(context), figures, ::open)
            DashboardSection.ACTIVITY -> DashboardActivity(viewModel, onViewAll = onActivity)
            DashboardSection.OVERVIEW -> DashboardGlanceCard(day, effortFormat, effortMax, onOpen = { onHealth() }, onHealth = onHealth)
            DashboardSection.FOCUS -> DashboardFocusRow(OverviewPrefs.focus(context), figures, stepGoal, ::open, onSleep, onCoach)
            DashboardSection.HEALTH -> DashboardHealthList(OverviewPrefs.health(context), figures, history, ::open, onHealth)
            DashboardSection.MOMENTUM -> if (isToday) onSection(TodaySection.SYNTHESIS)
            DashboardSection.GOALS -> if (isToday) onSection(TodaySection.GOALS)
            DashboardSection.KEY_METRICS -> onSection(TodaySection.KEY_METRICS)
            DashboardSection.ENERGY_DETAIL -> onSection(TodaySection.ENERGY)
            DashboardSection.WORKOUTS_LIST -> onSection(TodaySection.WORKOUTS)
            DashboardSection.HEART_RATE -> onSection(TodaySection.HEART_RATE)
            DashboardSection.RECOVERY_VITALS -> onSection(TodaySection.RECOVERY_VITALS)
            DashboardSection.YOUR_CARDS -> onSection(TodaySection.YOUR_CARDS)
            DashboardSection.MENSTRUAL_CYCLE -> onSection(TodaySection.MENSTRUAL_CYCLE)
            DashboardSection.JOURNAL -> onSection(TodaySection.JOURNAL)
            DashboardSection.ADDED_CARDS -> onSection(TodaySection.ADDED_CARDS)
            DashboardSection.LIVE_SESSION, DashboardSection.DATA_SOURCES -> Unit
        }
    }
}

/** "Arrange dashboard" (iOS `DashboardExtraSectionsSheet`): order and hide the style's blocks, then Save. */
@Composable
internal fun ForgeDashboardArrange(dashboard: String, onClose: (saved: Boolean) -> Unit) {
    val context = LocalContext.current
    val start = remember {
        val p = NoopPrefs.of(context)
        val order = DashboardLayoutPrefs.order(p.getString(DashboardLayoutPrefs.orderKey(dashboard), null), dashboard)
        val hidden = DashboardLayoutPrefs.hidden(p.getString(DashboardLayoutPrefs.hiddenKey(dashboard), null), dashboard)
        EditableLayoutDraft(order.filter { it !in hidden }, order.filter { it in hidden })
    }
    var draft by remember { mutableStateOf(start) }
    fun fresh(): EditableLayoutDraft<DashboardSection> {
        val order = DashboardSection.defaultOrder(dashboard)
        return EditableLayoutDraft(order.filter { !it.extra }, order.filter { it.extra })
    }
    ForgeSceneBackdrop(ForgeBackdrop.Sky) {
        ForgeEditorPage(stringResource(R.string.forge_db_arrange), onCancel = { onClose(false) }, onBack = null, onSave = {
            DashboardLayoutPrefs.save(context, dashboard, draft.visible + draft.hidden, draft.hidden.toSet())
            onClose(true)
        }) {
            ForgeEditableLayoutList(
                draft, { draft = it },
                stringResource(R.string.forge_lay_shown), stringResource(R.string.forge_lay_hidden),
                LayoutRowStyle(title = { stringResource(it.titleRes) }, icon = { Icons.Rounded.Tune }, tint = { Forge.colors.accent }),
                onReset = { draft = fresh() },
            )
        }
    }
}

/** iOS `DashboardArrangeHintSheet`: told once per style, the flag written as the sheet is raised. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun ForgeArrangeHint(dashboard: String) {
    val context = LocalContext.current
    val key = "$dashboard.dashboard.arrangeHintSeen"
    var open by remember { mutableStateOf(false) }
    androidx.compose.runtime.LaunchedEffect(dashboard) {
        val p = NoopPrefs.of(context)
        if (!p.getBoolean(key, false)) { p.edit().putBoolean(key, true).apply(); open = true }
    }
    if (!open) return
    val colors = Forge.colors
    androidx.compose.material3.ModalBottomSheet(onDismissRequest = { open = false }, containerColor = colors.surface) {
        Column(Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.screenPadding).padding(bottom = ForgeMetrics.space6),
               verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.size(36.dp).background(colors.accent.copy(alpha = 0.16f), CircleShape), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.TouchApp, null, tint = colors.accent, modifier = Modifier.size(16.dp))
                }
                Text(stringResource(R.string.forge_db_hint_title), style = Forge.type.title2, color = colors.text)
            }
            Text(stringResource(R.string.forge_db_hint_body), style = Forge.type.subhead, color = colors.textSecondary)
            Text(stringResource(R.string.forge_db_hint_settings), style = Forge.type.footnote, color = colors.textTertiary)
            androidx.compose.material3.Button(onClick = { open = false }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_db_hint_ok))
            }
        }
    }
}

/**
 * The Classic Today (iOS `TodayView`), as ryanbr's list of cards read: its own header, the arranged sections and
 * the cards, drawn in the Forge colours ([com.noop.ui.HostedPalette]) and routed to Forge's pages.
 */
@Composable
internal fun ForgeClassicToday(padding: androidx.compose.foundation.layout.PaddingValues, viewModel: AppViewModel) {
    val more = rememberMoreNavigator()
    val selectTab = LocalForgeTabSelect.current
    var settingsOpen by remember { mutableStateOf(false) }
    var quickActions by remember { mutableStateOf(false) }
    var startWorkout by remember { mutableStateOf(false) }
    var liveWorkout by remember { mutableStateOf(false) }
    var liveSession by remember { mutableStateOf(false) }
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
                QuickAction.CustomizeToday -> more.push(MoreRoute.Dest(MoreDest.Settings))
            }
        }
    }
    if (liveSession) ForgeLiveSessionCover(viewModel, onClose = { liveSession = false })
    MoreOverlay(more, viewModel, onOpenSettings = { settingsOpen = true })
    if (settingsOpen) {
        ForgeOverlayPage(onDismiss = { settingsOpen = false }) { ForgeSettings(viewModel, onClose = { settingsOpen = false }) }
    }
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
    // The classic list was drawn for a dark canvas (white header, near-black hero), so it gets Forge's dark theme.
    ForgeTheme(dark = true) {
    val forgeColors = Forge.colors
    val tokens = remember(forgeColors) { hostedTokens(forgeColors) }
    Box(Modifier.fillMaxSize().background(forgeColors.canvas).padding(padding)) {
        com.noop.ui.HostedPalette(tokens, forgeColors.dark) {
            com.noop.ui.TodayScreen(
                viewModel = viewModel,
                onQuickActions = { quickActions = true },
                onOpenSettings = { settingsOpen = true },
                onOpenHydration = { more.push(MoreRoute.Dest(MoreDest.Journal)) },
                onOpenStress = { more.push(MoreRoute.Dest(MoreDest.Stress)) },
                onOpenHealth = { more.push(MoreRoute.Dest(MoreDest.Health)) },
                onOpenMetric = { more.push(MoreRoute.Dest(MoreDest.Health)) },
                onOpenSleep = { selectTab(ForgeTab.Sleep) },
                onOpenCoupled = { more.push(MoreRoute.Dest(MoreDest.Health)) },
                onOpenCoach = { more.push(MoreRoute.Dest(MoreDest.Coach)) },
                onOpenActiveWorkout = { liveWorkout = true },
                onOpenDevices = { selectTab(ForgeTab.More) },
                onOpenJournal = { more.push(MoreRoute.Dest(MoreDest.Journal)) },
                onOpenTrainingLoad = { more.push(MoreRoute.Dest(MoreDest.TrainingLoad)) },
            )
        }
    }
    }
}
