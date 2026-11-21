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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableIntStateOf
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

/** A note out of ten with one decimal ("7,8"), in the app language. */
internal fun noteText(score: Double): String =
    NumberFormat.getNumberInstance(Locale.getDefault()).apply { minimumFractionDigits = 1; maximumFractionDigits = 1 }.format(score)

/**
 * What a food note is made of (owner, 2026-11-21), as iOS `FoodScoreView`: the day's, the week's or the month's, ten
 * parts in everyday words, and the last eight weeks on a labelled 0 to 10 axis.
 */
@Composable
internal fun ForgeFoodNotePage(quality: com.noop.core.CoreFoodNotes.Quality, male: Boolean, onBack: () -> Unit) {
    val colors = Forge.colors
    var span by remember { mutableIntStateOf(if (quality.day != null) 0 else if (quality.week != null) 1 else 2) }
    val note = when (span) { 0 -> quality.day; 1 -> quality.week; else -> quality.month }
    SettingsColumn {
        PageTitle(stringResource(R.string.food_note_title), onBack)
        Row(Modifier.fillMaxWidth().background(colors.inset, RoundedCornerShape(50)).padding(4.dp)) {
            listOf(R.string.food_span_day, R.string.food_span_week, R.string.food_span_month).forEachIndexed { index, label ->
                Text(stringResource(label), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold),
                     color = if (span == index) colors.text else colors.textSecondary, textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                     modifier = Modifier.weight(1f).background(if (span == index) colors.surface else androidx.compose.ui.graphics.Color.Transparent, RoundedCornerShape(50))
                         .clickable(role = Role.Tab) { span = index }.padding(vertical = 8.dp))
            }
        }
        Box(Modifier.fillMaxWidth().height(200.dp).clip(RoundedCornerShape(ForgeMetrics.space4)), contentAlignment = Alignment.CenterStart) {
            Image(painterResource(R.drawable.food_score_hero), contentDescription = null, contentScale = ContentScale.Crop,
                  alignment = Alignment.CenterEnd, modifier = Modifier.matchParentSize())
            Column(Modifier.padding(start = ForgeMetrics.space5)) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(note?.let { noteText(it.score) } ?: "–", style = Forge.type.heroNumber, color = colors.text)
                    Text(" / 10", style = Forge.type.headline, color = colors.textSecondary)
                }
                note?.let { Text(scoreWord(it.score * 10), style = Forge.type.headline, color = colors.text) }
                Text(when {
                    note == null && span == 0 -> stringResource(R.string.food_note_none_day)
                    note == null -> stringResource(R.string.food_note_too_few)
                    span == 0 -> stringResource(if (note.provisional) R.string.food_note_today_so_far else R.string.food_note_this_day)
                    span == 1 -> stringResource(R.string.food_score_from_days, note.loggedDays)
                    else -> stringResource(R.string.food_note_from_days_28, note.loggedDays)
                }, style = Forge.type.footnote, color = colors.textSecondary)
            }
        }
        Text(stringResource(if (span == 0) R.string.food_note_about_day else R.string.food_note_about_span), style = Forge.type.footnote,
             color = Forge.sceneInk.secondary)
        if (quality.trend.size >= 2) {
            FoodSectionHeader(stringResource(R.string.food_note_last_weeks))
            ForgeCard(Modifier.fillMaxWidth()) { FoodNoteTrend(quality.trend) }
        }
        note?.let { n ->
            val parts = n.parts.map { CoreFood.ScorePart(it.component, it.points, it.amountPerDay) }
            val (limits, adds) = parts.partition { it.component in LIMIT_PARTS }
            FoodSectionHeader(stringResource(R.string.food_score_adds))
            ForgeCard(Modifier.fillMaxWidth()) { adds.sortedByDescending { it.points }.forEach { ScorePartRow(it, male) } }
            FoodSectionHeader(stringResource(R.string.food_score_costs))
            ForgeCard(Modifier.fillMaxWidth()) { limits.sortedBy { it.points }.forEach { ScorePartRow(it, male) } }
            Text(stringResource(R.string.food_score_costs_note), style = Forge.type.footnote, color = Forge.sceneInk.secondary)
            n.processedShare?.let { share ->
                SettingsCard(stringResource(R.string.food_score_processed), stringResource(R.string.food_score_processed_note)) {
                    Text(stringResource(R.string.food_score_processed_value, (share * 100).roundToInt()), style = Forge.type.body, color = colors.text)
                }
            }
        }
    }
}

/** The last weeks' notes as bars on a 0 to 10 axis, each bar the seven days ending on its date. */
@Composable
private fun FoodNoteTrend(notes: List<com.noop.core.CoreFoodNotes.Note>) {
    val colors = Forge.colors
    val leaf = nutrientTint("fiber_g", colors.dark)
    Row(Modifier.fillMaxWidth().height(170.dp), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2),
        verticalAlignment = Alignment.Bottom) {
        notes.forEach { note ->
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(noteText(note.score), style = Forge.type.footnote, color = colors.textSecondary)
                Box(Modifier.fillMaxWidth().height((120 * note.score / 10).dp.coerceAtLeast(2.dp)).background(leaf, RoundedCornerShape(4.dp)))
                val date = java.time.LocalDate.parse(note.day)
                Text(date.format(java.time.format.DateTimeFormatter.ofPattern("d MMM", Locale.getDefault())), style = Forge.type.footnote,
                     color = colors.textSecondary, maxLines = 1)
            }
        }
    }
}

/** Parts where less is better, as iOS `FoodScore.Component.isLimit`. */
private val LIMIT_PARTS = setOf("sugaryDrinks", "redMeat", "sodium", "alcohol")

@Composable
private fun ScorePartRow(part: CoreFood.ScorePart, male: Boolean) {
    val colors = Forge.colors
    val green = nutrientTint("fiber_g", colors.dark)
    val red = nutrientTint("iron_mg", colors.dark)
    // Points added (more is better) or lost (less is better), from -10 to +10.
    val effect = if (part.component in LIMIT_PARTS) -(10 - part.points) else part.points
    val signed = if (kotlin.math.abs(effect) < 0.05) "0" else (if (effect > 0) "+" else "−") + gramsText(kotlin.math.abs(effect))
    Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2), verticalAlignment = Alignment.Top) {
        Image(painterResource(partPicture(part.component)), contentDescription = null, contentScale = ContentScale.Crop,
              modifier = Modifier.size(44.dp).clip(RoundedCornerShape(10.dp)))
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row {
                Text(foodComponentName(part.component), style = Forge.type.body, color = colors.text, modifier = Modifier.weight(1f))
                Text(signed, style = Forge.type.bodyNumber,
                     color = if (signed == "0") colors.textSecondary else if (effect > 0) green else red)
            }
            Canvas(Modifier.fillMaxWidth().height(12.dp)) {
                val half = size.width / 2
                val bar = 6.dp.toPx(); val y = (size.height - bar) / 2
                val radius = androidx.compose.ui.geometry.CornerRadius(bar / 2)
                drawRoundRect(colors.textSecondary.copy(alpha = 0.18f), Offset(0f, y), androidx.compose.ui.geometry.Size(size.width, bar), radius)
                val length = half * min(1.0, kotlin.math.abs(effect) / 10).toFloat()
                if (length > 0) drawRoundRect(if (effect > 0) green else red, Offset(if (effect > 0) half else half - length, y),
                                              androidx.compose.ui.geometry.Size(length, bar), radius)
                drawRect(colors.textSecondary, Offset(half - 1.dp.toPx(), 0f), androidx.compose.ui.geometry.Size(2.dp.toPx(), size.height))
            }
            Text(componentAmount(part) + " · " + componentGoal(part.component, male), style = Forge.type.footnote, color = colors.textSecondary)
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
    "fiber" -> R.drawable.food_motif_vegetables
    else -> R.drawable.food_motif_alcohol
}

@Composable
internal fun foodComponentName(c: String): String = stringResource(when (c) {
    "vegetables" -> R.string.food_part_vegetables
    "fruit" -> R.string.food_part_fruit
    "wholeGrains" -> R.string.food_part_whole_grains
    "sugaryDrinks" -> R.string.food_part_sweet_drinks
    "nutsLegumes" -> R.string.food_part_nuts
    "redMeat" -> R.string.food_part_red_meat
    "fishOmega3" -> R.string.food_part_fish
    "polyFats" -> R.string.food_part_fats
    "sodium" -> R.string.food_part_salt
    "fiber" -> R.string.food_part_fibre
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
    "fiber" -> R.string.food_full_fibre
    "redMeat" -> R.string.food_full_red_meat
    else -> R.string.food_full_none
})

@Composable
private fun componentAmount(p: CoreFood.ScorePart): String {
    val one = NumberFormat.getNumberInstance(Locale.getDefault()).apply { maximumFractionDigits = 1 }
    val a = p.amountPerDay
    return when (p.component) {
        "wholeGrains", "fiber" -> stringResource(R.string.food_amount_grams, gramsText(a))
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
                Text(stringResource(R.string.forge_ed_kcal, kcalText(habit.entries.sumOf { it.totals["energy_kcal"] ?: 0.0 })), style = Forge.type.footnote, color = colors.textSecondary)
            }
            IconButton(onClick = onAdd) { Icon(Icons.Rounded.AddCircle, stringResource(R.string.food_add), tint = colors.food) }
            IconButton(onClick = onDismiss) { Icon(Icons.Rounded.Close, stringResource(R.string.food_not_today), tint = colors.textSecondary) }
        }
    }
}
