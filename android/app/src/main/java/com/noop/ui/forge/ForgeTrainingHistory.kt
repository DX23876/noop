package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.noop.R
import com.noop.core.CoreRead
import com.noop.core.CoreTrainingHistory
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.UnitFormatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

private val historySpans = listOf("threeMonths", "oneYear", "fiveYears", "all")
private val historyLanes = listOf("all", "strength", "cardio", "session")

@Composable
internal fun TrainingHistoryButton(onOpen: () -> Unit) {
    TextButton(onClick = onOpen) { Text(stringResource(R.string.forge_history_title)) }
}

/** Separate load lanes, period coverage and adaptation curves from the common Swift preparation. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ForgeTrainingHistoryPage(initialFocus: String = "all", onClose: () -> Unit) {
    val context = LocalContext.current
    val prefs = remember(context) { NoopPrefs.of(context) }
    val mass = strengthUnits()
    var focus by rememberSaveable { mutableStateOf(initialFocus) }
    var span by rememberSaveable { mutableStateOf(prefs.getString("trainingHistory.span", "oneYear") ?: "oneYear") }
    var lifts by rememberSaveable { mutableStateOf(prefs.getString("trainingHistory.lifts", "").orEmpty()) }
    var jump by rememberSaveable { mutableStateOf<String?>(null) }
    var choosingDate by remember { mutableStateOf(false) }
    var choosingLifts by remember { mutableStateOf(false) }
    var retry by remember { mutableIntStateOf(0) }
    var loaded by remember { mutableStateOf(false) }
    var output by remember { mutableStateOf<CoreTrainingHistory.Output?>(null) }
    LaunchedEffect(span, lifts, jump, retry) {
        loaded = false
        output = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val profile = ProfileStore.from(context)
            CoreTrainingHistory.read(span, jump, lifts.lineSequence().filter { it.isNotBlank() }.toList(),
                profile.hrMax.toDouble(), profile.sex, dismissedTrainingWorkouts(context))
        }
        loaded = true
    }
    BackHandler { onClose() }
    val o = output
    if (choosingDate && o != null) {
        val earliest = LocalDate.parse(o.earliest ?: o.today)
        val today = LocalDate.parse(o.today)
        val state = rememberDatePickerState(initialSelectedDateMillis = LocalDate.parse(o.jumpDay ?: o.today).toEpochDay() * 86_400_000,
            yearRange = earliest.year..today.year, selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                    val day = LocalDate.ofEpochDay(utcTimeMillis / 86_400_000)
                    return day >= earliest && day <= today
                }
            })
        DatePickerDialog(onDismissRequest = { choosingDate = false }, confirmButton = {
            TextButton(onClick = { state.selectedDateMillis?.let { jump = LocalDate.ofEpochDay(it / 86_400_000).toString() }; choosingDate = false }) {
                Text(stringResource(R.string.forge_library_ok))
            }
        }, dismissButton = { TextButton(onClick = { choosingDate = false }) { Text(stringResource(R.string.forge_th_cancel)) } }) {
            DatePicker(state, title = { Text(stringResource(R.string.forge_history_jump), modifier = Modifier.padding(ForgeMetrics.screenPadding)) })
        }
    }
    if (choosingLifts && o != null) AlertDialog(onDismissRequest = { choosingLifts = false },
        title = { Text(stringResource(R.string.forge_history_lifts_choice)) },
        text = {
            androidx.compose.foundation.lazy.LazyColumn(Modifier.heightIn(max = ForgeMetrics.chartHeight * 2)) {
                item { TextButton(onClick = { lifts = ""; prefs.edit().putString("trainingHistory.lifts", "").apply() }) { Text(stringResource(R.string.forge_history_most_trained)) } }
                items(o.choices.size) { index ->
                    val choice = o.choices[index]
                    val selected = lifts.lineSequence().filter { it.isNotBlank() }.toList()
                    Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                        Checkbox(checked = choice.id in selected, enabled = choice.id in selected || selected.size < 3,
                            onCheckedChange = { checked ->
                                lifts = (if (checked) selected + choice.id else selected - choice.id).joinToString("\n")
                                prefs.edit().putString("trainingHistory.lifts", lifts).apply()
                            })
                        Text(choice.title, style = Forge.type.subhead, color = Forge.colors.text)
                    }
                }
            }
        }, confirmButton = { TextButton(onClick = { choosingLifts = false }) { Text(stringResource(R.string.forge_th_done)) } })
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_history_title), onClose)
        ReportNote(stringResource(R.string.forge_history_subtitle))
        ForgeCard(Modifier.fillMaxWidth()) {
            ReportPicker(historyLaneName(focus), historyLanes.map { historyLaneName(it) }) { focus = historyLanes[it] }
            ReportPicker(historySpanName(span), historySpans.map { historySpanName(it) }) {
                span = historySpans[it]; prefs.edit().putString("trainingHistory.span", span).apply()
            }
            if (o?.earliest != null) Row {
                TextButton(onClick = { choosingDate = true }) { Text(stringResource(R.string.forge_history_jump)) }
                if (jump != null) TextButton(onClick = { jump = null }) { Text(stringResource(R.string.nav_today)) }
            }
        }
        if (!loaded) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (!loaded) return@SettingsColumn
        if (o == null) {
            ReportNote(stringResource(R.string.forge_history_unavailable))
            TextButton(onClick = { retry++ }) { Text(stringResource(R.string.forge_report_retry)) }
            return@SettingsColumn
        }
        ReportHeading(stringResource(R.string.forge_history_guide_title))
        ReportNote(stringResource(R.string.forge_history_guide))
        if (focus == "all" || focus == "strength") HistoryLane(o, "strength", o.strength, TrainingLane.Strength.color) {
            HistoryAdaptations(o, o.lifts.mapIndexed { index, lift ->
                HistoryCurve(lift.title, lift.values, listOf(TrainingLane.Strength.color,
                    TrainingLane.Strength.bright, TrainingLane.Strength.deep)[index % 3])
            }, stringResource(R.string.forge_report_best_e1rm), { UnitFormatter.massFromKilograms(it, mass) })
            TextButton(onClick = { choosingLifts = true }) {
                Text(stringResource(if (lifts.isEmpty()) R.string.forge_history_lifts_auto else R.string.forge_history_lifts_choice))
            }
        }
        if (focus == "all" || focus == "cardio") HistoryLane(o, "cardio", o.cardio, TrainingLane.Cardio.color) {
            HistoryAdaptations(o, listOf(HistoryCurve("NOOP", o.vo2, TrainingLane.Cardio.color),
                HistoryCurve("Apple Watch", o.vo2Apple, Forge.colors.textSecondary, dotsOnly = true)),
                stringResource(R.string.forge_history_vo2), { historyNumber(it, 1) })
        }
        if (focus == "all" || focus == "session") HistoryLane(o, "session", o.session, Forge.colors.textSecondary) {}
        ForgeCard(Modifier.fillMaxWidth()) {
            ReportHeading(stringResource(R.string.forge_history_why))
            ReportNote(stringResource(R.string.forge_history_separate))
            ReportNote(stringResource(R.string.forge_history_band_note))
        }
    }
}

@Composable
private fun historyLaneName(id: String): String = stringResource(when (id) {
    "strength" -> R.string.forge_th_strength
    "cardio" -> R.string.forge_tl_cardio
    "session" -> R.string.forge_tl_session_load
    else -> R.string.forge_history_all
})

@Composable
private fun historySpanName(id: String): String = stringResource(when (id) {
    "threeMonths" -> R.string.forge_history_three_months
    "fiveYears" -> R.string.forge_history_five_years
    "all" -> R.string.trends_all_history
    else -> R.string.forge_history_one_year
})

@Composable
private fun HistoryLane(o: CoreTrainingHistory.Output, id: String, periods: List<CoreTrainingHistory.Period>,
                        color: Color, adaptation: @Composable () -> Unit) {
    ForgeCard(Modifier.fillMaxWidth()) {
        ReportHeading(historyLaneName(id))
        val unit = when (id) {
            "strength" -> stringResource(R.string.forge_history_weighted_sets)
            "cardio" -> "TRIMP"
            else -> stringResource(R.string.forge_history_session_unit)
        }
        ReportNote(unit)
        adaptation()
        val recorded = periods.filter { it.knownDays + it.unknownDays + it.estimatedDays > 0 }
        if (recorded.isEmpty()) ReportNote(stringResource(R.string.forge_history_empty)) else {
            HistoryBars(o, periods, color, unit)
            o.jumpDay?.let { day -> periods.firstOrNull { day >= it.start && day <= it.end }?.let { p ->
                ReportFact(historyDate(p.start), (p.total?.let { historyNumber(it) + " " + unit }
                    ?: stringResource(R.string.forge_history_unmeasured)))
                p.estimatedTotal?.let { ReportNote(stringResource(R.string.forge_history_estimated, historyNumber(it))) }
                p.band?.let { ReportNote(bandLabel(it)) }
            } }
            val possible = recorded.mapNotNull { it.possible }.sum()
            if (possible > 0) ReportNote(stringResource(R.string.forge_history_rated,
                recorded.mapNotNull { it.measured }.sum(), possible))
            val gaps = recorded.count { it.unknownDays > 0 }
            if (gaps > 0) ReportNote(stringResource(R.string.forge_history_gaps, gaps, recorded.size))
            if (recorded.any { it.estimatedDays > 0 }) ReportNote(stringResource(R.string.forge_history_estimate_note))
        }
    }
}

/** The x-axis uses calendar-day widths, including truncated final weeks and variable-length months. */
@Composable
private fun HistoryBars(o: CoreTrainingHistory.Output, periods: List<CoreTrainingHistory.Period>, color: Color, unit: String) {
    val start = LocalDate.parse(o.first).toEpochDay()
    val end = LocalDate.parse(o.last).toEpochDay() + 1
    val widthDays = (end - start).coerceAtLeast(1).toFloat()
    val peak = periods.maxOfOrNull { maxOf((it.total ?: 0.0) + (it.estimatedTotal ?: 0.0), it.level ?: 0.0) }?.coerceAtLeast(1.0) ?: 1.0
    val bands = periods.map { bandColor(it.band).takeIf { _ -> it.band != null } }
    val neutral = Forge.colors.textTertiary
    val highlight = Forge.colors.text
    val missing = stringResource(R.string.forge_history_unmeasured)
    val descriptions = periods.map { p ->
        "${historyDate(p.start)}: ${p.total?.let { historyNumber(it) + " " + unit } ?: missing}" +
            (if (p.unknownDays > 0) "; ${stringResource(R.string.forge_history_unknown_days, p.unknownDays)}" else "") +
            (p.estimatedTotal?.let { "; " + stringResource(R.string.forge_history_estimated, historyNumber(it)) } ?: "") +
            (p.band?.let { "; " + bandLabel(it) } ?: "")
    }
    val description = descriptions.joinToString("; ")
    Canvas(Modifier.fillMaxWidth().height(ForgeMetrics.chartHeight).semantics { contentDescription = description }) {
        val strip = ForgeMetrics.space2.toPx()
        val top = strip * 2; val bottom = size.height - strip
        fun x(day: String, after: Boolean = false) = size.width * (LocalDate.parse(day).toEpochDay() + (if (after) 1 else 0) - start) / widthDays
        fun y(value: Double) = bottom - ((bottom - top) * value / peak).toFloat()
        var previous: Offset? = null
        periods.forEachIndexed { i, p ->
            val a = x(p.start); val b = x(p.end, true); val inset = (b - a) * 0.12f
            bands[i]?.let { drawRect(it, Offset(a, 0f), Size(b - a, strip)) }
            if (p.unknownDays > 0) {
                val hatchWidth = (b - a - inset * 2).coerceAtLeast(1f)
                var lineY = top
                while (lineY < bottom) {
                    val rise = minOf(hatchWidth, bottom - lineY)
                    drawLine(neutral.copy(alpha = 0.4f), Offset(a + inset, lineY + rise), Offset(a + inset + rise, lineY), ForgeMetrics.hairline.toPx())
                    lineY += strip
                }
            }
            p.total?.let { drawRect(color.copy(alpha = if (p.unknownDays > 0) 0.55f else 1f),
                Offset(a + inset, y(it)), Size((b - a - inset * 2).coerceAtLeast(1f), (bottom - y(it)).coerceAtLeast(0f))) }
            p.estimatedTotal?.takeIf { it > 0 }?.let { estimate ->
                val base = p.total ?: 0.0
                drawRect(color.copy(alpha = 0.28f), Offset(a + inset, y(base + estimate)),
                    Size((b - a - inset * 2).coerceAtLeast(1f), (y(base) - y(base + estimate)).coerceAtLeast(0f)))
            }
            val point = p.level?.let { Offset((a + b) / 2, y(it)) }
            if (point != null) previous?.let { drawLine(neutral, it, point, ForgeMetrics.hairline.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(strip, strip))) }
            previous = point
            if (o.jumpDay?.let { it >= p.start && it <= p.end } == true) drawLine(highlight, Offset((a+b)/2, top), Offset((a+b)/2, bottom), ForgeMetrics.hairline.toPx())
        }
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        ReportNote(historyDate(o.first)); ReportNote(historyNumber(peak) + " " + unit); ReportNote(historyDate(o.last))
    }
}

private data class HistoryCurve(val title: String, val values: List<CoreTrainingHistory.Value>, val color: Color, val dotsOnly: Boolean = false)

@Composable
private fun HistoryAdaptations(o: CoreTrainingHistory.Output, curves: List<HistoryCurve>, label: String, format: (Double) -> String) {
    ReportNote(label)
    val valid = curves.flatMap { it.values }.mapNotNull { it.value }
    if (valid.isEmpty()) { ReportNote(stringResource(R.string.forge_no_data)); return }
    val low = valid.minOrNull()!!; val high = valid.maxOrNull()!!
    val spread = (high - low).takeIf { it > 0 } ?: maxOf(1.0, kotlin.math.abs(high) * 0.1)
    val lower = low - spread * 0.1; val upper = high + spread * 0.1
    val start = LocalDate.parse(o.first).toEpochDay(); val end = LocalDate.parse(o.last).toEpochDay() + 1
    val description = curves.joinToString("; ") { c -> c.title + ": " + c.values.mapNotNull { p -> p.value?.let { historyDate(p.start) + " " + format(it) } }.joinToString(", ") }
    Canvas(Modifier.fillMaxWidth().height(ForgeMetrics.chartHeight * 0.65f).semantics { contentDescription = description }) {
        curves.forEach { curve ->
            var previous: Offset? = null
            curve.values.forEach { p ->
                val point = p.value?.let { value ->
                    val middle = (LocalDate.parse(p.start).toEpochDay() + LocalDate.parse(p.end).toEpochDay() + 1) / 2.0
                    Offset((size.width * (middle - start) / (end - start).coerceAtLeast(1)).toFloat(),
                        (size.height * (1 - (value - lower) / (upper - lower))).toFloat())
                }
                if (point != null) {
                    if (!curve.dotsOnly) previous?.let { drawLine(curve.color, it, point, ForgeMetrics.hairline.toPx() * 2) }
                    drawCircle(curve.color, ForgeMetrics.hairline.toPx() * 3, point)
                }
                previous = point
            }
        }
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) { ReportNote(format(low)); ReportNote(format(high)) }
    curves.filter { it.values.any { p -> p.value != null } }.forEach { curve ->
        Text(curve.title, style = Forge.type.caption, color = curve.color)
    }
}

private fun historyDate(day: String): String = LocalDate.parse(day).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.SHORT).withLocale(Locale.getDefault()))
private fun historyNumber(value: Double, digits: Int = 0): String = NumberFormat.getNumberInstance(Locale.getDefault()).apply {
    minimumFractionDigits = digits; maximumFractionDigits = digits
}.format(value)
