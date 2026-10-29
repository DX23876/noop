package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.data.DailyMetric
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/** `SleepModel.typicalStageMin`: the mean of a stage's minutes over the days that have it. */
internal fun typicalStageMin(days: List<DailyMetric>, pick: (DailyMetric) -> Double?): Double? =
    days.mapNotNull(pick).filter { it > 0 }.takeIf { it.isNotEmpty() }?.average()

@Composable
private fun durationText(minutes: Double): String {
    val m = maxOf(0, minutes.roundToInt())
    return if (m < 60) "${m}m" else stringResource(R.string.forge_duration_hm, m / 60, m % 60)
}

/**
 * Fork (DX23876), Android parity plan 2.3: the Sleep tab's "Stages vs typical" as iOS draws it (`StagesVsTypicalCard`):
 * deep, REM and light of the shown night, each with its share of the night, its minutes against the typical night
 * (the mean over the stored days), a bar for the night and a marker at the typical value.
 */
@Composable
internal fun StagesVsTypicalCard(deep: Double, rem: Double, light: Double, days: List<DailyMetric>) {
    val colors = Forge.colors
    val total = deep + rem + light
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        Column {
            Text(stringResource(R.string.forge_sl_last_night).uppercase(), style = Forge.type.overline, color = Forge.colors.textSecondary)
            Text(stringResource(R.string.forge_sl_vs_typical), style = Forge.type.title2, color = Forge.colors.text)
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            StageRow(stringResource(R.string.forge_stage_deep), deep, typicalStageMin(days) { it.deepMin }, total, colors.sleepDeep)
            HorizontalDivider(color = colors.divider.copy(alpha = 0.4f), modifier = Modifier.padding(vertical = ForgeMetrics.space3))
            StageRow(stringResource(R.string.forge_stage_rem), rem, typicalStageMin(days) { it.remMin }, total, colors.sleepRem)
            HorizontalDivider(color = colors.divider.copy(alpha = 0.4f), modifier = Modifier.padding(vertical = ForgeMetrics.space3))
            StageRow(stringResource(R.string.forge_stage_light), light, typicalStageMin(days) { it.lightMin }, total, colors.sleepLight)
        }
    }
}

@Composable
private fun StageRow(label: String, last: Double, typical: Double?, nightTotal: Double, color: Color) {
    val colors = Forge.colors
    val scale = (maxOf(last, typical ?: 0.0) * 1.18).takeIf { it > 0 } ?: 1.0
    val share = if (nightTotal > 0) (last / nightTotal * 100).roundToInt() else 0
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(12.dp).background(color, RoundedCornerShape(3.dp)))
            Spacer(Modifier.width(8.dp))
            Text(label.uppercase(Locale.getDefault()), style = Forge.type.overline, color = colors.text, maxLines = 1)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.forge_percent, share), style = Forge.type.captionNumber, color = color)
            Spacer(Modifier.weight(1f))
            Text(durationText(last), style = Forge.type.captionNumber, color = colors.text)
            if (typical != null && typical > 0) {
                Spacer(Modifier.width(8.dp))
                val diff = last - typical
                Text(stringResource(R.string.forge_sl_delta_typ, if (diff >= 0) "+" else "−", durationText(abs(diff))),
                     style = Forge.type.footnote,
                     color = if (last >= typical) colors.recoveryStops.last().second else colors.effort)
            }
        }
        val track = colors.inset
        val mark = colors.text
        Canvas(Modifier.fillMaxWidth().height(14.dp)) {
            val h = 12.dp.toPx()
            val r = CornerRadius(h / 2, h / 2)
            drawRoundRect(track, size = Size(size.width, h), cornerRadius = r)
            drawRoundRect(color, size = Size(size.width * (last / scale).coerceIn(0.0, 1.0).toFloat(), h), cornerRadius = r)
            if (typical != null && typical > 0) {
                val x = size.width * (typical / scale).coerceIn(0.0, 1.0).toFloat()
                drawLine(mark, Offset(x, -3f), Offset(x, h + 3f), strokeWidth = 2.dp.toPx())
            }
        }
    }
}

/**
 * Fork (DX23876), Android parity plan 2.3: "Asleep duration" as iOS draws it (`AsleepDurationCard`): hours asleep per
 * night over the trailing 30 days as bars, the typical night (the mean over every stored day) in the header, and the
 * average, shortest, longest and night count below.
 */
@Composable
internal fun AsleepDurationCard(days: List<DailyMetric>) {
    val colors = Forge.colors
    val recent = days.takeLast(30).mapNotNull { d -> d.totalSleepMin?.takeIf { it > 0 }?.let { it / 60.0 } }
    val points = if (recent.size >= 2) recent else days.mapNotNull { d -> d.totalSleepMin?.takeIf { it > 0 }?.let { it / 60.0 } }
    val totals = days.mapNotNull { it.totalSleepMin }.filter { it > 0 }
    val avg = totals.takeIf { it.isNotEmpty() }?.average()?.div(60.0)
    fun h(v: Double) = String.format(Locale.getDefault(), "%.1f h", v)
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        Column {
            Text(stringResource(R.string.forge_sl_trend).uppercase(), style = Forge.type.overline, color = colors.textSecondary)
            Text(stringResource(R.string.forge_sl_asleep_duration), style = Forge.type.title2, color = colors.text)
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.forge_sl_hours_asleep).uppercase(), style = Forge.type.overline,
                         color = colors.textSecondary)
                    Text(stringResource(R.string.forge_sl_trailing30), style = Forge.type.subhead, color = colors.textSecondary)
                }
                avg?.let { Text(stringResource(R.string.forge_sl_h_avg, String.format(Locale.getDefault(), "%.1f", it)),
                                style = Forge.type.headline, color = colors.text) }
            }
            Spacer(Modifier.height(ForgeMetrics.space3))
            if (points.size < 2) {
                Text(stringResource(R.string.forge_sl_not_enough), style = Forge.type.subhead, color = colors.textTertiary)
            } else {
                val lo = maxOf(0.0, points.min() - 1)
                val hi = maxOf(points.max() + 1, lo + 1)
                val bar = colors.rest
                val line = colors.text.copy(alpha = 0.5f)
                Canvas(Modifier.fillMaxWidth().height(ForgeMetrics.chartHeight)) {
                    val slot = size.width / points.size
                    val w = slot * 0.62f
                    points.forEachIndexed { i, v ->
                        val top = size.height * (1 - ((v - lo) / (hi - lo)).toFloat())
                        drawRoundRect(bar, topLeft = Offset(i * slot + (slot - w) / 2, top),
                                      size = Size(w, size.height - top), cornerRadius = CornerRadius(w / 3, w / 3))
                    }
                    avg?.let {
                        val y = size.height * (1 - ((it - lo) / (hi - lo)).toFloat())
                        drawLine(line, Offset(0f, y), Offset(size.width, y), strokeWidth = 1.5.dp.toPx())
                    }
                }
                Spacer(Modifier.height(ForgeMetrics.space3))
                Row(Modifier.fillMaxWidth()) {
                    listOf(stringResource(R.string.forge_sl_avg) to (avg?.let(::h) ?: "—"),
                           stringResource(R.string.forge_sl_min) to h(points.min()),
                           stringResource(R.string.forge_sl_max) to h(points.max()),
                           stringResource(R.string.forge_sl_nights) to "${points.size}").forEach { (label, value) ->
                        Column(Modifier.weight(1f)) {
                            Text(label.uppercase(Locale.getDefault()), style = Forge.type.footnote, color = colors.textTertiary)
                            Text(value, style = Forge.type.captionNumber, color = colors.text)
                        }
                    }
                }
            }
        }
    }
}
