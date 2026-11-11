package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Alarm
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.Schedule
import androidx.compose.material.icons.rounded.Thermostat
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.Air
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
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
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.noop.R
import com.noop.alarm.WindDownStore
import com.noop.core.CoreRead
import com.noop.data.DailyMetric
import com.noop.ui.AppViewModel
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/*
 * Fork (DX23876), Forge parity 2026-11: the Sleep tab's cards in the new design, rebuilt from iOS's
 * `ForgeSleepView` and `ForgeNightBreakdown`: Tonight's bedtime, the night's stage lanes with its make-up, the
 * stages against the typical night, what shaped the night, the sleep debt, the body clock, the highlights, the
 * body through the night over fourteen nights, the history of hours asleep and the alarms. Every figure is one the
 * shipped Android Sleep screen already reads (the core's nights, the merged daily rows, `SleepModel`).
 */

/** A headline over a group of cards, as iOS's `ForgeSectionTitle`. */
@Composable
internal fun SleepSectionTitle(text: String) {
    Text(text, style = Forge.type.headline, color = Forge.colors.text, modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
}

/** Tomorrow's wake time from the phone alarm, with its per-day override (`Calendar.DAY_OF_WEEK`, Sunday 1). */
@Composable
internal fun rememberTomorrowWake(viewModel: AppViewModel): ZonedDateTime {
    val wakeBase by viewModel.phoneAlarmTargetMinutes.collectAsState()
    val overrides by viewModel.phoneAlarmDayOverrides.collectAsState()
    val zone = ZoneId.systemDefault()
    val tomorrow = LocalDate.now(zone).plusDays(1)
    val dow = tomorrow.dayOfWeek.value % 7 + 1
    return tomorrow.atStartOfDay(zone).plusMinutes((overrides[dow] ?: wakeBase).toLong())
}

/** Tonight's bedtime for full recovery, as iOS's `tonightCard`: the planner's bedtime, the need and the alarm. */
@Composable
internal fun SleepTonightCard(viewModel: AppViewModel, need: Double, onOpen: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val planned = remember { WindDownStore.from(context).sleepNeedMinutes.toDouble() }
    val wake = rememberTomorrowWake(viewModel)
    val bed = wake.minusMinutes(planned.toLong())
    val clock = rememberClockFormatter()
    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(40.dp).background(colors.rest.copy(alpha = 0.15f), CircleShape), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.Bedtime, contentDescription = null, tint = colors.rest, modifier = Modifier.size(20.dp))
            }
            Spacer(Modifier.width(ForgeMetrics.space3))
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.forge_sl_tonight), style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold),
                     color = colors.text)
                Text(stringResource(R.string.forge_sl_full_recovery), style = Forge.type.caption, color = colors.textSecondary)
            }
            Column(horizontalAlignment = Alignment.End) {
                Text(bed.format(clock), style = Forge.type.title1.copy(fontSize = 26.sp, fontWeight = FontWeight.SemiBold),
                     color = colors.rest, maxLines = 1)
                Text(stringResource(R.string.forge_sl_bedtime_word), style = Forge.type.caption, color = colors.textSecondary)
            }
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        Box(Modifier.fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider))
        Spacer(Modifier.height(ForgeMetrics.space3))
        Text(stringResource(R.string.forge_sl_need_alarm, TodayTimeline.hoursMinutes(need), wake.format(clock)),
             style = Forge.type.subhead, color = colors.textSecondary)
        // The bedtime counts back from the setting in Alarms, so say so when the two needs part.
        if (abs(need - planned) >= 15) {
            Text(stringResource(R.string.forge_sl_bed_counts, TodayTimeline.hoursMinutes(planned)),
                 style = Forge.type.caption, color = colors.textSecondary, modifier = Modifier.padding(top = ForgeMetrics.space1))
        }
    }
}

/** Whether the night has any stage minutes, as iOS's `night.stages.total > 0`, stretches or only per-stage totals. */
internal fun hasStageMinutes(night: CoreRead.Night): Boolean =
    SleepSummary.of(night).minutesByStage.let { (it["deep"] ?: 0) + (it["rem"] ?: 0) + (it["light"] ?: 0) } > 0

private data class StagePart(val name: String, val minutes: Double, val color: Color)

@Composable
private fun stageParts(night: CoreRead.Night): List<StagePart> {
    val c = Forge.colors
    val m = SleepSummary.of(night).minutesByStage
    return listOf(
        StagePart(stringResource(R.string.forge_stage_deep), (m["deep"] ?: 0).toDouble(), c.sleepDeep),
        StagePart(stringResource(R.string.forge_stage_rem), (m["rem"] ?: 0).toDouble(), c.sleepRem),
        StagePart(stringResource(R.string.forge_stage_light), (m["light"] ?: 0).toDouble(), c.sleepLight),
        StagePart(stringResource(R.string.forge_stage_awake), (m["wake"] ?: 0).toDouble(), c.sleepAwake),
    )
}

/**
 * The night, as iOS's `nightCard`: its clock span, the stages as four lanes over the night with the clock under
 * them, the night's make-up as one bar and each stage's total.
 */
@Composable
internal fun SleepNightCard(night: CoreRead.Night, isLatest: Boolean, zone: ZoneId) {
    val colors = Forge.colors
    val clock = rememberClockFormatter()
    fun at(ts: Long) = Instant.ofEpochSecond(ts).atZone(zone).format(clock)
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(if (isLatest) R.string.forge_last_night else R.string.forge_sl_this_night),
                 style = Forge.type.headline, color = colors.text, modifier = Modifier.weight(1f))
            Text(stringResource(R.string.l10n_sleep_screen_deleted_sleep_window_range_7bc5f027, at(night.startTs), at(night.endTs)),
                 style = Forge.type.caption, color = colors.textSecondary, maxLines = 1)
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        val parts = stageParts(night)
        if (!hasStageMinutes(night)) {
            Text(stringResource(R.string.forge_sl_no_stages), style = Forge.type.body, color = colors.textSecondary)
            return@ForgeCard
        }
        // The lanes need the stretches themselves; a night stored only as minutes per stage keeps the bar and totals.
        if (night.stages.isNotEmpty()) {
        StageLanes(night)
        Row(Modifier.fillMaxWidth().padding(top = 4.dp)) {
            Text(at(night.startTs), style = Forge.type.caption, color = colors.textTertiary)
            Spacer(Modifier.weight(1f))
            Text(at((night.startTs + night.endTs) / 2), style = Forge.type.caption, color = colors.textTertiary)
            Spacer(Modifier.weight(1f))
            Text(at(night.endTs), style = Forge.type.caption, color = colors.textTertiary)
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        }
        // The night's make-up as one bar, in the lanes' own stage colours.
        val total = parts.sumOf { it.minutes }.coerceAtLeast(1.0)
        BoxWithConstraints(Modifier.fillMaxWidth().height(10.dp).clearAndSetSemantics { }) {
            val usable = maxWidth - 6.dp
            Row(Modifier.fillMaxWidth().background(Color.Transparent, CircleShape), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                parts.filter { it.minutes > 0 }.forEachIndexed { i, p ->
                    val n = parts.count { it.minutes > 0 }
                    val shape = when {
                        n == 1 -> CircleShape
                        i == 0 -> RoundedCornerShape(topStart = 5.dp, bottomStart = 5.dp)
                        i == n - 1 -> RoundedCornerShape(topEnd = 5.dp, bottomEnd = 5.dp)
                        else -> RoundedCornerShape(0.dp)
                    }
                    Box(Modifier.width(usable * (p.minutes / total).toFloat()).height(10.dp).background(p.color, shape))
                }
            }
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        Row(Modifier.fillMaxWidth()) {
            parts.forEach { p ->
                Column(Modifier.weight(1f).semantics(mergeDescendants = true) { }) {
                    Text(TodayTimeline.hoursMinutes(p.minutes), style = Forge.type.bodyNumber.copy(fontWeight = FontWeight.SemiBold),
                         color = colors.text, maxLines = 1)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(7.dp).background(p.color, CircleShape))
                        Spacer(Modifier.width(4.dp))
                        Text(p.name, style = Forge.type.caption, color = colors.textSecondary, maxLines = 1)
                    }
                }
            }
        }
    }
}

/** Four lanes, awake at the top and deep at the bottom, each stage's stretches drawn where they fell in the night. */
@Composable
private fun StageLanes(night: CoreRead.Night) {
    val colors = Forge.colors
    val lanes = listOf("wake" to colors.sleepAwake, "rem" to colors.sleepRem, "light" to colors.sleepLight, "deep" to colors.sleepDeep)
    val track = colors.inset
    Canvas(Modifier.fillMaxWidth().height(132.dp).background(colors.inset.copy(alpha = 0.45f), RoundedCornerShape(10.dp))
               .padding(10.dp).clearAndSetSemantics { }) {
        val span = (night.endTs - night.startTs).coerceAtLeast(1).toFloat()
        val laneH = size.height / lanes.size
        val bar = laneH * 0.62f
        lanes.forEachIndexed { i, (stage, color) ->
            val y = laneH * i + (laneH - bar) / 2
            drawRoundRect(track.copy(alpha = 0.6f), Offset(0f, y), Size(size.width, bar), CornerRadius(bar / 3, bar / 3))
            night.stages.filter { it.stage == stage }.forEach { s ->
                val x0 = (s.start - night.startTs) / span * size.width
                val x1 = (s.end - night.startTs) / span * size.width
                drawRoundRect(color, Offset(x0, y), Size((x1 - x0).coerceAtLeast(2f), bar), CornerRadius(bar / 4, bar / 4))
            }
        }
    }
}

/** "7:05" for minutes, as iOS's `ForgeNightBreakdown.duration`. */
private fun clockDuration(minutes: Double): String {
    val m = minutes.roundToInt()
    return "%d:%02d".format(m / 60, m % 60)
}

/** The night's stages against the wearer's typical night, as iOS's `ForgeNightBreakdown.stages`. */
@Composable
internal fun SleepStagesVsTypical(night: CoreRead.Night, model: com.noop.ui.SleepModel?) {
    val colors = Forge.colors
    val parts = stageParts(night)
    val typical = listOf(model?.typicalDeepMin, model?.typicalRemMin, model?.typicalLightMin, null)
    val top = parts.indices.maxOf { maxOf(parts[it].minutes, typical[it] ?: 0.0) }.coerceAtLeast(1.0)
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        SleepSectionTitle(stringResource(R.string.forge_sl_stages))
        ForgeCard(Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                parts.forEachIndexed { i, p ->
                    val t = typical[i]
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(p.name, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text,
                             maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.width(64.dp))
                        Spacer(Modifier.width(10.dp))
                        Canvas(Modifier.weight(1f).height(18.dp)) {
                            val h = 12.dp.toPx(); val y = (size.height - h) / 2
                            drawRoundRect(colors.inset, Offset(0f, y), Size(size.width, h), CornerRadius(h / 2, h / 2))
                            drawRoundRect(p.color, Offset(0f, y), Size((size.width * (p.minutes / top)).toFloat().coerceAtLeast(4f), h),
                                          CornerRadius(h / 2, h / 2))
                            if (t != null) {
                                val x = (size.width * (t / top)).toFloat()
                                drawRoundRect(colors.text.copy(alpha = 0.6f), Offset(x - 1.dp.toPx(), 0f), Size(2.dp.toPx(), size.height),
                                              CornerRadius(1.dp.toPx(), 1.dp.toPx()))
                            }
                        }
                        Spacer(Modifier.width(10.dp))
                        Text(clockDuration(p.minutes), style = Forge.type.bodyNumber.copy(fontWeight = FontWeight.SemiBold),
                             color = colors.text, textAlign = TextAlign.End, modifier = Modifier.width(52.dp))
                    }
                }
                Text(stringResource(R.string.forge_sl_typical_mark), style = Forge.type.caption, color = colors.textSecondary)
            }
        }
    }
}

private data class Shaped(val label: String, val value: Double, val typical: Double?, val unit: String, val higherIsBetter: Boolean)

/**
 * What shaped the night, as iOS's `ForgeNightBreakdown.shaped`: hours against need, efficiency and restorative sleep
 * as rings with the usual as a tick, steadiness and breathing rate as rows with the usual beside them.
 */
@Composable
internal fun SleepShaped(night: CoreRead.Night, model: com.noop.ui.SleepModel?, need: Double, row: DailyMetric?,
                         steadiness: Double?) {
    val s = SleepSummary.of(night)
    val asleep = s.asleepMin.toDouble()
    val inBed = s.inBedMin.toDouble()
    val perMin = stringResource(R.string.forge_sl_per_min)
    val hoursNeed = stringResource(R.string.forge_sl_hours_need)
    val efficiency = stringResource(R.string.forge_sl_efficiency)
    val restorative = stringResource(R.string.forge_sl_restorative)
    val candidates = listOf(
        Shaped(hoursNeed, if (need > 0 && asleep > 0) asleep / need * 100 else Double.NaN, model?.hoursVsNeeded?.typical, "%", true),
        Shaped(efficiency, if (inBed > 0 && hasStageMinutes(night)) asleep / inBed * 100 else Double.NaN, model?.efficiency?.typical, "%", true),
        Shaped(stringResource(R.string.forge_sl_steadiness), steadiness ?: Double.NaN, model?.consistency?.typical, "%", true),
        Shaped(restorative, if (asleep > 0) s.restorativeMin / asleep * 100 else Double.NaN, model?.restorative?.typical, "%", true),
        Shaped(stringResource(R.string.forge_sl_breathing), row?.respRateBpm ?: Double.NaN, model?.respiratory?.typical, perMin, false),
    )
    // A figure the night lacks is left out, and so is one that never left zero (a measure still without nights).
    val rows = candidates.filter { !it.value.isNaN() && !(it.value == 0.0 && (it.typical ?: 0.0) == 0.0) }
    val ringNames = setOf(hoursNeed, efficiency, restorative)
    val rings = rows.filter { it.label in ringNames }
    val rest = rows.filter { it.label !in ringNames }
    if (rows.isEmpty()) return
    val colors = Forge.colors
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        SleepSectionTitle(stringResource(R.string.forge_sl_shaped))
        ForgeCard(Modifier.fillMaxWidth()) {
            if (rings.isNotEmpty()) {
                Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                    rings.forEach { ShareRing(it, Modifier.weight(1f)) }
                }
            }
            if (rings.isNotEmpty() && rest.isNotEmpty()) {
                Box(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space3).height(ForgeMetrics.hairline).background(colors.divider))
            }
            rest.forEachIndexed { i, r ->
                if (i > 0) Box(Modifier.fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider))
                ShapedRow(r)
            }
        }
    }
}

@Composable
private fun ShareRing(r: Shaped, modifier: Modifier) {
    val colors = Forge.colors
    val fraction = (r.value / 100).coerceIn(0.0, 1.0).toFloat()
    val below = r.typical?.let { r.value < it - 2 } ?: false
    val usual = r.typical?.let { stringResource(R.string.forge_sl_usual, it.roundToInt()) }
    Column(modifier.semantics(mergeDescendants = true) { }, horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(74.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(74.dp)) {
                val w = 9.dp.toPx()
                val inset = w / 2
                val arc = Size(size.width - w, size.height - w)
                drawArc(colors.rest.copy(alpha = 0.16f), 0f, 360f, false, Offset(inset, inset), arc, style = Stroke(w))
                drawArc(colors.rest, -90f, 360f * fraction, false, Offset(inset, inset), arc, style = Stroke(w, cap = StrokeCap.Round))
                r.typical?.let { t ->
                    val angle = Math.toRadians(360.0 * (t / 100).coerceIn(0.0, 1.0) - 90.0)
                    val radius = (size.width - w) / 2
                    val c = Offset(size.width / 2, size.height / 2)
                    val dir = Offset(kotlin.math.cos(angle).toFloat(), kotlin.math.sin(angle).toFloat())
                    drawLine(colors.text.copy(alpha = 0.7f), c + dir * (radius - 7.5.dp.toPx()), c + dir * (radius + 7.5.dp.toPx()),
                             strokeWidth = 2.5.dp.toPx(), cap = StrokeCap.Round)
                }
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(r.value.roundToInt().toString(), style = Forge.type.title2.copy(fontSize = 22.sp, fontWeight = FontWeight.SemiBold),
                     color = colors.text, maxLines = 1)
                Text("%", style = Forge.type.caption.copy(fontSize = 11.sp, fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(r.label, style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.text,
             textAlign = TextAlign.Center, maxLines = 2)
        if (usual != null) Text(usual, style = Forge.type.caption.copy(fontSize = 11.sp),
                                color = if (below) colors.effort else colors.textSecondary)
    }
}

@Composable
private fun ShapedRow(r: Shaped) {
    val colors = Forge.colors
    val value = if (r.unit == "%") "${r.value.roundToInt()} %" else stringResource(R.string.forge_pair_words,
        "%.1f".format(Locale.getDefault(), r.value), r.unit)
    Column(Modifier.fillMaxWidth().padding(vertical = 10.dp).semantics(mergeDescendants = true) { }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(r.label, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
                r.typical?.let { Text(stringResource(R.string.forge_sl_usual, it.roundToInt()), style = Forge.type.caption,
                                      color = colors.textSecondary) }
            }
            Text(value, style = Forge.type.title2.copy(fontSize = 20.sp, fontWeight = FontWeight.SemiBold), color = colors.text)
        }
        if (r.unit == "%") {
            Spacer(Modifier.height(ForgeMetrics.space2))
            Canvas(Modifier.fillMaxWidth().height(14.dp)) {
                val h = 8.dp.toPx(); val y = (size.height - h) / 2
                drawRoundRect(colors.rest.copy(alpha = 0.16f), Offset(0f, y), Size(size.width, h), CornerRadius(h / 2, h / 2))
                drawRoundRect(colors.rest, Offset(0f, y), Size((size.width * (r.value / 100).coerceIn(0.0, 1.0)).toFloat().coerceAtLeast(6f), h),
                              CornerRadius(h / 2, h / 2))
                r.typical?.let { t ->
                    val x = (size.width * (t / 100).coerceIn(0.0, 1.0)).toFloat()
                    drawRoundRect(colors.text.copy(alpha = 0.65f), Offset(x - 1.dp.toPx(), 0f), Size(2.dp.toPx(), size.height),
                                  CornerRadius(1.dp.toPx(), 1.dp.toPx()))
                }
            }
        }
    }
}

private data class Highlight(val title: String, val detail: String, val more: Boolean)

/** What this night did differently from the usual, ten minutes or more, as iOS's `highlights`: one page each. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun SleepHighlights(night: CoreRead.Night, model: com.noop.ui.SleepModel?) {
    val s = SleepSummary.of(night)
    val m = s.minutesByStage
    val rows = listOf(
        Triple(stringResource(R.string.forge_sl_time_asleep), s.asleepMin.toDouble(), model?.typicalTotalMin),
        Triple(stringResource(R.string.forge_sl_deep_sleep), (m["deep"] ?: 0).toDouble(), model?.typicalDeepMin),
        Triple(stringResource(R.string.forge_sl_rem_sleep), (m["rem"] ?: 0).toDouble(), model?.typicalRemMin),
        Triple(stringResource(R.string.forge_sl_light_sleep), (m["light"] ?: 0).toDouble(), model?.typicalLightMin),
    )
    val items = rows.mapNotNull { (title, value, typical) ->
        if (typical == null || abs(value - typical) < 10) null
        else Highlight(title, stringResource(R.string.forge_sl_usually, TodayTimeline.hoursMinutes(value), TodayTimeline.hoursMinutes(typical)),
                       value > typical)
    }
    if (items.isEmpty()) return
    val colors = Forge.colors
    val pager = rememberPagerState { items.size }
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        SleepSectionTitle(stringResource(R.string.forge_sl_highlights))
        ForgeCard(Modifier.fillMaxWidth()) {
            HorizontalPager(pager, Modifier.fillMaxWidth()) { i ->
                val item = items[i]
                Column(Modifier.fillMaxWidth()) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(38.dp).background(colors.rest.copy(alpha = 0.15f), CircleShape), contentAlignment = Alignment.Center) {
                            Icon(Icons.Rounded.Schedule, contentDescription = null, tint = colors.rest, modifier = Modifier.size(18.dp))
                        }
                        Spacer(Modifier.width(ForgeMetrics.space3))
                        Column(Modifier.weight(1f)) {
                            Text(item.title, style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
                            Text(item.detail, style = Forge.type.caption, color = colors.textSecondary)
                        }
                        val tone = if (item.more) colors.charge else colors.effort
                        Text(stringResource(if (item.more) R.string.forge_sl_more else R.string.forge_sl_less),
                             style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = tone,
                             modifier = Modifier.background(tone.copy(alpha = 0.14f), CircleShape).padding(horizontal = 10.dp, vertical = 4.dp))
                    }
                    Spacer(Modifier.height(ForgeMetrics.space3))
                    Text(stringResource(R.string.forge_sl_n_of, i + 1, items.size), style = Forge.type.caption, color = colors.textTertiary)
                }
            }
            if (items.size > 1) {
                Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space2), horizontalArrangement = Arrangement.Center) {
                    items.indices.forEach { i ->
                        Box(Modifier.padding(horizontal = 3.dp).size(6.dp)
                                .background(if (i == pager.currentPage) colors.text else colors.textTertiary.copy(alpha = 0.4f), CircleShape))
                    }
                }
            }
        }
    }
}

private data class Signal(val label: String, val value: String?, val unit: String, val icon: ImageVector, val series: List<Double?>)

/**
 * The body through the night, as iOS's `nightFacts`: wake-ups, resting HR, HRV and skin temperature, each with its
 * last fourteen nights as bars and this night drawn full; breathing joins them on a night without stages.
 */
@Composable
internal fun SleepThisNight(days: List<DailyMetric>, wakeKey: String, hasStages: Boolean) {
    val recent = days.filter { it.day <= wakeKey }.takeLast(14)
    val row = recent.lastOrNull()?.takeIf { it.day == wakeKey }
    val signals = mutableListOf(
        Signal(stringResource(R.string.forge_sl_wakeups), row?.disturbances?.toString(), "", Icons.Rounded.Visibility,
               recent.map { it.disturbances?.toDouble() }),
        Signal(stringResource(R.string.forge_sl_rhr_night), row?.restingHr?.toString(), "bpm", Icons.Rounded.Favorite,
               recent.map { it.restingHr?.toDouble() }),
        Signal(stringResource(R.string.forge_sl_hrv), row?.avgHrv?.roundToInt()?.toString(), "ms", Icons.Rounded.MonitorHeart,
               recent.map { it.avgHrv }),
        Signal(stringResource(R.string.forge_sl_skin_temp), row?.skinTempDevC?.let { "%+.1f".format(Locale.getDefault(), it) }, "°C",
               Icons.Rounded.Thermostat, recent.map { it.skinTempDevC }),
    )
    if (!hasStages) signals.add(3, Signal(stringResource(R.string.forge_sl_breaths),
        row?.respRateBpm?.let { "%.1f".format(Locale.getDefault(), it) }, "", Icons.Rounded.Air, recent.map { it.respRateBpm }))
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        SleepSectionTitle(stringResource(R.string.forge_sl_this_night))
        signals.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                pair.forEach { SignalTile(it, highlightLast = row != null, Modifier.weight(1f)) }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun SignalTile(s: Signal, highlightLast: Boolean, modifier: Modifier) {
    val colors = Forge.colors
    val present = s.series.filterNotNull()
    val lo = present.minOrNull() ?: 0.0
    val span = ((present.maxOrNull() ?: 1.0) - lo).coerceAtLeast(0.0001)
    val spoken = listOfNotNull(s.label, s.value ?: "–", s.unit.takeIf { it.isNotEmpty() && s.value != null }).joinToString(" ")
    ForgeCard(modifier.clearAndSetSemantics { contentDescription = spoken }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(s.icon, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(4.dp))
            Text(s.label, style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary,
                 maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(s.value ?: "–", style = Forge.type.title1.copy(fontSize = 26.sp, fontWeight = FontWeight.SemiBold),
                 color = colors.text, maxLines = 1)
            if (s.value != null && s.unit.isNotEmpty()) {
                Text(s.unit, style = Forge.type.footnote.copy(fontWeight = FontWeight.Medium), color = colors.textSecondary,
                     modifier = Modifier.padding(start = 3.dp, bottom = 4.dp))
            }
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Canvas(Modifier.fillMaxWidth().height(28.dp)) {
            if (present.size < 2) return@Canvas
            val n = s.series.size
            val gap = 3.dp.toPx()
            val w = ((size.width - gap * (n - 1)) / n).coerceAtLeast(1f)
            s.series.forEachIndexed { i, v ->
                val x = i * (w + gap)
                if (v == null) {
                    drawCircle(colors.divider, 1.5.dp.toPx(), Offset(x + w / 2, size.height - 1.5.dp.toPx()))
                } else {
                    val h = (6 + 22 * (v - lo) / span).toFloat().dp.toPx()
                    val last = highlightLast && i == n - 1
                    drawRoundRect(colors.rest.copy(alpha = if (last) 1f else 0.35f), Offset(x, size.height - h), Size(w, h),
                                  CornerRadius(2.dp.toPx(), 2.dp.toPx()))
                }
            }
        }
    }
}

/** Hours asleep night by night with the need as a dotted line, as iOS's `history`, over a week, month or year. */
@Composable
internal fun SleepHistory(days: List<DailyMetric>, need: Double) {
    val colors = Forge.colors
    var range by rememberSaveable { mutableStateOf(7) }
    val points = days.takeLast(range).mapNotNull { d -> d.totalSleepMin?.let { d.day to it / 60 } }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SleepSectionTitle(stringResource(R.string.forge_sl_history))
        // The segmented control, as iOS's `.segmented` picker.
        Row(Modifier.fillMaxWidth().background(colors.inset, RoundedCornerShape(9.dp)).padding(2.dp)) {
            listOf(7 to R.string.forge_sl_week, 30 to R.string.forge_sl_month, 365 to R.string.forge_sl_year).forEach { (n, label) ->
                val on = range == n
                Text(stringResource(label), style = Forge.type.footnote.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium),
                     color = colors.text, textAlign = TextAlign.Center, maxLines = 1,
                     modifier = Modifier.weight(1f).background(if (on) colors.surface else Color.Transparent, RoundedCornerShape(7.dp))
                         .clickable(role = Role.Tab) { range = n }.padding(vertical = 6.dp))
            }
        }
        if (points.size < 2) return@Column
        val description = stringResource(R.string.forge_sl_hours_night)
        ForgeCard(Modifier.fillMaxWidth()) {
            val top = (points.maxOf { it.second }.coerceAtLeast(need / 60) * 1.1).coerceAtLeast(1.0)
            Canvas(Modifier.fillMaxWidth().height(150.dp).semantics { contentDescription = description }) {
                val n = points.size
                val gap = if (range == 365) 0.5.dp.toPx() else 4.dp.toPx()
                val w = ((size.width - gap * (n - 1)) / n).coerceAtLeast(0.5f)
                val r = if (range == 365) 1.dp.toPx() else 5.dp.toPx()
                points.forEachIndexed { i, (_, h) ->
                    val bh = (h / top * size.height).toFloat()
                    drawRoundRect(colors.rest.copy(alpha = if (i == n - 1) 1f else 0.55f), Offset(i * (w + gap), size.height - bh),
                                  Size(w, bh), CornerRadius(r.coerceAtMost(w / 2), r.coerceAtMost(w / 2)))
                }
                val y = (size.height - need / 60 / top * size.height).toFloat()
                drawLine(colors.rest, Offset(0f, y), Offset(size.width, y), strokeWidth = 1.5.dp.toPx(), cap = StrokeCap.Round,
                         pathEffect = PathEffect.dashPathEffect(floatArrayOf(2.dp.toPx(), 4.dp.toPx())))
            }
            Spacer(Modifier.height(4.dp))
            // The axis: weekday initials for a week, a few dates for longer ranges.
            val locale = Locale.getDefault()
            if (range == 7) {
                Row(Modifier.fillMaxWidth()) {
                    points.forEach { (day, _) ->
                        Text(LocalDate.parse(day).dayOfWeek.getDisplayName(TextStyle.NARROW, locale), style = Forge.type.caption,
                             color = colors.textTertiary, textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
                    }
                }
            } else {
                val f = DateTimeFormatter.ofPattern(android.text.format.DateFormat.getBestDateTimePattern(locale, "dMMM"), locale)
                Row(Modifier.fillMaxWidth()) {
                    listOf(0, points.size / 3, points.size * 2 / 3, points.size - 1).distinct().forEachIndexed { i, idx ->
                        if (i > 0) Spacer(Modifier.weight(1f))
                        Text(LocalDate.parse(points[idx].first).format(f), style = Forge.type.caption, color = colors.textTertiary)
                    }
                }
            }
            Spacer(Modifier.height(ForgeMetrics.space3))
            Row(verticalAlignment = Alignment.CenterVertically) {
                repeat(3) { Box(Modifier.padding(end = 2.dp).size(3.dp).background(colors.rest, CircleShape)) }
                Spacer(Modifier.width(4.dp))
                Text(stringResource(R.string.forge_sl_need, TodayTimeline.hoursMinutes(need)), style = Forge.type.caption,
                     color = colors.textSecondary)
            }
        }
    }
}

/** The smart alarm and the bedtime reminder, as iOS's `more` group, both opening Alarms. */
@Composable
internal fun SleepAlarms(viewModel: AppViewModel, onOpen: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val clock = rememberClockFormatter()
    val wake = rememberTomorrowWake(viewModel)
    val store = remember { WindDownStore.from(context) }
    val reminder = if (!store.enabled) stringResource(R.string.forge_sl_off)
        else stringResource(R.string.forge_sl_reminder_at,
                            wake.minusMinutes((store.sleepNeedMinutes + store.leadMinutes).toLong()).format(clock))
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        SleepSectionTitle(stringResource(R.string.forge_sl_alarms))
        ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
            AlarmRow(Icons.Rounded.Alarm, stringResource(R.string.forge_sl_smart_alarm),
                     stringResource(R.string.forge_sl_smart_alarm_sub, wake.format(clock)), onOpen)
            Box(Modifier.padding(start = 56.dp).fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider))
            AlarmRow(Icons.Rounded.Bedtime, stringResource(R.string.forge_sl_bedtime), reminder, onOpen)
        }
    }
}

@Composable
private fun AlarmRow(icon: ImageVector, title: String, subtitle: String, onClick: () -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onClick).padding(horizontal = ForgeMetrics.space4, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(28.dp).background(colors.rest, RoundedCornerShape(7.dp)), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(Modifier.weight(1f)) {
            Text(title, style = Forge.type.body, color = colors.text)
            Text(subtitle, style = Forge.type.caption, color = colors.textSecondary, maxLines = 2)
        }
        Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary,
             modifier = Modifier.size(18.dp))
    }
}
