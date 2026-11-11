package com.noop.ui.forge

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreRead
import com.noop.ui.KeyMetric
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import kotlin.math.abs

/**
 * Fork (DX23876), Forge parity 2026-11: "What changed", the rule of iOS's `TrendsChangeSummary.rows`. Each measure's
 * mean over the last [span] days against the [span] days before, as a relative change; under 2 % it holds steady,
 * otherwise it is better or worse by the measure's good direction, or neutral where neither way is better. A span
 * needs a third of its days (at least two) on both sides. Largest move first. Pure, so the rule is tested.
 *
 * Android reads seven of iOS's ten measures through the core; sleep regularity, stress and weight are not on that
 * path yet, so a count here can be smaller than on iOS for the same data.
 */
internal object ChangeSummary {
    enum class Verdict { Better, Worse, Steady, Neutral }

    /**
     * A measure, its series and which way is good (null: neither way is better). A [metric] reads the core's day rows; a
     * [key] reads the shared resolved series under [source] (sleep regularity, stress and weight, which have no day
     * column), as iOS's `TrendsChangeSummary` reads every measure.
     */
    data class Measure(val metric: CoreRead.Metric?, val tile: KeyMetric?, val higherIsBetter: Boolean?,
                       val key: String? = null, val source: String? = null)

    data class Row(val measure: Measure, val before: Double, val now: Double, val change: Double, val verdict: Verdict)

    val measures = listOf(
        Measure(CoreRead.Metric.Charge, KeyMetric.CHARGE, true),
        Measure(CoreRead.Metric.Hrv, KeyMetric.HRV, true),
        Measure(CoreRead.Metric.RestingHr, KeyMetric.RESTING_HR, false),
        Measure(CoreRead.Metric.SleepMinutes, null, true),
        Measure(null, null, true, key = "sleep_consistency", source = "my-whoop"),
        Measure(CoreRead.Metric.RespRate, KeyMetric.RESPIRATORY, null),
        Measure(null, null, false, key = "stress", source = "my-whoop"),
        Measure(CoreRead.Metric.Steps, KeyMetric.STEPS, true),
        Measure(CoreRead.Metric.Effort, KeyMetric.EFFORT, null),
        Measure(null, KeyMetric.WEIGHT, null, key = "weight", source = "noop-weight"),
    )

    private const val DEADBAND = 0.02

    /** One measure's row from its daily values ("yyyy-MM-dd" to value), or null without enough days or a zero base. */
    fun row(measure: Measure, values: Map<String, Double>, today: LocalDate, span: Int): Row? {
        val cut = today.minusDays(span.toLong()).toString()
        val start = today.minusDays(2L * span).toString()
        val recent = values.filterKeys { it > cut }.values
        val earlier = values.filterKeys { it > start && it <= cut }.values
        val minimum = maxOf(2, span / 3)
        if (recent.size < minimum || earlier.size < minimum) return null
        val now = recent.average()
        val before = earlier.average()
        if (before == 0.0) return null
        val change = (now - before) / abs(before)
        val verdict = when {
            abs(change) < DEADBAND -> Verdict.Steady
            measure.higherIsBetter == null -> Verdict.Neutral
            (change > 0) == measure.higherIsBetter -> Verdict.Better
            else -> Verdict.Worse
        }
        return Row(measure, before, now, change, verdict)
    }

    fun rows(series: Map<Measure, Map<String, Double>>, today: LocalDate, span: Int): List<Row> =
        series.mapNotNull { (m, v) -> row(m, v, today, span) }.sortedByDescending { abs(it.change) }

    enum class Head { Strong, Tough, Mixed, Steady }

    /** The headline and the row it names, as iOS's `headline`: more better than worse is a strong stretch, and so on. */
    fun headline(rows: List<Row>): Pair<Head, Row?> {
        val better = rows.filter { it.verdict == Verdict.Better }
        val worse = rows.filter { it.verdict == Verdict.Worse }
        return when {
            better.size > worse.size -> Head.Strong to better.first()
            worse.size > better.size -> Head.Tough to worse.first()
            better.isNotEmpty() || worse.isNotEmpty() -> Head.Mixed to (better.firstOrNull() ?: worse.first())
            else -> Head.Steady to null
        }
    }
}

/**
 * Today's "What changed" card, as iOS's `ForgeChangesWidget`: the last seven days against the seven before in a word,
 * a tally bar with its counts, and the three measures that moved most with their before and now. Opens Health's
 * Trends, as iOS opens its Trends tab.
 */
@Composable
internal fun TodayChangesForge(onOpen: () -> Unit, strapId: String = "my-whoop") {
    val context = LocalContext.current
    val colors = Forge.colors
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val today = com.noop.ui.logicalDayNow()
    val rows by produceState<List<ChangeSummary.Row>?>(null, coreRevision, today) {
        value = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val from = today.minusDays(14).toString()
            val series = ChangeSummary.measures.associateWith { m ->
                m.metric?.let { CoreRead.series(it, from, today.toString()).associate { p -> p.day to p.value } }
                    ?: runCatching {
                        com.noop.core.CoreResolvedSeries.read(m.key!!, m.source!!, from, today.toString(), strapId)?.points
                            ?.associate { it.day to it.value }
                    }.getOrNull().orEmpty()
            }
            ChangeSummary.rows(series, today, 7)
        }
    }
    val list = rows.orEmpty()
    val better = list.count { it.verdict == ChangeSummary.Verdict.Better }
    val worse = list.count { it.verdict == ChangeSummary.Verdict.Worse }
    val steady = list.size - better - worse
    val effortFormat = rememberEffortFormat()
    ForgeCard(Modifier.fillMaxWidth().clickable(onClick = onOpen)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.forge_w_changes), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = colors.text, modifier = Modifier.weight(1f))
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = colors.textTertiary)
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        if (list.isEmpty()) {
            if (rows != null) Text(stringResource(R.string.forge_ch_few), style = Forge.type.caption, color = colors.textSecondary)
            return@ForgeCard
        }
        val (head, top) = ChangeSummary.headline(list)
        val topName = top?.let { measureName(it.measure) }
        Text(stringResource(when (head) {
            ChangeSummary.Head.Strong -> R.string.forge_ch_strong
            ChangeSummary.Head.Tough -> R.string.forge_ch_tough
            ChangeSummary.Head.Mixed -> R.string.forge_ch_mixed
            ChangeSummary.Head.Steady -> R.string.forge_ch_steady
        }), style = Forge.type.title2.copy(fontWeight = FontWeight.Bold), color = colors.text)
        Text(when (head) {
            ChangeSummary.Head.Strong -> stringResource(R.string.forge_ch_strong_d, topName.orEmpty())
            ChangeSummary.Head.Tough -> stringResource(R.string.forge_ch_tough_d, topName.orEmpty())
            ChangeSummary.Head.Mixed -> stringResource(R.string.forge_ch_mixed_d, topName.orEmpty())
            ChangeSummary.Head.Steady -> stringResource(R.string.forge_ch_steady_d)
        }, style = Forge.type.caption, color = colors.textSecondary, maxLines = 1,
             overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
        Spacer(Modifier.height(ForgeMetrics.space2))
        BoxWithConstraints(Modifier.fillMaxWidth().height(8.dp).clearAndSetSemantics { }) {
            val usable = maxWidth - 4.dp
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                listOf(better to colors.charge, worse to colors.effort, steady to colors.textSecondary.copy(alpha = 0.2f))
                    .filter { it.first > 0 }.forEach { (n, c) ->
                        Box(Modifier.width(usable * (n.toFloat() / list.size)).height(8.dp).background(c, CircleShape))
                    }
            }
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Legend(better, stringResource(R.string.forge_ch_better), colors.charge)
            Legend(worse, stringResource(R.string.forge_ch_worse), colors.effort)
            Legend(steady, stringResource(R.string.forge_ch_held), colors.textTertiary)
        }
        val moved = list.filter { it.verdict == ChangeSummary.Verdict.Better || it.verdict == ChangeSummary.Verdict.Worse }.take(3)
        moved.forEachIndexed { i, row ->
            if (i > 0) Box(Modifier.padding(start = 40.dp).fillMaxWidth().height(0.5.dp).background(colors.divider))
            val tint = row.measure.tile?.tileTint() ?: colors.rest
            Row(Modifier.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(28.dp).background(tint.copy(alpha = 0.16f), RoundedCornerShape(7.dp)), contentAlignment = Alignment.Center) {
                    Icon(row.measure.tile?.icon ?: Icons.Rounded.Bedtime, contentDescription = null,
                         tint = tint, modifier = Modifier.size(16.dp))
                }
                Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                    Text(measureName(row.measure), style = Forge.type.subhead.copy(fontWeight = FontWeight.Medium), color = colors.text, maxLines = 1)
                    Text(stringResource(R.string.forge_ch_from_to, valueText(row.measure, row.before, effortFormat),
                                        valueText(row.measure, row.now, effortFormat)),
                         style = Forge.type.captionNumber, color = colors.textSecondary, maxLines = 1)
                }
                Icon(if (row.change > 0) Icons.Rounded.ArrowUpward else Icons.Rounded.ArrowDownward, contentDescription = null,
                     tint = if (row.verdict == ChangeSummary.Verdict.Better) colors.charge else colors.effort, modifier = Modifier.size(14.dp))
            }
        }
    }
}

@Composable
private fun Legend(count: Int, word: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).background(color, CircleShape))
        Text(stringResource(R.string.forge_ch_count, count, word), style = Forge.type.captionNumber,
             color = Forge.colors.textSecondary, modifier = Modifier.padding(start = 4.dp))
    }
}

@Composable
private fun measureName(m: ChangeSummary.Measure): String = when (m.key) {
    "sleep_consistency" -> stringResource(R.string.forge_ch_consistency)
    "stress" -> stringResource(R.string.forge_ch_stress)
    "weight" -> stringResource(R.string.forge_ch_weight)
    else -> m.tile?.tileLabel() ?: stringResource(R.string.forge_sleep)
}

/** A mean as its tile prints it: hours and minutes for sleep, the Effort scale for Effort, units for the rest. */
@Composable
private fun valueText(m: ChangeSummary.Measure, v: Double, effort: (Double) -> String): String = when (m.metric) {
    CoreRead.Metric.SleepMinutes -> stringResource(R.string.forge_pair_words, TodayTimeline.hoursMinutes(v), stringResource(R.string.forge_goals_u_h))
    CoreRead.Metric.Effort -> effort(v)
    CoreRead.Metric.Hrv -> stringResource(R.string.forge_pair_words, Math.round(v).toString(), stringResource(R.string.forge_unit_ms))
    CoreRead.Metric.RestingHr -> stringResource(R.string.forge_pair_words, Math.round(v).toString(), stringResource(R.string.forge_unit_bpm))
    CoreRead.Metric.RespRate -> stringResource(R.string.forge_pair_words, "%.1f".format(java.util.Locale.getDefault(), v), stringResource(R.string.forge_unit_breaths))
    CoreRead.Metric.Steps -> java.text.NumberFormat.getIntegerInstance().format(Math.round(v))
    else -> when (m.key) {
        "sleep_consistency" -> "${Math.round(v)} %"
        "stress" -> "%.1f".format(java.util.Locale.getDefault(), v)
        "weight" -> stringResource(R.string.forge_pair_words, "%.1f".format(java.util.Locale.getDefault(), v), "kg")
        else -> Math.round(v).toString()
    }
}
