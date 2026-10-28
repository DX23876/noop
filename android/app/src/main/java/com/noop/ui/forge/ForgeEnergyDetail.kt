package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreEnergyDetail
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Fork (DX23876), Android parity plan 2.3: the Energy detail after `EnergyDetailView`: a chosen day's total so far
 * with its basal and active split (active split again into daily movement and training), the burn rate through
 * that day against the day before or the median of the 7 or 30 days before, and the last 30 days' daily burn. The
 * shared core reads and prices every figure; this page only draws them. The calculation page behind the iOS
 * screen is reduced to its source, coverage and confidence line here.
 */
@Composable
internal fun ForgeEnergyDetailPage(onBack: () -> Unit) {
    val context = LocalContext.current
    var day by remember { mutableStateOf<String?>(null) }
    var comparison by remember { mutableStateOf("sevenDay") }
    var detail by remember { mutableStateOf<CoreEnergyDetail.Detail?>(null) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(day, comparison) {
        detail = withContext(Dispatchers.IO) {
            CoreRead.open(context); CoreEnergyDetail.read(context, day, comparison, dismissedTrainingWorkouts(context))
        }
        loaded = true
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_ed_title), onBack)
        val d = detail
        if (d == null) {
            if (!loaded) Text(stringResource(R.string.forge_goals_loading), style = Forge.type.body, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        val isToday = d.day == d.today
        DayStepper(d, isToday, onDay = { day = it })
        val s = d.selected
        if (s != null && s.total != null) {
            Hero(s, d)
            RateCard(d, isToday, comparison) { comparison = it }
        } else {
            SettingsCard(title = stringResource(if (isToday) R.string.forge_ed_nothing_today else R.string.forge_ed_nothing_day),
                         blurb = stringResource(R.string.forge_ed_appears)) {}
        }
        val history = d.summaries.filter { it.day != d.today && it.total != null }
        if (history.size >= 2) {
            SettingsCard(title = stringResource(R.string.forge_ed_daily_burn), blurb = stringResource(R.string.forge_ed_last30)) {
                DailyBurnChart(history.map { it.total!! })
                Row {
                    Text(shortDay(history.first().day), style = Forge.type.caption, color = Forge.colors.textTertiary)
                    Spacer(Modifier.weight(1f))
                    Text(shortDay(history.last().day), style = Forge.type.caption, color = Forge.colors.textTertiary)
                }
            }
        }
        if (s != null) {
            SettingsCard(title = stringResource(R.string.forge_ed_quality), blurb = null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(s.compactLine ?: s.sourceLabel, style = Forge.type.footnote, color = Forge.colors.textSecondary,
                         modifier = Modifier.weight(1f))
                    Text(s.confidenceLabel, style = Forge.type.footnote, color = confidenceColor(s.confidence))
                }
            }
        }
    }
}

@Composable
private fun DayStepper(d: CoreEnergyDetail.Detail, isToday: Boolean, onDay: (String) -> Unit) {
    val date = LocalDate.parse(d.day)
    val oldest = LocalDate.parse(d.today).minusDays(29)
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        IconButton(enabled = date.isAfter(oldest), onClick = { onDay(date.minusDays(1).toString()) }) {
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowLeft, contentDescription = stringResource(R.string.forge_ed_day_before))
        }
        val label = when (d.day) {
            d.today -> stringResource(R.string.forge_ed_today)
            LocalDate.parse(d.today).minusDays(1).toString() -> stringResource(R.string.forge_ed_yesterday)
            else -> date.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))
        }
        Text(label, style = Forge.type.headline, color = Forge.colors.text, modifier = Modifier.weight(1f).clickable(enabled = !isToday) {
            onDay(d.today)
        }, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        IconButton(enabled = !isToday, onClick = { onDay(date.plusDays(1).toString()) }) {
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null)
        }
    }
}

@Composable
private fun Hero(s: CoreEnergyDetail.Summary, d: CoreEnergyDetail.Detail) {
    val whole = NumberFormat.getIntegerInstance(Locale.getDefault())
    val total = s.total ?: return
    SettingsCard(title = null, blurb = null) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(whole.format(total.roundToInt()), style = Forge.type.heroNumber, color = Forge.colors.text)
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text("kcal", style = Forge.type.subhead, color = Forge.colors.textSecondary, modifier = Modifier.padding(bottom = 6.dp))
        }
        Text(stringResource(R.string.forge_ed_so_far), style = Forge.type.footnote, color = Forge.colors.textSecondary)
        if (s.projectedLow != null && s.projectedHigh != null) {
            Text(stringResource(R.string.forge_ed_forecast, stringResource(R.string.forge_join_range,
                                                             whole.format(s.projectedLow.roundToInt()), whole.format(s.projectedHigh.roundToInt()))),
                 style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        val basalLabel = stringResource(if (s.basal == null) R.string.forge_ed_basal_day else R.string.forge_ed_basal_burn)
        Stat(basalLabel, s.basal ?: s.bmr24h, total)
        Stat(stringResource(R.string.forge_ed_active), s.active, total)
        if (d.movementKcal != null && d.trainingKcal != null) {
            Column(Modifier.padding(start = ForgeMetrics.space4)) {
                Stat(stringResource(R.string.forge_ed_movement), d.movementKcal, total)
                Stat(stringResource(R.string.forge_ed_training), d.trainingKcal, total)
            }
        }
    }
}

@Composable
private fun Stat(label: String, kcal: Double?, total: Double) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = Forge.type.body, color = Forge.colors.textSecondary, modifier = Modifier.weight(1f))
        Text(kcal?.let { stringResource(R.string.forge_ed_kcal, NumberFormat.getIntegerInstance(Locale.getDefault()).format(it.roundToInt())) } ?: "—",
             style = Forge.type.body, color = Forge.colors.text)
        if (kcal != null && total > 0) {
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(stringResource(R.string.forge_ed_pct, (kcal / total * 100).roundToInt()), style = Forge.type.caption,
                 color = Forge.colors.textTertiary)
        }
    }
}

@Composable
private fun RateCard(d: CoreEnergyDetail.Detail, isToday: Boolean, comparison: String, onComparison: (String) -> Unit) {
    if (d.points.isEmpty()) {
        val s = d.selected ?: return
        SettingsCard(title = stringResource(R.string.forge_ed_no_curve), blurb = null) {
            Text(stringResource(R.string.forge_ed_no_curve_detail, s.sourceLabel), style = Forge.type.caption,
                 color = Forge.colors.textSecondary)
        }
        return
    }
    SettingsCard(title = stringResource(if (isToday) R.string.forge_ed_rate_today else R.string.forge_ed_rate), blurb = null) {
        Text("kcal/min", style = Forge.type.caption, color = Forge.colors.textTertiary)
        RateChart(d.points, d.bands, d.comparisonPoints)
        Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            listOf("previousDay" to (if (isToday) R.string.forge_ed_yesterday else R.string.forge_ed_day_before),
                   "sevenDay" to R.string.forge_ed_7d, "thirtyDay" to R.string.forge_ed_30d).forEach { (mode, label) ->
                FilterChip(selected = comparison == mode, onClick = { onComparison(mode) }, label = { Text(stringResource(label)) })
            }
        }
        (d.comparisonUnavailable ?: d.comparisonCaption)?.let {
            Text(it, style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
    }
}

/** The day's rate as a filled line over 24 hours, sessions as shaded bands, the comparison as a thin line. */
@Composable
private fun RateChart(points: List<CoreEnergyDetail.Point>, bands: List<CoreEnergyDetail.Band>,
                      comparison: List<CoreEnergyDetail.Point>) {
    val energy = ForgeTokens.Color.systemOrange.resolve()
    val reference = Forge.colors.textTertiary
    val bandColor = energy.copy(alpha = 0.14f)
    Canvas(Modifier.fillMaxWidth().height(160.dp)) {
        val day = 86_400.0
        val top = (points + comparison).maxOfOrNull { it.kcalPerMinute }?.coerceAtLeast(1.0) ?: 1.0
        fun x(seconds: Double) = (seconds / day * size.width).toFloat()
        fun y(rate: Double) = (size.height - rate / (top * 1.1) * size.height).toFloat()
        bands.forEach { b -> drawRect(bandColor, Offset(x(b.start), 0f), Size(x(b.end) - x(b.start), size.height)) }
        fun path(p: List<CoreEnergyDetail.Point>) = Path().apply {
            p.forEachIndexed { i, pt ->
                val px = x(pt.start + pt.duration / 2)
                if (i == 0) moveTo(px, y(pt.kcalPerMinute)) else lineTo(px, y(pt.kcalPerMinute))
            }
        }
        val line = path(points)
        val fill = Path().apply {
            addPath(line)
            lineTo(x(points.last().start + points.last().duration / 2), size.height)
            lineTo(x(points.first().start + points.first().duration / 2), size.height)
            close()
        }
        drawPath(fill, energy.copy(alpha = 0.18f))
        drawPath(line, energy, style = Stroke(width = 2.dp.toPx()))
        if (comparison.size >= 2) drawPath(path(comparison), reference, style = Stroke(width = 1.5.dp.toPx()))
    }
}

/** The completed days' totals, fitted to their range rather than anchored at zero, as on iOS. */
@Composable
private fun DailyBurnChart(values: List<Double>) {
    val energy = ForgeTokens.Color.systemOrange.resolve()
    Canvas(Modifier.fillMaxWidth().height(140.dp)) {
        val lo = values.min(); val hi = values.max()
        val pad = maxOf(100.0, (hi - lo) * 0.2)
        val min = maxOf(0.0, lo - pad); val max = hi + pad
        fun x(i: Int) = (i.toFloat() / (values.size - 1)) * size.width
        fun y(v: Double) = (size.height - (v - min) / (max - min) * size.height).toFloat()
        val line = Path().apply { values.forEachIndexed { i, v -> if (i == 0) moveTo(x(i), y(v)) else lineTo(x(i), y(v)) } }
        drawPath(line, energy, style = Stroke(width = 2.dp.toPx()))
        values.forEachIndexed { i, v -> drawCircle(energy, 2.5.dp.toPx(), Offset(x(i), y(v))) }
    }
}

@Composable
private fun confidenceColor(confidence: String) = when (confidence) {
    "solid" -> ForgeTokens.Color.systemGreen.resolve()
    "building" -> ForgeTokens.Color.systemOrange.resolve()
    else -> Forge.colors.textTertiary
}

private fun shortDay(day: String): String =
    runCatching { LocalDate.parse(day).format(DateTimeFormatter.ofPattern("d MMM", Locale.getDefault())) }.getOrDefault(day)
