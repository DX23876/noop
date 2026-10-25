package com.noop.ui.forge

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
        /** The stages the screen draws, in lane order, as the core names them. */
        val stages = listOf("wake", "light", "deep", "rem")

        fun of(night: CoreRead.Night): SleepSummary {
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

private const val CLOCK_SKELETON = "jmm"

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
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding)
            .padding(horizontal = ForgeMetrics.screenPadding),
        verticalArrangement = Arrangement.spacedBy(ForgeMetrics.sectionGap),
    ) {
        Header(night, isLatest = i == nights.lastIndex, zone,
               canBack = i > 0, canForward = i in 0 until nights.lastIndex,
               onBack = { index = i - 1 }, onForward = { index = i + 1 })
        if (model != null && night == null) {
            ForgeCard(Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_no_nights), style = Forge.type.body, color = Forge.colors.textSecondary)
            }
        }
        if (night != null) {
            val rest = wakeDay?.let { model?.restByDay?.get(it.toString()) }
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                OrganicRing(rest, Forge.colors.rest, if (width == ForgeWidth.Compact) 220.dp else 240.dp, OrganicMetric.Rest)
            }
            Times(night, zone)
            Breakdown(night, zone)
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
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
    Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space4), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(stringResource(R.string.forge_sleep).uppercase(), style = Forge.type.overline, color = colors.textSecondary)
            Text(title, style = Forge.type.title1, color = colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        IconButton(onClick = onBack, enabled = canBack) {
            Icon(Icons.Rounded.ChevronLeft, stringResource(R.string.forge_previous_night),
                 tint = if (canBack) colors.text else colors.textTertiary)
        }
        IconButton(onClick = onForward, enabled = canForward) {
            Icon(Icons.Rounded.ChevronRight, stringResource(R.string.forge_next_night),
                 tint = if (canForward) colors.text else colors.textTertiary)
        }
    }
}

private fun clock(ts: Long, zone: ZoneId, locale: Locale): String =
    Instant.ofEpochSecond(ts).atZone(zone)
        .format(DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, CLOCK_SKELETON), locale))

@Composable
private fun Times(night: CoreRead.Night, zone: ZoneId) {
    val colors = Forge.colors
    val locale = Locale.getDefault()
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TimeColumn(Icons.Rounded.Bedtime, colors.rest, stringResource(R.string.forge_asleep),
                       clock(night.startTs, zone, locale), Modifier.weight(1f))
            Box(Modifier.width(ForgeMetrics.hairline).height(44.dp).background(colors.divider))
            Spacer(Modifier.width(ForgeMetrics.space4))
            TimeColumn(Icons.Rounded.WbSunny, colors.effort, stringResource(R.string.forge_woke),
                       clock(night.endTs, zone, locale), Modifier.weight(1f))
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
                SleepSummary.stages.forEach { stage ->
                    StageLane(night, stage, summary.minutesByStage[stage] ?: 0, summary.inBedMin)
                }
                Row(Modifier.fillMaxWidth()) {
                    val mid = (night.startTs + night.endTs) / 2
                    Text(clock(night.startTs, zone, locale), style = Forge.type.caption, color = colors.textTertiary)
                    Spacer(Modifier.weight(1f))
                    Text(clock(mid, zone, locale), style = Forge.type.caption, color = colors.textTertiary)
                    Spacer(Modifier.weight(1f))
                    Text(clock(night.endTs, zone, locale), style = Forge.type.caption, color = colors.textTertiary)
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
            drawRoundRect(colors.divider.copy(alpha = 0.25f), cornerRadius = CornerRadius(6f, 6f))
            night.stages.filter { it.stage == stage }.forEach { s ->
                val x0 = (s.start - night.startTs) / span * size.width
                val x1 = (s.end - night.startTs) / span * size.width
                drawRoundRect(color, topLeft = Offset(x0, 0f), size = Size((x1 - x0).coerceAtLeast(2f), size.height),
                              cornerRadius = CornerRadius(6f, 6f))
            }
        }
    }
}
