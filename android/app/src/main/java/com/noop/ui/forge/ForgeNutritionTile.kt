package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Restaurant
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.material3.Text
import com.noop.R
import com.noop.core.CoreDietPlan
import com.noop.core.CoreEnergyPlan
import com.noop.core.CoreFood
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import kotlin.math.roundToInt

/**
 * Fork (DX23876), kit round 2026-11-19: Today's Nutrition tile, iOS's `ForgeNutritionWidget`.
 *
 * What the owner asked for on 2026-11-18: the Food page shows the plan's progress and the Energy card the
 * burn, and the macros stood nowhere at all, nor "what may I still eat today". One tile answers both.
 *
 * Small says what is left of the day and what has been eaten of the goal; two columns adds the three
 * macros against theirs; the whole row adds them as bars and the week's calories.
 *
 * The goal is NOT resolved here. The core resolves it (`FoodTargets.dayGoal`, through `food.dayGoal`) over
 * the same reads the Food page makes, so the tile and the page cannot name different goals — which is the
 * one number in this app where that matters most.
 */
internal data class NutritionReading(
    val eatenKcal: Double?, val goalKcal: Double?,
    val proteinG: Double?, val carbsG: Double?, val fatG: Double?,
    val proteinGoal: Double?, val carbsGoal: Double?, val fatGoal: Double?,
    val weekKcal: List<Pair<String, Double>>,
) {
    /** What is left of today, never below nothing: past the goal there is nothing left, not a negative. */
    val leftKcal: Double? get() = goalKcal?.let { g -> eatenKcal?.let { maxOf(0.0, g - it) } }
    val logged: Boolean get() = (eatenKcal ?: 0.0) > 0 || weekKcal.any { it.second > 0 }
}

@Composable
internal fun rememberNutritionReading(revision: Int): NutritionReading? {
    val context = LocalContext.current
    val reading by produceState<NutritionReading?>(null, revision) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                val today = LocalDate.now().toString()
                val dismissed = dismissedTrainingWorkouts(context)
                val plan = CoreEnergyPlan.plan(context, dismissed)
                val inputs = planInputs(plan)
                val person = dietPerson(context)
                val goals = CoreDietPlan.dayGoal(context, CoreDietPlan.load(context), person, inputs.first,
                                                 inputs.second, plan?.burnedByDay ?: emptyMap(), today,
                                                 dismissed, plan)
                val day = CoreFood.day(today)
                val week = CoreFood.week(today, today, withScore = false, sex = person.sex)
                NutritionReading(
                    // The core's own nutrient keys ("energy_kcal", not "kcal"), which is what every other
                    // Android reader of a day's totals already uses. Shortened names read as nothing at
                    // all, so the tile said "– left today" over a week of logged meals (2026-11-19).
                    eatenKcal = day?.totals?.get("energy_kcal"),
                    goalKcal = goals?.kcal,
                    proteinG = day?.totals?.get("protein_g"), carbsG = day?.totals?.get("carbs_g"),
                    fatG = day?.totals?.get("fat_g"),
                    proteinGoal = goals?.proteinG, carbsGoal = goals?.carbsG, fatGoal = goals?.fatG,
                    weekKcal = week?.days.orEmpty().map { it.day to (it.totals["energy_kcal"] ?: 0.0) },
                )
            }.getOrNull()
        }
    }
    return reading
}

/** The tile itself, at whichever size it was placed. */
@Composable
internal fun TodayNutrition(compact: TileSize?, onOpen: () -> Unit) {
    val reading = rememberNutritionReading(0)
    val colors = Forge.colors
    val whole = java.text.NumberFormat.getIntegerInstance(java.util.Locale.getDefault())
    fun kcal(v: Double?) = v?.let { whole.format(it.roundToInt().toLong()) }
    val left = kcal(reading?.leftKcal)
    val eatenOfGoal = reading?.let { r ->
        val eaten = kcal(r.eatenKcal) ?: return@let null
        val goal = kcal(r.goalKcal) ?: return@let null
        stringResource(R.string.forge_nut_eaten_of, eaten, goal)
    }
    if (compact != null) {
        ForgeCardTile(Icons.Rounded.Restaurant, stringResource(R.string.forge_nut_title),
                      left, stringResource(R.string.forge_unit_kcal),
                      if (compact == TileSize.Medium) macroLine(reading) else eatenOfGoal,
                      ForgeTokens.StrandPalette.energyHighlight.resolve(), onOpen)
        return
    }
    ForgeCard(Modifier.fillMaxWidth().clickable(onClick = onOpen)) {
        WidgetHead(stringResource(R.string.forge_nut_title))
        Row(verticalAlignment = androidx.compose.ui.Alignment.Bottom) {
            Text(left ?: "—", style = Forge.type.title1.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
            Text(stringResource(R.string.forge_nut_left), style = Forge.type.subhead, color = colors.textSecondary,
                 modifier = Modifier.padding(start = 8.dp, bottom = 4.dp))
        }
        eatenOfGoal?.let { Text(it, style = Forge.type.caption, color = colors.textSecondary) }
        val r = reading ?: return@ForgeCard
        MacroBars(r)
        if (r.weekKcal.size > 1) {
            Text(stringResource(R.string.forge_nut_week), style = Forge.type.caption, color = colors.textTertiary,
                 modifier = Modifier.padding(top = ForgeMetrics.space2))
            WeekKcalBars(r.weekKcal, ForgeTokens.StrandPalette.energyHighlight.resolve())
        }
    }
}

/** "P 142 / 160 g · C 180 / 240 · F 55 / 70", the three macros against their goals. */
@Composable
private fun macroLine(r: NutritionReading?): String? {
    if (r == null) return null
    fun g(v: Double?) = v?.roundToInt()
    val p = g(r.proteinG) ?: return null
    val c = g(r.carbsG) ?: return null
    val f = g(r.fatG) ?: return null
    val pg = g(r.proteinGoal); val cg = g(r.carbsGoal); val fg = g(r.fatGoal)
    return if (pg != null && cg != null && fg != null)
        stringResource(R.string.forge_nut_macros_goal, p, pg, c, cg, f, fg)
    else stringResource(R.string.forge_nut_macros, p, c, f)
}

/** The three macros as bars against their goals, so "how far" is seen and not only read. */
@Composable
private fun MacroBars(r: NutritionReading) {
    val protein = stringResource(R.string.food_protein)
    val carbs = stringResource(R.string.food_carbs)
    val fat = stringResource(R.string.food_fat)
    val rows = listOf(Triple(protein, r.proteinG, r.proteinGoal),
                      Triple(carbs, r.carbsG, r.carbsGoal),
                      Triple(fat, r.fatG, r.fatGoal))
    val tint = ForgeTokens.StrandPalette.energyHighlight.resolve()
    val track = Forge.colors.textTertiary.copy(alpha = 0.25f)
    Column(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space2),
           verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
        rows.forEach { (label, value, goal) ->
            if (value == null) return@forEach
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Text(label, style = Forge.type.caption, color = Forge.colors.textSecondary,
                     modifier = Modifier.weight(0.3f))
                Canvas(Modifier.weight(1f).height(8.dp)) {
                    val share = goal?.takeIf { it > 0 }?.let { (value / it).coerceIn(0.0, 1.0) } ?: 0.0
                    drawRoundRect(track, Offset.Zero, size,
                                  CornerRadius(4.dp.toPx(), 4.dp.toPx()))
                    if (share > 0) {
                        drawRoundRect(tint, Offset.Zero, Size((size.width * share).toFloat(), size.height),
                                      CornerRadius(4.dp.toPx(), 4.dp.toPx()))
                    }
                }
                Text(goal?.let { stringResource(R.string.forge_nut_grams_of, value.roundToInt(), it.roundToInt()) }
                         ?: stringResource(R.string.forge_nut_grams, value.roundToInt()),
                     style = Forge.type.caption, color = Forge.colors.text,
                     textAlign = TextAlign.End, modifier = Modifier.weight(0.45f))
            }
        }
    }
}

/** The week's calories as bars, newest last. */
@Composable
private fun WeekKcalBars(week: List<Pair<String, Double>>, tint: Color) {
    val top = week.maxOfOrNull { it.second } ?: return
    if (top <= 0) return
    Canvas(Modifier.fillMaxWidth().height(56.dp)) {
        val slot = size.width / week.size
        val w = slot * 0.62f
        week.forEachIndexed { i, (_, value) ->
            val h = maxOf(2f, (value / top * size.height).toFloat())
            drawRoundRect(tint.copy(alpha = if (i == week.lastIndex) 1f else 0.5f),
                          Offset(i * slot + (slot - w) / 2, size.height - h), Size(w, h),
                          CornerRadius(4.dp.toPx(), 4.dp.toPx()))
        }
    }
}
