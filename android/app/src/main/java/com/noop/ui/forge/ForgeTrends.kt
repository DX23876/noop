package com.noop.ui.forge

import android.text.format.DateFormat
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.ChevronLeft
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material.icons.rounded.IosShare
import com.noop.analytics.WeeklyDigestEngine
import com.noop.analytics.WeeklyMetric
import com.noop.analytics.WeeklyMetricSummary
import com.noop.ui.UnitPrefs
import com.noop.ui.effortDisplayFactor
import androidx.compose.foundation.layout.size
import com.noop.R
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * A metric over the chosen window beside the same number of days before it. [change] is the relative change of
 * the averages in percent, null when either window has no value.
 */
data class TrendStats(val current: List<CoreRead.Point>, val average: Double?, val previousAverage: Double?) {
    val change: Int? get() = if (average != null && previousAverage != null && previousAverage != 0.0)
        ((average - previousAverage) / previousAverage * 100).roundToInt() else null

    companion object {
        /** Splits [points] into the [days] ending with [today] and the [days] before them. */
        fun of(points: List<CoreRead.Point>, days: Int, today: LocalDate): TrendStats {
            val start = today.minusDays(days - 1L).toString()
            val previousStart = today.minusDays(2L * days - 1).toString()
            val current = points.filter { it.day >= start && it.day <= today.toString() }
            val previous = points.filter { it.day >= previousStart && it.day < start }
            return TrendStats(current, current.map { it.value }.average().takeIf { current.isNotEmpty() },
                              previous.map { it.value }.average().takeIf { previous.isNotEmpty() })
        }
    }
}

private const val SHORT_DATE_SKELETON = "dMMM"

private val windows = listOf(7 to R.string.forge_days_7, 30 to R.string.forge_days_30, 90 to R.string.forge_days_90)

/** The Trends ranges as iOS offers them (`TrendsView.Range`): trailing days, null for all history. */
private enum class TrendRange(val days: Int?, val labelRes: Int, val nameRes: Int) {
    Week(7, R.string.forge_tr_w, R.string.forge_tr_week),
    Month(30, R.string.forge_tr_m, R.string.forge_tr_month),
    Quarter(90, R.string.forge_tr_3m, R.string.forge_tr_3months),
    Half(180, R.string.forge_tr_6m, R.string.forge_tr_6months),
    Year(365, R.string.forge_tr_1y, R.string.forge_tr_year),
    All(null, R.string.forge_tr_all, R.string.forge_tr_all_lower),
}

/**
 * Fork (DX23876), Android parity plan 2.3: Trends as iOS lays it out (`TrendsView`): the week in review with its week
 * stepper (the three week means as rings with their change against the week before, and the digest's sentences),
 * the range bar (W, M, 3M, 6M, 1Y, ALL with the trailing caption and the reading count), Charge over the range, the
 * daily signals (heart rate variability, resting heart rate, Effort) and the link to the long training history.
 * Every series comes from the shared core; the digest is the same `WeeklyDigestEngine` the classic card used.
 */
@Composable
fun ForgeTrendsScreen(padding: PaddingValues, width: ForgeWidth) {
    val context = LocalContext.current
    var rangeName by rememberSaveable { mutableStateOf(TrendRange.Quarter.name) }
    val range = TrendRange.valueOf(rangeName)
    var weekOffset by rememberSaveable { mutableIntStateOf(0) }
    var history by remember { mutableStateOf(false) }
    var series by remember { mutableStateOf<Map<CoreRead.Metric, List<CoreRead.Point>>?>(null) }
    LaunchedEffect(Unit) {
        series = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val today = LocalDate.now()
            listOf(CoreRead.Metric.Charge, CoreRead.Metric.Effort, CoreRead.Metric.Rest, CoreRead.Metric.Hrv,
                   CoreRead.Metric.RestingHr).associateWith { CoreRead.series(it, "2000-01-01", today.toString()) }
        }
    }
    val today = LocalDate.now()
    val colors = Forge.colors
    val effortFormat = rememberEffortFormat()
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding)
            .padding(horizontal = ForgeMetrics.screenPadding),
        verticalArrangement = Arrangement.spacedBy(ForgeMetrics.sectionGap),
    ) {
        Column(Modifier.padding(top = ForgeMetrics.space4)) {
            Text(stringResource(R.string.nav_trends), style = Forge.type.title1, color = Forge.sceneInk.text)
            Text(stringResource(R.string.forge_trends_subtitle), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
        }
        val all = series ?: return@Column
        if (all.values.all { it.isEmpty() }) {
            Text(stringResource(R.string.forge_not_enough_days), style = Forge.type.body, color = Forge.sceneInk.secondary)
            return@Column
        }
        WeekReview(all, today, weekOffset, onStep = { weekOffset = it })
        RangeBar(range, all[CoreRead.Metric.Charge].orEmpty(), today) { rangeName = it.name }
        fun window(m: CoreRead.Metric) = inRange(all[m].orEmpty(), range, today)
        val subtitle = range.days?.let { stringResource(R.string.forge_tr_trailing_days, it) }
            ?: stringResource(R.string.forge_tr_all_history)
        val tall = width != ForgeWidth.Compact
        RangeCard(stringResource(R.string.forge_charge), subtitle, "", window(CoreRead.Metric.Charge), range, today,
                  colors.charge, higherIsBetter = true, tall = tall)
        SectionHeader(stringResource(R.string.forge_tr_daily_signals))
        RangeCard(stringResource(R.string.forge_tr_hrv), subtitle, stringResource(R.string.forge_unit_ms),
                  window(CoreRead.Metric.Hrv), range, today, colors.accent, higherIsBetter = true, tall = tall)
        RangeCard(stringResource(R.string.forge_tr_rhr), subtitle, stringResource(R.string.forge_unit_bpm),
                  window(CoreRead.Metric.RestingHr), range, today, colors.heart, higherIsBetter = false, tall = tall)
        RangeCard(stringResource(R.string.forge_effort), subtitle, "", window(CoreRead.Metric.Effort), range, today,
                  colors.effort, higherIsBetter = null, tall = tall, format = effortFormat)
        LargeRow(Icons.Rounded.BarChart, ForgeTokens.Color.systemOrange.resolve(),
                 stringResource(R.string.forge_tr_training_history), stringResource(R.string.forge_tr_training_history_sub)) {
            history = true
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
    }
    if (history) {
        ForgeOverlayPage(onDismiss = { history = false }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) { ForgeTrainingHistoryPage(onClose = { history = false }) }
        }
    }
}

/** The points inside [range] ending today; all of them for all history. */
private fun inRange(points: List<CoreRead.Point>, range: TrendRange, today: LocalDate): List<CoreRead.Point> {
    val days = range.days ?: return points.filter { it.day <= today.toString() }
    val start = today.minusDays(days - 1L).toString()
    return points.filter { it.day >= start && it.day <= today.toString() }
}

/** The week in review (`TrendsView.weeklyDigestNav`): the stepper, the rings, the digest's sentences. */
@Composable
private fun WeekReview(all: Map<CoreRead.Metric, List<CoreRead.Point>>, today: LocalDate, offset: Int, onStep: (Int) -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    fun map(m: CoreRead.Metric) = all[m].orEmpty().associate { it.day to it.value }
    val factor = effortDisplayFactor(UnitPrefs.effortScale(context))
    val anchor = today.plusWeeks(offset.toLong()).toString()
    val digest = WeeklyDigestEngine.build(mapOf(
        WeeklyMetric.CHARGE to map(CoreRead.Metric.Charge), WeeklyMetric.EFFORT to map(CoreRead.Metric.Effort),
        WeeklyMetric.REST to map(CoreRead.Metric.Rest), WeeklyMetric.RHR to map(CoreRead.Metric.RestingHr),
        WeeklyMetric.HRV to map(CoreRead.Metric.Hrv)), anchor, factor)
    val earliest = all.values.flatten().minOfOrNull { it.day }?.let(LocalDate::parse) ?: today
    val minOffset = -(java.time.temporal.ChronoUnit.WEEKS.between(earliest, today)).toInt()
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { onStep(maxOf(minOffset, offset - 1)) }, enabled = offset > minOffset) {
                Icon(Icons.Rounded.ChevronLeft, stringResource(R.string.forge_tr_prev_week),
                     tint = if (offset > minOffset) colors.accent else colors.textTertiary)
            }
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(when (offset) {
                    0 -> stringResource(R.string.forge_tr_this_week)
                    -1 -> stringResource(R.string.forge_tr_last_week)
                    else -> stringResource(R.string.forge_tr_weeks_ago, -offset)
                }, style = Forge.type.headline, color = Forge.sceneInk.text)
                val daysLine = joinDot(weekRange(digest.weekStart, digest.weekEnd),
                                       stringResource(R.string.forge_tr_days_of_7, digest.daysWithData))
                Text(daysLine,
                     style = Forge.type.subhead, color = Forge.sceneInk.secondary, maxLines = 1)
            }
            IconButton(onClick = { onStep(minOf(0, offset + 1)) }, enabled = offset < 0) {
                Icon(Icons.Rounded.ChevronRight, stringResource(R.string.forge_tr_next_week),
                     tint = if (offset < 0) colors.accent else colors.textTertiary)
            }
        }
        if (digest.isEmpty) {
            ForgeCard(Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_tr_no_readings), style = Forge.type.headline, color = colors.text)
                Text(stringResource(R.string.forge_tr_no_readings_note), style = Forge.type.subhead, color = colors.textSecondary)
            }
            return@Column
        }
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.heroRadius) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                val charge = digest.summary(WeeklyMetric.CHARGE)
                WeekRing(R.string.forge_charge, charge,
                         charge?.thisWeek?.takeIf { it.n > 0 }?.mean?.let { colors.chargeRing(it) } ?: colors.charge,
                         OrganicMetric.Charge)
                WeekRing(R.string.forge_effort, digest.summary(WeeklyMetric.EFFORT), colors.effort, OrganicMetric.Effort,
                         rememberEffortFormat())
                WeekRing(R.string.forge_rest, digest.summary(WeeklyMetric.REST), colors.rest, OrganicMetric.Rest)
            }
        }
        if (digest.focalPoints.isNotEmpty()) {
            ForgeCard(Modifier.fillMaxWidth()) {
                digest.focalPoints.forEach { line ->
                    Row(verticalAlignment = Alignment.Top) {
                        Icon(Icons.Rounded.AutoAwesome, null, tint = colors.accent, modifier = Modifier.size(18.dp).padding(top = 2.dp))
                        Spacer(Modifier.width(ForgeMetrics.space2))
                        Text(line, style = Forge.type.body, color = colors.text)
                    }
                }
            }
        }
        // "Share recap": iOS shares the card as an image; Android hands the same recap to the share sheet as text.
        val title = when (offset) {
            0 -> stringResource(R.string.forge_tr_this_week)
            -1 -> stringResource(R.string.forge_tr_last_week)
            else -> stringResource(R.string.forge_tr_weeks_ago, -offset)
        }
        val labels = listOf(stringResource(R.string.forge_charge) to WeeklyMetric.CHARGE,
                            stringResource(R.string.forge_effort) to WeeklyMetric.EFFORT,
                            stringResource(R.string.forge_rest) to WeeklyMetric.REST)
        val chooser = stringResource(R.string.forge_tr_share_recap)
        androidx.compose.material3.Button(colors = androidx.compose.material3.ButtonDefaults.buttonColors(
            containerColor = colors.surface, contentColor = colors.text), onClick = {
            val text = buildString {
                appendLine("NOOP · $title (${weekRange(digest.weekStart, digest.weekEnd)})")
                labels.forEach { (label, metric) ->
                    digest.summary(metric)?.thisWeek?.takeIf { it.n > 0 }?.let { appendLine("$label: ${it.mean.roundToInt()}") }
                }
                digest.focalPoints.forEach { appendLine("• $it") }
            }.trim()
            val send = android.content.Intent(android.content.Intent.ACTION_SEND).setType("text/plain")
                .putExtra(android.content.Intent.EXTRA_TEXT, text)
            context.startActivity(android.content.Intent.createChooser(send, chooser))
        }) {
            Icon(Icons.Rounded.IosShare, null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(chooser, style = Forge.type.headline)
        }
    }
}

private fun joinDot(a: String, b: String) = "$a · $b"
private fun withUnit(value: String, unit: String) = if (unit.isEmpty()) value else "$value $unit"
private fun signedValue(d: Double, format: (Double) -> String) = (if (d >= 0) "+" else "−") + format(kotlin.math.abs(d))

/** The week-over-week chip: an arrow and the change; below one percent "<1%", as the digest card says it. */
private fun weekChip(pct: Double): String {
    val arrow = if (pct >= 0) "↗" else "↘"
    val size = if (kotlin.math.abs(pct) < 1) "<1%" else "${if (pct >= 0) "+" else "−"}${kotlin.math.abs(pct).roundToInt()}%"
    return "$arrow $size"
}

private fun weekRange(start: String, end: String): String {
    val locale = Locale.getDefault()
    val f = DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, SHORT_DATE_SKELETON), locale)
    return "${LocalDate.parse(start).format(f)}–${LocalDate.parse(end).format(f)}"
}

/** One week mean as Today's organic ring, its label above and its week-over-week change as a chip below. */
@Composable
private fun WeekRing(labelRes: Int, s: WeeklyMetricSummary?, tint: Color, metric: OrganicMetric,
                     format: (Double) -> String = WHOLE_NUMBER) {
    val colors = Forge.colors
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(stringResource(labelRes).uppercase(), style = Forge.type.overline, color = tint, maxLines = 1)
        OrganicRing(s?.thisWeek?.takeIf { it.n > 0 }?.mean, tint, 96.dp, metric, format = format)
        val pct = s?.weekOverWeek?.pctChange
        if (s != null && pct != null && s.weekOverWeek.current.n > 0 && s.weekOverWeek.previous.n > 0) {
            val chip = when {
                s.isRoughComparison || s.wowGoodness == 0 -> colors.textTertiary
                s.wowGoodness > 0 -> colors.recoveryStops.last().second
                else -> colors.recoveryStops.first().second
            }
            Text(weekChip(pct), style = Forge.type.captionNumber,
                 color = chip, maxLines = 1,
                 modifier = Modifier.background(chip.copy(alpha = 0.14f), RoundedCornerShape(percent = 50))
                     .padding(horizontal = 8.dp, vertical = 2.dp))
        } else Text(" ", style = Forge.type.captionNumber)
    }
}

/** The range pills with the trailing caption beside them and the reading count below (`TrendsView.rangeBar`). */
@Composable
private fun RangeBar(range: TrendRange, charge: List<CoreRead.Point>, today: LocalDate, onPick: (TrendRange) -> Unit) {
    val colors = Forge.colors
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f).background(colors.heroFill, RoundedCornerShape(percent = 50)).padding(3.dp)) {
                TrendRange.entries.forEach { r ->
                    val selected = r == range
                    Box(Modifier.weight(1f).height(36.dp)
                            .background(if (selected) colors.surfaceTop else Color.Transparent, RoundedCornerShape(percent = 50))
                            .clickable(role = Role.Tab) { onPick(r) },
                        contentAlignment = Alignment.Center) {
                        Text(stringResource(r.labelRes), style = Forge.type.subhead,
                             color = if (selected) colors.text else colors.textSecondary, maxLines = 1)
                    }
                }
            }
            Spacer(Modifier.width(ForgeMetrics.space2))
            Column {
                if (range.days != null) {
                    Text(stringResource(R.string.forge_tr_trailing).uppercase(), style = Forge.type.overline, color = Forge.sceneInk.secondary)
                    Text(stringResource(R.string.forge_tr_n_days, range.days).uppercase(), style = Forge.type.overline,
                         color = Forge.sceneInk.secondary)
                } else Text(stringResource(R.string.forge_tr_all_history).uppercase(), style = Forge.type.overline,
                            color = Forge.sceneInk.secondary)
            }
        }
        val n = inRange(charge, range, today).size
        val name = stringResource(range.nameRes)
        Text(if (n == 1) stringResource(R.string.forge_tr_one_reading, name) else stringResource(R.string.forge_tr_readings, n, name),
             style = Forge.type.footnote, color = Forge.sceneInk.tertiary)
    }
}

/**
 * One metric over the range as iOS's `ChartCard`: the title and the trailing caption, the latest reading on the right,
 * the line with its mean, the axis dates, and the trend chip (the recent half against the earlier half).
 */
@Composable
private fun RangeCard(title: String, subtitle: String, unit: String, points: List<CoreRead.Point>, range: TrendRange,
                      today: LocalDate, tint: Color, higherIsBetter: Boolean?, tall: Boolean,
                      format: (Double) -> String = WHOLE_NUMBER) {
    val colors = Forge.colors
    val locale = Locale.getDefault()
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Text(title.uppercase(), style = Forge.type.overline, color = colors.textSecondary, maxLines = 1,
                     overflow = TextOverflow.Ellipsis)
                Text(subtitle, style = Forge.type.subhead, color = colors.textSecondary)
            }
            points.lastOrNull()?.let {
                Text(withUnit(format(it.value), unit), style = Forge.type.title2, color = colors.text)
            }
        }
        if (points.size < 2) {
            Spacer(Modifier.height(ForgeMetrics.space2))
            Text(stringResource(R.string.forge_not_enough_days), style = Forge.type.body, color = colors.textTertiary)
            return@ForgeCard
        }
        Spacer(Modifier.height(ForgeMetrics.space4))
        val values = points.map { it.value }
        val lo = floor(values.min() / 5) * 5
        val hi = ceil(values.max() / 5) * 5 + if (values.max() == values.min()) 5 else 0
        val first = range.days?.let { today.minusDays(it - 1L) } ?: LocalDate.parse(points.first().day)
        val span = (today.toEpochDay() - first.toEpochDay() + 1).toInt()
        Row(Modifier.fillMaxWidth().height(if (tall) 200.dp else 150.dp)) {
            Column(Modifier.width(32.dp).fillMaxSize(), verticalArrangement = Arrangement.SpaceBetween) {
                Text(format(hi), style = Forge.type.caption, color = colors.textTertiary)
                Text(format((hi + lo) / 2), style = Forge.type.caption, color = colors.textTertiary)
                Text(format(lo), style = Forge.type.caption, color = colors.textTertiary)
            }
            LineChart(points, span, lo, hi, values.average(), tint, Modifier.weight(1f).fillMaxSize())
        }
        val f = DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, SHORT_DATE_SKELETON), locale)
        Row(Modifier.fillMaxWidth().padding(start = 32.dp, top = ForgeMetrics.space1), verticalAlignment = Alignment.CenterVertically) {
            Text(first.format(f), style = Forge.type.caption, color = colors.textTertiary)
            Spacer(Modifier.weight(1f))
            Text(today.format(f), style = Forge.type.caption, color = colors.textTertiary)
        }
        // `TrendsView.periodChange`: the mean of the recent half against the earlier half, from four readings on.
        if (values.size >= 4) {
            val mid = values.size / 2
            val d = values.drop(mid).average() - values.take(mid).average()
            if (kotlin.math.abs(d) > 0.0001) {
                val chip = when {
                    higherIsBetter == null -> colors.textTertiary
                    (d > 0) == higherIsBetter -> colors.recoveryStops.last().second
                    else -> colors.recoveryStops.first().second
                }
                Spacer(Modifier.height(ForgeMetrics.space2))
                Text(stringResource(R.string.forge_tr_trend).uppercase(), style = Forge.type.footnote, color = colors.textTertiary)
                Text(signedValue(d, format), style = Forge.type.captionNumber, color = chip,
                     modifier = Modifier.background(chip.copy(alpha = 0.14f), RoundedCornerShape(percent = 50))
                         .padding(horizontal = 8.dp, vertical = 2.dp))
            }
        }
    }
}

@Composable
private fun WindowPicker(days: Int, onPick: (Int) -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().background(colors.heroFill, RoundedCornerShape(percent = 50)).padding(4.dp)) {
        windows.forEach { (d, label) ->
            val selected = d == days
            Box(
                Modifier.weight(1f).height(ForgeMetrics.minHitTarget - 4.dp)
                    .background(if (selected) colors.surfaceTop else Color.Transparent, RoundedCornerShape(percent = 50))
                    .clickable(role = Role.Tab) { onPick(d) },
                contentAlignment = Alignment.Center,
            ) {
                Text(stringResource(label), style = Forge.type.headline,
                     color = if (selected) colors.text else colors.textSecondary, maxLines = 1)
            }
        }
    }
}

/** The colour a change is drawn in: good, bad, or neutral when neither direction is better. */
@Composable
private fun changeColor(change: Int, higherIsBetter: Boolean?): Color = when {
    higherIsBetter == null || change == 0 -> Forge.colors.textSecondary
    (change > 0) == higherIsBetter -> Forge.colors.recoveryStops.last().second
    else -> Forge.colors.recoveryStops.first().second
}

private fun signed(change: Int) = if (change > 0) "+$change%" else "$change%"

@Composable
private fun AverageRing(labelRes: Int, stats: TrendStats, tint: Color, higherIsBetter: Boolean?, metric: OrganicMetric,
                        format: (Double) -> String = WHOLE_NUMBER) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(stringResource(labelRes).uppercase(), style = Forge.type.overline, color = tint, maxLines = 1)
        OrganicRing(stats.average, tint, 96.dp, metric, format = format)
        val change = stats.change
        Text(change?.let(::signed) ?: " ", style = Forge.type.captionNumber,
             color = change?.let { changeColor(it, higherIsBetter) } ?: Forge.colors.textTertiary, maxLines = 1)
    }
}

@Composable
private fun TrendCard(titleRes: Int, unit: String, stats: TrendStats, days: Int, tint: Color, higherIsBetter: Boolean,
                      tall: Boolean) {
    val colors = Forge.colors
    val locale = Locale.getDefault()
    ForgeCard(Modifier.fillMaxWidth()) {
        Text(stringResource(titleRes).uppercase(), style = Forge.type.overline, color = colors.textSecondary,
             maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(ForgeMetrics.space1))
        val avg = stats.average
        if (avg == null || stats.current.size < 2) {
            Text(stringResource(R.string.forge_not_enough_days), style = Forge.type.body, color = colors.textTertiary)
            return@ForgeCard
        }
        Text(stringResource(R.string.forge_average_value, stringResource(R.string.forge_value_unit, avg.roundToInt(), unit)), style = Forge.type.title2,
             color = colors.text, maxLines = 1)
        stats.change?.let { change ->
            Text(stringResource(R.string.forge_vs_previous, signed(change), days), style = Forge.type.caption,
                 color = changeColor(change, higherIsBetter), maxLines = 1)
        }
        Spacer(Modifier.height(ForgeMetrics.space4))
        val values = stats.current.map { it.value }
        val lo = floor(values.min() / 5) * 5
        val hi = ceil(values.max() / 5) * 5 + if (values.max() == values.min()) 5 else 0
        Row(Modifier.fillMaxWidth().height(if (tall) 200.dp else 150.dp)) {
            Column(Modifier.width(32.dp).fillMaxSize(), verticalArrangement = Arrangement.SpaceBetween) {
                Text(hi.roundToInt().toString(), style = Forge.type.caption, color = colors.textTertiary)
                Text(((hi + lo) / 2).roundToInt().toString(), style = Forge.type.caption, color = colors.textTertiary)
                Text(lo.roundToInt().toString(), style = Forge.type.caption, color = colors.textTertiary)
            }
            LineChart(stats.current, days, lo, hi, avg, tint, Modifier.weight(1f).fillMaxSize())
        }
        val f = DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, SHORT_DATE_SKELETON), locale)
        Row(Modifier.fillMaxWidth().padding(start = 32.dp, top = ForgeMetrics.space1)) {
            Text(LocalDate.now().minusDays(days - 1L).format(f), style = Forge.type.caption, color = colors.textTertiary)
            Spacer(Modifier.weight(1f))
            Text(LocalDate.now().format(f), style = Forge.type.caption, color = colors.textTertiary)
        }
    }
}

@Composable
private fun LineChart(points: List<CoreRead.Point>, days: Int, lo: Double, hi: Double, average: Double, tint: Color,
                      modifier: Modifier) {
    val colors = Forge.colors
    val first = LocalDate.now().minusDays(days - 1L)
    Canvas(modifier) {
        fun x(p: CoreRead.Point): Float {
            val i = LocalDate.parse(p.day).toEpochDay() - first.toEpochDay()
            return if (days <= 1) size.width / 2 else i.toFloat() / (days - 1) * size.width
        }
        fun y(v: Double): Float = size.height - ((v - lo) / (hi - lo)).toFloat() * size.height
        listOf(lo, (lo + hi) / 2, hi).forEach { v ->
            drawLine(colors.divider.copy(alpha = 0.35f), Offset(0f, y(v)), Offset(size.width, y(v)), strokeWidth = 1f)
        }
        drawLine(tint.copy(alpha = 0.6f), Offset(0f, y(average)), Offset(size.width, y(average)), strokeWidth = 2f,
                 pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 8f)))
        val line = Path()
        points.forEachIndexed { i, p -> if (i == 0) line.moveTo(x(p), y(p.value)) else line.lineTo(x(p), y(p.value)) }
        val fill = Path().apply {
            addPath(line)
            lineTo(x(points.last()), size.height)
            lineTo(x(points.first()), size.height)
            close()
        }
        drawPath(fill, Brush.verticalGradient(listOf(tint.copy(alpha = 0.28f), tint.copy(alpha = 0f))))
        drawPath(line, tint, style = Stroke(width = 5f, cap = StrokeCap.Round))
        if (days <= 30) points.forEach { drawCircle(tint, radius = 6f, center = Offset(x(it), y(it.value))) }
        val lastPoint = points.last()
        drawCircle(colors.surface, radius = 9f, center = Offset(x(lastPoint), y(lastPoint.value)))
        drawCircle(tint, radius = 6f, center = Offset(x(lastPoint), y(lastPoint.value)))
    }
}

/**
 * One metric's trend on its own page, opened from a key-metric tile on Today (iOS opens the metric's detail from the
 * same tile): the window picker and the metric's trend card over the last six months, from the shared core.
 */
@Composable
internal fun ForgeMetricTrendPage(metric: CoreRead.Metric, titleRes: Int, unit: String, tint: Color, higherIsBetter: Boolean,
                                  onAskCoach: ((title: String, summary: String) -> Unit)? = null, onBack: () -> Unit) {
    val context = LocalContext.current
    var days by rememberSaveable { mutableIntStateOf(30) }
    var points by remember { mutableStateOf<List<CoreRead.Point>?>(null) }
    LaunchedEffect(metric) {
        points = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val today = LocalDate.now()
            CoreRead.series(metric, today.minusDays(179).toString(), today.toString())
        }
    }
    SettingsColumn {
        PageTitle(stringResource(titleRes), onBack)
        WindowPicker(days) { days = it }
        val stats = TrendStats.of(points.orEmpty(), days, LocalDate.now())
        TrendCard(titleRes, unit, stats, days, tint, higherIsBetter, tall = true)
        // "Ask coach" (`TodayView`'s card context): what the page shows, as the line the coach reads.
        val title = stringResource(titleRes)
        val latest = stats.current.lastOrNull()
        if (onAskCoach != null && latest != null) {
            val summary = "$title: ${latest.value.roundToInt()} $unit (${latest.day})." +
                (stats.average?.let { " ${days}d average: ${it.roundToInt()} $unit." } ?: "") +
                (stats.change?.let { " Change against the ${days} days before: $it %." } ?: "")
            androidx.compose.material3.TextButton(onClick = { onAskCoach(title, summary) }) {
                Text(stringResource(R.string.forge_ask_coach), style = Forge.type.headline, color = tint)
            }
        }
    }
}

/** A Trends card hosted on Today (Today's "Added cards"): the metric over the trailing 30 days from the core. */
@Composable
internal fun ForgeHostedTrend(metric: CoreRead.Metric) {
    val context = LocalContext.current
    var points by remember { mutableStateOf<List<CoreRead.Point>>(emptyList()) }
    LaunchedEffect(metric) {
        points = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreRead.series(metric, LocalDate.now().minusDays(29).toString(), LocalDate.now().toString())
        }
    }
    val colors = Forge.colors
    val (title, unit, tint, better) = when (metric) {
        CoreRead.Metric.Hrv -> listOf(stringResource(R.string.forge_tr_hrv), stringResource(R.string.forge_unit_ms), colors.accent, true)
        CoreRead.Metric.RestingHr -> listOf(stringResource(R.string.forge_tr_rhr), stringResource(R.string.forge_unit_bpm), colors.heart, false)
        else -> listOf(stringResource(R.string.forge_effort), "", colors.effort, null)
    }
    RangeCard(title as String, stringResource(R.string.forge_tr_trailing_days, 30), unit as String, points, TrendRange.Month,
              LocalDate.now(), tint as Color, better as Boolean?, tall = false)
}
