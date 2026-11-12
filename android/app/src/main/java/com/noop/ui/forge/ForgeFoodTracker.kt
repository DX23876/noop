package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.Flag
import androidx.compose.material.icons.rounded.Hotel
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material.icons.rounded.PauseCircle
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreDietPlan

/*
 * Fork (DX23876), Android parity 2026-11-12: the Food page's plan lines under the plate (the day's phase, training or
 * rest day, the active-day extra), the note when another source's calories count for the day, and the row that marks
 * a day as completely logged, as iOS's `ForgeFoodView`, `FoodOtherIntakeNote` and `FoodCompleteDayRow` draw them.
 */

/** The day's plan lines under the plate, each shown only when iOS shows it. */
@Composable
internal fun FoodPlanDayLines(day: CoreDietPlan.PlanDay) {
    val colors = Forge.colors
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        when (day.phase) {
            "dietBreak" -> PlanLine(Icons.Rounded.PauseCircle, stringResource(R.string.food_phase_break), colors.charge)
            "transition" -> PlanLine(Icons.Rounded.Flag, stringResource(R.string.food_phase_transition), colors.charge)
            "holding" -> PlanLine(Icons.Rounded.Flag, stringResource(R.string.food_phase_holding), colors.charge)
        }
        if (day.showsTrainingLabel) {
            if (day.isTrainingDay) PlanLine(Icons.Rounded.FitnessCenter, stringResource(R.string.food_training_day), colors.effort)
            else PlanLine(Icons.Rounded.Hotel, stringResource(R.string.food_rest_day), colors.textSecondary)
        }
        if (day.showsActiveBonus) PlanLine(Icons.Rounded.LocalFireDepartment,
                                           stringResource(R.string.food_active_bonus, kcalText(day.activeBonusKcal)), colors.effort)
    }
}

@Composable
private fun PlanLine(icon: ImageVector, text: String, tint: Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(text, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = tint, textAlign = TextAlign.Center)
    }
}

/** When the energy plan counts the day's calories from somewhere else, so two intakes never stand unexplained. */
@Composable
internal fun FoodOtherIntakeNote(kcal: Double, source: String) {
    val colors = Forge.colors
    val text = when (source) {
        "manual" -> stringResource(R.string.food_other_intake_manual, kcalText(kcal))
        else -> stringResource(R.string.food_other_intake, kcalText(kcal), when (source) {
            "appleHealth" -> "Apple Health"
            "healthConnect" -> "Health Connect"
            "csv" -> stringResource(R.string.food_other_csv)
            else -> stringResource(R.string.food_other_log)
        })
    }
    Row(Modifier.padding(horizontal = ForgeMetrics.space1), verticalAlignment = Alignment.Top) {
        Icon(Icons.Rounded.Info, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(text, style = Forge.type.caption, color = colors.textSecondary)
    }
}

/**
 * Under the meals: marks the day as completely logged, or asks from the evening on (iOS `FoodCompleteDayRow`). Only
 * marked days count toward the real burn.
 */
@Composable
internal fun FoodCompleteDayRow(complete: Boolean, asks: Boolean, toggle: () -> Unit) {
    val colors = Forge.colors
    val haptics = LocalHapticFeedback.current
    val ask = asks && !complete
    Row(Modifier.fillMaxWidth()
            .background(if (ask) colors.accent.copy(alpha = 0.12f) else colors.surface, RoundedCornerShape(ForgeMetrics.cardRadius))
            .clickable(role = Role.Button) { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove); toggle() }
            .semantics(mergeDescendants = true) { selected = complete }
            .padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(if (complete) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked, contentDescription = null,
             tint = if (complete) colors.charge else colors.textTertiary, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(Modifier.weight(1f)) {
            Text(stringResource(when {
                complete -> R.string.food_complete_done
                asks -> R.string.food_complete_ask
                else -> R.string.food_complete_mark
            }), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
            Text(stringResource(R.string.food_complete_note), style = Forge.type.footnote, color = colors.textSecondary)
        }
    }
}

/** The real burn from food and weight beside the strap's, as iOS's `DietBurnCard`; [onBase] switches the plan's basis. */
@Composable
internal fun ForgeDietBurnCard(day: CoreDietPlan.PlanDay, onScale: Boolean, onBase: (Boolean) -> Unit) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            Text(stringResource(R.string.diet_burn_title), style = Forge.type.headline, color = colors.text)
            val real = day.realBurnKcal
            if (day.expenditure == "estimate" && real != null) {
                val top = maxOf(real, day.strapKcal ?: 0.0, 1.0)
                BurnBar(stringResource(R.string.diet_burn_food), real, top, colors.charge)
                day.strapKcal?.let { BurnBar(stringResource(R.string.diet_burn_strap), it, top, colors.effort) }
                Text(burnComparison(real, day.strapKcal), style = Forge.type.subhead, color = colors.text)
                Text(stringResource(R.string.diet_burn_from_days, day.completeDays), style = Forge.type.footnote, color = colors.textSecondary)
                BurnButton(stringResource(if (onScale) R.string.diet_burn_back else R.string.diet_burn_base)) { onBase(!onScale) }
            } else {
                Text(stringResource(R.string.diet_burn_missing, day.needCompleteDays, day.needWeighIns, day.completeDays, day.weighIns ?: 0),
                     style = Forge.type.subhead, color = colors.text)
                Text(stringResource(R.string.diet_burn_mark_hint), style = Forge.type.footnote, color = colors.textSecondary)
                if (onScale) {
                    Text(stringResource(R.string.diet_burn_until), style = Forge.type.subhead, color = colors.text)
                    BurnButton(stringResource(R.string.diet_burn_back)) { onBase(false) }
                }
            }
        }
    }
}

@Composable
private fun burnComparison(real: Double, strap: Double?): String {
    val ratio = strap?.takeIf { it > 0 }?.let { real / it } ?: return stringResource(R.string.diet_burn_body, kcalText(real))
    val percent = kotlin.math.round((1 / ratio - 1) * 100).toInt()
    if (kotlin.math.abs(percent) < 3) return stringResource(R.string.diet_burn_agree)
    val amount = "${kotlin.math.abs(percent)} %"
    return stringResource(if (percent > 0) R.string.diet_burn_above else R.string.diet_burn_below, amount)
}

@Composable
private fun BurnBar(label: String, kcal: Double, top: Double, tint: Color) {
    val colors = Forge.colors
    Column(Modifier.semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, style = Forge.type.subhead, color = colors.textSecondary, modifier = Modifier.weight(1f))
            Text(kcalText(kcal) + " kcal", style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
        }
        androidx.compose.foundation.layout.Box(Modifier.fillMaxWidth().height(8.dp)
                .background(colors.inset, androidx.compose.foundation.shape.CircleShape)) {
            androidx.compose.foundation.layout.Box(Modifier.fillMaxWidth((kcal / top).toFloat().coerceIn(0f, 1f)).height(8.dp)
                    .background(tint, androidx.compose.foundation.shape.CircleShape))
        }
    }
}

@Composable
private fun BurnButton(label: String, onClick: () -> Unit) {
    val colors = Forge.colors
    Text(label, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.accent,
         modifier = Modifier.background(colors.accent.copy(alpha = 0.15f), RoundedCornerShape(8.dp))
             .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 14.dp, vertical = 8.dp))
}
