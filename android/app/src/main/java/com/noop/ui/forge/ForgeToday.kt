package com.noop.ui.forge

import android.text.format.DateFormat
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreRead
import com.noop.ui.AppViewModel
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

/** The metrics whose tile shows a change against the week before. */
private val baselineMetrics = listOf(CoreRead.Metric.Hrv, CoreRead.Metric.RestingHr, CoreRead.Metric.RespRate)

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
        Header(shown, isToday = shown == today)
        Hero(model?.day, width)
        if (shown == today) LiveHeartCard(viewModel)
        KeyMetrics(model, columns = if (width == ForgeWidth.Compact) 2 else 3)
        Spacer(Modifier.height(ForgeMetrics.space2))
    }
}

@Composable
private fun Header(date: LocalDate, isToday: Boolean) {
    val colors = Forge.colors
    val locale = Locale.getDefault()
    // The iOS header row: the title and its date on the left, the wordmark centred on the same line.
    Box(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space4)) {
        Column(Modifier.fillMaxWidth(0.34f)) {
            Text(
                if (isToday) stringResource(R.string.nav_today)
                else date.format(DateTimeFormatter.ofPattern(WEEKDAY_PATTERN, locale)).replaceFirstChar { it.titlecase(locale) },
                style = Forge.type.title2.copy(fontWeight = FontWeight.Bold), color = colors.text, maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(date.format(DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, DAY_MONTH_SKELETON), locale)),
                 style = Forge.type.subhead, color = colors.textSecondary, maxLines = 1)
        }
        ForgeWordmark(Modifier.align(Alignment.TopCenter).padding(top = ForgeMetrics.space2))
    }
}

@Composable
private fun Hero(day: CoreRead.Day?, width: ForgeWidth) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.heroRadius, fill = colors.heroFill) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val slot = maxWidth / 3
            val diameter = if (width == ForgeWidth.Compact) slot else minOf(slot, 150.dp)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                ScoreSlot(R.string.forge_charge, day?.charge, day?.charge?.let { colors.chargeRing(it) } ?: colors.charge,
                          diameter, OrganicMetric.Charge)
                ScoreSlot(R.string.forge_effort, day?.effort, colors.effort, diameter, OrganicMetric.Effort)
                ScoreSlot(R.string.forge_rest, day?.rest, colors.rest, diameter, OrganicMetric.Rest)
            }
        }
    }
}

@Composable
private fun ScoreSlot(labelRes: Int, score: Double?, tint: Color, diameter: androidx.compose.ui.unit.Dp,
                      metric: OrganicMetric) {
    val label = stringResource(labelRes)
    val spoken = if (score == null) stringResource(R.string.forge_score_missing, label, stringResource(R.string.forge_no_data))
                 else stringResource(R.string.forge_score_spoken, label, score.roundToInt())
    Column(horizontalAlignment = Alignment.CenterHorizontally,
           modifier = Modifier.semantics(mergeDescendants = true) { contentDescription = spoken }) {
        OrganicRing(score, tint, diameter, metric)
        Text(label.uppercase() + CHEVRON, style = Forge.type.overline, color = Forge.colors.textSecondary, maxLines = 1,
             overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center, modifier = Modifier.size(width = diameter, height = 18.dp))
    }
}

/**
 * Live heart rate while the strap streams, with the last two minutes as a trace, as the iOS Today shows it. It
 * collects the rate itself, so the once-a-second updates redraw this card and not the whole screen. Hidden when
 * nothing streams.
 */
@Composable
private fun LiveHeartCard(viewModel: AppViewModel) {
    val colors = Forge.colors
    val bpm by viewModel.bpm.collectAsState()
    val trace = remember { mutableStateListOf<Int>() }
    LaunchedEffect(viewModel) {
        viewModel.bpm.collect { value ->
            if (value == null) trace.clear() else { trace.add(value); if (trace.size > 120) trace.removeAt(0) }
        }
    }
    val current = bpm ?: return
    val spoken = stringResource(R.string.forge_live_hr_spoken, current)
    ForgeCard(Modifier.fillMaxWidth().semantics(mergeDescendants = true) { contentDescription = spoken }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.Favorite, contentDescription = null, tint = colors.heart, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(stringResource(R.string.forge_heart_rate).uppercase(), style = Forge.type.overline,
                 color = colors.textSecondary, modifier = Modifier.weight(1f))
            Text(stringResource(R.string.forge_live).uppercase(), style = Forge.type.overline, color = colors.heart)
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(current.toString(), style = Forge.type.title1.copy(fontSize = Forge.type.heroNumber.fontSize),
                 color = colors.text)
            Spacer(Modifier.width(ForgeMetrics.space1))
            Text(stringResource(R.string.forge_unit_bpm), style = Forge.type.subhead, color = colors.textSecondary,
                 modifier = Modifier.padding(bottom = 6.dp))
            Spacer(Modifier.width(ForgeMetrics.space4))
            Canvas(Modifier.weight(1f).height(44.dp)) {
                if (trace.size < 2) return@Canvas
                val lo = trace.min() - 3f; val hi = trace.max() + 3f
                val step = size.width / (120 - 1)
                val start = size.width - step * (trace.size - 1)
                val path = Path()
                trace.forEachIndexed { i, v ->
                    val x = start + i * step
                    val y = size.height - (v - lo) / (hi - lo) * size.height
                    if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
                }
                drawPath(path, colors.heart, style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round))
            }
        }
    }
}

@Composable
private fun KeyMetrics(model: TodayModel?, columns: Int) {
    val colors = Forge.colors
    val day = model?.day
    val base = model?.baselines.orEmpty()
    val noData = stringResource(R.string.forge_no_data)
    val sleep = day?.sleepMinutes?.roundToInt()
    val tiles: List<@Composable (Modifier) -> Unit> = listOf(
        { m -> MetricTile(Icons.Rounded.MonitorHeart, colors.accent, stringResource(R.string.forge_hrv),
                          day?.hrv?.roundToInt()?.toString(), stringResource(R.string.forge_unit_ms), noData, m,
                          deltaText(day?.hrv, base[CoreRead.Metric.Hrv], 0)) },
        { m -> MetricTile(Icons.Rounded.Favorite, colors.heart, stringResource(R.string.forge_resting_hr),
                          day?.restingHr?.toString(), stringResource(R.string.forge_unit_bpm), noData, m,
                          deltaText(day?.restingHr?.toDouble(), base[CoreRead.Metric.RestingHr], 0)) },
        { m -> MetricTile(Icons.Rounded.WaterDrop, colors.sleepLight, stringResource(R.string.forge_blood_oxygen),
                          day?.spo2?.roundToInt()?.toString(), "%", noData, m) },
        { m -> MetricTile(Icons.Rounded.Air, colors.sleepRem, stringResource(R.string.forge_breathing),
                          day?.respRate?.let { "%.1f".format(it) }, stringResource(R.string.forge_unit_breaths), noData, m,
                          deltaText(day?.respRate, base[CoreRead.Metric.RespRate], 1)) },
        { m -> MetricTile(Icons.Rounded.Bedtime, colors.rest, stringResource(R.string.forge_sleep),
                          sleep?.let { stringResource(R.string.forge_hours_minutes, it / 60, it % 60) }, null, noData, m) },
        { m -> MetricTile(Icons.Rounded.DirectionsWalk, colors.charge, stringResource(R.string.forge_steps),
                          day?.steps?.let { "%,d".format(it) }, null, noData, m) },
    )
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        SectionHeader(stringResource(R.string.forge_key_metrics))
        tiles.chunked(columns).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
                row.forEach { tile -> tile(Modifier.weight(1f)) }
                repeat(columns - row.size) { Box(Modifier.weight(1f)) }
            }
        }
    }
}
