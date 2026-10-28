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

/**
 * Fork (DX23876), Android plan E-3: Trends on the shared core. The window's average Charge, Effort and Rest as
 * rings with their change against the window before, then heart rate variability and resting heart rate as
 * charts with labelled axes.
 */
@Composable
fun ForgeTrendsScreen(padding: PaddingValues, width: ForgeWidth) {
    val context = LocalContext.current
    var days by rememberSaveable { mutableIntStateOf(7) }
    var series by remember { mutableStateOf<Map<CoreRead.Metric, List<CoreRead.Point>>?>(null) }
    LaunchedEffect(Unit) {
        series = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val today = LocalDate.now()
            val from = today.minusDays(179).toString()
            listOf(CoreRead.Metric.Charge, CoreRead.Metric.Effort, CoreRead.Metric.Rest, CoreRead.Metric.Hrv,
                   CoreRead.Metric.RestingHr).associateWith { CoreRead.series(it, from, today.toString()) }
        }
    }
    val today = LocalDate.now()
    fun stats(m: CoreRead.Metric) = TrendStats.of(series?.get(m).orEmpty(), days, today)
    val colors = Forge.colors
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding)
            .padding(horizontal = ForgeMetrics.screenPadding),
        verticalArrangement = Arrangement.spacedBy(ForgeMetrics.sectionGap),
    ) {
        Column(Modifier.padding(top = ForgeMetrics.space4)) {
            Text(stringResource(R.string.nav_trends), style = Forge.type.title1, color = Forge.sceneInk.text)
            Text(stringResource(R.string.forge_trends_subtitle), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
        }
        WindowPicker(days) { days = it }
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.heroRadius) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                val charge = stats(CoreRead.Metric.Charge)
                AverageRing(R.string.forge_charge, charge, charge.average?.let { colors.chargeRing(it) } ?: colors.charge,
                            higherIsBetter = true, OrganicMetric.Charge)
                AverageRing(R.string.forge_effort, stats(CoreRead.Metric.Effort), colors.effort, higherIsBetter = null,
                            OrganicMetric.Effort, rememberEffortFormat())
                AverageRing(R.string.forge_rest, stats(CoreRead.Metric.Rest), colors.rest, higherIsBetter = true,
                            OrganicMetric.Rest)
            }
        }
        TrendCard(R.string.forge_hrv_long, stringResource(R.string.forge_unit_ms), stats(CoreRead.Metric.Hrv), days,
                  colors.accent, higherIsBetter = true, tall = width != ForgeWidth.Compact)
        TrendCard(R.string.forge_rhr_long, stringResource(R.string.forge_unit_bpm), stats(CoreRead.Metric.RestingHr),
                  days, colors.heart, higherIsBetter = false, tall = width != ForgeWidth.Compact)
        Spacer(Modifier.height(ForgeMetrics.space2))
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
