package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.material.icons.automirrored.rounded.DirectionsWalk
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.HourglassBottom
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.WbTwilight
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material3.Icon
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreAgeLess
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Fork (DX23876), Forge parity 2026-11: the AgeLess page as iOS's `ForgeAgeLessView`. One question, "am I ageing faster
 * or slower than the calendar, and what moves it?", answered by one age line: the actual age, the AgeLess age and where
 * the last 30 days lead in six months. Below it the story, the strongest next steps, where the years come from (sleep,
 * activity and fitness as bars either side of zero, each opening its measures) and the age over time, which also picks
 * the week the page shows. Every number arrives resolved from the shared core (`CoreAgeLess`). Analysis migration
 * required: no.
 */
@Composable
internal fun ForgeAgeLessPage(onBack: () -> Unit, onOpenRhythm: () -> Unit = {}) {
    val context = LocalContext.current
    var output by remember { mutableStateOf<CoreAgeLess.Output?>(null) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        output = withContext(Dispatchers.IO) { CoreRead.open(context); CoreAgeLess.snapshot(context) }
        loaded = true
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_ageless_title), onBack)
        val weeks = output?.weeks.orEmpty()
        if (weeks.isEmpty()) {
            AgelessCard {
                Text(stringResource(R.string.forge_al_health_age), style = Forge.type.headline, color = Forge.colors.text)
                Text(stringResource(if (loaded) R.string.forge_ageless_b_filling else R.string.forge_goals_loading),
                     style = Forge.type.body, color = Forge.colors.textSecondary)
            }
            return@SettingsColumn
        }
        var index by rememberSaveable { mutableIntStateOf(weeks.lastIndex) }
        val shown = index.coerceIn(0, weeks.lastIndex)
        val week = weeks[shown]
        AgeLessHero(week, isLatest = shown == weeks.lastIndex)
        NarrativeCard(week)
        if (week.levers.isNotEmpty()) LeversCard(week)
        AgelessSection(stringResource(R.string.forge_al_where))
        DomainsCard(week)
        if (weeks.size > 1) {
            AgelessSection(stringResource(R.string.forge_al_over_time))
            OverTimeCard(weeks, shown, onPick = { index = it })
        }
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
            HubRow(Icons.Rounded.WbTwilight, Forge.colors.charge, stringResource(R.string.forge_al_rhythm),
                   stringResource(R.string.forge_al_rhythm_sub), onOpenRhythm)
        }
        Text(stringResource(R.string.forge_al_beta), style = Forge.type.caption, color = Forge.colors.textTertiary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
    }
}

@Composable
private fun AgelessSection(title: String) {
    Text(title, style = Forge.type.title2.copy(fontWeight = FontWeight.Bold), color = Forge.sceneInk.text,
         modifier = Modifier.padding(top = ForgeMetrics.space2, start = ForgeMetrics.space1))
}

@Composable
private fun AgelessCard(content: @Composable () -> Unit) {
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = ForgeMetrics.space4) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) { content() }
    }
}

/** The pace in words: how many years of ageing one calendar year brings at the current habits. */
@Composable
private fun paceSentence(week: CoreAgeLess.Week, pace: Double): String {
    val n = number(abs(pace), 1)
    return stringResource(when (week.paceClass) {
        "reversing" -> R.string.forge_al_pace_reversing
        "slowing" -> R.string.forge_al_pace_slowing
        "accelerating" -> R.string.forge_al_pace_accelerating
        else -> R.string.forge_al_pace_steady
    }, n)
}

@Composable
private fun AgeLessHero(week: CoreAgeLess.Week, isLatest: Boolean) {
    val gap = week.age - week.actualAge
    AgelessCard {
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(years(week.age), style = Forge.type.title1.copy(fontSize = 52.sp, fontWeight = FontWeight.Bold), color = ageColor(gap))
            Column(Modifier.padding(bottom = 8.dp)) {
                Text(stringResource(R.string.forge_al_age), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
                Text(stringResource(R.string.forge_al_actual_age, years(week.actualAge)), style = Forge.type.caption, color = Forge.colors.textSecondary)
            }
        }
        ForgeAgeLine(week.actualAge, week.age, week.projectedAge, Modifier.fillMaxWidth().height(74.dp))
        week.pace?.let { pace ->
            Text(paceSentence(week, pace), style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
            week.projectedAge?.let { Text(stringResource(R.string.forge_al_in6, years(it)), style = Forge.type.body, color = Forge.colors.textSecondary) }
        }
        Text(if (isLatest) stringResource(R.string.forge_al_based, week.coveredDays)
             else stringResource(R.string.forge_al_week_based, weekLabel(week.day), week.coveredDays),
             style = Forge.type.caption, color = Forge.colors.textTertiary)
    }
}

/**
 * iOS's `ForgeAgeLessSummary`: the top of the AgeLess page on the same age line, opening the page. Today's wide
 * AgeLess card draws it; without a week it still opens the page, which says what is missing.
 */
@Composable
internal fun ForgeAgeLessSummary(week: CoreAgeLess.Week?, onOpen: () -> Unit) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen), contentPadding = ForgeMetrics.space4) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Rounded.HourglassBottom, null, tint = colors.text, modifier = Modifier.size(18.dp))
                Text(stringResource(R.string.forge_ageless_title), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                     color = colors.text, modifier = Modifier.weight(1f))
                Icon(Icons.Rounded.ChevronRight, null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
            }
            if (week != null) {
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                    Text(years(week.age), style = Forge.type.title1.copy(fontSize = 34.sp, fontWeight = FontWeight.Bold),
                         color = ageColor(week.age - week.actualAge))
                    Text(stringResource(R.string.forge_al_age_actual, years(week.actualAge)), style = Forge.type.caption,
                         color = colors.textSecondary, modifier = Modifier.padding(bottom = 6.dp))
                }
                ForgeAgeLine(week.actualAge, week.age, week.projectedAge, Modifier.fillMaxWidth().height(70.dp))
                week.pace?.let { Text(paceSentence(week, it), style = Forge.type.caption, color = colors.textSecondary) }
            } else {
                Text(stringResource(R.string.forge_al_health_age), style = Forge.type.caption, color = colors.textSecondary)
            }
        }
    }
}

/**
 * iOS's `ForgeAgeLine`: one axis with the actual age and the AgeLess age as dots, the gap between them shaded and
 * named, and a dashed ring where six more months at the current pace lead.
 */
@Composable
internal fun ForgeAgeLine(actual: Double, age: Double, projected: Double?, modifier: Modifier) {
    val colors = Forge.colors
    val younger = age <= actual
    val tint = if (younger) colors.charge else colors.effort
    val ink = ageColor(age - actual)
    val points = listOfNotNull(actual, age, projected)
    val lo = points.min() - 1.5
    val hi = points.max() + 1.5
    val gapText = if (younger) stringResource(R.string.forge_al_years_younger, years(actual - age))
                  else stringResource(R.string.forge_al_years_older, years(age - actual))
    val actualWord = stringResource(R.string.forge_al_actual)
    val sixMonths = stringResource(R.string.forge_al_in_6_months)
    val measurer = androidx.compose.ui.text.rememberTextMeasurer()
    val gapStyle = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold, color = ink)
    val smallStyle = Forge.type.caption.copy(fontSize = 11.sp, color = colors.textSecondary)
    val track = colors.inset
    val card = colors.surface
    val secondary = colors.textSecondary
    androidx.compose.foundation.Canvas(modifier) {
        val w = size.width
        fun x(v: Double) = ((v - lo) / (hi - lo)).toFloat() * w
        val mid = 30.dp.toPx()
        drawRoundRect(track, topLeft = Offset(0f, mid - 3.dp.toPx()), size = Size(w, 6.dp.toPx()), cornerRadius = CornerRadius(3.dp.toPx()))
        val left = minOf(x(actual), x(age))
        drawRoundRect(tint.copy(alpha = 0.35f), topLeft = Offset(left, mid - 7.dp.toPx()),
                      size = Size(maxOf(6.dp.toPx(), abs(x(actual) - x(age))), 14.dp.toPx()), cornerRadius = CornerRadius(7.dp.toPx()))
        projected?.let {
            drawCircle(tint, 7.dp.toPx(), Offset(x(it), mid),
                       style = Stroke(2.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx()))))
        }
        drawCircle(card, 10.dp.toPx(), Offset(x(actual), mid))
        drawCircle(secondary, 8.5.dp.toPx(), Offset(x(actual), mid), style = Stroke(3.dp.toPx()))
        drawCircle(card, 12.dp.toPx(), Offset(x(age), mid))
        drawCircle(tint, 9.dp.toPx(), Offset(x(age), mid))
        val gapLayout = measurer.measure(gapText, gapStyle)
        val gx = ((x(actual) + x(age)) / 2).coerceIn(60.dp.toPx(), w - 60.dp.toPx()) - gapLayout.size.width / 2
        drawText(gapLayout, topLeft = Offset(gx, 6.dp.toPx() - gapLayout.size.height / 2))
        val actualLayout = measurer.measure(actualWord, smallStyle)
        drawText(actualLayout, topLeft = Offset(x(actual) - actualLayout.size.width / 2, mid + 24.dp.toPx() - actualLayout.size.height / 2))
        projected?.let {
            val crowded = abs(x(it) - x(actual)) < 80.dp.toPx()
            val l = measurer.measure(sixMonths, smallStyle)
            val px = x(it).coerceIn(36.dp.toPx(), w - 36.dp.toPx()) - l.size.width / 2
            drawText(l, topLeft = Offset(px, mid + (if (crowded) 38 else 24).dp.toPx() - l.size.height / 2))
        }
    }
}

@Composable
private fun NarrativeCard(week: CoreAgeLess.Week) {
    val helper = week.helper?.let { componentName(it) }
    val lever = week.lever?.let { componentName(it) }
    val (title, body) = when (week.narrative) {
        "reversing" -> R.string.forge_ageless_n_reversing to helper?.let { stringResource(R.string.forge_ageless_b_reversing, it) }
        "youngerSteady" -> R.string.forge_ageless_n_younger_steady to helper?.let { stringResource(R.string.forge_ageless_b_younger_steady, it) }
        "youngerAccelerating" -> R.string.forge_ageless_n_younger_acc to lever?.let { stringResource(R.string.forge_ageless_b_younger_acc, it) }
        "olderImproving" -> R.string.forge_ageless_n_older_improving to lever?.let { stringResource(R.string.forge_ageless_b_older_improving, it) }
        else -> R.string.forge_ageless_n_older_acc to lever?.let { stringResource(R.string.forge_ageless_b_older_acc, it) }
    }
    AgelessCard {
        Text(stringResource(title), style = Forge.type.title2, color = Forge.colors.text)
        Text(body ?: stringResource(R.string.forge_ageless_b_filling), style = Forge.type.body, color = Forge.colors.textSecondary)
    }
}

@Composable
private fun LeversCard(week: CoreAgeLess.Week) {
    val biggest = week.levers.maxOf { -it.years }.coerceAtLeast(0.01)
    AgelessCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.forge_ageless_levers), style = Forge.type.title2, color = Forge.colors.text,
                 modifier = Modifier.weight(1f))
            week.leversYears?.let { Text(signedYears(it), style = Forge.type.subhead, color = ForgeTokens.StrandPalette.agelessYoungDeep.resolve()) }
        }
        week.levers.forEachIndexed { i, lever ->
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.forge_join_rank, i + 1, componentName(lever.component)), style = Forge.type.body, color = Forge.colors.text,
                         modifier = Modifier.weight(1f))
                    Text(signedYears(lever.years), style = Forge.type.subhead, color = ForgeTokens.StrandPalette.agelessYoungDeep.resolve())
                }
                Text(stringResource(R.string.forge_join_arrow, valueText(lever.component, lever.current), valueText(lever.component, lever.next)),
                     style = Forge.type.caption, color = Forge.colors.textSecondary)
                Bar(position = (-lever.years / biggest).coerceIn(0.0, 1.0), target = null, filled = true)
            }
        }
    }
}

/** iOS's domain rows: each area in its colour and symbol, its years as a bar either side of zero, opening its measures. */
@Composable
private fun DomainsCard(week: CoreAgeLess.Week) {
    val colors = Forge.colors
    val span = (week.domains.maxOfOrNull { abs(it.years) } ?: 1.0).coerceAtLeast(1.0)
    var open by remember { mutableStateOf(setOf<String>()) }
    val showsMeasures = stringResource(R.string.forge_al_shows_measures)
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 4.dp)) {
            week.domains.forEachIndexed { i, d ->
                if (i > 0) Box(Modifier.fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider))
                val (icon, tint) = when (d.domain) {
                    "sleep" -> Icons.Rounded.Bedtime to colors.rest
                    "activity" -> Icons.AutoMirrored.Rounded.DirectionsWalk to ForgeTokens.StrandPalette.metricAmber.resolve()
                    else -> Icons.Rounded.Favorite to ForgeTokens.StrandPalette.metricRose.resolve()
                }
                val name = domainName(d.domain)
                val signed = signedYears(d.years)
                val spoken = stringResource(R.string.forge_join_dot, name, signed)
                Row(Modifier.fillMaxWidth().clickable(role = Role.Button) { open = if (d.domain in open) open - d.domain else open + d.domain }
                        .semantics(mergeDescendants = true) { contentDescription = spoken; onClick(label = showsMeasures) { false } }
                        .padding(vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(Modifier.size(30.dp).clip(CircleShape).background(Brush.linearGradient(listOf(tint.copy(alpha = 0.75f), tint))),
                        contentAlignment = Alignment.Center) {
                        Icon(icon, null, tint = Color.White, modifier = Modifier.size(15.dp))
                    }
                    Text(name, style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = colors.text, maxLines = 1,
                         modifier = Modifier.width(70.dp))
                    YearsBar(d.years, span, Modifier.weight(1f).height(14.dp))
                    Text(signed, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = ageColor(d.years),
                         textAlign = TextAlign.End, modifier = Modifier.width(70.dp))
                    Icon(if (d.domain in open) Icons.Rounded.KeyboardArrowUp else Icons.Rounded.KeyboardArrowDown, null,
                         tint = colors.textTertiary, modifier = Modifier.size(18.dp))
                }
                if (d.domain in open) Measures(d)
            }
            Row(Modifier.fillMaxWidth().padding(start = 98.dp, end = 92.dp, top = 2.dp, bottom = 8.dp)) {
                Text(stringResource(R.string.forge_al_younger), style = Forge.type.caption.copy(fontWeight = FontWeight.Medium),
                     color = ageColor(-1.0), modifier = Modifier.weight(1f))
                Text(stringResource(R.string.forge_al_older), style = Forge.type.caption.copy(fontWeight = FontWeight.Medium), color = ageColor(1.0))
            }
        }
    }
}

/** iOS's `ForgeYearsBar`: years off to the left in the Charge colour, years on to the right in the Effort colour. */
@Composable
private fun YearsBar(years: Double, span: Double, modifier: Modifier) {
    val colors = Forge.colors
    val track = colors.inset
    val line = colors.divider
    val fill = if (years <= 0) colors.charge else colors.effort
    androidx.compose.foundation.Canvas(modifier) {
        val half = size.width / 2
        val len = maxOf((minOf(abs(years) / span, 1.0) * half).toFloat(), 3.dp.toPx())
        drawRoundRect(track, topLeft = Offset(0f, (size.height - 8.dp.toPx()) / 2), size = Size(size.width, 8.dp.toPx()),
                      cornerRadius = CornerRadius(4.dp.toPx()))
        drawRect(line, topLeft = Offset(half, 0f), size = Size(1.5.dp.toPx(), size.height))
        drawRoundRect(fill, topLeft = Offset(if (years <= 0) half - len else half, (size.height - 10.dp.toPx()) / 2),
                      size = Size(len, 10.dp.toPx()), cornerRadius = CornerRadius(5.dp.toPx()))
    }
}

/** One area's measures, each with its value, trend arrow, years and where it sits on its bar. */
@Composable
private fun Measures(domain: CoreAgeLess.Domain) {
    Column(Modifier.padding(bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(R.string.forge_al_measures_key), style = Forge.type.caption, color = Forge.colors.textSecondary)
        domain.measures.forEach { m ->
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(componentName(m.component), style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
                    val arrow = when (m.trendRising) { true -> " ↑"; false -> " ↓"; null -> "" }
                    Text((m.value?.let { valueText(m.component, it) } ?: "–") + arrow, style = Forge.type.subhead,
                         color = when (m.trendBetter) { true -> ageColor(-1.0); false -> ageColor(1.0); null -> Forge.colors.textSecondary })
                    m.years?.let {
                        Spacer(Modifier.width(ForgeMetrics.space2))
                        Text(signedYears(it), style = Forge.type.caption, color = ageColor(it))
                    }
                }
                Bar(position = m.position, target = m.targetPosition)
            }
        }
    }
}

/** The AgeLess age week by week against the dashed actual age; a tap or drag picks the week the page shows. */
@Composable
private fun OverTimeCard(weeks: List<CoreAgeLess.Week>, shown: Int, onPick: (Int) -> Unit) {
    val colors = Forge.colors
    val actual = weeks[shown].actualAge
    val values = weeks.map { it.age } + actual
    val lo = kotlin.math.floor(values.min()) - 1
    val hi = kotlin.math.ceil(values.max()) + 1
    val tint = if (weeks[shown].age <= actual) colors.charge else colors.effort
    val ruler = colors.textSecondary
    val selected = colors.text
    val label = stringResource(R.string.forge_al_chart_label)
    AgelessCard {
        val pick: (Float, Float) -> Unit = { x, w ->
            onPick(if (weeks.size == 1) 0 else ((x / w) * (weeks.size - 1)).roundToInt().coerceIn(0, weeks.lastIndex))
        }
        androidx.compose.foundation.Canvas(Modifier.fillMaxWidth().height(140.dp).semantics { contentDescription = label }
                .pointerInput(weeks.size) { detectTapGestures { pick(it.x, size.width.toFloat()) } }
                .pointerInput(weeks.size) { detectDragGestures { change, _ -> pick(change.position.x, size.width.toFloat()) } }) {
            val pad = 8.dp.toPx()
            val w = size.width - 2 * pad
            fun px(i: Int) = pad + if (weeks.size == 1) w / 2 else w * i / (weeks.size - 1)
            fun py(v: Double) = ((hi - v) / (hi - lo)).toFloat() * size.height
            drawLine(ruler, Offset(0f, py(actual)), Offset(size.width, py(actual)), 1.5.dp.toPx(),
                     pathEffect = PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 4.dp.toPx())))
            val path = Path()
            weeks.forEachIndexed { i, wk -> if (i == 0) path.moveTo(px(i), py(wk.age)) else path.lineTo(px(i), py(wk.age)) }
            drawPath(path, tint, style = Stroke(2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
            weeks.forEachIndexed { i, wk ->
                drawCircle(if (i == shown) selected else tint, (if (i == shown) 5.dp else 2.8.dp).toPx(), Offset(px(i), py(wk.age)))
            }
        }
        Text(stringResource(R.string.forge_al_chart_note), style = Forge.type.caption, color = Forge.colors.textSecondary)
    }
}

/** A thin track with a dot at [position] (0…1) and an optional target tick, or a filled share when [filled]. */
@Composable
private fun Bar(position: Double?, target: Double?, filled: Boolean = false) {
    val accent = ForgeTokens.StrandPalette.agelessYoung.resolve()
    BoxWithConstraints(Modifier.fillMaxWidth().height(12.dp)) {
        val w = maxWidth
        Box(Modifier.align(Alignment.CenterStart).fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp))
                .background(Forge.colors.inset))
        if (filled && position != null) {
            Box(Modifier.align(Alignment.CenterStart).width(w * position.toFloat()).height(4.dp).clip(RoundedCornerShape(2.dp))
                    .background(accent))
        }
        target?.let {
            Box(Modifier.align(Alignment.CenterStart).offset(x = w * it.toFloat() - 1.dp).width(2.dp).height(12.dp)
                    .background(Forge.colors.textTertiary))
        }
        if (!filled && position != null) {
            Box(Modifier.align(Alignment.CenterStart).offset(x = w * position.toFloat() - 6.dp).size(12.dp).clip(CircleShape)
                    .background(accent))
        }
    }
}

@Composable
private fun ageColor(years: Double): Color =
    if (years <= 0) ForgeTokens.StrandPalette.agelessYoungDeep.resolve() else ForgeTokens.StrandPalette.agelessOld.resolve()

private fun number(v: Double, digits: Int): String =
    NumberFormat.getNumberInstance(Locale.getDefault()).apply { minimumFractionDigits = digits; maximumFractionDigits = digits }.format(v)

private fun years(v: Double): String = number(v, 1)

@Composable
private fun signedYears(v: Double): String = when {
    abs(v) < 0.05 -> stringResource(R.string.forge_ageless_yrs, years(abs(v)))
    v < 0 -> stringResource(R.string.forge_ageless_yrs_minus, years(abs(v)))
    else -> stringResource(R.string.forge_ageless_yrs_plus, years(v))
}

@Composable
private fun domainName(d: String): String = stringResource(when (d) {
    "sleep" -> R.string.forge_ageless_d_sleep
    "activity" -> R.string.forge_ageless_d_activity
    else -> R.string.forge_ageless_d_fitness
})

@Composable
private fun componentName(c: String): String = stringResource(when (c) {
    "sleepDuration" -> R.string.forge_ageless_c_sleepDuration
    "sleepConsistency" -> R.string.forge_ageless_c_sleepConsistency
    "dailySteps" -> R.string.forge_ageless_c_dailySteps
    "zone13" -> R.string.forge_ageless_c_zone13
    "zone45" -> R.string.forge_ageless_c_zone45
    "strength" -> R.string.forge_ageless_c_strength
    "vo2max" -> R.string.forge_ageless_c_vo2max
    "restingHR" -> R.string.forge_ageless_c_restingHR
    else -> R.string.forge_ageless_c_leanMass
})

/** A measure's value in everyday units, as `HealthspanSection.value` writes it. */
@Composable
private fun valueText(c: String, v: Double): String {
    val whole = NumberFormat.getIntegerInstance(Locale.getDefault()).format(v.roundToInt())
    return when (c) {
        "sleepDuration" -> stringResource(R.string.forge_ageless_h, number(v, 1))
        "sleepConsistency", "leanMass" -> NumberFormat.getPercentInstance(Locale.getDefault()).format(v / 100)
        "dailySteps" -> whole
        "zone13", "zone45", "strength" -> stringResource(R.string.forge_ageless_minwk, whole)
        "vo2max" -> number(v, 1)
        else -> stringResource(R.string.forge_ageless_bpm, whole)
    }
}

/** "Oct 25" for the Saturday a week is stored under, as iOS's `weekLabel`. */
private fun weekLabel(saturday: String): String = runCatching {
    LocalDate.parse(saturday).format(DateTimeFormatter.ofPattern("d MMM", Locale.getDefault()))
}.getOrDefault(saturday)
