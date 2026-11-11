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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreRead
import com.noop.ui.AppViewModel
import com.noop.ui.EffortScale
import com.noop.ui.UnitFormatter
import com.noop.ui.UnitPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.roundToInt

/*
 * Fork (DX23876), Forge parity 2026-11: the new design's Effort and Rest pages, as iOS's `ForgeEffortDetailView` and
 * `ForgeRestDetailView` (ForgeScoreDetailViews.swift): the ring with its verdict, the sentence, why it is what it is,
 * the last 14 days with History one tap away, and how the score is made. Today's rings open them in the new design.
 */

/** Today's Effort target in stored 0 to 100 units from the morning's Charge, as iOS's `effortTargetStored`. */
internal fun effortTargetStored(charge: Double?): ClosedFloatingPointRange<Double>? =
    com.noop.ui.optimalStrainRange(charge)?.let { (it.low * 100.0 / 21)..(it.high * 100.0 / 21) }

@Composable
private fun ScorePageHead(title: String, overline: String, onBack: () -> Unit) {
    PageTitle(title, onBack)
    Text(overline, style = Forge.type.subhead, color = Forge.sceneInk.secondary,
         modifier = Modifier.padding(start = ForgeMetrics.space4))
}

/** The score's ring with its verdict in the score's colour under it and the page's sentence, centred. */
@Composable
private fun ScoreHero(value: Double?, tint: Color, metric: OrganicMetric, verdict: String?, name: String, sentence: String?,
                      format: ((Double) -> String)? = null) {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        if (format != null) OrganicRing(value, tint, 170.dp, metric, format = format) else OrganicRing(value, tint, 170.dp, metric)
        Spacer(Modifier.height(ForgeMetrics.space3))
        Text(verdict?.replaceFirstChar { it.titlecase(Locale.getDefault()) } ?: name,
             style = Forge.type.title2.copy(fontWeight = FontWeight.SemiBold), color = tint)
        sentence?.let {
            Spacer(Modifier.height(ForgeMetrics.space2))
            Text(it, style = Forge.type.body, color = Forge.colors.text, textAlign = TextAlign.Center)
        }
    }
}

/**
 * "Last 14 days" as iOS's `ForgeDailyChart`: the title with History beside it, one mark per day (bars or a line),
 * an optional band per day behind them, the score on the right and the weekday under each mark.
 */
@Composable
internal fun ScoreDailyChart(points: List<Pair<String, Double>>, maxValue: Double, tint: Color, bars: Boolean,
                             bands: List<ClosedFloatingPointRange<Double>?> = emptyList(), caption: String? = null,
                             onHistory: (() -> Unit)? = null) {
    val colors = Forge.colors
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space1), verticalAlignment = Alignment.Bottom) {
            Text(stringResource(R.string.forge_sp_last14), style = Forge.type.title2, color = Forge.sceneInk.text,
                 modifier = Modifier.weight(1f))
            if (onHistory != null) Text(stringResource(R.string.forge_sp_history), style = Forge.type.subhead, color = colors.accent,
                                        modifier = Modifier.clickable(role = Role.Button, onClick = onHistory).padding(4.dp))
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            if (points.size < 2) {
                Text(stringResource(R.string.forge_sp_not_enough), style = Forge.type.body, color = colors.textSecondary)
                return@ForgeCard
            }
            val ticks = if (maxValue <= 21) listOf(0.0, 7.0, 14.0, 21.0) else listOf(0.0, 50.0, 100.0)
            Row {
                Canvas(Modifier.weight(1f).height(150.dp)) {
                    val n = points.size
                    val slot = size.width / n
                    fun y(v: Double) = (size.height - v / maxValue * size.height).toFloat()
                    ticks.forEach { t -> drawLine(colors.divider, Offset(0f, y(t)), Offset(size.width, y(t)), strokeWidth = 0.5.dp.toPx()) }
                    bands.forEachIndexed { i, b ->
                        if (b != null) drawRect(tint.copy(alpha = 0.18f), Offset(i * slot, y(b.endInclusive)),
                                                Size(slot, y(b.start) - y(b.endInclusive)))
                    }
                    if (bars) {
                        val w = slot * 0.62f
                        points.forEachIndexed { i, (_, v) ->
                            val top = y(v.coerceIn(0.0, maxValue))
                            drawRoundRect(tint.copy(alpha = if (i == n - 1) 1f else 0.6f), Offset(i * slot + (slot - w) / 2, top),
                                          Size(w, size.height - top), CornerRadius(4.dp.toPx(), 4.dp.toPx()))
                        }
                    } else {
                        val path = Path()
                        points.forEachIndexed { i, (_, v) ->
                            val x = i * slot + slot / 2; val yy = y(v.coerceIn(0.0, maxValue))
                            if (i == 0) path.moveTo(x, yy) else path.lineTo(x, yy)
                        }
                        drawPath(path, tint, style = Stroke(2.2.dp.toPx(), cap = StrokeCap.Round))
                        val last = points.last().second.coerceIn(0.0, maxValue)
                        drawCircle(tint, 4.dp.toPx(), Offset((n - 1) * slot + slot / 2, y(last)))
                    }
                }
                Column(Modifier.width(26.dp).height(150.dp), verticalArrangement = Arrangement.SpaceBetween,
                       horizontalAlignment = Alignment.End) {
                    ticks.reversed().forEach { Text(it.roundToInt().toString(), style = Forge.type.caption, color = colors.textTertiary) }
                }
            }
            Row(Modifier.fillMaxWidth().padding(end = 26.dp, top = 4.dp)) {
                val locale = Locale.getDefault()
                points.forEachIndexed { i, (day, _) ->
                    val letter = runCatching { LocalDate.parse(day).dayOfWeek.getDisplayName(TextStyle.NARROW, locale) }.getOrDefault("")
                    Text(letter, style = Forge.type.caption, color = if (i == points.lastIndex) colors.text else colors.textTertiary,
                         textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
                }
            }
            caption?.let {
                Spacer(Modifier.height(ForgeMetrics.space2))
                Text(it, style = Forge.type.footnote, color = colors.textSecondary)
            }
        }
    }
}

/** "How X is made": a heading and one short paragraph, as iOS's `ForgeExplainer`. */
@Composable
private fun ScoreExplainer(title: String, text: String) {
    Column(Modifier.padding(horizontal = ForgeMetrics.space1), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = Forge.type.title2, color = Forge.sceneInk.text)
        Text(text, style = Forge.type.body, color = Forge.sceneInk.secondary)
    }
}

/** One "Why N?" row, as iOS's `ForgeWhyRow`: the factor, its value, its direction, the 0 to 100 track with the usual. */
@Composable
private fun WhyRow(label: String, value: String, delta: Int, usual: String?, track: Pair<Double, Double?>?) {
    val colors = Forge.colors
    val dot = when { delta > 0 -> colors.charge; delta < 0 -> colors.effort; else -> colors.textSecondary }
    Column(Modifier.fillMaxWidth().padding(vertical = 12.dp).semantics(mergeDescendants = true) { }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text, modifier = Modifier.weight(1f))
            Text(value, style = Forge.type.bodyNumber.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(when { delta > 0 -> "↑"; delta < 0 -> "↓"; else -> "–" }, style = Forge.type.subhead, color = dot)
        }
        track?.let { (v, u) ->
            Spacer(Modifier.height(6.dp))
            Canvas(Modifier.fillMaxWidth().height(14.dp)) {
                val h = 6.dp.toPx(); val cy = size.height / 2
                drawRoundRect(colors.inset, Offset(0f, cy - h / 2), Size(size.width, h), CornerRadius(h / 2, h / 2))
                u?.let { drawRoundRect(colors.charge.copy(alpha = 0.55f), Offset((size.width * (it / 100)).toFloat() - 1.5f, 0f),
                                       Size(3.dp.toPx(), size.height), CornerRadius(1.5f, 1.5f)) }
                val x = (size.width * (v / 100)).toFloat().coerceIn(7.dp.toPx(), size.width - 7.dp.toPx())
                drawCircle(colors.surface, 7.dp.toPx(), Offset(x, cy)); drawCircle(dot, 5.dp.toPx(), Offset(x, cy))
            }
        }
        usual?.let { Text(it, style = Forge.type.footnote, color = colors.textSecondary, modifier = Modifier.padding(top = 4.dp)) }
    }
}

/** The new design's Effort page (iOS `ForgeEffortDetailView`). */
@Composable
internal fun ForgeEffortPage(viewModel: AppViewModel, effortStored: Double?, charge: Double?, onBack: () -> Unit,
                             onHistory: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val scale = remember { UnitPrefs.effortScale(context) }
    val format = rememberEffortFormat()
    val max = if (scale == EffortScale.WHOOP) 21.0 else 100.0
    fun shown(v: Double) = UnitFormatter.effortValue(v, scale)
    fun whole(v: Double) = shown(v).roundToInt().toString()
    val target = effortTargetStored(charge)
    val workouts by viewModel.workouts.collectAsState()
    val today = LocalDate.now(ZoneId.systemDefault())
    val todays = workouts.filter { java.time.Instant.ofEpochSecond(it.startTs).atZone(ZoneId.systemDefault()).toLocalDate() == today }
        .sortedByDescending { it.startTs }
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val days by produceState(emptyList<Triple<String, Double, Double?>>(), coreRevision) {
        value = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val from = today.minusDays(30).toString(); val to = today.toString()
            val charges = CoreRead.series(CoreRead.Metric.Charge, from, to).associate { it.day to it.value }
            CoreRead.series(CoreRead.Metric.Effort, from, to).takeLast(14).map { Triple(it.day, it.value, charges[it.day]) }
        }
    }
    val sentence = if (effortStored != null && target != null) {
        val res = when {
            effortStored < target.start -> R.string.forge_sp_below
            effortStored > target.endInclusive -> R.string.forge_sp_above
            else -> R.string.forge_sp_inside
        }
        stringResource(res, format(effortStored), whole(target.start), whole(target.endInclusive))
    } else null
    SettingsColumn {
        ScorePageHead(stringResource(R.string.forge_effort), stringResource(R.string.forge_sp_today), onBack)
        ScoreHero(effortStored, colors.effort, OrganicMetric.Effort,
                  target?.let { stringResource(R.string.forge_sp_target, whole(it.start), whole(it.endInclusive)) },
                  stringResource(R.string.forge_effort), sentence, format)
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(effortStored?.let { stringResource(R.string.forge_sp_why, format(it)) } ?: stringResource(R.string.forge_sp_added),
                 style = Forge.type.title2, color = Forge.sceneInk.text, modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
            if (todays.isEmpty()) {
                Text(stringResource(R.string.forge_sp_no_workout), style = Forge.type.body, color = Forge.sceneInk.secondary,
                     modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
            } else ForgeCard(Modifier.fillMaxWidth()) {
                val clock = rememberClockFormatter()
                todays.forEachIndexed { i, row ->
                    if (i > 0) Box(Modifier.fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider))
                    val minutes = ((row.durationS ?: (row.endTs - row.startTs).toDouble()) / 60).toInt()
                    Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(com.noop.ui.WorkoutEditing.displaySport(row.sport), style = Forge.type.body, color = colors.text)
                            Text(stringResource(R.string.forge_pair_words,
                                                java.time.Instant.ofEpochSecond(row.startTs).atZone(ZoneId.systemDefault()).format(clock),
                                                stringResource(R.string.forge_tw_min, minutes)),
                                 style = Forge.type.footnote, color = colors.textSecondary)
                        }
                        row.strain?.let { s ->
                            Column(horizontalAlignment = Alignment.End) {
                                Text(format(s), style = Forge.type.headline, color = colors.text)
                                Text(stringResource(R.string.forge_effort), style = Forge.type.caption, color = colors.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        ScoreDailyChart(days.map { it.first to shown(it.second) }, max, colors.effort, bars = true,
                        bands = days.map { d -> effortTargetStored(d.third)?.let { shown(it.start)..shown(it.endInclusive) } },
                        caption = stringResource(R.string.forge_sp_band), onHistory = onHistory)
        ScoreExplainer(stringResource(R.string.forge_sp_effort_how), stringResource(R.string.forge_sp_effort_how_text))
        Spacer(Modifier.height(ForgeMetrics.space6))
    }
}

/** The new design's Rest page (iOS `ForgeRestDetailView`), reading the Sleep tab's own night and model. */
@Composable
internal fun ForgeRestPage(viewModel: AppViewModel, rest: Double?, onBack: () -> Unit, onHistory: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val recentDays by viewModel.recentDays.collectAsState()
    val night by produceState<CoreRead.Night?>(null, coreRevision) {
        value = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val now = System.currentTimeMillis() / 1000
            CoreRead.nights(now - 3 * 86_400, now + 86_400).maxByOrNull { it.endTs }
        }
    }
    val model by produceState<com.noop.ui.SleepModel?>(null, coreRevision, recentDays) {
        value = withContext(Dispatchers.IO) { runCatching { nightDetailModel(viewModel, recentDays) }.getOrNull() }
    }
    val days by produceState(emptyList<Pair<String, Double>>(), coreRevision) {
        value = withContext(Dispatchers.IO) {
            val today = LocalDate.now()
            CoreRead.series(CoreRead.Metric.Rest, today.minusDays(30).toString(), today.toString()).takeLast(14).map { it.day to it.value }
        }
    }
    val clock = rememberClockFormatter()
    SettingsColumn {
        ScorePageHead(stringResource(R.string.forge_rest), stringResource(R.string.forge_last_night), onBack)
        val sentence = night?.let { n ->
            val zone = ZoneId.systemDefault()
            stringResource(R.string.forge_sp_asleep_span, TodayTimeline.hoursMinutes(SleepSummary.of(n).asleepMin.toDouble()),
                           java.time.Instant.ofEpochSecond(n.startTs).atZone(zone).format(clock),
                           java.time.Instant.ofEpochSecond(n.endTs).atZone(zone).format(clock))
        }
        ScoreHero(rest, colors.rest, OrganicMetric.Rest, rest?.let { stringResource(RestWord.of(it)) },
                  stringResource(R.string.forge_rest), sentence)
        model?.let { m ->
            val factors = listOf(stringResource(R.string.forge_sp_hours_need) to m.hoursVsNeeded,
                                 stringResource(R.string.forge_sl_efficiency) to m.efficiency,
                                 stringResource(R.string.forge_sp_consistency) to m.consistency,
                                 stringResource(R.string.forge_sl_restorative) to m.restorative)
                .filter { !((it.second.latest ?: 0.0) == 0.0 && (it.second.typical ?: 0.0) == 0.0) }
            if (factors.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(rest?.let { stringResource(R.string.forge_sp_why, "${it.roundToInt()} %") } ?: stringResource(R.string.forge_sp_shaped),
                     style = Forge.type.title2, color = Forge.sceneInk.text, modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
                ForgeCard(Modifier.fillMaxWidth()) {
                    factors.forEachIndexed { i, (label, metric) ->
                        if (i > 0) Box(Modifier.fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider))
                        val latest = metric.latest; val typical = metric.typical
                        val delta = if (latest != null && typical != null) {
                            if (latest - typical >= 2) 1 else if (latest - typical <= -2) -1 else 0
                        } else 0
                        WhyRow(label, latest?.let { "${it.roundToInt()} %" } ?: "–", delta,
                               typical?.let { stringResource(R.string.forge_sp_usually, it.roundToInt()) },
                               latest?.let { it to typical })
                    }
                }
            }
        }
        ScoreDailyChart(days, 100.0, colors.rest, bars = false, onHistory = onHistory)
        ScoreExplainer(stringResource(R.string.forge_sp_rest_how), stringResource(R.string.forge_sp_rest_how_text))
        Spacer(Modifier.height(ForgeMetrics.space6))
    }
}
