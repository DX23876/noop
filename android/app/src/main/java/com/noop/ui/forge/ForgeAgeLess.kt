package com.noop.ui.forge

import androidx.compose.foundation.background
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
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
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
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Fork (DX23876), Android parity plan 2.3: the AgeLess screen after `HealthspanDetailView`. Week by week: the age
 * against the actual age, the aging speed, the status line, the biggest levers, every measure on its bar grouped as
 * sleep, activity and fitness, and the age over the weeks. Every number arrives resolved from the shared core.
 */
@Composable
internal fun ForgeAgeLessPage(onBack: () -> Unit) {
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
            Text(stringResource(if (loaded) R.string.forge_ageless_b_filling else R.string.forge_goals_loading),
                 style = Forge.type.body, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        var index by rememberSaveable { mutableIntStateOf(weeks.lastIndex) }
        val shown = index.coerceIn(0, weeks.lastIndex)
        val week = weeks[shown]
        WeekSwitcher(week, shown > 0, shown < weeks.lastIndex, onPrevious = { index = shown - 1 }, onNext = { index = shown + 1 })
        AgeCard(week)
        week.pace?.let { pace -> PaceCard(week, pace) }
        NarrativeCard(week)
        if (week.levers.isNotEmpty()) LeversCard(week)
        week.domains.forEach { DomainCard(it) }
        if (shown > 0) OverTimeCard(weeks.subList(0, shown + 1), week.actualAge)
    }
}

@Composable
private fun AgelessCard(content: @Composable () -> Unit) {
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) { content() }
    }
}

@Composable
private fun WeekSwitcher(week: CoreAgeLess.Week, hasPrevious: Boolean, hasNext: Boolean,
                         onPrevious: () -> Unit, onNext: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onPrevious, enabled = hasPrevious) {
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowLeft, contentDescription = stringResource(R.string.forge_ageless_prev),
                 tint = Forge.sceneInk.secondary)
        }
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(weekRange(week.day), style = Forge.type.subhead, color = Forge.sceneInk.text)
            if (week.provisional) {
                Text(stringResource(R.string.forge_ageless_based, week.coveredDays), style = Forge.type.caption,
                     color = Forge.sceneInk.secondary)
            }
        }
        IconButton(onClick = onNext, enabled = hasNext) {
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = stringResource(R.string.forge_ageless_next),
                 tint = Forge.sceneInk.secondary)
        }
    }
}

@Composable
private fun AgeCard(week: CoreAgeLess.Week) {
    val younger = week.delta <= 0
    AgelessCard {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(years(week.age), style = Forge.type.title1, color = ageColor(week.delta))
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(stringResource(R.string.forge_join_space, years(abs(week.delta)),
                                stringResource(if (younger) R.string.forge_ageless_younger else R.string.forge_ageless_older)),
                 style = Forge.type.subhead, color = Forge.colors.textSecondary, modifier = Modifier.padding(bottom = 4.dp))
        }
    }
}

@Composable
private fun PaceCard(week: CoreAgeLess.Week, pace: Double) {
    AgelessCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.forge_ageless_speed), style = Forge.type.title2, color = Forge.colors.text,
                 modifier = Modifier.weight(1f))
            Text(stringResource(R.string.forge_join_dot, number(pace, 2), paceClassText(week.paceClass)), style = Forge.type.subhead,
                 color = if (pace <= 1.0) ForgeTokens.StrandPalette.agelessYoungDeep.resolve() else ForgeTokens.StrandPalette.agelessOld.resolve())
        }
        // The slider runs from reversing (below zero) to accelerating (twice the calendar).
        Bar(position = ((pace + 0.5) / 2.5).coerceIn(0.0, 1.0), target = (1.5 / 2.5))
        week.projectedAge?.let {
            Text(stringResource(R.string.forge_ageless_in6, years(it)), style = Forge.type.footnote,
                 color = Forge.colors.textSecondary)
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

@Composable
private fun DomainCard(domain: CoreAgeLess.Domain) {
    AgelessCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(domainName(domain.domain), style = Forge.type.title2, color = Forge.colors.text, modifier = Modifier.weight(1f))
            Text(signedYears(domain.years), style = Forge.type.subhead, color = ageColor(domain.years))
        }
        domain.measures.forEach { m ->
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(componentName(m.component), style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
                    val arrow = when (m.trendRising) { true -> " ↑"; false -> " ↓"; null -> "" }
                    Text((m.value?.let { valueText(m.component, it) } ?: "–") + arrow, style = Forge.type.subhead,
                         color = when (m.trendBetter) { true -> ForgeTokens.StrandPalette.agelessYoungDeep.resolve()
                                                        false -> ForgeTokens.StrandPalette.agelessOld.resolve()
                                                        null -> Forge.colors.textSecondary })
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

@Composable
private fun OverTimeCard(weeks: List<CoreAgeLess.Week>, actualAge: Double) {
    val values = weeks.map { it.age } + actualAge
    val lo = values.min() - 1
    val hi = values.max() + 1
    AgelessCard {
        Text(stringResource(R.string.forge_ageless_over_time), style = Forge.type.title2, color = Forge.colors.text)
        BoxWithConstraints(Modifier.fillMaxWidth().height(120.dp)) {
            val w = maxWidth
            val actualY = 120.dp * ((hi - actualAge) / (hi - lo)).toFloat()
            Box(Modifier.offset(y = actualY).fillMaxWidth().height(1.dp).background(Forge.colors.divider))
            weeks.forEachIndexed { i, week ->
                val x = if (weeks.size == 1) w / 2 else w * (i.toFloat() / (weeks.size - 1))
                val y = 120.dp * ((hi - week.age) / (hi - lo)).toFloat()
                Box(Modifier.offset(x = x - 4.dp, y = y - 4.dp).size(8.dp).clip(CircleShape)
                        .background(ForgeTokens.StrandPalette.agelessYoung.resolve()))
            }
        }
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
private fun paceClassText(cls: String?): String = stringResource(when (cls) {
    "reversing" -> R.string.forge_ageless_p_reversing
    "slowing" -> R.string.forge_ageless_p_slowing
    "accelerating" -> R.string.forge_ageless_p_accelerating
    else -> R.string.forge_ageless_p_steady
})

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

/** "Oct 25 – Oct 31" for the Saturday a week is stored under. */
private fun weekRange(saturday: String): String = runCatching {
    val start = LocalDate.parse(saturday)
    val f = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(Locale.getDefault())
    "${start.format(f)} – ${start.plusDays(6).format(f)}"
}.getOrDefault(saturday)
