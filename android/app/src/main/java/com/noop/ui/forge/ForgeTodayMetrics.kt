package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.analytics.SkinTempDisplay
import com.noop.core.CoreBody
import com.noop.core.CoreCoach
import com.noop.core.CoreEnergyDetail
import com.noop.core.CoreRead
import com.noop.ui.KeyMetric
import com.noop.ui.KeyMetricPrefs
import com.noop.ui.TemperatureUnit
import com.noop.ui.UnitPrefs
import com.noop.ui.UnitSystem
import com.noop.ui.UnitFormatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.util.Locale
import kotlin.math.roundToInt

/** Text at or above this scale draws one tile per row, as iOS does at the accessibility sizes. */
private const val LARGE_TEXT_SCALE = 1.5f

/** The trend series behind a tile, where the core keeps one. */
private val KeyMetric.series: CoreRead.Metric?
    get() = when (this) {
        KeyMetric.CHARGE -> CoreRead.Metric.Charge
        KeyMetric.EFFORT -> CoreRead.Metric.Effort
        KeyMetric.REST -> CoreRead.Metric.Rest
        KeyMetric.HRV -> CoreRead.Metric.Hrv
        KeyMetric.RESTING_HR -> CoreRead.Metric.RestingHr
        KeyMetric.RESPIRATORY -> CoreRead.Metric.RespRate
        KeyMetric.BLOOD_OXYGEN -> CoreRead.Metric.Spo2
        KeyMetric.STEPS -> CoreRead.Metric.Steps
        KeyMetric.SKIN_TEMP -> CoreRead.Metric.SkinTemp
        else -> null
    }

/**
 * The detailed tile's line (`LiquidTodayView.windowedSpark`): the points inside the window, or, when that cannot
 * draw a line, the last [maxPoints] measurements of the whole series, so a sparse series such as weight never
 * leaves a tile empty while its number shows.
 */
internal fun windowedSpark(points: List<Pair<String, Double>>, cutoff: String, maxPoints: Int): List<Double> {
    val windowed = points.filter { it.first >= cutoff }
    if (windowed.size >= 2) return windowed.map { it.second }
    return points.takeLast(maxPoints).map { it.second }
}

/** One tile's figures: the value, its unit, the change against the week before and where a tap goes. */
private class KeyTile(val value: String?, val unit: String?, val delta: String? = null, val opens: CoreRead.Metric? = null,
                      val opensEnergy: Boolean = false)

/**
 * Fork (DX23876), Android parity: Key Metrics after the Liquid `keyMetricsSection`. The tiles are the editor's
 * selection in its order (`today.keyMetrics`); an untouched selection drops a tile without a value, a chosen one
 * keeps it as "—" after the others. Two tiles per row unless chosen otherwise, one at the largest text sizes; a
 * lone last tile in two columns takes the full row. Detailed tiles draw the metric's trend over the chosen window.
 */
@Composable
internal fun ForgeKeyMetrics(model: TodayModel?, revision: Int, onEdit: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val selection = remember(revision) { TodayLayoutDefaults.keyMetricSelection(KeyMetricPrefs.enabledRaw(context)) }
    val detailed = remember(revision) { KeyMetricPrefs.detailed(context) }
    val windowDays = remember(revision) { KeyMetricPrefs.detailWindowDays(context) }
    val columns = TodayLayoutDefaults.keyMetricsColumns(
        remember(revision) { KeyMetricPrefs.storedColumns(context) },
        largeText = LocalDensity.current.fontScale >= LARGE_TEXT_SCALE,
    )
    val date = model?.date ?: LocalDate.now()
    val isToday = date == LocalDate.now()
    // Weight and today's burn come from their own stores, read only while their tile is chosen.
    val weightKg by produceState<Double?>(null, date, selection) {
        value = if (KeyMetric.WEIGHT !in selection.metrics) null else withContext(Dispatchers.IO) {
            CoreBody.snapshot(context)?.weight?.lastOrNull { it.day <= date.toString() }?.value
        }
    }
    val energyTotal by produceState<Double?>(null, date, selection) {
        value = if (KeyMetric.CALORIES !in selection.metrics || !isToday) null else withContext(Dispatchers.IO) {
            CoreEnergyDetail.today(context, dismissedTrainingWorkouts(context))?.total
        }
    }
    val sparks by produceState<Map<KeyMetric, List<Double>>>(emptyMap(), date, selection, detailed, windowDays) {
        value = if (!detailed) emptyMap() else withContext(Dispatchers.IO) {
            val cutoff = date.minusDays(windowDays - 1L).toString(); val to = date.toString()
            // The whole history up to the day, so a sparse series can fall back to its latest measurements.
            val dismissed = if (KeyMetric.CALORIES in selection.metrics) dismissedTrainingWorkouts(context) else emptyList()
            fun history(metric: KeyMetric): List<Pair<String, Double>>? = when (metric) {
                KeyMetric.WEIGHT -> CoreBody.snapshot(context)?.weight?.filter { it.day <= to }?.map { it.day to it.value }
                KeyMetric.CALORIES -> CoreEnergyDetail.read(context, to, "sevenDay", dismissed)
                    ?.summaries?.mapNotNull { s -> s.total?.let { s.day to it } }
                else -> metric.series?.let { s -> CoreRead.series(s, "1970-01-01", to).map { it.day to it.value } }
            }
            selection.metrics.mapNotNull { m -> history(m)?.let { m to windowedSpark(it, cutoff, windowDays) } }
                .filter { it.second.size >= 2 }.toMap()
        }
    }

    val day = model?.day
    val base = model?.baselines.orEmpty()
    val effortFormat = rememberEffortFormat()
    val units = remember { UnitPrefs.system(context) }
    val fahrenheit = remember { UnitPrefs.temperature(context) == TemperatureUnit.FAHRENHEIT }
    val whole = remember { java.text.NumberFormat.getIntegerInstance(Locale.getDefault()) }
    val tiles: Map<KeyMetric, KeyTile> = KeyMetric.entries.associateWith { metric ->
        when (metric) {
            KeyMetric.CHARGE -> KeyTile(day?.charge?.roundToInt()?.toString(), "%",
                                        deltaText(day?.charge, base[CoreRead.Metric.Charge], 0), CoreRead.Metric.Charge)
            KeyMetric.EFFORT -> KeyTile(day?.effort?.let(effortFormat), null, opens = CoreRead.Metric.Effort)
            KeyMetric.REST -> KeyTile(day?.rest?.roundToInt()?.toString(), "%",
                                      deltaText(day?.rest, base[CoreRead.Metric.Rest], 0), CoreRead.Metric.Rest)
            KeyMetric.HRV -> KeyTile(day?.hrv?.roundToInt()?.toString(), stringResource(R.string.forge_unit_ms),
                                     deltaText(day?.hrv, base[CoreRead.Metric.Hrv], 0), CoreRead.Metric.Hrv)
            KeyMetric.RESTING_HR -> KeyTile(day?.restingHr?.toString(), stringResource(R.string.forge_unit_bpm),
                                            deltaText(day?.restingHr?.toDouble(), base[CoreRead.Metric.RestingHr], 0),
                                            CoreRead.Metric.RestingHr)
            KeyMetric.BLOOD_OXYGEN -> KeyTile(day?.spo2?.roundToInt()?.toString(), "%")
            KeyMetric.RESPIRATORY -> KeyTile(day?.respRate?.let { "%.1f".format(it) }, stringResource(R.string.forge_unit_breaths),
                                             deltaText(day?.respRate, base[CoreRead.Metric.RespRate], 1), CoreRead.Metric.RespRate)
            KeyMetric.STEPS -> KeyTile(day?.steps?.let { whole.format(it.toLong()) }, null)
            KeyMetric.WEIGHT -> KeyTile(weightKg?.let { "%.1f".format(if (units == UnitSystem.IMPERIAL) UnitFormatter.kgToPounds(it) else it) },
                                        UnitFormatter.massUnit(units))
            KeyMetric.CALORIES -> KeyTile(energyTotal?.let { whole.format(kotlin.math.round(it).toLong()) }, "kcal", opensEnergy = true)
            // The core keeps the night's deviation only, so the tile reads "+0.1 Δ°C" as the Apple tile does then.
            KeyMetric.SKIN_TEMP -> KeyTile(day?.skinTempDev?.let {
                SkinTempDisplay.formatReading(SkinTempDisplay.Reading(it, SkinTempDisplay.Kind.DEVIATION), fahrenheit)
            }, null)
        }
    }
    val ordered = TodayLayoutDefaults.arrangedKeyMetrics(selection) { tiles.getValue(it).value != null }

    var open by remember { mutableStateOf<CoreRead.Metric?>(null) }
    var energyOpen by remember { mutableStateOf(false) }
    var coachOpen by remember { mutableStateOf(false) }
    val noData = stringResource(R.string.forge_no_data)
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        val editLabel = stringResource(R.string.forge_lay_edit_key_metrics)
        Row(Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space1), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.forge_key_metrics).uppercase(), style = Forge.type.overline, color = colors.textSecondary,
                 modifier = Modifier.weight(1f))
            // The window label only while detailed tiles draw a trend; otherwise nothing here shows one.
            if (detailed) {
                Text(stringResource(when (windowDays) {
                    7 -> R.string.forge_lay_7_day_trend
                    30 -> R.string.forge_lay_30_day_trend
                    else -> R.string.forge_lay_14_day_trend
                }), style = Forge.type.caption, color = colors.textTertiary, modifier = Modifier.padding(end = ForgeMetrics.space3))
            }
            Text(stringResource(R.string.forge_lay_edit).uppercase(), style = Forge.type.overline, color = colors.accent,
                 modifier = Modifier.clickable(role = Role.Button, onClick = onEdit).padding(ForgeMetrics.space2)
                     .semantics { contentDescription = editLabel })
        }
        val spansLast = columns == 2 && ordered.size % 2 == 1
        val gridded = if (spansLast) ordered.dropLast(1) else ordered
        @Composable
        fun Tile(metric: KeyMetric, modifier: Modifier) {
            val t = tiles.getValue(metric)
            val tint = metric.tint()
            val tap = when {
                t.opens != null -> Modifier.clickable { open = t.opens }
                t.opensEnergy && t.value != null -> Modifier.clickable { energyOpen = true }
                else -> Modifier
            }
            MetricTile(metric.icon, tint, stringResource(metric.titleRes), t.value, t.unit, noData, modifier.then(tap), t.delta,
                       below = sparks[metric]?.let { values -> @Composable { Spark(values, tint) } })
        }
        gridded.chunked(columns).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
                row.forEach { Tile(it, Modifier.weight(1f)) }
                repeat(columns - row.size) { Box(Modifier.weight(1f)) }
            }
        }
        if (spansLast) Tile(ordered.last(), Modifier.fillMaxWidth())
    }
    open?.let { metric ->
        val unitMs = stringResource(R.string.forge_unit_ms)
        val unitBpm = stringResource(R.string.forge_unit_bpm)
        val unitBreaths = stringResource(R.string.forge_unit_breaths)
        // "Ask coach" while the coach is on: the metric goes to the chat, which opens in place of the trend page.
        // Hidden without data access or its purposes, as iOS hides its card buttons: a card read sends the card's
        // figures, and the shared coach would drop a read its purposes do not cover without a word.
        val coachOn = com.noop.ui.NoopPrefs.coachEnabled(context) && com.noop.ai.AiKeyStore.readConsent(context)
        var purposesOn by remember { mutableStateOf(false) }
        LaunchedEffect(coachOn) { purposesOn = coachOn && withContext(Dispatchers.IO) { CoreCoach.cardAllowed() } }
        val ask: ((String, String) -> Unit)? = if (!coachOn || !purposesOn) null
            else { title, summary -> com.noop.ui.CoachHandoff.pendingCard = title to summary; open = null; coachOpen = true }
        ForgeOverlayPage(onDismiss = { open = null }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) {
                when (metric) {
                    CoreRead.Metric.Hrv -> ForgeMetricTrendPage(metric, R.string.forge_hrv_long, unitMs, colors.accent, true, ask) { open = null }
                    CoreRead.Metric.RestingHr -> ForgeMetricTrendPage(metric, R.string.forge_rhr_long, unitBpm, colors.heart, false, ask) { open = null }
                    CoreRead.Metric.RespRate -> ForgeMetricTrendPage(metric, R.string.forge_breathing, unitBreaths, colors.sleepRem, false, ask) { open = null }
                    CoreRead.Metric.Charge -> ForgeMetricTrendPage(metric, R.string.forge_charge, "%", colors.charge, true, ask) { open = null }
                    CoreRead.Metric.Effort -> ForgeMetricTrendPage(metric, R.string.forge_effort, "", colors.effort, true, ask) { open = null }
                    CoreRead.Metric.Rest -> ForgeMetricTrendPage(metric, R.string.forge_rest, "%", colors.rest, true, ask) { open = null }
                    CoreRead.Metric.SleepMinutes -> ForgeMetricTrendPage(metric, R.string.forge_sleep,
                        stringResource(R.string.forge_unit_min), colors.rest, true, ask) { open = null }
                    // SpO2, steps and skin temperature draw a tile line only; their tiles open no page, as on iOS.
                    CoreRead.Metric.Spo2, CoreRead.Metric.Steps, CoreRead.Metric.SkinTemp -> Unit
                }
            }
        }
    }
    if (energyOpen) {
        ForgeOverlayPage(onDismiss = { energyOpen = false }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) { ForgeEnergyDetailPage(onBack = { energyOpen = false }) }
        }
    }
    if (coachOpen) {
        ForgeOverlayPage(onDismiss = { coachOpen = false }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) {
                ForgeCoachDestination(stringResource(R.string.nav_coach), onBack = { coachOpen = false }, onOpen = {})
            }
        }
    }
}

/** A detailed tile's trend: the window's values as one line, scaled to their own range. */
@Composable
private fun Spark(values: List<Double>, tint: Color) {
    Canvas(Modifier.fillMaxWidth().height(28.dp)) {
        val lo = values.min(); val hi = values.max()
        val span = (hi - lo).takeIf { it > 0 } ?: 1.0
        val step = size.width / (values.size - 1)
        val path = Path()
        values.forEachIndexed { i, v ->
            val x = i * step
            val y = size.height - ((v - lo) / span).toFloat() * size.height
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        drawPath(path, tint, style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round))
    }
}
