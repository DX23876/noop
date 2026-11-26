package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.Flag
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreRead
import com.noop.core.CoreWeight
import com.noop.ui.UnitFormatter
import com.noop.ui.UnitPrefs
import com.noop.ui.UnitSystem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Fork (DX23876), owner decisions 2026-11-26: the weight page as iOS's `WeightDetailView`, in three sections
 * (overview, history, reports), every figure from the shared core's `WeightTracker` snapshot (`CoreWeight`). This
 * file words and draws; it computes nothing, so the page, the widgets and the iPhone read the scale alike.
 */
@Composable
internal fun ForgeWeightPage(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val units = UnitPrefs.system(context)
    var page by remember { mutableStateOf<CoreWeight.Page?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var revision by remember { mutableIntStateOf(0) }
    var section by remember { mutableIntStateOf(0) }
    var logging by remember { mutableStateOf<WeighInDraft?>(null) }
    var editingEvent by remember { mutableStateOf<EventDraft?>(null) }
    var settings by remember { mutableStateOf(false) }
    androidx.activity.compose.BackHandler(enabled = logging != null || editingEvent != null || settings) {
        logging = null; editingEvent = null; settings = false
    }
    LaunchedEffect(revision) {
        page = withContext(Dispatchers.IO) { CoreRead.open(context); CoreWeight.page(context) }
        loaded = true
        withContext(Dispatchers.IO) { com.noop.widget.WeightWidgets.publish(context, page) }
    }
    fun after(block: suspend () -> Boolean) {
        scope.launch { if (withContext(Dispatchers.IO) { block() }) revision++ }
    }
    val fmt = rememberWeightFormat(units)

    logging?.let { draft ->
        WeighInEditor(draft, fmt, onCancel = { logging = null }, onSave = { kg, at, note ->
            after {
                val ok = if (draft.id == null) CoreWeight.logWeight(kg, at, note) else CoreWeight.updateWeight(draft.id, kg, at, note)
                if (ok) { logging = null; com.noop.notif.BodyMeasurementReminder.refresh(context) }
                ok
            }
        }, onDelete = draft.id?.let { id -> { after { CoreWeight.deleteWeight(id).also { if (it) logging = null } } } })
        return
    }
    editingEvent?.let { draft ->
        EventEditor(draft, onCancel = { editingEvent = null }, onSave = { name, day ->
            after { CoreWeight.saveEvent(draft.id, name, day).also { if (it) editingEvent = null } }
        }, onDelete = draft.id?.let { id -> { after { CoreWeight.deleteEvent(id).also { if (it) editingEvent = null } } } })
        return
    }
    if (settings) {
        page?.let { p ->
            WeightSettingsPage(p.settings, p.snapshot?.rates, fmt, onBack = { settings = false }) { next ->
                after { CoreWeight.saveSettings(next).also { if (it) settings = false } }
            }
        }
        return
    }

    SettingsColumn {
        PageTitle(stringResource(R.string.wt_title), onBack) {
            IconButton(onClick = { settings = true }) {
                Icon(Icons.Rounded.Tune, contentDescription = stringResource(R.string.wt_settings), tint = WEIGHT_TINT.resolve())
            }
        }
        val p = page
        val s = p?.snapshot
        if (p == null || s == null) {
            if (loaded) {
                ForgeCard(Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.wt_empty_title), style = Forge.type.headline, color = Forge.colors.text)
                    Text(stringResource(R.string.wt_empty_body), style = Forge.type.footnote, color = Forge.colors.textSecondary)
                }
                LogButton { logging = WeighInDraft(null, null, Instant.now(), null) }
            } else {
                Text(stringResource(R.string.forge_goals_loading), style = Forge.type.body, color = Forge.colors.textSecondary)
            }
            return@SettingsColumn
        }
        Hero(s, p.goalSource == "dietPlan", fmt)
        ForgeSegmented(listOf(stringResource(R.string.wt_overview), stringResource(R.string.wt_history),
                              stringResource(R.string.wt_reports)), section, Modifier.fillMaxWidth()) { section = it }
        when (section) {
            0 -> Overview(p, s, fmt, onRate = { mode -> after { CoreWeight.saveSettings(p.settings.copy(rateMode = mode)) } },
                          onEvent = { editingEvent = it }, onLog = { logging = WeighInDraft(null, s.latest.kg, Instant.now(), null) })
            1 -> History(p, s, fmt, onLog = { logging = WeighInDraft(null, s.latest.kg, Instant.now(), null) },
                         onEdit = { row -> row.reading.id?.let { logging = WeighInDraft(it, row.reading.kg, Instant.ofEpochSecond(row.reading.at), row.reading.note) } })
            else -> Reports(p, s, fmt)
        }
    }
}

/** The core's names for a forecast's start and its planned rate's source (`WeightTracker`). */
private const val BASIS_LOW = "tenDayLow"
private const val WISH_PLAN = "dietPlan"
private const val WISH_GOAL = "goal"
private const val WISH_MANUAL = "manual"
private const val SOURCE_NOOP = "noop"

/** The page's one colour: the pink of its picture, as on iOS. */
internal val WEIGHT_TINT = ForgeTokens.Color.systemPink

internal data class WeighInDraft(val id: String?, val kg: Double?, val at: Instant, val note: String?)
internal data class EventDraft(val id: String?, val name: String, val day: LocalDate)

/** Number and date formatting made once per page: a pattern per row is what filled a tester's heap (2026-11-22). */
internal class WeightFormat(val units: UnitSystem, val unit: String, private val locale: Locale) {
    private val one = NumberFormat.getNumberInstance(locale).apply { minimumFractionDigits = 1; maximumFractionDigits = 1 }
    private val zone = ZoneId.systemDefault()
    val dayMonth: DateTimeFormatter = DateTimeFormatter.ofPattern(
        android.text.format.DateFormat.getBestDateTimePattern(locale, "dMMM"), locale)
    val dayMonthYear: DateTimeFormatter = DateTimeFormatter.ofPattern(
        android.text.format.DateFormat.getBestDateTimePattern(locale, "dMMMy"), locale)
    val monthYear: DateTimeFormatter = DateTimeFormatter.ofPattern(
        android.text.format.DateFormat.getBestDateTimePattern(locale, "MMMMy"), locale)
    val year: DateTimeFormatter = DateTimeFormatter.ofPattern("y", locale)

    fun value(kg: Double): Double = if (units == UnitSystem.IMPERIAL) UnitFormatter.kgToPounds(kg) else kg
    fun number(kg: Double): String = one.format(value(kg))
    fun mass(kg: Double): String = "${number(kg)} $unit"
    fun signed(kg: Double): String = (if (kg > 0.05) "+" else if (kg < -0.05) "−" else "") + "${one.format(kotlin.math.abs(value(kg)))} $unit"
    fun signedNumber(kg: Double): String = (if (kg > 0.05) "+" else if (kg < -0.05) "−" else "") + one.format(kotlin.math.abs(value(kg)))
    fun day(epoch: Long, f: DateTimeFormatter = dayMonth): String = Instant.ofEpochSecond(epoch).atZone(zone).format(f)
    fun dayKey(key: String, f: DateTimeFormatter = dayMonthYear): String = runCatching { LocalDate.parse(key).format(f) }.getOrDefault(key)
}

@Composable
internal fun rememberWeightFormat(units: UnitSystem): WeightFormat {
    val unit = UnitFormatter.massUnit(units)
    return remember(units, unit) { WeightFormat(units, unit, Locale.getDefault()) }
}

@Composable
private fun Hero(s: CoreWeight.Snapshot, fromPlan: Boolean, fmt: WeightFormat) {
    val colors = Forge.colors
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.Bottom) {
            Column(Modifier.weight(1f)) {
                Text(fmt.mass(s.latest.kg), style = Forge.type.heroNumber, color = colors.text, maxLines = 1)
                // Relative, as iOS says it ("2 hours ago"), so a stale weigh-in reads as stale at a glance.
                val ago = android.text.format.DateUtils.getRelativeTimeSpanString(
                    minOf(s.latest.at * 1000, System.currentTimeMillis()), System.currentTimeMillis(),
                    android.text.format.DateUtils.MINUTE_IN_MILLIS).toString()
                Text(stringResource(R.string.wt_last_weigh_in, ago),
                     style = Forge.type.footnote, color = colors.textSecondary)
            }
            Column(horizontalAlignment = Alignment.End) {
                Text(fmt.mass(s.trendKg), style = Forge.type.title2, color = colors.text)
                Text(stringResource(if (s.trendSettled) R.string.wt_trend else R.string.wt_trend_settling),
                     style = Forge.type.footnote, color = colors.textSecondary)
            }
        }
        s.goal?.let { g ->
            val maintain = g.band != null || g.baseline == g.target
            Text(stringResource(if (maintain) R.string.wt_goal_stay else R.string.wt_goal, fmt.mass(g.target)),
                 style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
            if (fromPlan) Text(stringResource(R.string.wt_goal_from_plan), style = Forge.type.footnote, color = colors.textTertiary)
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = Forge.type.title2, color = Forge.colors.text, modifier = Modifier.semantics { heading() })
}

@Composable
private fun LogButton(onClick: () -> Unit) {
    val tint = WEIGHT_TINT.resolve()
    // Tinted, as iOS's prominent button draws it in the new design: a wash of the page colour, the label in it.
    Box(Modifier.fillMaxWidth().height(50.dp).background(tint.copy(alpha = 0.18f), RoundedCornerShape(14.dp))
            .clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.AddCircle, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.wt_log), style = Forge.type.headline, color = tint)
        }
    }
}

/** Tinted only against a goal: without one, losing is not "good" and gaining is not "bad". */
@Composable
private fun deltaColor(delta: Double?, goal: CoreWeight.Goal?): Color {
    val colors = Forge.colors
    if (delta == null || kotlin.math.abs(delta) <= 0.05 || goal == null || goal.band != null || goal.baseline == goal.target) return colors.text
    val toward = if (goal.target > goal.baseline) delta > 0 else delta < 0
    return if (toward) ForgeTokens.Color.systemGreen.resolve() else ForgeTokens.Color.systemOrange.resolve()
}

// MARK: Overview

@Composable
private fun Overview(p: CoreWeight.Page, s: CoreWeight.Snapshot, fmt: WeightFormat, onRate: (String) -> Unit,
                     onEvent: (EventDraft) -> Unit, onLog: () -> Unit) {
    val set = p.settings
    if (set.shows("milestones")) s.milestones?.let { m -> MilestonesCard(m, fmt) }
    if (set.shows("forecast")) ForecastCard(s, fmt, onRate)
    if (set.shows("events")) EventsCard(s, fmt, onEvent)
    if (set.shows("changes")) ChangesCard(s, fmt)
    if (set.shows("week")) s.week?.let { WeekCard(it, fmt) }
    LogButton(onLog)
}

@Composable
private fun MilestonesCard(m: CoreWeight.Milestones, fmt: WeightFormat) {
    val colors = Forge.colors
    val tint = WEIGHT_TINT.resolve()
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(96.dp), contentAlignment = Alignment.Center) {
                val track = colors.inset
                Canvas(Modifier.size(96.dp)) {
                    val stroke = Stroke(width = 9.dp.toPx(), cap = StrokeCap.Round)
                    drawArc(track, 135f, 270f, false, style = stroke)
                    drawArc(tint, 135f, 270f * m.progress.toFloat().coerceIn(0f, 1f), false, style = stroke)
                }
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(NumberFormat.getPercentInstance(Locale.getDefault()).format(m.progress.coerceIn(0.0, 1.0)),
                         style = Forge.type.headline, color = colors.text)
                    Text(stringResource(R.string.wt_of_the_way), style = Forge.type.caption, color = colors.textSecondary)
                }
            }
            Spacer(Modifier.width(ForgeMetrics.space4))
            Column(Modifier.weight(1f)) {
                if (m.next != null) {
                    Text(stringResource(R.string.wt_next_stop), style = Forge.type.footnote, color = colors.textSecondary)
                    Text(fmt.mass(m.next), style = Forge.type.title1, color = colors.text)
                    m.toNextKg?.let { Text(stringResource(R.string.wt_to_go, fmt.mass(it)), style = Forge.type.footnote, color = colors.textSecondary) }
                } else {
                    Text(stringResource(R.string.wt_all_stops), style = Forge.type.headline, color = colors.text)
                }
            }
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        Row(verticalAlignment = Alignment.CenterVertically) {
            m.route.forEachIndexed { i, stop ->
                val reached = stop.reachedDay != null
                if (i > 0) Box(Modifier.weight(1f).height(3.dp).background(if (reached) tint else colors.divider))
                Box(Modifier.size(14.dp).background(if (reached) tint else colors.surface, CircleShape)
                        .border(2.dp, if (reached) tint else colors.textTertiary, CircleShape))
            }
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Text(stringResource(R.string.wt_stops_reached, m.reachedCount, m.route.size),
             style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
    }
}

@Composable
private fun ForecastCard(s: CoreWeight.Snapshot, fmt: WeightFormat, onRate: (String) -> Unit) {
    val colors = Forge.colors
    val f = s.forecast
    val modes = listOf("current", "overall", "wish")
    SectionTitle(stringResource(R.string.wt_forecast))
    ForgeCard(Modifier.fillMaxWidth()) {
        ForgeSegmented(listOf(stringResource(R.string.wt_rate_current), stringResource(R.string.wt_rate_overall),
                              stringResource(R.string.wt_rate_plan)), modes.indexOf(f.rateMode).coerceAtLeast(0),
                       Modifier.fillMaxWidth()) { onRate(modes[it]) }
        Spacer(Modifier.height(ForgeMetrics.space3))
        Text(forecastSentence(s, fmt), style = Forge.type.body, color = colors.text)
        Spacer(Modifier.height(ForgeMetrics.space2))
        val fromLow = f.basis == BASIS_LOW
        val basisLine = if (fromLow) stringResource(R.string.wt_basis_low, fmt.mass(f.startKg), fmt.day(f.startAt))
                        else stringResource(R.string.wt_basis_trend, fmt.mass(f.startKg))
        Text(basisLine, style = Forge.type.footnote, color = colors.textSecondary)
        if (f.rateMode == "wish") {
            val wishLine = when (s.rates.wishSource) {
                WISH_PLAN -> R.string.wt_wish_plan; WISH_GOAL -> R.string.wt_wish_goal; WISH_MANUAL -> R.string.wt_wish_manual
                else -> R.string.wt_wish_none
            }
            Text(stringResource(wishLine), style = Forge.type.footnote, color = colors.textSecondary)
            if (s.rates.wishIsSteep) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Warning, null, tint = ForgeTokens.Color.systemOrange.resolve(), modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.wt_wish_steep), style = Forge.type.footnote, color = ForgeTokens.Color.systemOrange.resolve())
                }
            }
        }
    }
}

@Composable
private fun forecastSentence(s: CoreWeight.Snapshot, fmt: WeightFormat): String {
    val f = s.forecast
    val rate = f.rateKgPerWeek?.let { stringResource(R.string.wt_per_week, fmt.signed(it)) } ?: "—"
    val target = fmt.mass(s.goal?.target ?: 0.0)
    return when (f.state) {
        "arriving" -> {
            val date = f.targetAt?.let { fmt.day(it, fmt.dayMonthYear) } ?: ""
            if (f.rateMode == "wish") stringResource(R.string.wt_fc_arriving_plan, rate, target, date)
            else stringResource(R.string.wt_fc_arriving, rate, target, date)
        }
        "reached" -> stringResource(R.string.wt_fc_reached)
        "movingAway" -> stringResource(R.string.wt_fc_away, rate)
        "tooSlow" -> stringResource(R.string.wt_fc_slow, rate)
        "notEnoughData" -> stringResource(if (f.rateMode == "wish") R.string.wt_fc_no_plan else R.string.wt_fc_too_few)
        "withinBand" -> stringResource(R.string.wt_fc_in_band)
        "outsideBand" -> stringResource(R.string.wt_fc_out_band)
        else -> if (f.rateKgPerWeek == null) stringResource(R.string.wt_fc_too_few) else stringResource(R.string.wt_fc_no_goal, rate)
    }
}

@Composable
private fun EventsCard(s: CoreWeight.Snapshot, fmt: WeightFormat, onEvent: (EventDraft) -> Unit) {
    val colors = Forge.colors
    val current = s.events.filter { it.phase != "archived" }
    val archived = s.events.filter { it.phase == "archived" }
    var showArchive by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f)) { SectionTitle(stringResource(R.string.wt_dates)) }
        TextButton(onClick = { onEvent(EventDraft(null, "", LocalDate.now().plusMonths(1))) }) {
            Text(stringResource(R.string.wt_add), color = WEIGHT_TINT.resolve(), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold))
        }
    }
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
        if (current.isEmpty()) {
            Text(stringResource(R.string.wt_dates_empty), style = Forge.type.footnote, color = colors.textSecondary,
                 modifier = Modifier.padding(ForgeMetrics.space4))
        }
        current.forEachIndexed { i, e ->
            if (i > 0) HorizontalDivider(color = colors.divider, modifier = Modifier.padding(start = ForgeMetrics.space4))
            EventRow(e, fmt, onEvent)
        }
        if (archived.isNotEmpty()) {
            HorizontalDivider(color = colors.divider)
            Text(stringResource(R.string.wt_past_dates, archived.size), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold),
                 color = colors.textSecondary,
                 modifier = Modifier.fillMaxWidth().clickable { showArchive = !showArchive }.padding(ForgeMetrics.space4))
            if (showArchive) archived.forEach { EventRow(it, fmt, onEvent) }
        }
    }
}

@Composable
private fun EventRow(e: CoreWeight.EventForecast, fmt: WeightFormat, onEvent: (EventDraft) -> Unit) {
    val colors = Forge.colors
    val date = fmt.dayKey(e.event.day)
    Row(Modifier.fillMaxWidth().clickable {
            onEvent(EventDraft(e.event.id, e.event.name, runCatching { LocalDate.parse(e.event.day) }.getOrDefault(LocalDate.now())))
        }.padding(horizontal = ForgeMetrics.space4, vertical = ForgeMetrics.space3),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(e.event.name, style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
            Text(when {
                e.phase != "upcoming" -> date
                e.daysAway == 0 -> stringResource(R.string.wt_date_today, date)
                else -> pluralStringResource(R.plurals.wt_date_in_days, e.daysAway, date, e.daysAway)
            }, style = Forge.type.footnote, color = colors.textSecondary)
        }
        Column(horizontalAlignment = Alignment.End) {
            if (e.phase == "upcoming") {
                Text(e.predictedKg?.let { fmt.mass(it) } ?: "—", style = Forge.type.headline, color = colors.text)
                Text(stringResource(R.string.wt_expected), style = Forge.type.caption, color = colors.textSecondary)
            } else {
                Text(e.measuredKg?.let { fmt.mass(it) } ?: "—", style = Forge.type.headline, color = colors.text)
                Text(e.predictedBeforeKg?.let { stringResource(R.string.wt_measured_vs, fmt.mass(it)) } ?: stringResource(R.string.wt_measured),
                     style = Forge.type.caption, color = colors.textSecondary)
            }
        }
    }
}

@Composable
private fun ChangesCard(s: CoreWeight.Snapshot, fmt: WeightFormat) {
    val colors = Forge.colors
    SectionTitle(stringResource(R.string.wt_change))
    ForgeCard(Modifier.fillMaxWidth()) {
        Row {
            listOf(7, 30, 90, null).forEach { days ->
                val value = s.changes.firstOrNull { it.days == days }?.kg
                Column(Modifier.weight(1f)) {
                    Text(value?.let { fmt.signed(it) } ?: "—", style = Forge.type.headline, color = deltaColor(value, s.goal), maxLines = 1)
                    Text(if (days == null) stringResource(R.string.wt_since_start) else pluralStringResource(R.plurals.wt_days, days, days),
                         style = Forge.type.footnote, color = colors.textSecondary)
                }
            }
        }
    }
}

@Composable
private fun WeekCard(w: CoreWeight.Week, fmt: WeightFormat) {
    val colors = Forge.colors
    val tint = WEIGHT_TINT.resolve()
    SectionTitle(stringResource(R.string.wt_this_week))
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            // A line needs two points; a week with one weigh-in shows its figures alone.
            if (w.readings.size > 1 || w.trend.size > 1) {
                WeightLines(w.readings, w.trend, null, null, Modifier.weight(1f).height(110.dp), dots = false)
                Spacer(Modifier.width(ForgeMetrics.space3))
            }
            Column(if (w.readings.size > 1 || w.trend.size > 1) Modifier.width(132.dp) else Modifier.fillMaxWidth(),
                   verticalArrangement = Arrangement.spacedBy(6.dp)) {
                WeekFigure(stringResource(R.string.wt_high), fmt.mass(w.high.kg), ForgeTokens.Color.systemOrange.resolve())
                WeekFigure(stringResource(R.string.wt_latest), fmt.mass(w.latest.kg), colors.text)
                WeekFigure(stringResource(R.string.wt_trend_label), fmt.mass(w.trendKg), tint)
                WeekFigure(stringResource(R.string.wt_low), fmt.mass(w.low.kg), ForgeTokens.Color.systemGreen.resolve())
            }
        }
    }
}

@Composable
private fun WeekFigure(label: String, value: String, tint: Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = tint, modifier = Modifier.weight(1f))
        Text(value, style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
    }
}

/**
 * The scale's readings as dots (or a thin line) and the trend as the page's line, with the goal as a dashed rule and
 * a maintain goal's band behind it. Drawn here rather than in a chart library, as the other Forge cards draw theirs.
 */
@Composable
private fun WeightLines(readings: List<CoreWeight.Point>, trend: List<CoreWeight.Point>, goalKg: Double?, band: Double?,
                        modifier: Modifier, dots: Boolean = true, labels: Boolean = dots) {
    val colors = Forge.colors
    val tint = WEIGHT_TINT.resolve()
    val goalColor = ForgeTokens.Color.systemGreen.resolve()
    val faint = colors.textTertiary
    val labelColor = colors.textSecondary.toArgb()
    val goalWord = stringResource(R.string.wt_goal_word)
    val density = androidx.compose.ui.platform.LocalDensity.current
    val labelPx = with(density) { 11.sp.toPx() }
    Canvas(modifier) {
        val all = readings + trend
        if (all.isEmpty()) return@Canvas
        val values = all.map { it.kg } + listOfNotNull(goalKg?.let { it - (band ?: 0.0) }, goalKg?.let { it + (band ?: 0.0) })
        val lo = values.min() - 0.5
        val hi = values.max() + 0.5
        val t0 = all.minOf { it.at }.toFloat()
        val t1 = all.maxOf { it.at }.toFloat().coerceAtLeast(t0 + 1f)
        fun x(t: Long) = (t - t0) / (t1 - t0) * size.width
        fun y(v: Double) = ((hi - v) / (hi - lo)).toFloat() * size.height
        // The axis: a few round values on the left, as iOS's chart labels them, and the goal line named.
        if (labels) {
            val paint = android.graphics.Paint().apply { color = labelColor; textSize = labelPx; isAntiAlias = true }
            val step = listOf(0.5, 1.0, 2.0, 5.0, 10.0, 20.0).firstOrNull { (hi - lo) / it <= 4 } ?: 50.0
            var v = kotlin.math.ceil(lo / step) * step
            while (v <= hi) {
                drawLine(faint.copy(alpha = 0.25f), Offset(0f, y(v)), Offset(size.width, y(v)), 1f)
                drawContext.canvas.nativeCanvas.drawText(if (step < 1) "%.1f".format(v) else "%.0f".format(v), 0f, y(v) - 4f, paint)
                v += step
            }
            if (goalKg != null) {
                paint.color = goalColor.toArgb(); paint.isFakeBoldText = true
                drawContext.canvas.nativeCanvas.drawText(goalWord, size.width - paint.measureText(goalWord), y(goalKg) - 6f, paint)
            }
        }
        if (goalKg != null) {
            if (band != null) drawRect(goalColor.copy(alpha = 0.12f), Offset(0f, y(goalKg + band)),
                                       androidx.compose.ui.geometry.Size(size.width, y(goalKg - band) - y(goalKg + band)))
            drawLine(goalColor, Offset(0f, y(goalKg)), Offset(size.width, y(goalKg)), 1.5.dp.toPx(),
                     pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 8f)))
        }
        if (dots) readings.forEach { drawCircle(faint, 2.dp.toPx(), Offset(x(it.at), y(it.kg))) }
        else if (readings.size > 1) {
            val path = Path().apply { readings.forEachIndexed { i, p -> if (i == 0) moveTo(x(p.at), y(p.kg)) else lineTo(x(p.at), y(p.kg)) } }
            drawPath(path, faint, style = Stroke(1.5.dp.toPx(), cap = StrokeCap.Round))
        }
        if (trend.size > 1) {
            val path = Path().apply { trend.forEachIndexed { i, p -> if (i == 0) moveTo(x(p.at), y(p.kg)) else lineTo(x(p.at), y(p.kg)) } }
            drawPath(path, tint, style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round))
        }
    }
}

// MARK: History

@Composable
private fun History(p: CoreWeight.Page, s: CoreWeight.Snapshot, fmt: WeightFormat, onLog: () -> Unit,
                    onEdit: (CoreWeight.LogRow) -> Unit) {
    val colors = Forge.colors
    var range by remember { mutableIntStateOf(1) }
    val ranges = listOf(30, 90, 365, 0)
    if (p.settings.shows("chart")) {
        ForgeCard(Modifier.fillMaxWidth()) {
            ForgeSegmented(listOf(pluralStringResource(R.plurals.wt_days, 30, 30), pluralStringResource(R.plurals.wt_days, 90, 90),
                                  stringResource(R.string.wt_one_year), stringResource(R.string.wt_all)), range, Modifier.fillMaxWidth()) { range = it }
            Spacer(Modifier.height(ForgeMetrics.space3))
            val cutoff = if (ranges[range] == 0) Long.MIN_VALUE else Instant.now().epochSecond - ranges[range] * 86_400L
            WeightLines(s.readings.filter { it.at >= cutoff }, s.trend.filter { it.at >= cutoff }, s.goal?.target, s.goal?.band,
                        Modifier.fillMaxWidth().height(220.dp))
            Spacer(Modifier.height(ForgeMetrics.space2))
            Text(stringResource(R.string.wt_chart_legend), style = Forge.type.caption, color = colors.textSecondary)
        }
    }
    LogButton(onLog)
    SectionTitle(stringResource(R.string.wt_logbook))
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
        Row(Modifier.padding(horizontal = ForgeMetrics.space4, vertical = ForgeMetrics.space2)) {
            Text(stringResource(R.string.wt_col_day), style = Forge.type.caption, color = colors.textSecondary, modifier = Modifier.weight(1f))
            Text(stringResource(R.string.wt_col_scale), style = Forge.type.caption, color = colors.textSecondary, modifier = Modifier.width(76.dp), textAlign = TextAlign.End)
            Text(stringResource(R.string.wt_col_trend), style = Forge.type.caption, color = colors.textSecondary, modifier = Modifier.width(64.dp), textAlign = TextAlign.End)
            Text(stringResource(R.string.wt_col_week), style = Forge.type.caption, color = colors.textSecondary, modifier = Modifier.width(56.dp), textAlign = TextAlign.End)
        }
        s.log.take(400).forEach { row ->
            HorizontalDivider(color = colors.divider, modifier = Modifier.padding(start = ForgeMetrics.space4))
            Column(Modifier.fillMaxWidth().clickable(enabled = row.reading.id != null) { onEdit(row) }
                       .padding(horizontal = ForgeMetrics.space4, vertical = ForgeMetrics.space2)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(fmt.day(row.reading.at), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
                        // Only an imported reading names its source: on every row of one's own it was noise.
                        if (row.reading.source != SOURCE_NOOP) {
                            Text(stringResource(R.string.wt_src_health), style = Forge.type.caption, color = colors.textTertiary)
                        }
                    }
                    Text(fmt.number(row.reading.kg), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text,
                         modifier = Modifier.width(76.dp), textAlign = TextAlign.End)
                    Text(fmt.number(row.trendKg), style = Forge.type.subhead, color = colors.textSecondary,
                         modifier = Modifier.width(64.dp), textAlign = TextAlign.End)
                    Text(row.weeklyRateKg?.let { fmt.signedNumber(it) } ?: "—", style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                         color = deltaColor(row.weeklyRateKg, s.goal), modifier = Modifier.width(56.dp), textAlign = TextAlign.End)
                }
                row.reading.note?.takeIf { it.isNotBlank() }?.let { Text(it, style = Forge.type.footnote, color = colors.textSecondary) }
                row.milestoneKg?.let { m ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.Flag, null, tint = WEIGHT_TINT.resolve(), modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(4.dp))
                        Text(stringResource(R.string.wt_reached, fmt.mass(m)), style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold),
                             color = WEIGHT_TINT.resolve())
                    }
                }
            }
        }
    }
    Text(stringResource(R.string.wt_log_hint), style = Forge.type.footnote, color = colors.textTertiary)
}

// MARK: Reports

@Composable
private fun Reports(p: CoreWeight.Page, s: CoreWeight.Snapshot, fmt: WeightFormat) {
    var period by remember { mutableIntStateOf(0) }
    ForgeSegmented(listOf(stringResource(R.string.wt_months), stringResource(R.string.wt_years)), period, Modifier.fillMaxWidth()) { period = it }
    val list = if (period == 0) s.months else s.years
    if (list.isEmpty()) {
        ForgeCard(Modifier.fillMaxWidth()) { Text(stringResource(R.string.wt_empty_title), style = Forge.type.body, color = Forge.colors.textSecondary) }
    }
    list.take(36).forEach { ReportCard(it, s.goal, fmt) }
}

@Composable
private fun ReportCard(r: CoreWeight.Report, goal: CoreWeight.Goal?, fmt: WeightFormat) {
    val colors = Forge.colors
    val title = Instant.ofEpochSecond(r.start).atZone(ZoneId.systemDefault()).format(if (r.period == "month") fmt.monthYear else fmt.year)
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title.replaceFirstChar { it.titlecase() }, style = Forge.type.headline, color = colors.text, modifier = Modifier.weight(1f))
            Text(pluralStringResource(R.plurals.wt_weigh_ins, r.count, r.count), style = Forge.type.footnote, color = colors.textSecondary)
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        if (!r.enough) {
            Text(stringResource(R.string.wt_report_too_few), style = Forge.type.footnote, color = colors.textSecondary)
            return@ForgeCard
        }
        Row {
            ReportFigure(stringResource(R.string.wt_lowest), r.low?.let { fmt.mass(it.kg) } ?: "—", r.low?.let { fmt.day(it.at) }, Modifier.weight(1f))
            ReportFigure(stringResource(R.string.wt_average), r.averageKg?.let { fmt.mass(it) } ?: "—",
                         r.vsPreviousKg?.let { stringResource(R.string.wt_vs_before, fmt.signed(it)) }, Modifier.weight(1f))
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Row {
            ReportFigure(stringResource(R.string.wt_trend_change), r.trendChangeKg?.let { fmt.signed(it) } ?: "—", null, Modifier.weight(1f))
            ReportFigure(stringResource(R.string.wt_per_week_label), r.ratePerWeekKg?.let { fmt.signed(it) } ?: "—", null, Modifier.weight(1f))
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        // The goal line only near the period's own values; far below, it flattens the period into a straight line.
        val lo = r.trend.minOfOrNull { it.kg }; val hi = r.trend.maxOfOrNull { it.kg }
        val goalNear = goal?.target?.takeIf { lo != null && hi != null && it >= lo - 2 && it <= hi + 2 }
        WeightLines(emptyList(), r.trend, goalNear, null, Modifier.fillMaxWidth().height(80.dp), labels = false)
    }
}

@Composable
private fun ReportFigure(label: String, value: String, sub: String?, modifier: Modifier) {
    val colors = Forge.colors
    Column(modifier) {
        Text(label, style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
        Text(value, style = Forge.type.headline, color = colors.text)
        sub?.let { Text(it, style = Forge.type.caption, color = colors.textSecondary) }
    }
}
