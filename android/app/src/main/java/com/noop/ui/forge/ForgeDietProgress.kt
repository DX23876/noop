package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowCircleDown
import androidx.compose.material.icons.rounded.ArrowCircleUp
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.Straighten
import androidx.compose.material.icons.rounded.DragHandle
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.noop.R
import com.noop.core.CoreDietPlan
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Fork (DX23876), Forge parity 2026-11: the way to the goal weight, as iOS's `DietProgressCard`, `DietWayPath` and
 * `DietRecompLines` (DietTrackerCards.swift). Every figure comes from the shared `DietProgress` (core call
 * `food.planProgress`), so the plan page and Today's card read the same way. Display only. Analysis migration
 * required: no.
 */
@Composable
internal fun ForgeDietProgressCard(progress: CoreDietPlan.Progress, compact: Boolean, male: Boolean?, forecastLine: String? = null) {
    val context = LocalContext.current
    val colors = Forge.colors
    val showsPicture = compact || progress.kind != "recomp"
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = 14.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            if (showsPicture) {
                Image(painterResource(dietProgressArt(context, progress, male)), null, contentScale = ContentScale.Crop,
                      modifier = Modifier.fillMaxWidth().height(if (compact) 110.dp else 160.dp).clip(RoundedCornerShape(10.dp)))
            }
            Column(Modifier.padding(horizontal = ForgeMetrics.space1), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
                Text(dietProgressTitle(progress), style = Forge.type.title2.copy(fontSize = if (compact) 20.sp else 24.sp, fontWeight = FontWeight.Bold),
                     color = colors.text)
                Text(dietProgressDetail(progress), style = Forge.type.subhead, color = colors.textSecondary)
                if (!compact && forecastLine != null) Text(forecastLine, style = Forge.type.subhead, color = colors.textSecondary)
            }
            if (progress.kind == "way") {
                DietWayPath(progress.fraction, Modifier.fillMaxWidth().height(if (compact) 34.dp else 44.dp).padding(horizontal = ForgeMetrics.space1))
            }
            if (progress.kind == "recomp") DietRecompLines(progress, compact)
        }
    }
}

/** The stage's picture, the ridge for holding, the half-carved stone (or the profile's fitness photo) for recomposition. */
private fun dietProgressArt(context: android.content.Context, p: CoreDietPlan.Progress, male: Boolean?): Int {
    fun named(name: String): Int = context.resources.getIdentifier(name, "drawable", context.packageName)
    val path = named("diet_explain_path").takeIf { it != 0 } ?: R.drawable.food_motif_dishes
    val name = when (p.kind) {
        "way" -> "diet_stage_" + when (p.stage) { "threeQuarter" -> "three_quarter"; null -> "start"; else -> p.stage }
        "hold" -> "diet_stage_hold"
        else -> if (male == null) "diet_stage_recomp" else "diet_goal_gain_" + if (male) "m" else "f"
    }
    return named(name).takeIf { it != 0 } ?: path
}

private fun dietKg(v: Double): String {
    val rounded = (v * 10).roundToInt() / 10.0
    return NumberFormat.getNumberInstance(Locale.getDefault()).apply { maximumFractionDigits = 1 }.format(if (rounded == 0.0) 0.0 else rounded) + " kg"
}

@Composable
private fun dietProgressTitle(p: CoreDietPlan.Progress): String = stringResource(when (p.kind) {
    "way" -> when (p.stage) {
        "quarter" -> R.string.forge_dg_quarter
        "half" -> R.string.forge_dg_half
        "threeQuarter" -> R.string.forge_dg_three_quarter
        "goal" -> R.string.forge_dg_goal
        else -> R.string.forge_dg_start
    }
    "hold" -> if (p.inRange) R.string.forge_dg_holding else R.string.forge_dg_off
    else -> if (p.working) R.string.forge_dg_reshaping else R.string.forge_dg_recomp
})

@Composable
private fun dietProgressDetail(p: CoreDietPlan.Progress): String = when (p.kind) {
    "way" -> if (p.stage == "goal") stringResource(R.string.forge_dg_at_goal, dietKg(p.trendKg))
             else stringResource(R.string.forge_dg_done_left, dietKg(p.doneKg), dietKg(p.leftKg))
    "recomp" -> stringResource(when {
        p.working -> R.string.forge_dg_working
        !p.weightSteady -> R.string.forge_dg_moved
        else -> R.string.forge_dg_takes_months
    })
    else -> when {
        p.inRange && p.weeksInRange >= 1 -> stringResource(R.string.forge_dg_within_weeks, dietKg(p.startKg), p.weeksInRange)
        p.inRange -> stringResource(R.string.forge_dg_within, dietKg(p.startKg))
        else -> stringResource(R.string.forge_dg_away, dietKg(p.trendKg), dietKg(abs(p.trendKg - p.startKg)))
    }
}

/** iOS's `DietWayPath`: a gentle S from the lower left to the upper right, walked to the trend, a stone per stage. */
@Composable
private fun DietWayPath(fraction: Double, modifier: Modifier) {
    val colors = Forge.colors
    val walked = colors.charge
    val track = colors.inset
    val open = colors.surface
    val rim = colors.textTertiary
    Canvas(modifier) {
        val inset = 8.dp.toPx()
        val l = inset; val r = size.width - inset; val t = inset; val b = size.height - inset; val mid = (l + r) / 2
        val path = Path().apply { moveTo(l, b); cubicTo(mid, b, mid, t, r, t) }
        val stroke = Stroke(width = 4.dp.toPx(), cap = StrokeCap.Round)
        drawPath(path, track, style = stroke)
        val measure = PathMeasure().apply { setPath(path, false) }
        val length = measure.length
        val done = Path()
        measure.getSegment(0f, length * fraction.coerceIn(0.001, 1.0).toFloat(), done, true)
        drawPath(done, walked, style = stroke)
        listOf(0.0, 0.25, 0.5, 0.75, 1.0).forEach { threshold ->
            val point: Offset = measure.getPosition(length * threshold.toFloat())
            val reached = fraction + 1e-9 >= threshold
            val radius = (if (threshold == 1.0) 8 else 6).dp.toPx()
            drawCircle(if (reached) walked else open, radius, point)
            drawCircle(if (reached) walked else rim, radius - 1.dp.toPx(), point, style = Stroke(2.dp.toPx()))
        }
    }
}

/** Recomposition's three signs, each in words with a symbol; a line without readings says how to get them. */
@Composable
private fun DietRecompLines(p: CoreDietPlan.Progress, compact: Boolean) {
    fun signed(v: Double, decimals: Int): String {
        val text = NumberFormat.getNumberInstance(Locale.getDefault()).apply { maximumFractionDigits = decimals }.format(abs(v))
        return (if (v > 0) "+" else if (v < 0) "−" else "") + text
    }
    Column(Modifier.padding(horizontal = ForgeMetrics.space1), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        RecompLine(stringResource(R.string.forge_dg_weight), p.weightSteady, if (p.weightSteady) Icons.Rounded.DragHandle else Icons.Rounded.Error,
                   stringResource(R.string.forge_dg_weight_line, dietKg(p.trendKg), dietKg(p.startKg)))
        val bf = p.bodyFatChange
        val waist = p.waistChangeCm
        when {
            bf != null -> RecompLine(stringResource(R.string.forge_dg_body_fat), bf < -0.3,
                                     if (bf < 0) Icons.Rounded.ArrowCircleDown else Icons.Rounded.ArrowCircleUp,
                                     stringResource(R.string.forge_dg_points, signed(bf, 1)))
            waist != null -> RecompLine(stringResource(R.string.forge_dg_waist), waist < -0.5,
                                        if (waist < 0) Icons.Rounded.ArrowCircleDown else Icons.Rounded.ArrowCircleUp, "${signed(waist, 1)} cm")
            !compact -> RecompLine(stringResource(R.string.forge_dg_body_fat), null, Icons.Rounded.Straighten, stringResource(R.string.forge_dg_measure_fat))
        }
        val strength = p.strengthChangePercent
        if (strength != null) {
            RecompLine(stringResource(R.string.forge_dg_strength), strength > 1,
                       if (strength >= 0) Icons.Rounded.ArrowCircleUp else Icons.Rounded.ArrowCircleDown, "${signed(strength, 0)} %")
        } else if (!compact) {
            RecompLine(stringResource(R.string.forge_dg_strength), null, Icons.Rounded.FitnessCenter, stringResource(R.string.forge_dg_log_strength))
        }
    }
}

@Composable
private fun RecompLine(title: String, ok: Boolean?, icon: androidx.compose.ui.graphics.vector.ImageVector, value: String) {
    val colors = Forge.colors
    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp),
             tint = when (ok) { true -> colors.charge; false -> colors.effort; null -> colors.textTertiary })
        Column {
            Text(title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
            Text(value, style = Forge.type.footnote, color = colors.textSecondary)
        }
    }
}

/**
 * iOS's `ForgeDietGoalWidget`: the plan page's card in small on Today, or without a way to show why. It opens the
 * Food page, where the plan lives.
 */
@Composable
internal fun TodayDietGoalCard(onOpen: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val revision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val read by produceState<Pair<CoreDietPlan.Plan?, CoreDietPlan.Progress?>>(null to null, revision) {
        value = withContext(Dispatchers.IO) {
            val plan = CoreDietPlan.load(context)
            CoreRead.open(context)
            plan to plan?.takeIf { !it.hideNumbers }?.let { runCatching { CoreDietPlan.progress(it, dietPerson(context), body = false) }.getOrNull() }
        }
    }
    val (plan, progress) = read
    val sex = com.noop.ui.ProfileStore.from(context).sex.lowercase()
    val male = if (sex == "male") true else if (sex == "female") false else null
    Column(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen)) {
        if (progress != null) ForgeDietProgressCard(progress, compact = true, male = male)
        else ForgeCard(Modifier.fillMaxWidth(), contentPadding = 14.dp) {
            Text(stringResource(R.string.forge_dg_title), style = Forge.type.caption, color = colors.textSecondary)
            Text(stringResource(when {
                plan == null -> R.string.forge_dg_no_plan
                plan.hideNumbers -> R.string.forge_dg_hidden
                else -> R.string.forge_dg_no_goal
            }), style = Forge.type.subhead, color = colors.text)
        }
    }
}
