package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreRead
import com.noop.ui.AppViewModel
import com.noop.ui.EffortScale
import com.noop.ui.UnitFormatter
import com.noop.ui.UnitPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.time.temporal.IsoFields
import java.time.temporal.TemporalAdjusters
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Fork (DX23876), Forge parity 2026-11: the week in figures, as iOS's `ForgeWeekly`: this week against the one before,
 * from daily values other screens already show. Pure; nothing is scored again or stored. Analysis migration
 * required: no.
 */
internal object ForgeWeekly {
    data class DayValues(val charge: Double? = null, val effort: Double? = null, val rest: Double? = null,
                         val asleepMin: Double? = null, val steps: Double? = null)

    data class Week(val days: List<String>, val values: List<DayValues>) {
        fun mean(pick: (DayValues) -> Double?): Double? = values.mapNotNull(pick).takeIf { it.isNotEmpty() }?.average()
        /** The day with the highest value, as its index in [days]. */
        fun bestIndex(pick: (DayValues) -> Double?): Int? =
            values.indices.mapNotNull { i -> pick(values[i])?.let { i to it } }.maxByOrNull { it.second }?.first
    }

    /**
     * The week holding [date] and the one before, the week starting on [firstDay]. On the week's first day the report
     * is about the week that just ended (iOS's anchor), so [anchor] steps back a day then.
     */
    fun weeks(date: LocalDate, firstDay: DayOfWeek, lookup: (String) -> DayValues): Pair<Week, Week> {
        val anchor = if (date.dayOfWeek == firstDay) date.minusDays(1) else date
        val start = anchor.with(TemporalAdjusters.previousOrSame(firstDay))
        fun week(first: LocalDate): Week {
            val keys = (0..6).map { first.plusDays(it.toLong()).toString() }
            return Week(keys, keys.map(lookup))
        }
        return week(start) to week(start.minusDays(7))
    }
}

/** The new design's weekly report (iOS `ForgeWeeklyReportView`), opened from Health's long-term group. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ForgeWeeklyReportPage(viewModel: AppViewModel, onBack: () -> Unit, onAsk: ((String) -> Unit)?) {
    val context = LocalContext.current
    val colors = Forge.colors
    val scale = remember { UnitPrefs.effortScale(context) }
    fun eff(v: Double) = UnitFormatter.effortValue(v, scale)
    val effortMax = if (scale == EffortScale.WHOOP) 21.0 else 100.0
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val workouts by viewModel.workouts.collectAsState()
    data class Loaded(val weeks: Pair<ForgeWeekly.Week, ForgeWeekly.Week>?, val needMin: Double)
    val loaded by produceState(Loaded(null, 480.0), coreRevision) {
        value = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val today = LocalDate.now()
            val from = today.minusDays(21).toString(); val to = today.toString()
            fun map(m: CoreRead.Metric) = CoreRead.series(m, from, to).associate { it.day to it.value }
            val charge = map(CoreRead.Metric.Charge); val effort = map(CoreRead.Metric.Effort); val rest = map(CoreRead.Metric.Rest)
            val sleep = map(CoreRead.Metric.SleepMinutes); val steps = map(CoreRead.Metric.Steps)
            // The training week starts where Training's does: Monday (Android never stores another start).
            val weeks = ForgeWeekly.weeks(today, DayOfWeek.MONDAY) { d ->
                ForgeWeekly.DayValues(charge[d], effort[d], rest[d], sleep[d], steps[d])
            }
            val traits = runCatching { viewModel.repo.restTraits(viewModel.activeStrapId) }.getOrNull()
            Loaded(weeks, (traits?.needHoursFor(to) ?: 8.0) * 60)
        }
    }
    val (thisWeek, lastWeek) = loaded.weeks ?: return
    val locale = Locale.getDefault()
    val dayMonth = DateTimeFormatter.ofPattern(android.text.format.DateFormat.getBestDateTimePattern(locale, "dMMM"), locale)
    fun narrow(key: String) = runCatching { LocalDate.parse(key).dayOfWeek.getDisplayName(TextStyle.NARROW, locale) }.getOrDefault("")
    SettingsColumn {
        PageTitle(null, onBack)
        val first = LocalDate.parse(thisWeek.days.first()); val last = LocalDate.parse(thisWeek.days.last())
        Column(Modifier.padding(horizontal = ForgeMetrics.space1)) {
            Text(stringResource(R.string.forge_wr_range, first.format(dayMonth), last.format(dayMonth)).uppercase(locale),
                 style = Forge.type.overline, color = Forge.sceneInk.secondary)
            Text(stringResource(R.string.forge_wr_week, first.get(IsoFields.WEEK_OF_WEEK_BASED_YEAR)),
                 style = Forge.type.title1, color = Forge.sceneInk.text)
        }
        // The coach's weekly review on top when there is one this week (iOS `weeklyNote`), else "Your week".
        val review by produceState<com.noop.core.CoreCoach.Note?>(null, coreRevision) {
            value = if (onAsk == null) null else withContext(Dispatchers.IO) {
                runCatching { com.noop.core.CoreCoach.notes(days = 7).firstOrNull { it.origin == "weeklyReview" } }.getOrNull()
            }
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            review?.let { note ->
                Text(stringResource(R.string.forge_cn_weekly), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.accent)
                Text(note.headline, style = Forge.type.title2.copy(fontWeight = FontWeight.Bold), color = colors.text)
                if (note.body.isNotEmpty()) Text(note.body.replace("**", ""), style = Forge.type.body, color = colors.textSecondary)
            } ?: Text(stringResource(R.string.forge_tr_your_week), style = Forge.type.title2.copy(fontWeight = FontWeight.Bold), color = colors.text)
            Spacer(Modifier.height(ForgeMetrics.space3))
            Row(Modifier.fillMaxWidth()) {
                WeekRing(thisWeek.mean { it.charge }, lastWeek.mean { it.charge }, stringResource(R.string.forge_charge), colors.charge,
                         OrganicMetric.Charge, Modifier.weight(1f)) { it.roundToInt().toString() }
                WeekRing(thisWeek.mean { it.effort }?.let(::eff), lastWeek.mean { it.effort }?.let(::eff), stringResource(R.string.forge_effort),
                         colors.effort, OrganicMetric.Effort, Modifier.weight(1f)) {
                    if (scale == EffortScale.WHOOP) "%.1f".format(locale, it) else it.roundToInt().toString()
                }
                WeekRing(thisWeek.mean { it.rest }, lastWeek.mean { it.rest }, stringResource(R.string.forge_rest), colors.rest,
                         OrganicMetric.Rest, Modifier.weight(1f)) { it.roundToInt().toString() }
            }
            Spacer(Modifier.height(ForgeMetrics.space3))
            Row(Modifier.fillMaxWidth()) {
                thisWeek.days.forEachIndexed { i, d ->
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                        val v = thisWeek.values[i]
                        WeekMiniRings(v.charge, v.effort, v.rest)
                        Text(narrow(d), style = Forge.type.caption, color = colors.textSecondary)
                    }
                }
            }
            if (onAsk != null) {
                Spacer(Modifier.height(ForgeMetrics.space3))
                val keepPrompt = stringResource(R.string.forge_wr_keep_prompt); val planPrompt = stringResource(R.string.forge_wr_plan_prompt)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(stringResource(R.string.forge_wr_keep) to keepPrompt, stringResource(R.string.forge_wr_plan) to planPrompt).forEach { (t, p) ->
                        Text(t, style = Forge.type.subhead, color = colors.accent,
                             modifier = Modifier.background(colors.accent.copy(alpha = 0.12f), CircleShape)
                                 .clickable(role = Role.Button) { onAsk(p) }.padding(horizontal = 14.dp, vertical = 8.dp))
                    }
                }
            }
        }
        // Highlights: the best day, the hardest session, sleep and steps against last week.
        SleepSectionTitle(stringResource(R.string.forge_sl_highlights))
        val tiles = mutableListOf<@Composable (Modifier) -> Unit>()
        thisWeek.bestIndex { it.charge }?.let { i ->
            val v = thisWeek.values[i].charge ?: return@let
            tiles += { m -> Highlight(m, stringResource(R.string.forge_wr_best_day), colors.charge,
                LocalDate.parse(thisWeek.days[i]).dayOfWeek.getDisplayName(TextStyle.SHORT, locale), null,
                stringResource(R.string.forge_wr_charge_pct, v.roundToInt())) }
        }
        val keys = thisWeek.days.toSet()
        workouts.filter { it.strain != null && java.time.Instant.ofEpochSecond(it.startTs).atZone(java.time.ZoneId.systemDefault()).toLocalDate().toString() in keys }
            .maxByOrNull { it.strain ?: 0.0 }?.let { row ->
                val day = java.time.Instant.ofEpochSecond(row.startTs).atZone(java.time.ZoneId.systemDefault()).dayOfWeek.getDisplayName(TextStyle.SHORT, locale)
                tiles += { m -> Highlight(m, stringResource(R.string.forge_wr_hardest), colors.effort,
                    if (scale == EffortScale.WHOOP) "%.1f".format(locale, eff(row.strain!!)) else eff(row.strain!!).roundToInt().toString(),
                    stringResource(R.string.forge_effort), stringResource(R.string.forge_wr_pair, com.noop.ui.WorkoutEditing.displaySport(row.sport), day)) }
            }
        thisWeek.mean { it.asleepMin }?.let { asleep ->
            val detail = lastWeek.mean { it.asleepMin }?.let { (asleep - it).roundToInt() }
            tiles += { m -> Highlight(m, stringResource(R.string.forge_wr_sleep), colors.rest, TodayTimeline.hoursMinutes(asleep),
                stringResource(R.string.forge_wr_h_avg), detail?.let { d -> stringResource(R.string.forge_wr_min_vs, if (d >= 0) "+" else "−", abs(d)) }) }
        }
        thisWeek.mean { it.steps }?.let { steps ->
            val pct = lastWeek.mean { it.steps }?.takeIf { it > 0 }?.let { ((steps - it) / it * 100).roundToInt() }
            tiles += { m -> Highlight(m, stringResource(R.string.forge_wr_steps), colors.charge, "%,d".format(locale, steps.roundToInt()),
                stringResource(R.string.forge_wr_avg), pct?.let { p -> stringResource(R.string.forge_wr_pct_vs, if (p >= 0) "+" else "−", abs(p)) }) }
        }
        tiles.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                pair.forEach { it(Modifier.weight(1f)) }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
        // Charge this week against last week, sleep against the need, Effort per day.
        ForgeCard(Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.forge_charge), style = Forge.type.headline, color = colors.text, modifier = Modifier.weight(1f))
                Text(stringResource(R.string.forge_wr_this_vs_last), style = Forge.type.caption, color = colors.textSecondary)
            }
            Spacer(Modifier.height(ForgeMetrics.space2))
            Canvas(Modifier.fillMaxWidth().height(150.dp)) {
                val slot = size.width / 7
                fun pt(i: Int, v: Double) = Offset(i * slot + slot / 2, (size.height - v / 100 * size.height).toFloat())
                fun line(values: List<Double?>, color: Color, width: Float, dash: Boolean) {
                    var prev: Offset? = null
                    values.forEachIndexed { i, v ->
                        if (v == null) { prev = null; return@forEachIndexed }
                        val p = pt(i, v)
                        prev?.let { drawLine(color, it, p, width, cap = StrokeCap.Round,
                                             pathEffect = if (dash) PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx())) else null) }
                        if (!dash) drawCircle(color, 3.5.dp.toPx(), p)
                        prev = p
                    }
                }
                line(lastWeek.values.map { it.charge }, colors.textTertiary, 1.5.dp.toPx(), true)
                line(thisWeek.values.map { it.charge }, colors.charge, 2.5.dp.toPx(), false)
            }
            WeekAxis(thisWeek.days.map(::narrow))
            Legend(listOf(Triple(stringResource(R.string.forge_wr_this_week), colors.charge, false),
                          Triple(stringResource(R.string.forge_wr_last_week), colors.textTertiary, true)))
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.forge_wr_sleep), style = Forge.type.headline, color = colors.text, modifier = Modifier.weight(1f))
                Text(stringResource(R.string.forge_wr_hours_need), style = Forge.type.caption, color = colors.textSecondary)
            }
            Spacer(Modifier.height(ForgeMetrics.space2))
            val hours = thisWeek.values.map { (it.asleepMin ?: 0.0) / 60 }
            val need = loaded.needMin / 60
            WeekBars(hours, (maxOf(hours.maxOrNull() ?: 0.0, need) * 1.15).coerceAtLeast(1.0), colors.rest,
                     thisWeek.bestIndex { it.asleepMin }, need)
            WeekAxis(thisWeek.days.map(::narrow))
            Legend(listOf(Triple(stringResource(R.string.forge_wr_asleep), colors.rest, false),
                          Triple(stringResource(R.string.forge_sl_need, TodayTimeline.hoursMinutes(loaded.needMin)), colors.textSecondary, true)))
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.forge_wr_load), style = Forge.type.headline, color = colors.text)
            Spacer(Modifier.height(ForgeMetrics.space2))
            WeekBars(thisWeek.values.map { eff(it.effort ?: 0.0) }, effortMax, colors.effort, thisWeek.bestIndex { it.effort }, null)
            WeekAxis(thisWeek.days.map(::narrow))
        }
        ForgeGoalsContextCard("training")
        ForgeGoalsContextCard("sleep")
        Spacer(Modifier.height(ForgeMetrics.space6))
    }
}

@Composable
private fun WeekRing(value: Double?, previous: Double?, name: String, tint: Color, metric: OrganicMetric, modifier: Modifier,
                     format: (Double) -> String) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        OrganicRing(value, tint, 84.dp, metric, format = format)
        Text(name, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = tint)
        if (value != null && previous != null) {
            val d = value - previous
            Text(stringResource(R.string.forge_wr_vs_last, (if (d >= 0) "↑ " else "↓ ") + format(abs(d))),
                 style = Forge.type.caption.copy(fontWeight = FontWeight.Medium), color = tint, textAlign = TextAlign.Center, maxLines = 2)
        }
    }
}

@Composable
private fun WeekMiniRings(charge: Double?, effort: Double?, rest: Double?) {
    val colors = Forge.colors
    Canvas(Modifier.size(32.dp)) {
        val w = 3.dp.toPx()
        listOf(charge to colors.charge, effort to colors.effort, rest to colors.rest).forEachIndexed { i, (v, c) ->
            val inset = w / 2 + i * (w + 1.dp.toPx())
            val arc = Size(size.width - inset * 2, size.height - inset * 2)
            drawArc(c.copy(alpha = 0.18f), 0f, 360f, false, Offset(inset, inset), arc, style = androidx.compose.ui.graphics.drawscope.Stroke(w))
            val f = ((v ?: 0.0) / 100).coerceIn(0.0, 1.0).toFloat()
            if (f > 0f) drawArc(c, -90f, 360f * f, false, Offset(inset, inset), arc,
                                style = androidx.compose.ui.graphics.drawscope.Stroke(w, cap = StrokeCap.Round))
        }
    }
}

@Composable
private fun Highlight(modifier: Modifier, label: String, tint: Color, value: String, unit: String?, detail: String?) {
    val colors = Forge.colors
    ForgeCard(modifier, contentPadding = 12.dp) {
        Text(label, style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = tint)
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value, style = Forge.type.title2.copy(fontWeight = FontWeight.SemiBold), color = colors.text, maxLines = 1)
            unit?.let { Text(it, style = Forge.type.subhead, color = colors.textSecondary, modifier = Modifier.padding(start = 4.dp, bottom = 2.dp)) }
        }
        detail?.let { Text(it, style = Forge.type.footnote, color = colors.textSecondary, maxLines = 1) }
    }
}

@Composable
private fun WeekBars(values: List<Double>, max: Double, tint: Color, best: Int?, rule: Double?) {
    val colors = Forge.colors
    Canvas(Modifier.fillMaxWidth().height(140.dp)) {
        val slot = size.width / values.size
        val w = slot * 0.62f
        values.forEachIndexed { i, v ->
            val h = (v / max * size.height).toFloat()
            drawRoundRect(tint.copy(alpha = if (i == best) 1f else 0.55f), Offset(i * slot + (slot - w) / 2, size.height - h), Size(w, h),
                          CornerRadius(6.dp.toPx(), 6.dp.toPx()))
        }
        rule?.let {
            val y = (size.height - it / max * size.height).toFloat()
            drawLine(colors.textSecondary, Offset(0f, y), Offset(size.width, y), 1.dp.toPx(),
                     pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx())))
        }
    }
}

@Composable
private fun WeekAxis(labels: List<String>) {
    Row(Modifier.fillMaxWidth().padding(top = 4.dp)) {
        labels.forEach { Text(it, style = Forge.type.caption, color = Forge.colors.textTertiary, textAlign = TextAlign.Center, modifier = Modifier.weight(1f)) }
    }
}

@Composable
private fun Legend(items: List<Triple<String, Color, Boolean>>) {
    Row(Modifier.padding(top = ForgeMetrics.space2), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        items.forEach { (t, c, thin) ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.width(14.dp).height(if (thin) 2.dp else 3.dp).background(c, CircleShape))
                Spacer(Modifier.width(4.dp))
                Text(t, style = Forge.type.caption, color = Forge.colors.textSecondary)
            }
        }
    }
}
