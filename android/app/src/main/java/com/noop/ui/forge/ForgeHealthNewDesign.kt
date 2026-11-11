package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.WbTwilight
import androidx.compose.material.icons.rounded.CompareArrows
import androidx.compose.material.icons.rounded.ShowChart
import androidx.compose.material.icons.rounded.HourglassBottom
import androidx.compose.material.icons.rounded.Book
import androidx.compose.material.icons.rounded.Lightbulb
import androidx.compose.material.icons.rounded.Air
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.WaterDrop
import androidx.compose.material.icons.rounded.Science
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material.icons.rounded.MonitorWeight
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.Alarm
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Psychology
import androidx.compose.material.icons.rounded.Accessibility
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import kotlin.math.roundToInt
import com.noop.core.CoreRead
import com.noop.data.DailyMetric
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.format.TextStyle
import java.util.Locale

/*
 * Fork (DX23876), Forge parity 2026-11: the Health tab's Focus areas, their pages and "Your week in rings" in the new
 * design, rebuilt from iOS's `ForgeHealthView` and `ForgeFocusView`. A focus tile opens its measure in Explore, which
 * stands in for iOS's single-metric page.
 */

/** The six focus areas, as iOS's `ForgeFocusArea`, each with the Android pages that belong to it. */
internal enum class FocusArea(val titleRes: Int, val subRes: Int, val icon: ImageVector, val dests: List<MoreDest>) {
    Fitness(R.string.forge_hf_fitness, R.string.forge_hf_fitness_sub, Icons.Rounded.DirectionsRun,
            listOf(MoreDest.Cardio, MoreDest.Strength, MoreDest.TrainingLoad, MoreDest.Workouts)),
    Sleep(R.string.forge_hf_sleep, R.string.forge_hf_sleep_sub, Icons.Rounded.Bedtime, emptyList()),
    Vitals(R.string.forge_hf_vitals, R.string.forge_hf_vitals_sub, Icons.Rounded.Favorite,
           listOf(MoreDest.Health, MoreDest.Ecg, MoreDest.BeatRhythm, MoreDest.Live)),
    Body(R.string.forge_hf_body, R.string.forge_hf_body_sub, Icons.Rounded.Accessibility,
         listOf(MoreDest.Body, MoreDest.Food, MoreDest.Energy, MoreDest.Biomarkers)),
    Mind(R.string.forge_hf_mind, R.string.forge_hf_mind_sub, Icons.Rounded.Psychology,
         listOf(MoreDest.Stress, MoreDest.Breathe, MoreDest.Insights, MoreDest.Journal)),
    More(R.string.forge_hf_more, R.string.forge_hf_more_sub, Icons.Rounded.GridView,
         listOf(MoreDest.Explore, MoreDest.Compare)),
    ;

    @Composable
    fun tint(): Color = when (this) {
        Fitness -> Forge.colors.effort
        Sleep -> Forge.colors.rest
        Vitals -> Forge.colors.heart
        Body -> Forge.colors.charge
        Mind -> ForgeTokens.Color.systemTeal.resolve()
        More -> Forge.colors.accent
    }
}

/** The focus areas as six tiles in two columns, as iOS's grid of `ForgeFocusTile`. */
@Composable
internal fun HealthFocusGrid(onOpen: (FocusArea) -> Unit) {
    val colors = Forge.colors
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        FocusArea.entries.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                pair.forEach { area ->
                    val tint = area.tint()
                    ForgeCard(Modifier.weight(1f).heightIn(min = 112.dp).clickable(role = Role.Button) { onOpen(area) }) {
                        Box(Modifier.size(36.dp).background(tint.copy(alpha = 0.16f), CircleShape), contentAlignment = Alignment.Center) {
                            Icon(area.icon, contentDescription = null, tint = tint, modifier = Modifier.size(19.dp))
                        }
                        Spacer(Modifier.height(ForgeMetrics.space3))
                        Text(stringResource(area.titleRes), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                             color = colors.text, maxLines = 2)
                        Text(stringResource(area.subRes), style = Forge.type.caption, color = colors.textSecondary, maxLines = 2)
                    }
                }
            }
        }
    }
}

/** One measure on a focus page: its series key and preferred source, as iOS's `ForgeFocusArea.metrics`. */
internal data class FocusMeasure(val key: String, val source: String, val titleRes: Int, val unit: String, val decimals: Int)

/** One entry under a focus page's tiles: a page or a tab, as iOS's `FocusLink`. */
private data class FocusLink(val titleRes: Int, val subRes: Int, val icon: androidx.compose.ui.graphics.vector.ImageVector,
                             val tint: Color, val dest: MoreDest? = null, val action: String? = null)

internal fun FocusArea.measures(): List<FocusMeasure> = when (this) {
    FocusArea.Fitness -> listOf(FocusMeasure("vo2max_est", "my-whoop", R.string.forge_fm_vo2, "", 1),
        FocusMeasure("rhr", "my-whoop", R.string.forge_fm_rhr, "bpm", 0), FocusMeasure("hr_zones13_min", "my-whoop", R.string.forge_fm_zones, "min", 0),
        FocusMeasure("strength_min", "my-whoop", R.string.forge_fm_strength, "min", 0), FocusMeasure("steps", "my-whoop", R.string.forge_fm_steps, "", 0),
        FocusMeasure("strain", "my-whoop", R.string.forge_fm_effort, "/100", 1))
    FocusArea.Sleep -> listOf(FocusMeasure("sleep_performance", "my-whoop", R.string.forge_fm_rest, "%", 0),
        FocusMeasure("sleep_total_min", "my-whoop", R.string.forge_fm_asleep, "min", 0),
        FocusMeasure("sleep_consistency", "my-whoop", R.string.forge_fm_consistency, "%", 0),
        FocusMeasure("sleep_debt_min", "my-whoop", R.string.forge_fm_debt, "min", 0),
        FocusMeasure("restorative_min", "my-whoop", R.string.forge_fm_restorative, "min", 0),
        FocusMeasure("sleep_efficiency", "my-whoop", R.string.forge_fm_efficiency, "%", 0))
    FocusArea.Vitals -> listOf(FocusMeasure("hrv", "my-whoop", R.string.forge_fm_hrv, "ms", 0),
        FocusMeasure("rhr", "my-whoop", R.string.forge_fm_rhr, "bpm", 0), FocusMeasure("spo2", "my-whoop", R.string.forge_fm_spo2, "%", 0),
        FocusMeasure("resp_rate", "my-whoop", R.string.forge_fm_resp, "/min", 1), FocusMeasure("skin_temp", "my-whoop", R.string.forge_fm_skin, "°C", 1),
        FocusMeasure("avg_hr", "my-whoop", R.string.forge_fm_avg_hr, "bpm", 0))
    FocusArea.Body -> listOf(FocusMeasure("weight", "noop-weight", R.string.forge_fm_weight, "kg", 1),
        FocusMeasure("body_fat", "apple-health", R.string.forge_fm_body_fat, "%", 1),
        FocusMeasure("lean_mass", "apple-health", R.string.forge_fm_lean, "kg", 1),
        FocusMeasure("calories_in", "nutrition-csv", R.string.forge_fm_cal_in, "kcal", 0),
        FocusMeasure("active_kcal", "apple-health", R.string.forge_fm_active, "kcal", 0))
    FocusArea.Mind -> listOf(FocusMeasure("stress", "my-whoop", R.string.forge_fm_stress, "/3", 1),
        FocusMeasure("mood", "noop-mood", R.string.forge_fm_mood, "/5", 0))
    FocusArea.More -> emptyList()
}

/** A focus value as iOS's `ForgeFocusView.format`: minutes as h:mm, a change in skin temperature with its sign. */
internal fun focusValue(v: Double, m: FocusMeasure): String {
    if (m.unit == "min") { val t = v.roundToInt(); return "%d:%02d".format(t / 60, t % 60) }
    val text = "%.${if (m.unit == "/100") 0 else m.decimals}f".format(Locale.getDefault(), v)
    return if (m.key == "skin_temp" && v >= 0 && v < 20) "+$text" else text
}

internal fun focusUnit(m: FocusMeasure): String = when (m.unit) { "min" -> "h"; "/100" -> ""; else -> m.unit }

@Composable
private fun focusLinks(area: FocusArea, context: android.content.Context): List<FocusLink> {
    val c = Forge.colors
    val red = ForgeTokens.Color.systemRed.resolve(); val pink = ForgeTokens.Color.systemPink.resolve()
    val teal = ForgeTokens.Color.systemTeal.resolve(); val orange = ForgeTokens.Color.systemOrange.resolve()
    val blue = ForgeTokens.Color.systemBlue.resolve(); val yellow = ForgeTokens.Color.systemYellow.resolve()
    val I = androidx.compose.material.icons.Icons.Rounded
    return when (area) {
        FocusArea.Fitness -> listOf(FocusLink(R.string.forge_fl_cardio, R.string.forge_fl_cardio_sub, I.DirectionsRun, c.effort, MoreDest.Cardio),
            FocusLink(R.string.forge_fl_strength, R.string.forge_fl_strength_sub, androidx.compose.material.icons.Icons.Rounded.FitnessCenter, c.rest, MoreDest.Strength),
            FocusLink(R.string.forge_fl_load, R.string.forge_fl_load_sub, androidx.compose.material.icons.Icons.Rounded.BarChart, c.effort, MoreDest.TrainingLoad),
            FocusLink(R.string.forge_fl_workouts, R.string.forge_fl_workouts_sub, androidx.compose.material.icons.Icons.Rounded.CalendarMonth, c.effort, MoreDest.Workouts))
        FocusArea.Sleep -> listOf(FocusLink(R.string.forge_fl_sleep, R.string.forge_fl_sleep_sub, I.Bedtime, c.rest, action = "sleep"),
            FocusLink(R.string.forge_fl_alarm, R.string.forge_fl_alarm_sub, androidx.compose.material.icons.Icons.Rounded.Alarm, c.rest, MoreDest.Alarms))
        FocusArea.Vitals -> listOf(FocusLink(R.string.forge_fl_hr, R.string.forge_fl_hr_sub, androidx.compose.material.icons.Icons.Rounded.MonitorHeart, red, MoreDest.Health),
            FocusLink(R.string.forge_fl_ecg, R.string.forge_fl_ecg_sub, I.Favorite, pink, MoreDest.Ecg),
            FocusLink(R.string.forge_fl_rhythm, R.string.forge_fl_rhythm_sub, androidx.compose.material.icons.Icons.Rounded.GraphicEq, pink, MoreDest.BeatRhythm))
        FocusArea.Body -> listOfNotNull(FocusLink(R.string.forge_fl_weight, R.string.forge_fl_weight_sub, androidx.compose.material.icons.Icons.Rounded.MonitorWeight, blue, MoreDest.Body),
            FocusLink(R.string.forge_fl_body, R.string.forge_fl_body_sub, I.Accessibility, teal, MoreDest.Body),
            FocusLink(R.string.forge_fl_energy, R.string.forge_fl_energy_sub, androidx.compose.material.icons.Icons.Rounded.LocalFireDepartment, orange, MoreDest.Energy),
            FocusLink(R.string.forge_fl_records, R.string.forge_fl_records_sub, androidx.compose.material.icons.Icons.Rounded.Science, c.accent, MoreDest.Biomarkers),
            FocusLink(R.string.forge_fl_cycle, R.string.forge_fl_cycle_sub, androidx.compose.material.icons.Icons.Rounded.WaterDrop, pink, action = "cycle")
                .takeIf { com.noop.ui.NoopPrefs.cycleTracking(context) })
        FocusArea.Mind -> listOf(FocusLink(R.string.forge_fl_stress, R.string.forge_fl_stress_sub, androidx.compose.material.icons.Icons.Rounded.Bolt, orange, MoreDest.Stress),
            FocusLink(R.string.forge_fl_breathe, R.string.forge_fl_breathe_sub, androidx.compose.material.icons.Icons.Rounded.Air, teal, MoreDest.Breathe),
            FocusLink(R.string.forge_fl_works, R.string.forge_fl_works_sub, androidx.compose.material.icons.Icons.Rounded.Lightbulb, yellow, MoreDest.Insights),
            FocusLink(R.string.forge_fl_journal, R.string.forge_fl_journal_sub, androidx.compose.material.icons.Icons.Rounded.Book, c.effort, MoreDest.Journal),
            FocusLink(R.string.forge_fl_momentum, R.string.forge_fl_momentum_sub, androidx.compose.material.icons.Icons.Rounded.Bolt, orange, MoreDest.Momentum))
        FocusArea.More -> listOfNotNull(
            FocusLink(R.string.forge_fl_ageless_sub, R.string.forge_fl_ageless_sub, androidx.compose.material.icons.Icons.Rounded.HourglassBottom, c.charge, MoreDest.AgeLess)
                .takeIf { MoreDest.AgeLess.shown(context) },
            FocusLink(R.string.forge_fl_trends, R.string.forge_fl_trends_sub, androidx.compose.material.icons.Icons.Rounded.ShowChart, c.charge, action = "trends"),
            FocusLink(R.string.forge_fl_all, R.string.forge_fl_all_sub, I.GridView, blue, MoreDest.Explore),
            FocusLink(R.string.forge_fl_compare, R.string.forge_fl_compare_sub, androidx.compose.material.icons.Icons.Rounded.CompareArrows, blue, MoreDest.Compare),
            FocusLink(R.string.forge_fl_rhythm_age, R.string.forge_fl_rhythm_age_sub, androidx.compose.material.icons.Icons.Rounded.WbTwilight, c.charge, MoreDest.RhythmAge)
                .takeIf { MoreDest.RhythmAge.shown(context) })
    }
}

/**
 * A focus area's own page, as iOS's `ForgeFocusView`: the area's measures as tiles with their last 30 values (Body adds
 * each finished day's burn), then the area's pages under "In this area". [onAction] handles links that are not a More
 * page: "sleep" (the Sleep tab), "trends" and "cycle".
 */
@Composable
internal fun FocusAreaPage(area: FocusArea, viewModel: com.noop.ui.AppViewModel, onBack: () -> Unit, onOpen: (MoreDest) -> Unit,
                           onAction: (String) -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val tint = area.tint()
    val noData = stringResource(R.string.forge_no_data)
    val series by produceState(emptyList<Pair<FocusMeasure, List<Double>>>(), area) {
        value = withContext(Dispatchers.IO) {
            val today = LocalDate.now()
            val from = today.minusDays(90).toString(); val to = today.toString()
            val seen = mutableSetOf<String>()
            area.measures().mapNotNull { m ->
                if (m.key in seen) return@mapNotNull null
                val points = runCatching { viewModel.repo.resolvedSeries(m.key, m.source, from, to, strapDeviceId = viewModel.activeStrapId).points }
                    .getOrDefault(emptyList()).map { it.value }.filter { it.isFinite() }
                if (points.isEmpty()) null else { seen += m.key; m to points }
            }
        }
    }
    val energy by produceState(emptyList<Double>(), area) {
        value = if (area != FocusArea.Body) emptyList() else withContext(Dispatchers.IO) {
            val today = LocalDate.now().toString()
            runCatching {
                com.noop.core.CoreEnergyDetail.read(context, today, "sevenDay", dismissedTrainingWorkouts(context))
                    ?.summaries?.filter { it.day != today }?.sortedBy { it.day }?.mapNotNull { it.total }
            }.getOrNull().orEmpty()
        }
    }
    SettingsColumn {
        PageTitle(stringResource(area.titleRes), onBack)
        data class FocusTile(val key: String?, val label: String, val value: String, val unit: String, val values: List<Double>)
        val tiles = series.map { (m, v) -> FocusTile(m.key, stringResource(m.titleRes), focusValue(v.last(), m), focusUnit(m), v.takeLast(30)) } +
            (if (energy.isNotEmpty()) listOf(FocusTile("energy", stringResource(R.string.forge_fm_energy),
                java.text.NumberFormat.getIntegerInstance(Locale.getDefault()).format(energy.last().roundToInt()), "kcal", energy.takeLast(30))) else emptyList())
        if (tiles.isNotEmpty()) {
            tiles.chunked(2).forEach { pair ->
                Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                    pair.forEach { t ->
                        val key = t.key
                        val values = t.values
                        MetricTile(area.icon, tint, t.label, t.value, t.unit.ifEmpty { null }, noData,
                                   Modifier.weight(1f).clickable(role = Role.Button) {
                                       com.noop.ui.ExploreLaunch.pendingKey = key?.let(com.noop.ui.ExploreLaunch::exploreKey); onOpen(if (key == "energy") MoreDest.Energy else MoreDest.Explore)
                                   },
                                   below = values.takeIf { it.size > 1 }?.let { v -> @Composable { KeyTileSpark(v, tint) } })
                    }
                    if (pair.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        } else if (area.measures().isNotEmpty()) {
            Text(stringResource(R.string.forge_fo_none), style = Forge.type.body, color = Forge.sceneInk.secondary,
                 modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        }
        val links = focusLinks(area, context).filter { it.dest == null || it.dest.shown(context) }
        if (links.isNotEmpty()) {
            Text(stringResource(R.string.forge_fo_in_area), style = Forge.type.title2, color = Forge.sceneInk.text,
                 modifier = Modifier.padding(horizontal = ForgeMetrics.space1, vertical = ForgeMetrics.space2))
            ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
                links.forEachIndexed { i, l ->
                    TrainingGroupRow(l.icon, l.tint, if (l.titleRes == R.string.forge_fl_ageless_sub) "AgeLess" else stringResource(l.titleRes),
                                     stringResource(l.subRes), i > 0) { l.dest?.let(onOpen) ?: l.action?.let(onAction) }
                }
            }
        }
        Spacer(Modifier.height(ForgeMetrics.space6))
    }
}

/** The last seven days' Charge, Effort and Rest as small nested rings, as iOS's `weekInRings`. Opens Trends. */
@Composable
internal fun HealthWeekInRings(days: List<DailyMetric>, onOpen: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val week = days.takeLast(7)
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val rest by produceState(emptyMap<String, Double>(), week.firstOrNull()?.day, coreRevision) {
        val from = week.firstOrNull()?.day ?: return@produceState
        value = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreRead.series(CoreRead.Metric.Rest, from, week.last().day).associate { it.day to it.value }
        }
    }
    if (week.isEmpty()) return
    val locale = Locale.getDefault()
    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen)) {
        Text(stringResource(R.string.forge_hf_week_rings), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
             color = colors.textSecondary)
        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth().clearAndSetSemantics { }) {
            week.forEach { d ->
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    MiniRings(d.recovery, d.strain, rest[d.day])
                    Spacer(Modifier.height(4.dp))
                    Text(runCatching { LocalDate.parse(d.day).dayOfWeek.getDisplayName(TextStyle.NARROW, locale) }.getOrDefault(""),
                         style = Forge.type.caption, color = colors.textSecondary, textAlign = TextAlign.Center)
                }
            }
        }
    }
}

/** Charge outside, Effort in the middle, Rest inside, each a share of its own full ring. */
@Composable
private fun MiniRings(charge: Double?, effort: Double?, rest: Double?) {
    val colors = Forge.colors
    Canvas(Modifier.size(34.dp)) {
        val w = 3.dp.toPx()
        listOf(charge to colors.charge, effort to colors.effort, rest to colors.rest).forEachIndexed { i, (v, c) ->
            val inset = w / 2 + i * (w + 1.dp.toPx())
            val arc = Size(size.width - inset * 2, size.height - inset * 2)
            drawArc(c.copy(alpha = 0.18f), 0f, 360f, false, Offset(inset, inset), arc, style = Stroke(w))
            val f = ((v ?: 0.0) / 100).coerceIn(0.0, 1.0).toFloat()
            if (f > 0f) drawArc(c, -90f, 360f * f, false, Offset(inset, inset), arc, style = Stroke(w, cap = StrokeCap.Round))
        }
    }
}
