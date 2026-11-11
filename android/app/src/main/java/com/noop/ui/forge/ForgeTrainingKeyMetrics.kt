package com.noop.ui.forge

import androidx.compose.foundation.background
import kotlin.math.roundToInt
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.material3.Icon
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Air
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Speed
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreRead
import com.noop.core.CoreTraining
import com.noop.ui.AppViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.LocalDate

/**
 * Fork (DX23876), Forge parity 2026-11: Training's "Key metrics" in the new design, as iOS's
 * `ForgeTrainingView.analysis`: the training week's Effort (the daily mean, as the weekly report's ring reads it,
 * with a bar per day), VO₂max from the banked estimate (one decimal, as the metric page prints it), and the last
 * 30 days' workouts with a bar per week. iOS's pace tile waits for a pace reading on Android.
 */
@Composable
internal fun TrainingKeyMetrics(week: List<CoreTraining.PlannedDay>, viewModel: AppViewModel, onWorkouts: () -> Unit,
                                onCardio: () -> Unit = {}) {
    val context = LocalContext.current
    val noData = stringResource(R.string.forge_no_data)
    val effortFormat = rememberEffortFormat()
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val weekEffort by produceState(emptyList<Double?>(), week, coreRevision) {
        val days = week.map { it.day }
        value = if (days.isEmpty()) emptyList() else withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val byDay = CoreRead.series(CoreRead.Metric.Effort, days.first(), days.last()).associate { it.day to it.value }
            days.map { byDay[it] }
        }
    }
    val vo2max by produceState(emptyList<Double>(), coreRevision) {
        val today = LocalDate.now()
        value = withContext(Dispatchers.IO) {
            runCatching {
                viewModel.repo.resolvedSeries("vo2max_est", "my-whoop", today.minusDays(120).toString(), today.toString(),
                                              strapDeviceId = viewModel.activeStrapId).points
                    .sortedBy { it.day }.map { it.value }
            }.getOrDefault(emptyList())
        }
    }
    val workouts by viewModel.workouts.collectAsState()
    val now = System.currentTimeMillis() / 1000
    val recent = remember(workouts) { workouts.filter { it.startTs >= now - 30 * 86_400 } }
    val perWeek = remember(recent) {
        DoubleArray(4).also { weeks -> recent.forEach { r ->
            val age = ((now - r.startTs) / (7 * 86_400)).toInt()
            if (age in 0..3) weeks[3 - age] += 1.0
        } }.toList()
    }
    // The pace tile, as iOS's `paceTile`: the last eight runs over half a kilometre, else the walks, as seconds per km.
    fun paces(sport: String) = recent.filter { it.sport.lowercase().contains(sport) && (it.distanceM ?: 0.0) > 500 }
        .sortedBy { it.startTs }.takeLast(8).mapNotNull { r ->
            val secs = r.durationS ?: (r.endTs - r.startTs).coerceAtLeast(0).toDouble()
            val m = r.distanceM ?: return@mapNotNull null
            if (m > 0 && secs > 0) secs / (m / 1000) else null
        }
    val runPaces = remember(recent) { paces("run") }
    val walkPaces = remember(recent) { paces("walk") }
    val pace = when {
        runPaces.isNotEmpty() -> R.string.forge_th_running_pace to runPaces
        walkPaces.isNotEmpty() -> R.string.forge_th_walking_pace to walkPaces
        else -> null
    }
    val distanceSystem = remember { com.noop.ui.UnitPrefs.distanceSystem(context) }
    var open by remember { mutableStateOf<CoreRead.Metric?>(null) }
    val decimal = remember { NumberFormat.getNumberInstance().apply { minimumFractionDigits = 1; maximumFractionDigits = 1 } }
    val mean = weekEffort.filterNotNull().takeIf { it.isNotEmpty() }?.average()

    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        Text(stringResource(R.string.forge_th_key_metrics), style = Forge.type.title2, color = Forge.colors.text,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        // In iOS's order: Effort this week, the pace (when there is one), VO₂max, the last 30 days, two to a row.
        val tiles = buildList<@Composable (Modifier) -> Unit> {
            add { m -> MetricTile(Icons.Rounded.Speed, Forge.colors.effort, stringResource(R.string.forge_th_effort_week),
                       mean?.let(effortFormat), mean?.let { stringResource(R.string.forge_th_avg) }, noData,
                       m.clickable { open = CoreRead.Metric.Effort },
                       below = weekEffort.takeIf { it.any { v -> v != null } }?.let { values ->
                           @Composable { MiniBars(values.map { it ?: 0.0 }, Forge.colors.effort) }
                       }) }
            pace?.let { (label, values) ->
                add { m -> MetricTile(Icons.Rounded.DirectionsRun, Forge.colors.accent, stringResource(label),
                           com.noop.ui.UnitFormatter.paceFromSecPerKm(values.last(), distanceSystem), null, noData,
                           m.clickable(onClick = onCardio),
                           // Faster reads higher, as iOS draws the negated paces.
                           below = values.takeIf { it.size > 1 }?.let { v -> @Composable { KeyTileSpark(v.map { -it }, Forge.colors.accent) } }) }
            }
            add { m -> MetricTile(Icons.Rounded.Air, Forge.colors.charge, stringResource(R.string.forge_th_vo2max),
                       vo2max.lastOrNull()?.let { decimal.format(it) }, null, noData, m,
                       below = vo2max.takeLast(30).takeIf { it.size > 1 }?.let { values ->
                           @Composable { KeyTileSpark(values, Forge.colors.charge) }
                       }) }
            add { m -> MetricTile(Icons.Rounded.History, Forge.colors.accent, stringResource(R.string.forge_th_last30),
                       recent.size.toString(), stringResource(R.string.forge_th_workouts_unit), noData,
                       m.clickable(onClick = onWorkouts),
                       below = @Composable { MiniBars(perWeek, Forge.colors.accent) }) }
        }
        tiles.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
                pair.forEach { it(Modifier.weight(1f)) }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
    ForgeMetricDetail(open) { open = null }
}

/** A bar per value, scaled to the largest, as iOS's `ForgeMetricTile(bars:)`; an empty value keeps a stub. */
@Composable
private fun MiniBars(values: List<Double>, tint: Color) {
    val top = values.maxOrNull()?.takeIf { it > 0 } ?: 1.0
    Row(Modifier.fillMaxWidth().height(28.dp), horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.Bottom) {
        values.forEach { v ->
            Box(Modifier.weight(1f).fillMaxHeight((v / top).toFloat().coerceIn(0.08f, 1f))
                    .background(if (v > 0) tint else tint.copy(alpha = 0.2f), RoundedCornerShape(3.dp)))
        }
    }
}

/**
 * The new design's head of Training, as iOS's `weekHero`: this training week's workouts (how many, how long) and a
 * circle per day carrying the first workout's sport, today ringed in the accent. The days are the core's training
 * week ([CoreTraining.PlannedDay]), so the week starts where the schedule's does.
 */
@Composable
internal fun TrainingWeekHero(week: List<CoreTraining.PlannedDay>, viewModel: AppViewModel) {
    val colors = Forge.colors
    val zone = java.time.ZoneId.systemDefault()
    val workouts by viewModel.workouts.collectAsState()
    val days = remember(week) { week.map { LocalDate.parse(it.day) } }
    val inWeek = remember(workouts, days) {
        if (days.isEmpty()) emptyList() else workouts.filter { w ->
            val d = java.time.Instant.ofEpochSecond(w.startTs).atZone(zone).toLocalDate()
            d >= days.first() && d <= days.last()
        }
    }
    val minutes = inWeek.sumOf { (it.durationS ?: (it.endTs - it.startTs).coerceAtLeast(0).toDouble()) / 60 }.roundToInt()
    val trained = stringResource(R.string.forge_tw_trained)
    val rest = stringResource(R.string.forge_tw_no_workout)
    Column(Modifier.padding(horizontal = ForgeMetrics.space1), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(R.string.forge_tw_this_week), style = Forge.type.subhead.copy(fontWeight = FontWeight.Medium),
             color = colors.textSecondary)
        Row(verticalAlignment = Alignment.Bottom) {
            Text(if (inWeek.isEmpty()) stringResource(R.string.forge_tw_none)
                 else pluralStringResource(R.plurals.forge_tw_count, inWeek.size, inWeek.size),
                 style = Forge.type.title2.copy(fontWeight = FontWeight.Bold), color = colors.text)
            if (inWeek.isNotEmpty()) {
                Spacer(Modifier.width(ForgeMetrics.space2))
                Text(if (minutes < 60) stringResource(R.string.forge_tw_min, minutes)
                     else stringResource(R.string.forge_tw_hmin, minutes / 60, "%02d".format(minutes % 60)),
                     style = Forge.type.body.copy(fontWeight = FontWeight.Medium), color = colors.textSecondary,
                     modifier = Modifier.padding(bottom = 2.dp))
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 10.dp)) {
            days.forEach { day ->
                val first = inWeek.filter {
                    java.time.Instant.ofEpochSecond(it.startTs).atZone(zone).toLocalDate() == day
                }.minByOrNull { it.startTs }
                val isToday = day == com.noop.ui.logicalDayNow()
                val name = day.dayOfWeek.getDisplayName(java.time.format.TextStyle.FULL, java.util.Locale.getDefault())
                Column(Modifier.weight(1f).clearAndSetSemantics {
                           contentDescription = name; stateDescription = if (first != null) trained else rest
                       },
                       horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Box(Modifier.size(36.dp)
                            .background(if (first != null) colors.accent.copy(alpha = 0.22f) else colors.surface.copy(alpha = 0.7f), CircleShape)
                            .border(if (isToday) 1.5.dp else 1.dp, if (isToday) colors.accent else colors.divider, CircleShape),
                        contentAlignment = Alignment.Center) {
                        if (first != null) Icon(com.noop.ui.sportIcon(first.sport), contentDescription = null,
                                                tint = colors.accent, modifier = Modifier.size(16.dp))
                    }
                    Text(day.dayOfWeek.getDisplayName(java.time.format.TextStyle.NARROW, java.util.Locale.getDefault()),
                         style = Forge.type.caption.copy(fontWeight = if (isToday) FontWeight.Bold else FontWeight.Normal),
                         color = if (isToday) colors.text else colors.textSecondary)
                }
            }
        }
    }
}
