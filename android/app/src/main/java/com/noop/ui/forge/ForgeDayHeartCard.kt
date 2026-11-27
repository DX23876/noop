package com.noop.ui.forge

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material3.Icon
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.core.CoreRead
import com.noop.ui.AppViewModel
import com.noop.ui.FullDayChartScreen
import com.noop.ui.TimelineChart
import com.noop.ui.TimelinePoint
import com.noop.ui.TimelineTimeAxisLabels
import com.noop.ui.TimelineWorkoutSpan
import com.noop.ui.chartTimeTicks
import com.noop.ui.mainSleepSpan
import com.noop.ui.workoutSpansOverlapping
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Fork (DX23876), 2026-11-27: the Android twin of iOS `ForgeDayHeartWidget`, the whole-day heart rate card adopted
 * from DX23876/noop#58 by @sondrealf. Today's banked five-minute heart rate from midnight, last night's sleep as a
 * band behind it, a sport glyph at each workout, and Min, Avg and Max under it. It is the Deep Timeline's chart at a
 * glance (the same [TimelineChart], sleep pick and workout scoping), held still so the page scrolls over it, and the
 * card opens the Deep Timeline. The header shows a figure only while a strap streams one, marked as now.
 */
@Composable
internal fun DayHeartWideCard(viewModel: AppViewModel) {
    val context = LocalContext.current
    val colors = Forge.colors
    val zone = remember { ZoneId.systemDefault() }
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val dayStart = LocalDate.now(zone).atStartOfDay(zone).toEpochSecond()
    val dayEnd = dayStart + 86_400L
    val heart by produceState<List<CoreRead.HeartPoint>>(emptyList(), coreRevision, dayStart) {
        value = withContext(Dispatchers.IO) {
            runCatching { CoreRead.open(context); CoreRead.heartRate(dayStart, dayEnd - 1) }.getOrDefault(emptyList())
        }
    }
    // The same night pick as the Deep Timeline: every sleep of the last two days, the longest one overlapping today.
    val sleeps by produceState<List<LongRange>>(emptyList(), coreRevision, dayStart) {
        value = withContext(Dispatchers.IO) {
            runCatching { viewModel.repo.allSleepSessionsUnion(viewModel.activeStrapId, 2) }
                .getOrDefault(emptyList()).map { it.effectiveStartTs..it.endTs }
        }
    }
    val allWorkouts by viewModel.workouts.collectAsStateWithLifecycle()
    val bpm by viewModel.bpm.collectAsState()
    val liveBpm = bpm?.takeIf { it > 0 }

    var open by remember { mutableStateOf(false) }
    if (open) {
        ForgeOverlayPage(onDismiss = { open = false }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) { FullDayChartScreen(vm = viewModel, onBack = { open = false }) }
        }
    }

    val title = stringResource(R.string.forge_day_heart_title)
    val values = heart.map { it.bpm }
    val stats = if (values.size >= 2) Triple(values.min(), values.average(), values.max()) else null
    val minLabel = stringResource(R.string.today_hr_min)
    val avgLabel = stringResource(R.string.today_hr_avg)
    val maxLabel = stringResource(R.string.today_hr_max)
    // Read as the card shows it: the title, then each figure after its own label.
    val spoken = stats?.let { (lo, avg, hi) ->
        listOf(title, minLabel, lo.roundToInt(), avgLabel, avg.roundToInt(), maxLabel, hi.roundToInt()).joinToString(" ")
    } ?: title
    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Button) { open = true }
                  .semantics(mergeDescendants = true) { contentDescription = spoken }) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Rounded.Favorite, contentDescription = null, tint = colors.heart, modifier = Modifier.size(18.dp))
                Text(title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text,
                     modifier = Modifier.weight(1f))
                if (liveBpm != null) {
                    Text(stringResource(R.string.forge_lt_now), style = Forge.type.caption, color = colors.textSecondary)
                    Text(liveBpm.toString(), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                         color = colors.heart)
                    Text(stringResource(R.string.forge_unit_bpm), style = Forge.type.caption, color = colors.textSecondary)
                }
            }
            if (stats != null) {
                val window = dayStart..dayEnd
                val ticks = remember(dayStart) { chartTimeTicks(dayStart, dayEnd, zone) }
                val sleepBand = remember(sleeps, dayStart) { mainSleepSpan(sleeps, window) }
                val dayWorkouts = remember(allWorkouts, dayStart) {
                    workoutSpansOverlapping(allWorkouts.map { TimelineWorkoutSpan(it.startTs, it.endTs, it.sport) }, window)
                }
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    TimelineChart(
                        points = heart.map { TimelinePoint(it.ts, it.bpm) },
                        windowStart = dayStart,
                        windowEnd = dayEnd,
                        bounds = window,
                        color = colors.heart,
                        modifier = Modifier.fillMaxWidth().height(170.dp),
                        onWindowChange = {},
                        timeTicks = ticks,
                        sleepBand = sleepBand,
                        workouts = dayWorkouts,
                        gesturesEnabled = false,
                    )
                    TimelineTimeAxisLabels(ticks = ticks, windowStart = dayStart, windowEnd = dayEnd)
                }
                val (lo, avg, hi) = stats
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    DayHeartStat(minLabel, lo)
                    Spacer(Modifier.weight(1f))
                    DayHeartStat(avgLabel, avg)
                    Spacer(Modifier.weight(1f))
                    DayHeartStat(maxLabel, hi)
                }
            } else {
                Box(Modifier.fillMaxWidth().heightIn(min = 60.dp), contentAlignment = Alignment.Center) {
                    Text(stringResource(R.string.forge_day_heart_empty), style = Forge.type.caption,
                         color = colors.textTertiary)
                }
            }
        }
    }
}

@Composable
private fun DayHeartStat(label: String, value: Double) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Text(label, style = Forge.type.caption, color = Forge.colors.textTertiary)
        Text(value.roundToInt().toString(), style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold),
             color = Forge.colors.textSecondary)
    }
}
