package com.noop.ui.forge

import com.noop.analytics.ClockFormat
import com.noop.ui.ClockPrefs
import android.text.format.DateFormat
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.ChevronLeft
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.WbSunny
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

/** A night reduced to what the Sleep screen states: minutes per stage, time in bed and asleep. */
data class SleepSummary(val inBedMin: Int, val asleepMin: Int, val minutesByStage: Map<String, Int>) {
    val restorativeMin: Int get() = (minutesByStage["deep"] ?: 0) + (minutesByStage["rem"] ?: 0)

    companion object {
        /** The stages a night is summed over, as the core names them. */
        val stages = listOf("wake", "light", "deep", "rem")

        /** The order the lanes are drawn in, as on iOS (`stageTimelineRow`): awake, REM, light, deep. */
        val laneOrder = listOf("wake", "rem", "light", "deep")

        fun of(night: CoreRead.Night): SleepSummary {
            // The core's stage totals, as iOS states them: time in bed is the stages' sum, not the onset-to-wake
            // span, so a gap between the blocks of a split night is not counted as in bed.
            night.minutes?.let { m ->
                val byStage = stages.associateWith { (m[it] ?: 0.0).roundToInt() }
                val total = m.values.sum()
                if (total > 0) {
                    return SleepSummary(total.roundToInt(), (total - (m["wake"] ?: 0.0)).roundToInt(), byStage)
                }
            }
            val byStage = stages.associateWith { stage ->
                (night.stages.filter { it.stage == stage }.sumOf { it.end - it.start } / 60).toInt()
            }
            val inBed = ((night.endTs - night.startTs) / 60).toInt()
            val staged = byStage.values.sum()
            // Without stages the whole stretch counts as asleep; with them, everything but wake.
            val asleep = if (staged == 0) inBed else staged - (byStage["wake"] ?: 0)
            return SleepSummary(inBed, asleep, byStage)
        }
    }
}

/**
 * A time of day as the wearer's Clock setting asks (`ClockPrefs`: system, 12 or 24 hours, the iOS twin), with
 * the locale still deciding the order and the AM/PM wording (`ClockFormat.hourMinuteTemplate`).
 */
@Composable
internal fun rememberClockFormatter(): DateTimeFormatter {
    val is24 = ClockPrefs.uses24Hour(LocalContext.current)
    val locale = Locale.getDefault()
    return remember(is24, locale) {
        DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, ClockFormat.hourMinuteTemplate(is24)), locale)
    }
}

private data class SleepModel(val nights: List<CoreRead.Night>, val restByDay: Map<String, Double>)

/**
 * Fork (DX23876), Android plan E-3: the Sleep screen on the shared core. The night's Rest as a large ring, when
 * sleep started and ended, then the stage breakdown with each stage on its own lane across the night.
 */
@Composable
fun ForgeSleepScreen(padding: PaddingValues, width: ForgeWidth) {
    val context = LocalContext.current
    val zone = ZoneId.systemDefault()
    var model by remember { mutableStateOf<SleepModel?>(null) }
    var index by rememberSaveable { mutableIntStateOf(-1) }   // -1: the latest night
    LaunchedEffect(Unit) {
        model = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val now = Instant.now().epochSecond
            val nights = CoreRead.nights(now - 60L * 86_400, now)
            val from = LocalDate.now().minusDays(61).toString()
            val rest = CoreRead.series(CoreRead.Metric.Rest, from, LocalDate.now().toString())
            SleepModel(nights, rest.associate { it.day to it.value })
        }
    }
    val nights = model?.nights.orEmpty()
    val i = if (index < 0 || index >= nights.size) nights.lastIndex else index
    val night = nights.getOrNull(i)
    val wakeDay = night?.let { Instant.ofEpochSecond(it.endTs).atZone(zone).toLocalDate() }
    // The heading sits on the night band; everything below it on one canvas sheet with a rounded top, as on iOS
    // (`restHero` over `sleepNightTopBackground`, then `canvasSheet`).
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding)) {
        Header(night, isLatest = i == nights.lastIndex, zone,
               canBack = i > 0, canForward = i in 0 until nights.lastIndex,
               onBack = { index = i - 1 }, onForward = { index = i + 1 })
        Spacer(Modifier.height(ForgeMetrics.space4))
        Column(
            Modifier.fillMaxWidth()
                .background(Forge.colors.canvas, RoundedCornerShape(topStart = SHEET_RADIUS, topEnd = SHEET_RADIUS))
                .padding(horizontal = ForgeMetrics.screenPadding).padding(top = ForgeMetrics.space5),
            verticalArrangement = Arrangement.spacedBy(ForgeMetrics.sectionGap),
        ) {
        if (model != null && night == null) {
            ForgeCard(Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_no_nights), style = Forge.type.body, color = Forge.colors.textSecondary)
            }
        }
        if (night != null) {
            val rest = wakeDay?.let { model?.restByDay?.get(it.toString()) }
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                OrganicRing(rest, Forge.colors.rest, if (width == ForgeWidth.Compact) 260.dp else 280.dp, OrganicMetric.Rest)
                if (rest != null) {
                    Spacer(Modifier.height(ForgeMetrics.space3))
                    Text(stringResource(RestWord.of(rest)), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                         color = Forge.colors.rest)
                }
            }
            Times(night, zone)
            Breakdown(night, zone)
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        }
    }
}

private val SHEET_RADIUS = ForgeMetrics.cardRadius * 1.5f

/** The word under the sleep ring, banded as iOS bands it (`sleepScoreWord`): below 50, 70 and 85. */
object RestWord {
    fun of(score: Double): Int = when {
        score < 50 -> R.string.forge_rest_poor
        score < 70 -> R.string.forge_rest_fair
        score < 85 -> R.string.forge_rest_good
        else -> R.string.forge_rest_optimal
    }
}

@Composable
private fun Header(night: CoreRead.Night?, isLatest: Boolean, zone: ZoneId, canBack: Boolean, canForward: Boolean,
                   onBack: () -> Unit, onForward: () -> Unit) {
    val colors = Forge.colors
    val locale = Locale.getDefault()
    val title = when {
        night == null || isLatest -> stringResource(R.string.forge_last_night)
        else -> {
            val f = DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, DAY_MONTH_SKELETON), locale)
            stringResource(R.string.forge_night_range,
                           Instant.ofEpochSecond(night.startTs).atZone(zone).format(f),
                           Instant.ofEpochSecond(night.endTs).atZone(zone).format(f))
        }
    }
    Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space6).padding(start = ForgeMetrics.screenPadding,
                                                                            end = ForgeMetrics.space1),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title.uppercase(), style = Forge.type.overline, color = Forge.sceneInk.secondary, maxLines = 1,
                 overflow = TextOverflow.Ellipsis)
            Text(stringResource(R.string.forge_sleep_performance), style = Forge.type.title2, color = Forge.sceneInk.text,
                 maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        IconButton(onClick = onBack, enabled = canBack) {
            Icon(Icons.Rounded.ChevronLeft, stringResource(R.string.forge_previous_night),
                 tint = if (canBack) Forge.sceneInk.text else Forge.sceneInk.tertiary)
        }
        IconButton(onClick = onForward, enabled = canForward) {
            Icon(Icons.Rounded.ChevronRight, stringResource(R.string.forge_next_night),
                 tint = if (canForward) Forge.sceneInk.text else Forge.sceneInk.tertiary)
        }
    }
}

private fun clock(ts: Long, zone: ZoneId, format: DateTimeFormatter): String =
    Instant.ofEpochSecond(ts).atZone(zone).format(format)

@Composable
private fun Times(night: CoreRead.Night, zone: ZoneId) {
    val colors = Forge.colors
    val clockFormat = rememberClockFormatter()
    val locale = Locale.getDefault()
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TimeColumn(Icons.Rounded.Bedtime, colors.rest, stringResource(R.string.forge_asleep),
                       clock(night.startTs, zone, clockFormat), Modifier.weight(1f))
            Box(Modifier.width(ForgeMetrics.hairline).height(44.dp).background(colors.divider))
            Spacer(Modifier.width(ForgeMetrics.space4))
            TimeColumn(Icons.Rounded.WbSunny, colors.effort, stringResource(R.string.forge_woke),
                       clock(night.endTs, zone, clockFormat), Modifier.weight(1f))
        }
    }
}

@Composable
private fun TimeColumn(icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, label: String, time: String,
                       modifier: Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = tint)
        Spacer(Modifier.width(ForgeMetrics.space2))
        Column {
            Text(label.uppercase(), style = Forge.type.overline, color = Forge.colors.textSecondary, maxLines = 1)
            Text(time, style = Forge.type.title2, color = Forge.colors.text, maxLines = 1)
        }
    }
}

@Composable
private fun hm(minutes: Int): String = stringResource(R.string.forge_duration_hm, minutes / 60, minutes % 60)

@Composable
private fun Breakdown(night: CoreRead.Night, zone: ZoneId) {
    val colors = Forge.colors
    val clockFormat = rememberClockFormatter()
    val summary = SleepSummary.of(night)
    val locale = Locale.getDefault()
    ForgeCard(Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.forge_stage_breakdown).uppercase(), style = Forge.type.overline,
             color = colors.textSecondary)
        Text(stringResource(R.string.forge_in_bed, hm(summary.inBedMin), ((night.efficiency ?: 0.0) * 100).roundToInt()),
             style = Forge.type.caption, color = colors.textTertiary)
        Spacer(Modifier.height(ForgeMetrics.space4))
        Row {
            Column(Modifier.weight(1f)) {
                Text(hm(summary.asleepMin), style = Forge.type.title1, color = colors.text, maxLines = 1)
                Text(stringResource(R.string.forge_hours_of_sleep).uppercase(), style = Forge.type.overline,
                     color = colors.textSecondary, maxLines = 2)
            }
            Column(Modifier.weight(1f)) {
                Text(hm(summary.restorativeMin), style = Forge.type.title1, color = colors.sleepRem, maxLines = 1)
                Text(stringResource(R.string.forge_restorative).uppercase(), style = Forge.type.overline,
                     color = colors.textSecondary, maxLines = 2)
            }
        }
        if (night.stages.isNotEmpty()) {
            Spacer(Modifier.height(ForgeMetrics.space4))
            Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.rowSpacing)) {
                SleepSummary.laneOrder.forEach { stage ->
                    StageLane(night, stage, summary.minutesByStage[stage] ?: 0, summary.inBedMin)
                }
                Row(Modifier.fillMaxWidth()) {
                    val mid = (night.startTs + night.endTs) / 2
                    Text(clock(night.startTs, zone, clockFormat), style = Forge.type.caption, color = colors.textTertiary)
                    Spacer(Modifier.weight(1f))
                    Text(clock(mid, zone, clockFormat), style = Forge.type.caption, color = colors.textTertiary)
                    Spacer(Modifier.weight(1f))
                    Text(clock(night.endTs, zone, clockFormat), style = Forge.type.caption, color = colors.textTertiary)
                }
            }
        }
    }
}

@Composable
private fun StageLane(night: CoreRead.Night, stage: String, minutes: Int, inBed: Int) {
    val colors = Forge.colors
    val (label, color) = when (stage) {
        "wake" -> stringResource(R.string.forge_stage_awake) to colors.sleepAwake
        "light" -> stringResource(R.string.forge_stage_light) to colors.sleepLight
        "deep" -> stringResource(R.string.forge_stage_deep) to colors.sleepDeep
        else -> stringResource(R.string.forge_stage_rem) to colors.sleepRem
    }
    val pct = if (inBed > 0) (minutes * 100f / inBed).roundToInt() else 0
    Column(Modifier.fillMaxWidth().background(colors.inset.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
               .padding(horizontal = 12.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label.uppercase(), style = Forge.type.overline, color = colors.text, maxLines = 1)
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(stringResource(R.string.forge_percent, pct), style = Forge.type.captionNumber, color = color, maxLines = 1)
            Spacer(Modifier.weight(1f))
            Text(hm(minutes), style = Forge.type.captionNumber, color = colors.text, maxLines = 1)
        }
        Spacer(Modifier.height(6.dp))
        Canvas(Modifier.fillMaxWidth().height(18.dp)) {
            val span = (night.endTs - night.startTs).coerceAtLeast(1).toFloat()
            // The hatched night-long track of the iOS row (`StageHatchedTrack`), solid where the stage occurred.
            drawRect(colors.inset.copy(alpha = 0.9f))
            val step = 5.dp.toPx()
            var x = -size.height
            while (x < size.width) {
                drawLine(colors.textTertiary.copy(alpha = 0.16f), Offset(x, size.height), Offset(x + size.height, 0f),
                         strokeWidth = 1.dp.toPx())
                x += step
            }
            night.stages.filter { it.stage == stage }.forEach { s ->
                val x0 = (s.start - night.startTs) / span * size.width
                val x1 = (s.end - night.startTs) / span * size.width
                drawRoundRect(color, topLeft = Offset(x0, 0f), size = Size((x1 - x0).coerceAtLeast(2f), size.height),
                              cornerRadius = CornerRadius(1.5.dp.toPx(), 1.5.dp.toPx()))
            }
        }
    }
}
