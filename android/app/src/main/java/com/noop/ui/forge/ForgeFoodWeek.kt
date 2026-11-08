package com.noop.ui.forge

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Eco
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreFood
import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/*
 * Fork (DX23876), decision 2026-11-08: the Food page's week strip, nutrition score, "as usual" offer, evening
 * sentence and meal pictures, as iOS `FoodWeekStrip`, `FoodScoreRow`, `FoodScoreView`, `FoodHabitCard` and
 * `FoodMealPicture` draw them. The numbers come from the shared core (`food.week`, `food.habit`, `food.sentence`).
 */

/** The Lab switch, the same key as iOS (`FoodScore.enabledKey`). */
internal const val FOOD_SCORE_KEY = "food.score.enabled"
private const val HABIT_DISMISSED_KEY = "food.repeat.dismissed"

internal fun foodScoreEnabled(context: android.content.Context) = com.noop.ui.NoopPrefs.of(context).getBoolean(FOOD_SCORE_KEY, false)

/** "Not today" holds for the rest of the day (iOS keys it by day and meal; one offer a day is enough here). */
internal fun foodHabitDismissed(context: android.content.Context, day: String) =
    com.noop.ui.NoopPrefs.of(context).getString(HABIT_DISMISSED_KEY, null)?.startsWith("$day:") == true

internal fun dismissFoodHabit(context: android.content.Context, day: String) {
    com.noop.ui.NoopPrefs.of(context).edit().putString(HABIT_DISMISSED_KEY, "$day:any").apply()
}

@DrawableRes
internal fun foodMotifDrawable(motif: String?): Int? = when (motif) {
    "bread" -> R.drawable.food_motif_bread
    "grains" -> R.drawable.food_motif_grains
    "fruit" -> R.drawable.food_motif_fruit
    "vegetables" -> R.drawable.food_motif_vegetables
    "legumes" -> R.drawable.food_motif_legumes
    "dairy" -> R.drawable.food_motif_dairy
    "eggs" -> R.drawable.food_motif_eggs
    "fish" -> R.drawable.food_motif_fish
    "meat" -> R.drawable.food_motif_meat
    "poultry" -> R.drawable.food_motif_poultry
    "sweets" -> R.drawable.food_motif_sweets
    "drinks" -> R.drawable.food_motif_drinks
    "fats" -> R.drawable.food_motif_fats
    "dishes" -> R.drawable.food_motif_dishes
    else -> null
}

/** A meal's still life; decorative, the card's text names the meal. */
@Composable
internal fun FoodMotifPicture(@DrawableRes res: Int, modifier: Modifier) {
    Image(painterResource(res), contentDescription = null, contentScale = ContentScale.Crop,
          modifier = modifier.clip(RoundedCornerShape(ForgeMetrics.space4)))
}

/** The evening's one or two observations, under the plate. */
@Composable
internal fun FoodSentence(points: List<CoreFood.SentencePoint>) {
    val text = points.mapNotNull { p ->
        when (p.nutrient to p.plenty) {
            "protein_g" to true -> stringResource(R.string.food_sentence_protein_plenty)
            "protein_g" to false -> stringResource(R.string.food_sentence_protein_low)
            "fiber_g" to true -> stringResource(R.string.food_sentence_fibre_plenty)
            "fiber_g" to false -> stringResource(R.string.food_sentence_fibre_low)
            else -> when (p.nutrient) {
                "sat_fat_g" -> stringResource(R.string.food_sentence_satfat)
                "sugar_g" -> stringResource(R.string.food_sentence_sugar)
                "salt_g" -> stringResource(R.string.food_sentence_salt)
                else -> null
            }
        }
    }.joinToString(" ")
    if (text.isNotEmpty()) {
        Text(text, style = Forge.type.body, color = Forge.colors.text, textAlign = TextAlign.Center,
             modifier = Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space4))
    }
}

/** Seven small plates for the week; a tap shows that day. */
@Composable
internal fun FoodWeekStrip(days: List<CoreFood.WeekDay>, shownDay: String, goals: CoreFood.Goals?, onSelect: (String) -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth()) {
        days.forEach { d ->
            val shown = d.day == shownDay
            val date = LocalDate.parse(d.day)
            val label = date.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.getDefault()) + ", " +
                (if (d.logged) "${kcalText(d.totals["energy_kcal"])} kcal" else stringResource(R.string.food_nothing_logged))
            Column(Modifier.weight(1f).clickable(role = Role.Button) { onSelect(d.day) }
                    .semantics { contentDescription = label; selected = shown }
                    .padding(vertical = ForgeMetrics.space1),
                   horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                FoodMiniPlate(share(d.totals["energy_kcal"], goals?.kcal),
                              listOf(share(d.totals["protein_g"], goals?.proteinG), share(d.totals["carbs_g"], goals?.carbsG),
                                     share(d.totals["fat_g"], goals?.fatG)),
                              Modifier.alpha(if (d.logged) 1f else 0.45f))
                Text(date.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault()), style = Forge.type.caption,
                     color = if (shown) colors.text else colors.textSecondary,
                     fontWeight = if (shown) FontWeight.Bold else FontWeight.Normal)
                Box(Modifier.size(4.dp).background(if (shown) colors.food else Color.Transparent, CircleShape))
            }
        }
    }
}

private fun share(value: Double?, goal: Double?): Double = if (value == null || goal == null || goal <= 0) 0.0 else value / goal

/** Four thin rings without glow: seven side by side stay calm. */
@Composable
private fun FoodMiniPlate(kcal: Double, macros: List<Double>, modifier: Modifier = Modifier) {
    val colors = Forge.colors
    val tints = listOf(colors.protein, colors.carbs, colors.fat)
    Canvas(modifier.size(40.dp)) {
        fun ring(diameter: Float, line: Float, s: Double, tint: Color) {
            val d = diameter.dp.toPx() - line.dp.toPx(); val w = line.dp.toPx()
            val topLeft = Offset((size.width - d) / 2, (size.height - d) / 2)
            val box = androidx.compose.ui.geometry.Size(d, d)
            drawArc(tint.copy(alpha = 0.16f), 0f, 360f, false, topLeft, box, style = Stroke(w))
            val sweep = (360 * min(1.0, max(0.0, s))).toFloat()
            if (sweep > 0) drawArc(tint, -90f, sweep, false, topLeft, box, style = Stroke(w, cap = StrokeCap.Round))
        }
        ring(40f, 4.5f, kcal, colors.food)
        macros.take(3).forEachIndexed { i, s -> ring(30f - i * 8f, 3f, s, tints[i]) }
    }
}

/** The week's score in a number and a word, or how far the week is before five logged days. */
@Composable
internal fun FoodScoreRow(score: CoreFood.Score?, loggedDays: Int, onOpen: () -> Unit) {
    val colors = Forge.colors
    val leaf = nutrientTint("fiber_g", colors.dark)
    ForgeCard(Modifier.fillMaxWidth().clickable(enabled = score != null, role = Role.Button, onClick = onOpen)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(34.dp).background(leaf.copy(alpha = 0.16f), CircleShape), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.Eco, null, tint = leaf, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(ForgeMetrics.space3))
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.food_score_title), style = Forge.type.headline, color = colors.text)
                Text(if (score != null) stringResource(R.string.food_score_week, scoreWord(score.score))
                     else stringResource(R.string.food_score_after, loggedDays),
                     style = Forge.type.footnote, color = colors.textSecondary)
            }
            if (score != null) Text(score.score.roundToInt().toString(), style = Forge.type.title1, color = colors.text)
            Icon(Icons.Rounded.ChevronRight, null, tint = colors.textSecondary)
        }
    }
}

@Composable
private fun scoreWord(score: Double): String = stringResource(when {
    score < 40 -> R.string.food_score_word_grow
    score < 60 -> R.string.food_score_word_fair
    score < 75 -> R.string.food_score_word_good
    else -> R.string.food_score_word_very_good
})

/** What the score is made of, in everyday words, as iOS `FoodScoreView`. */
@Composable
internal fun ForgeFoodScorePage(score: CoreFood.Score, male: Boolean, onBack: () -> Unit) {
    val colors = Forge.colors
    SettingsColumn {
        PageTitle(stringResource(R.string.food_score_title), onBack)
        // A still life of a balanced week behind the number, as iOS `FoodScoreView`; the photo is dark in both themes.
        Box(Modifier.fillMaxWidth().height(200.dp).clip(RoundedCornerShape(ForgeMetrics.space4)), contentAlignment = Alignment.CenterStart) {
            Image(painterResource(R.drawable.food_score_hero), contentDescription = null, contentScale = ContentScale.Crop,
                  alignment = Alignment.CenterEnd, modifier = Modifier.matchParentSize())
            Column(Modifier.padding(start = ForgeMetrics.space5)) {
                Text(score.score.roundToInt().toString(), style = Forge.type.heroNumber, color = Color.White)
                Text(scoreWord(score.score), style = Forge.type.headline, color = Color.White)
                Text(stringResource(R.string.food_score_from_days, score.loggedDays), style = Forge.type.footnote, color = Color.White.copy(alpha = 0.78f))
            }
        }
        Text(stringResource(R.string.food_score_about), style = Forge.type.footnote, color = Forge.sceneInk.secondary)
        ForgeCard(Modifier.fillMaxWidth()) {
            score.parts.sortedByDescending { it.points }.forEach { part ->
              Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2), verticalAlignment = Alignment.Top) {
                Image(painterResource(partPicture(part.component)), contentDescription = null, contentScale = ContentScale.Crop,
                      modifier = Modifier.size(44.dp).clip(RoundedCornerShape(10.dp)))
                Spacer(Modifier.width(ForgeMetrics.space3))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row {
                        Text(componentName(part.component), style = Forge.type.body, color = colors.text, modifier = Modifier.weight(1f))
                        Text("${gramsText(part.points)} / 10", style = Forge.type.bodyNumber, color = colors.text)
                    }
                    val tint = nutrientTint(when { part.points >= 7 -> "fiber_g"; part.points >= 4 -> "potassium_mg"; else -> "iron_mg" }, colors.dark)
                    LinearProgressIndicator(progress = { (part.points / 10).toFloat() }, color = tint, trackColor = tint.copy(alpha = 0.16f),
                                            modifier = Modifier.fillMaxWidth().height(6.dp).clip(CircleShape))
                    Text(componentAmount(part) + " · " + componentGoal(part.component, male), style = Forge.type.footnote, color = colors.textSecondary)
                }
              }
            }
        }
        score.processedShare?.let { share ->
            SettingsCard(stringResource(R.string.food_score_processed), stringResource(R.string.food_score_processed_note)) {
                Text(stringResource(R.string.food_score_processed_value, (share * 100).roundToInt()), style = Forge.type.body, color = colors.text)
            }
        }
    }
}

@DrawableRes
private fun partPicture(c: String): Int = when (c) {
    "vegetables" -> R.drawable.food_motif_vegetables
    "fruit" -> R.drawable.food_motif_fruit
    "wholeGrains" -> R.drawable.food_motif_grains
    "sugaryDrinks" -> R.drawable.food_motif_drinks
    "nutsLegumes" -> R.drawable.food_motif_legumes
    "redMeat" -> R.drawable.food_motif_meat
    "fishOmega3" -> R.drawable.food_motif_fish
    "polyFats" -> R.drawable.food_motif_fats
    "sodium" -> R.drawable.food_motif_salt
    else -> R.drawable.food_motif_alcohol
}

@Composable
private fun componentName(c: String): String = stringResource(when (c) {
    "vegetables" -> R.string.food_part_vegetables
    "fruit" -> R.string.food_part_fruit
    "wholeGrains" -> R.string.food_part_whole_grains
    "sugaryDrinks" -> R.string.food_part_sweet_drinks
    "nutsLegumes" -> R.string.food_part_nuts
    "redMeat" -> R.string.food_part_red_meat
    "fishOmega3" -> R.string.food_part_fish
    "polyFats" -> R.string.food_part_fats
    "sodium" -> R.string.food_part_salt
    else -> R.string.food_part_alcohol
})

@Composable
private fun componentGoal(c: String, male: Boolean): String = stringResource(when (c) {
    "vegetables" -> R.string.food_full_vegetables
    "fruit" -> R.string.food_full_fruit
    "wholeGrains" -> if (male) R.string.food_full_whole_grains_m else R.string.food_full_whole_grains_f
    "nutsLegumes" -> R.string.food_full_nuts
    "fishOmega3" -> R.string.food_full_fish
    "polyFats" -> R.string.food_full_fats
    "sodium" -> R.string.food_full_salt
    else -> R.string.food_full_none
})

@Composable
private fun componentAmount(p: CoreFood.ScorePart): String {
    val one = NumberFormat.getNumberInstance(Locale.getDefault()).apply { maximumFractionDigits = 1 }
    val a = p.amountPerDay
    return when (p.component) {
        "wholeGrains" -> stringResource(R.string.food_amount_grams, gramsText(a))
        "fishOmega3" -> stringResource(R.string.food_amount_mg, kcalText(a))
        "polyFats" -> stringResource(R.string.food_amount_share, one.format(a))
        "sodium" -> stringResource(R.string.food_amount_salt, one.format(a * 2.5 / 1000))
        "alcohol" -> stringResource(R.string.food_amount_drinks, one.format(a))
        else -> stringResource(R.string.food_amount_portions, one.format(a))
    }
}

/** "As usual": quieter than a logged meal, one tap adds it, the other hides it for today. */
@Composable
internal fun FoodHabitCard(habit: CoreFood.Habit, onAdd: () -> Unit, onDismiss: () -> Unit) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth().alpha(0.86f)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            foodMotifDrawable(habit.motif)?.let { res ->
                FoodMotifPicture(res, Modifier.size(56.dp))
                Spacer(Modifier.width(ForgeMetrics.space3))
            }
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.food_as_usual, mealName(habit.kind)), style = Forge.type.footnote, color = colors.textSecondary)
                Text(habit.entries.joinToString(", ") { it.name.substringBefore(", ") }, style = Forge.type.body, color = colors.text, maxLines = 2)
                Text("${kcalText(habit.entries.sumOf { it.totals["energy_kcal"] ?: 0.0 })} kcal", style = Forge.type.footnote, color = colors.textSecondary)
            }
            IconButton(onClick = onAdd) { Icon(Icons.Rounded.AddCircle, stringResource(R.string.food_add), tint = colors.food) }
            IconButton(onClick = onDismiss) { Icon(Icons.Rounded.Close, stringResource(R.string.food_not_today), tint = colors.textSecondary) }
        }
    }
}
