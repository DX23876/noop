package com.noop.ui.forge

import androidx.compose.foundation.background
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
internal fun TrainingKeyMetrics(week: List<CoreTraining.PlannedDay>, viewModel: AppViewModel, onWorkouts: () -> Unit) {
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
    var open by remember { mutableStateOf<CoreRead.Metric?>(null) }
    val decimal = remember { NumberFormat.getNumberInstance().apply { minimumFractionDigits = 1; maximumFractionDigits = 1 } }
    val mean = weekEffort.filterNotNull().takeIf { it.isNotEmpty() }?.average()

    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        Text(stringResource(R.string.forge_th_key_metrics), style = Forge.type.title2, color = Forge.colors.text,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
            MetricTile(Icons.Rounded.Speed, Forge.colors.effort, stringResource(R.string.forge_th_effort_week),
                       mean?.let(effortFormat), mean?.let { stringResource(R.string.forge_th_avg) }, noData,
                       Modifier.weight(1f).clickable { open = CoreRead.Metric.Effort },
                       below = weekEffort.takeIf { it.any { v -> v != null } }?.let { values ->
                           @Composable { MiniBars(values.map { it ?: 0.0 }, Forge.colors.effort) }
                       })
            MetricTile(Icons.Rounded.Air, Forge.colors.charge, stringResource(R.string.forge_th_vo2max),
                       vo2max.lastOrNull()?.let { decimal.format(it) }, null, noData, Modifier.weight(1f),
                       below = vo2max.takeLast(30).takeIf { it.size > 1 }?.let { values ->
                           @Composable { KeyTileSpark(values, Forge.colors.charge) }
                       })
        }
        Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
            MetricTile(Icons.Rounded.History, Forge.colors.accent, stringResource(R.string.forge_th_last30),
                       recent.size.toString(), stringResource(R.string.forge_th_workouts_unit), noData,
                       Modifier.weight(1f).clickable(onClick = onWorkouts),
                       below = @Composable { MiniBars(perWeek, Forge.colors.accent) })
            Spacer(Modifier.weight(1f))
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
