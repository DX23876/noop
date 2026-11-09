package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.annotation.DrawableRes
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreDietPlan
import com.noop.core.CoreEnergyPlan
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.LocalDate
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/*
 * Fork (DX23876), decision 2026-11-09: the diet planner, the plan page and the plan line, as iOS `DietPlannerView`,
 * `DietPlanView` and `DietPlanLine`. Every figure comes from the shared core (`food.plan*`).
 */

private val FORMS = listOf("balanced", "mediterranean", "dash", "highProtein", "flexitarian", "lowFat", "lowCarb", "keto",
                           "fasting168", "fasting52", "alternateDay", "alternateDayFull")
private val ADVANCED_FORMS = setOf("keto", "fasting52", "alternateDay", "alternateDayFull")
private val FORM_EFFORT = mapOf("balanced" to 1, "mediterranean" to 2, "dash" to 2, "highProtein" to 2, "flexitarian" to 2,
                                "lowFat" to 3, "lowCarb" to 3, "fasting168" to 3, "fasting52" to 4, "alternateDay" to 4,
                                "keto" to 5, "alternateDayFull" to 5)
private val KEEPS = listOf("breadAndPasta", "meat", "sweets", "lateEating", "regularMeals")

internal fun dietPerson(context: android.content.Context): CoreDietPlan.Person {
    val p = com.noop.ui.ProfileStore.from(context)
    return CoreDietPlan.Person(p.weightKg, p.heightCm.takeIf { it > 0 }, p.age.takeIf { it > 0 }, p.sex)
}

/** The planner's picture for a name: its own series when it exists, else a meal still life. */
@DrawableRes
private fun dietArt(context: android.content.Context, name: String, @DrawableRes fallback: Int): Int {
    val id = context.resources.getIdentifier(name, "drawable", context.packageName)
    return if (id != 0) id else fallback
}

@DrawableRes
internal fun dietFormArt(context: android.content.Context, form: String): Int {
    val fallback = when (form) {
        "balanced", "flexitarian" -> R.drawable.food_motif_dishes
        "mediterranean" -> R.drawable.food_motif_fats
        "dash" -> R.drawable.food_motif_vegetables
        "highProtein" -> R.drawable.food_motif_eggs
        "lowFat" -> R.drawable.food_motif_fruit
        "lowCarb", "keto" -> R.drawable.food_motif_meat
        else -> R.drawable.food_motif_drinks
    }
    val key = if (form.startsWith("fasting") || form.startsWith("alternate")) "diet_form_fasting" else "diet_form_" + form.lowercase()
    return dietArt(context, key, fallback)
}

@Composable
private fun formName(form: String): String = stringResource(when (form) {
    "mediterranean" -> R.string.diet_form_mediterranean
    "dash" -> R.string.diet_form_dash
    "highProtein" -> R.string.diet_form_high_protein
    "flexitarian" -> R.string.diet_form_flexitarian
    "lowFat" -> R.string.diet_form_low_fat
    "lowCarb" -> R.string.diet_form_low_carb
    "keto" -> R.string.diet_form_keto
    "fasting168" -> R.string.diet_form_fasting168
    "fasting52" -> R.string.diet_form_fasting52
    "alternateDay" -> R.string.diet_form_alternate_day
    "alternateDayFull" -> R.string.diet_form_alternate_day_full
    else -> R.string.diet_form_balanced
})

@Composable
private fun formWhy(form: String): String = stringResource(when (form) {
    "mediterranean" -> R.string.diet_why_mediterranean
    "dash" -> R.string.diet_why_dash
    "highProtein" -> R.string.diet_why_high_protein
    "flexitarian" -> R.string.diet_why_flexitarian
    "lowFat" -> R.string.diet_why_low_fat
    "lowCarb" -> R.string.diet_why_low_carb
    "keto" -> R.string.diet_why_keto
    "fasting168" -> R.string.diet_why_fasting168
    "fasting52" -> R.string.diet_why_fasting52
    "alternateDay" -> R.string.diet_why_alternate_day
    "alternateDayFull" -> R.string.diet_why_alternate_day_full
    else -> R.string.diet_why_balanced
})

@Composable
private fun goalName(goal: String): String = stringResource(when (goal) {
    "maintain" -> R.string.diet_goal_maintain
    "gain" -> R.string.diet_goal_gain
    else -> R.string.diet_goal_lose
})

@Composable
private fun effortName(effort: String): String = stringResource(when (effort) {
    "doable" -> R.string.diet_effort_doable
    "demanding" -> R.string.diet_effort_demanding
    "veryHard" -> R.string.diet_effort_very_hard
    else -> R.string.diet_effort_easy
})

@Composable
private fun effortTint(score: Double): Color = nutrientTint(when {
    score < 2 -> "fiber_g"; score < 3 -> "calcium_mg"; score < 4.5 -> "potassium_mg"; else -> "iron_mg"
}, Forge.colors.dark)

@Composable
private fun addonName(addon: String?): String = stringResource(when (addon) {
    "pescatarian" -> R.string.diet_addon_pescatarian
    "vegetarian" -> R.string.diet_addon_vegetarian
    "vegan" -> R.string.diet_addon_vegan
    else -> R.string.diet_addon_none
})

@Composable
private fun noteText(note: String): String? = when (note) {
    "paceCapped" -> stringResource(R.string.diet_note_pace_capped)
    "paceAboveRecommended" -> stringResource(R.string.diet_note_pace_above)
    "floorApplied" -> stringResource(R.string.diet_note_floor)
    "proteinLow" -> stringResource(R.string.diet_note_protein_low)
    "youngNoDeficit" -> stringResource(R.string.diet_note_young)
    "pregnancyNoDeficit" -> stringResource(R.string.diet_note_pregnancy)
    "underweightNoDeficit" -> stringResource(R.string.diet_note_underweight)
    "goalWeightRaised" -> stringResource(R.string.diet_note_goal_raised)
    else -> null
}

@Composable
private fun holdText(hold: String): String = stringResource(when (hold) {
    "manualSteering" -> R.string.diet_hold_manual
    "tooEarly" -> R.string.diet_hold_too_early
    "notAWeekYet" -> R.string.diet_hold_week
    "fewLoggedDays" -> R.string.diet_hold_logs
    "fewWeighIns" -> R.string.diet_hold_weighins
    else -> R.string.diet_hold_on_plan
})

private fun pct(v: Double): String = NumberFormat.getNumberInstance(Locale.getDefault()).apply { maximumFractionDigits = 2 }.format(v) + " %"
private fun kg(v: Double): String = NumberFormat.getNumberInstance(Locale.getDefault()).apply { maximumFractionDigits = 1 }.format(v) + " kg"

@Composable
private fun EffortDots(effort: Int) {
    val tint = effortTint(effort.toDouble())
    Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        (1..5).forEach { i -> Box(Modifier.size(6.dp).background(if (i <= effort) tint else Forge.colors.textTertiary.copy(alpha = 0.3f), CircleShape)) }
    }
}

@Composable
private fun ChoiceCard(@DrawableRes image: Int, title: String, detail: String, selected: Boolean, badge: String? = null,
                       effort: Int? = null, enabled: Boolean = true, onClick: () -> Unit) {
    val colors = Forge.colors
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(ForgeMetrics.cardRadius))
            .background(colors.surface.copy(alpha = if (enabled) 1f else 0.4f))
            .border(BorderStroke(2.dp, if (selected) colors.accent else Color.Transparent), RoundedCornerShape(ForgeMetrics.cardRadius))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick).padding(12.dp),
           verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Image(painterResource(image), null, contentScale = ContentScale.Crop,
              modifier = Modifier.fillMaxWidth().height(96.dp).clip(RoundedCornerShape(16.dp)))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = Forge.type.headline, color = colors.text, modifier = Modifier.weight(1f))
            effort?.let { EffortDots(it) }
        }
        badge?.let { Text(it, style = Forge.type.caption, color = colors.accent) }
        Text(detail, style = Forge.type.footnote, color = colors.textSecondary)
    }
}

@Composable
private fun CheckRow(title: String, on: Boolean, onToggle: () -> Unit) {
    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Checkbox, onClick = onToggle)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
            Icon(if (on) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked, null,
                 tint = if (on) Forge.colors.accent else Forge.colors.textSecondary)
        }
    }
}

@Composable
private fun ExplainCard(title: String, text: String, art: String = "diet_explain_path") {
    val context = LocalContext.current
    var sources by remember { mutableStateOf(false) }
    ForgeCard(Modifier.fillMaxWidth()) {
        Image(painterResource(dietArt(context, art, R.drawable.food_score_hero)), null, contentScale = ContentScale.Crop,
              modifier = Modifier.fillMaxWidth().height(140.dp).clip(RoundedCornerShape(16.dp)))
        Spacer(Modifier.height(ForgeMetrics.space2))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = Forge.type.headline, color = Forge.colors.text, modifier = Modifier.weight(1f))
            Icon(Icons.Rounded.Info, stringResource(R.string.diet_sources_title), tint = Forge.colors.textSecondary,
                 modifier = Modifier.clickable(role = Role.Button) { sources = !sources }.padding(8.dp))
        }
        Text(text, style = Forge.type.body, color = Forge.colors.textSecondary)
        if (sources) Text(stringResource(R.string.diet_sources), style = Forge.type.caption, color = Forge.colors.textSecondary)
    }
}

@Composable
private fun ForecastChart(weeks: List<CoreDietPlan.Week>, goalKg: Double?) {
    val colors = Forge.colors
    val shown = weeks.take(53)
    if (shown.size < 2) return
    val values = shown.flatMap { listOf(it.lowKg, it.highKg) } + listOfNotNull(goalKg)
    val low = values.min() - 1; val high = values.max() + 1
    Canvas(Modifier.fillMaxWidth().height(180.dp)) {
        fun x(i: Int) = size.width * i / (shown.size - 1)
        fun y(v: Double) = (size.height * (1 - (v - low) / (high - low))).toFloat()
        val band = Path().apply {
            moveTo(x(0), y(shown[0].highKg)); shown.forEachIndexed { i, w -> lineTo(x(i), y(w.highKg)) }
            shown.indices.reversed().forEach { i -> lineTo(x(i), y(shown[i].lowKg)) }; close()
        }
        drawPath(band, colors.food.copy(alpha = 0.24f))
        val line = Path().apply { moveTo(x(0), y(shown[0].midKg)); shown.forEachIndexed { i, w -> lineTo(x(i), y(w.midKg)) } }
        drawPath(line, colors.food, style = Stroke(width = 2.5.dp.toPx()))
        goalKg?.let { g -> drawLine(colors.textSecondary, Offset(0f, y(g)), Offset(size.width, y(g)), strokeWidth = 1.dp.toPx(),
                                    pathEffect = androidx.compose.ui.graphics.PathEffect.dashPathEffect(floatArrayOf(10f, 10f))) }
    }
}

@Composable
private fun NumbersCard(r: CoreDietPlan.Resolved, hide: Boolean) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth()) {
        if (!hide) {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(kcalText(r.averageKcal), style = Forge.type.heroNumber, color = colors.text)
                Spacer(Modifier.width(6.dp))
                Text(stringResource(R.string.diet_kcal_a_day), style = Forge.type.body, color = colors.textSecondary, modifier = Modifier.weight(1f))
                Column(horizontalAlignment = Alignment.End) {
                    EffortDots(r.effortScore.roundToInt())
                    Text(effortName(r.effort), style = Forge.type.caption, color = effortTint(r.effortScore))
                }
            }
            r.fastingDayKcal?.let { f ->
                Text(stringResource(R.string.diet_fasting_days_line, kcalText(r.eatingDayKcal), kcalText(f)), style = Forge.type.footnote, color = colors.textSecondary)
            }
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Row(Modifier.fillMaxWidth()) {
            listOf(Triple(R.string.food_protein, r.proteinG, colors.protein), Triple(R.string.food_carbs, r.carbsG, colors.carbs),
                   Triple(R.string.food_fat, r.fatG, colors.fat)).forEach { (name, g, tint) ->
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(8.dp).background(tint, CircleShape)); Spacer(Modifier.width(4.dp))
                        Text(stringResource(name), style = Forge.type.footnote, color = colors.textSecondary)
                    }
                    Text("${gramsText(g)} g", style = Forge.type.title2, color = colors.text)
                }
            }
        }
        if (!hide) {
            Spacer(Modifier.height(ForgeMetrics.space2))
            Text(when {
                r.dailyDeltaKcal < 0 -> stringResource(R.string.diet_burn_less, kcalText(r.burnKcal), kcalText(-r.dailyDeltaKcal))
                r.dailyDeltaKcal > 0 -> stringResource(R.string.diet_burn_more, kcalText(r.burnKcal), kcalText(r.dailyDeltaKcal))
                else -> stringResource(R.string.diet_burn_same, kcalText(r.burnKcal))
            }, style = Forge.type.footnote, color = colors.textSecondary)
        }
    }
}

/** The guided planner: one question a step, pictures, a live readout of calories and effort, a forecast at the end. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ForgeDietPlanner(start: CoreDietPlan.Plan?, burnKcal: Double?, kcalPerKg: Double?, onClose: () -> Unit,
                              onSaved: (CoreDietPlan.Plan) -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val person = remember { dietPerson(context) }
    var draft by remember { mutableStateOf(start ?: CoreDietPlan.Plan(startDay = LocalDate.now().toString(), startWeightKg = person.weightKg)) }
    var step by remember { mutableIntStateOf(0) }
    var likesRules by remember { mutableStateOf(false) }
    var resolved by remember { mutableStateOf<CoreDietPlan.Resolved?>(null) }
    var suggestions by remember { mutableStateOf<List<CoreDietPlan.Suggestion>>(emptyList()) }
    LaunchedEffect(draft) { resolved = withContext(Dispatchers.IO) { CoreDietPlan.resolve(draft, person, burnKcal, kcalPerKg, LocalDate.now().toString()) } }
    LaunchedEffect(draft.keep, draft.strength, draft.mode, likesRules) {
        suggestions = withContext(Dispatchers.IO) { CoreDietPlan.suggest(draft.keep, likesRules, draft.strength, draft.mode) }
    }
    BackHandler { if (step > 0) step-- else onClose() }
    val steps = 9
    val r = resolved
    Column(Modifier.fillMaxWidth()) {
        SettingsColumn {
            PageTitle(stringResource(R.string.diet_plan_your_diet), { if (step > 0) step-- else onClose() })
            androidx.compose.material3.LinearProgressIndicator(progress = { (step + 1f) / steps }, color = colors.accent,
                modifier = Modifier.fillMaxWidth())
            fun title(@androidx.annotation.StringRes id: Int): @Composable () -> Unit = { Text(stringResource(id), style = Forge.type.title1, color = Forge.sceneInk.text) }
            when (step) {
                0 -> {
                    ExplainCard(stringResource(R.string.diet_explain_start_title), stringResource(R.string.diet_explain_start))
                    title(R.string.diet_q_mode)()
                    ChoiceCard(R.drawable.food_score_hero, stringResource(R.string.diet_mode_simple), stringResource(R.string.diet_mode_simple_detail),
                               draft.mode == "simple") { draft = draft.copy(mode = "simple", steering = "coached",
                                   form = if (draft.form in ADVANCED_FORMS) "balanced" else draft.form, pacePercent = minOf(draft.pacePercent, 1.0)) }
                    ChoiceCard(R.drawable.food_motif_eggs, stringResource(R.string.diet_mode_advanced), stringResource(R.string.diet_mode_advanced_detail),
                               draft.mode == "advanced") { draft = draft.copy(mode = "advanced") }
                }
                1 -> {
                    title(R.string.diet_q_goal)()
                    listOf("lose" to R.drawable.food_motif_vegetables, "maintain" to R.drawable.food_score_hero, "gain" to R.drawable.food_motif_poultry).forEach { (g, img) ->
                        ChoiceCard(dietArt(context, "diet_goal_$g", img), goalName(g), stringResource(when (g) {
                            "maintain" -> R.string.diet_goal_maintain_detail; "gain" -> R.string.diet_goal_gain_detail; else -> R.string.diet_goal_lose_detail
                        }), draft.goal == g) { draft = draft.copy(goal = g, pacePercent = if (g == "gain") 0.25 else if (draft.pacePercent == 0.0) 0.5 else minOf(draft.pacePercent, 1.0)) }
                    }
                    if (person.sex.lowercase() != "male") CheckRow(stringResource(R.string.diet_pregnant), draft.pregnantOrNursing) {
                        draft = draft.copy(pregnantOrNursing = !draft.pregnantOrNursing)
                    }
                }
                2 -> {
                    title(R.string.diet_q_start)()
                    ForgeCard(Modifier.fillMaxWidth()) {
                        Row { Text(stringResource(R.string.diet_today), Modifier.weight(1f), color = colors.text); Text(kg(person.weightKg), color = colors.textSecondary) }
                        Row { Text(stringResource(R.string.diet_usual_burn), Modifier.weight(1f), color = colors.text); Text("${kcalText(r?.burnKcal)} kcal", color = colors.textSecondary) }
                        Text(stringResource(R.string.diet_start_note), style = Forge.type.footnote, color = colors.textSecondary)
                    }
                    if (draft.goal != "maintain") {
                        title(R.string.diet_q_goal_weight)()
                        ForgeCard(Modifier.fillMaxWidth()) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Pill(stringResource(R.string.diet_no_goal_weight), draft.goalWeightKg == null, Modifier.weight(1f)) { draft = draft.copy(goalWeightKg = null) }
                                Pill(stringResource(R.string.diet_set_goal_weight), draft.goalWeightKg != null, Modifier.weight(1f)) {
                                    if (draft.goalWeightKg == null) draft = draft.copy(goalWeightKg = ((person.weightKg * if (draft.goal == "lose") 0.9 else 1.05) * 2).roundToInt() / 2.0)
                                }
                            }
                            draft.goalWeightKg?.let { g ->
                                val range = if (draft.goal == "gain") person.weightKg.toFloat()..(person.weightKg * 1.25).toFloat()
                                            else (person.weightKg * 0.6).toFloat()..person.weightKg.toFloat()
                                Text(kg(g), style = Forge.type.heroNumber, color = colors.text)
                                Slider(g.toFloat().coerceIn(range), { draft = draft.copy(goalWeightKg = (it * 2).roundToInt() / 2.0) }, valueRange = range,
                                       colors = SliderDefaults.colors(thumbColor = colors.food, activeTrackColor = colors.food))
                            }
                        }
                    }
                }
                3 -> {
                    title(R.string.diet_q_pace)()
                    if (draft.goal == "maintain") Text(stringResource(R.string.diet_no_pace), color = colors.textSecondary)
                    else if (draft.mode == "simple") {
                        val paces = if (draft.goal == "gain") listOf(R.string.diet_pace_gentle to 0.25, R.string.diet_pace_normal to 0.5)
                                    else listOf(R.string.diet_pace_gentle to 0.5, R.string.diet_pace_normal to 0.75, R.string.diet_pace_ambitious to 1.0)
                        paces.forEach { (name, p) ->
                            ChoiceCard(R.drawable.food_motif_vegetables, stringResource(name), stringResource(R.string.diet_pace_detail, pct(p), kg(person.weightKg * p / 100)),
                                       abs(draft.pacePercent - p) < 0.01) { draft = draft.copy(pacePercent = p) }
                        }
                    } else {
                        ForgeCard(Modifier.fillMaxWidth()) {
                            Row { Text(stringResource(R.string.diet_pace_a_week, pct(draft.pacePercent)), Modifier.weight(1f), style = Forge.type.headline, color = colors.text)
                                  Text(kg(person.weightKg * draft.pacePercent / 100), color = colors.textSecondary) }
                            Slider(draft.pacePercent.toFloat(), { draft = draft.copy(pacePercent = (it * 20).roundToInt() / 20.0) },
                                   valueRange = 0.1f..(if (draft.goal == "gain") 1f else 1.5f),
                                   colors = SliderDefaults.colors(thumbColor = colors.food, activeTrackColor = colors.food))
                        }
                    }
                    r?.notes?.filter { it == "paceAboveRecommended" }?.forEach { n -> noteText(n)?.let { Text(it, style = Forge.type.footnote, color = colors.textSecondary) } }
                    if (draft.goal == "lose") ExplainCard(stringResource(R.string.diet_explain_pace_title), stringResource(R.string.diet_explain_pace), "diet_explain_pace")
                }
                4 -> {
                    title(R.string.diet_q_keep)()
                    Text(stringResource(R.string.diet_keep_note), style = Forge.type.footnote, color = colors.textSecondary)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        KEEPS.forEach { k ->
                            Pill(stringResource(when (k) { "breadAndPasta" -> R.string.diet_keep_bread; "meat" -> R.string.diet_keep_meat
                                "sweets" -> R.string.diet_keep_sweets; "lateEating" -> R.string.diet_keep_late; else -> R.string.diet_keep_meals }),
                                 k in draft.keep) { draft = draft.copy(keep = if (k in draft.keep) draft.keep - k else draft.keep + k) }
                        }
                    }
                    CheckRow(stringResource(R.string.diet_likes_rules), likesRules) { likesRules = !likesRules }
                    CheckRow(stringResource(R.string.diet_strength), draft.strength) { draft = draft.copy(strength = !draft.strength) }
                }
                5 -> {
                    title(R.string.diet_q_form)()
                    if (suggestions.isNotEmpty()) Text(stringResource(R.string.diet_suggested), style = Forge.type.subhead, color = colors.textSecondary)
                    suggestions.forEach { s -> FormCard(s.form, draft, stringResource(when (s.reason) {
                        "closestToYourLog" -> R.string.diet_reason_log; "keepsWhatYouLove" -> R.string.diet_reason_keeps
                        "likesRules" -> R.string.diet_reason_rules; "strength" -> R.string.diet_reason_strength; else -> R.string.diet_reason_easy
                    })) { draft = it } }
                    ExplainCard(stringResource(R.string.diet_explain_forms_title), stringResource(R.string.diet_explain_forms), "diet_form_mediterranean")
                    Text(stringResource(R.string.diet_all_forms), style = Forge.type.subhead, color = colors.textSecondary)
                    FORMS.filter { (draft.mode == "advanced" || it !in ADVANCED_FORMS) && suggestions.none { s -> s.form == it } }
                        .forEach { f -> FormCard(f, draft, null) { draft = it } }
                }
                6 -> {
                    title(R.string.diet_q_addon)()
                    listOf(null, "pescatarian", "vegetarian", "vegan").forEach { a ->
                        val blocked = a == "vegan" && draft.form == "keto"
                        ChoiceCard(dietArt(context, "diet_form_" + (a ?: "balanced"), if (a == null) R.drawable.food_motif_dishes else if (a == "pescatarian") R.drawable.food_motif_fish else R.drawable.food_motif_legumes),
                                   addonName(a), if (blocked) stringResource(R.string.diet_addon_blocked) else stringResource(when (a) {
                                       "pescatarian" -> R.string.diet_addon_pescatarian_detail; "vegetarian" -> R.string.diet_addon_vegetarian_detail
                                       "vegan" -> R.string.diet_addon_vegan_detail; else -> R.string.diet_addon_none_detail }),
                                   draft.addon == a, enabled = !blocked) { draft = draft.copy(addon = a) }
                    }
                }
                7 -> {
                    title(R.string.diet_q_numbers)()
                    r?.let { NumbersCard(it, false) }
                    if (draft.mode == "advanced") ForgeCard(Modifier.fillMaxWidth()) {
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            listOf("coached" to R.string.diet_steer_coached, "caloriesOnly" to R.string.diet_steer_calories, "manual" to R.string.diet_steer_manual).forEach { (s, n) ->
                                Pill(stringResource(n), draft.steering == s, Modifier.weight(1f)) { draft = draft.copy(steering = s) }
                            }
                        }
                        if (draft.steering == "manual") Dial(stringResource(R.string.diet_dial_kcal), (draft.fixedKcal ?: r?.averageKcal ?: 2000.0), 1200f..6000f,
                            { "${kcalText(it)} kcal" }) { draft = draft.copy(fixedKcal = (it / 25).roundToInt() * 25.0) }
                        Dial(stringResource(R.string.diet_dial_protein), draft.proteinPerKg ?: ((r?.proteinG ?: 0.0) / maxOf(1.0, person.weightKg)).coerceIn(1.2, 2.4),
                             1.2f..2.4f, { String.format(Locale.getDefault(), "%.1f g", it) }) { draft = draft.copy(proteinPerKg = (it * 10).roundToInt() / 10.0) }
                        if (draft.form != "lowCarb" && draft.form != "keto") Dial(stringResource(R.string.diet_dial_carbs), draft.carbShareOfRest ?: 0.55, 0.2f..0.8f,
                            { pct(it * 100) }) { draft = draft.copy(carbShareOfRest = (it * 20).roundToInt() / 20.0) }
                    }
                    r?.notes?.filter { it != "goalWeightRaised" && it != "paceAboveRecommended" }?.forEach { n ->
                        noteText(n)?.let { Text(it, style = Forge.type.footnote, color = colors.textSecondary) }
                    }
                }
                else -> {
                    title(R.string.diet_q_summary)()
                    r?.let { res ->
                        Text("${goalName(res.goal)} · ${formName(draft.form)}" + (draft.addon?.let { " · ${addonName(it)}" } ?: ""), style = Forge.type.headline, color = Forge.sceneInk.text)
                        if (res.goal != "maintain") ForgeCard(Modifier.fillMaxWidth()) {
                            ForecastChart(res.weeks, res.goalWeightKg)
                            Text(forecastLine(res), style = Forge.type.body, color = colors.text)
                            Text(stringResource(R.string.diet_band_note), style = Forge.type.footnote, color = colors.textSecondary)
                        }
                        NumbersCard(res, draft.hideNumbers)
                        res.notes.forEach { n -> noteText(n)?.let { Text(it, style = Forge.type.footnote, color = colors.textSecondary) } }
                    }
                    CheckRow(stringResource(R.string.diet_hide_numbers), draft.hideNumbers) { draft = draft.copy(hideNumbers = !draft.hideNumbers) }
                    ExplainCard(stringResource(R.string.diet_explain_hold_title), stringResource(R.string.diet_explain_hold), "diet_explain_hold")
                }
            }
            Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space3), verticalAlignment = Alignment.CenterVertically) {
                if (step in 3..7 && r != null) Column(Modifier.weight(1f)) {
                    Text("${kcalText(r.averageKcal)} kcal", style = Forge.type.headline, color = colors.text)
                    Text(effortName(r.effort), style = Forge.type.caption, color = effortTint(r.effortScore))
                } else Spacer(Modifier.weight(1f))
                Box(Modifier.clip(CircleShape).background(colors.accent).clickable(role = Role.Button) {
                        if (step < steps - 1) step++ else {
                            val saved = draft.copy(startWeightKg = person.weightKg,
                                startDay = if (start == null || start.goal != draft.goal || start.form != draft.form) LocalDate.now().toString() else draft.startDay)
                            CoreDietPlan.save(context, saved); onSaved(saved)
                        }
                    }.padding(horizontal = 28.dp, vertical = 14.dp)) {
                    Text(stringResource(if (step < steps - 1) R.string.diet_next else R.string.diet_start_plan), style = Forge.type.headline, color = Color.White)
                }
            }
        }
    }
}

@Composable
private fun forecastLine(r: CoreDietPlan.Resolved): String = when {
    r.goalWeightKg == null -> stringResource(R.string.diet_band_note)
    r.goalWeeks == null -> stringResource(R.string.diet_goal_beyond)
    r.goalWeeks.first == r.goalWeeks.second -> stringResource(R.string.diet_goal_in, r.goalWeeks.first)
    else -> stringResource(R.string.diet_goal_in_range, r.goalWeeks.first, r.goalWeeks.second)
}

@Composable
private fun FormCard(form: String, draft: CoreDietPlan.Plan, badge: String?, onPick: (CoreDietPlan.Plan) -> Unit) {
    val context = LocalContext.current
    ChoiceCard(dietFormArt(context, form), formName(form), formWhy(form), draft.form == form, badge, FORM_EFFORT[form]) {
        onPick(draft.copy(form = form, addon = if (form == "keto" && draft.addon == "vegan") null else draft.addon))
    }
}

@Composable
private fun Pill(text: String, on: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(modifier.clip(CircleShape).background(if (on) Forge.colors.accent else Forge.colors.surface)
            .clickable(role = Role.Button, onClick = onClick).heightIn(min = 44.dp).padding(horizontal = 14.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center) {
        Text(text, style = Forge.type.subhead, color = if (on) Color.White else Forge.colors.text)
    }
}

@Composable
private fun Dial(label: String, value: Double, range: ClosedFloatingPointRange<Float>, text: (Double) -> String, onChange: (Double) -> Unit) {
    Column {
        Row { Text(label, Modifier.weight(1f), color = Forge.colors.text); Text(text(value), color = Forge.colors.textSecondary) }
        Slider(value.toFloat().coerceIn(range), { onChange(it.toDouble()) }, valueRange = range,
               colors = SliderDefaults.colors(thumbColor = Forge.colors.accent, activeTrackColor = Forge.colors.accent))
    }
}

/** The plan in one line at the top of Nutrition. */
@Composable
internal fun DietPlanLine(plan: CoreDietPlan.Plan?, resolved: CoreDietPlan.Resolved?, onClick: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().clip(CircleShape).background(colors.surface).clickable(role = Role.Button, onClick = onClick).padding(10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Image(painterResource(plan?.let { dietFormArt(context, it.form) } ?: R.drawable.food_score_hero), null, contentScale = ContentScale.Crop,
              modifier = Modifier.size(40.dp).clip(CircleShape))
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(Modifier.weight(1f)) {
            Text(if (plan == null || resolved == null) stringResource(R.string.diet_plan_your_diet)
                 else if (resolved.goal == "maintain" || plan.hideNumbers) goalName(resolved.goal)
                 else "${goalName(resolved.goal)} · ${stringResource(R.string.diet_pace_a_week, pct(resolved.pacePercent))}",
                 style = Forge.type.subhead, color = colors.text)
            Text(plan?.let { formName(it.form) } ?: stringResource(R.string.diet_plan_line_empty), style = Forge.type.footnote, color = colors.textSecondary, maxLines = 1)
        }
        Icon(Icons.Rounded.ChevronRight, null, tint = colors.textSecondary)
    }
}

/** The plan page: where the plan heads, this week's look, every day's numbers and the foods that suit it. */
@Composable
internal fun ForgeDietPlanPage(plan: CoreDietPlan.Plan, resolved: CoreDietPlan.Resolved?, week: CoreDietPlan.Outcome?, weekApplied: Boolean,
                               onBack: () -> Unit, onEdit: () -> Unit, onEnd: () -> Unit, onPlanChange: (CoreDietPlan.Plan) -> Unit,
                               onWeekAccept: () -> Unit, onWeekDecline: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    BackHandler(onBack = onBack)
    SettingsColumn {
        PageTitle(stringResource(R.string.diet_plan), onBack)
        Box(Modifier.fillMaxWidth().height(180.dp).clip(RoundedCornerShape(ForgeMetrics.cardRadius)), contentAlignment = Alignment.BottomStart) {
            Image(painterResource(dietFormArt(context, plan.form)), null, contentScale = ContentScale.Crop, modifier = Modifier.matchParentSize())
            Column(Modifier.padding(16.dp)) {
                Text(goalName(resolved?.goal ?: plan.goal), style = Forge.type.title1, color = Color.White)
                Text(formName(plan.form) + (plan.addon?.let { " · ${addonName(it)}" } ?: ""), style = Forge.type.body, color = Color.White.copy(alpha = 0.8f))
            }
        }
        week?.let { w ->
            ForgeCard(Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.diet_this_week), style = Forge.type.subhead, color = colors.textSecondary)
                if (w.hold != null) Text(holdText(w.hold), style = Forge.type.body, color = colors.text)
                else {
                    val amount = kcalText(abs(w.changeKcal))
                    Text(stringResource(if (weekApplied) (if (w.changeKcal < 0) R.string.diet_week_lowered else R.string.diet_week_raised)
                                        else (if (w.changeKcal < 0) R.string.diet_week_lower_q else R.string.diet_week_raise_q), amount),
                         style = Forge.type.body, color = colors.text)
                    Row {
                        if (weekApplied) TextButton(onClick = onWeekDecline) { Text(stringResource(R.string.diet_undo)) }
                        else { TextButton(onClick = onWeekAccept) { Text(stringResource(R.string.diet_change_it)) }
                               TextButton(onClick = onWeekDecline) { Text(stringResource(R.string.diet_keep_goal)) } }
                    }
                }
            }
        }
        resolved?.let { r ->
            if (!plan.hideNumbers && r.goal != "maintain") {
                FoodSectionHeader(stringResource(R.string.diet_heading))
                ForgeCard(Modifier.fillMaxWidth()) {
                    ForecastChart(r.weeks, r.goalWeightKg)
                    Text(forecastLine(r), style = Forge.type.body, color = colors.text)
                    Text(stringResource(R.string.diet_band_note), style = Forge.type.footnote, color = colors.textSecondary)
                }
            }
            FoodSectionHeader(stringResource(R.string.diet_every_day))
            NumbersCard(r, plan.hideNumbers)
            r.notes.forEach { n -> noteText(n)?.let { Text(it, style = Forge.type.footnote, color = colors.textSecondary) } }
        }
        CheckRow(stringResource(R.string.diet_hide_numbers), plan.hideNumbers) { onPlanChange(plan.copy(hideNumbers = !plan.hideNumbers)) }
        Box(Modifier.fillMaxWidth().clip(CircleShape).background(colors.accent).clickable(role = Role.Button, onClick = onEdit).padding(14.dp),
            contentAlignment = Alignment.Center) { Text(stringResource(R.string.diet_change_plan), style = Forge.type.headline, color = Color.White) }
        TextButton(onClick = onEnd, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.diet_end_plan), color = colors.effort) }
    }
}

/** The energy plan's figures the planner needs: usual burn and the wearer's own cost per kilogram. */
internal fun planInputs(plan: CoreEnergyPlan.Plan?): Pair<Double?, Double?> =
    (plan?.measuredMeanKcal ?: plan?.allDaysMeanKcal ?: plan?.formulaTdeeKcal) to plan?.observedKcalPerKg
