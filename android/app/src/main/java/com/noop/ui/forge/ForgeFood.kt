package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.ChevronLeft
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Numbers
import androidx.compose.material.icons.rounded.QrCodeScanner
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.TextSnippet
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.sp
import androidx.compose.ui.input.pointer.pointerInput
import com.noop.R
import com.noop.core.CoreDietPlan
import com.noop.core.CoreEnergyPlan
import com.noop.core.CoreFood
import com.noop.core.CoreRead
import com.noop.ingest.FoodHealthConnect
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Fork (DX23876), decision 2026-11-08: the Food page after iOS `ForgeFoodView`. One day of the shared food log:
 * calories against the energy plan's goal (`FoodTargets` in the core), the macronutrients, the nutrients worth a
 * look and the meals in eating order; adding through search, recent, favourites, own foods, the barcode scanner,
 * a quick calorie entry and, with the coach on, a described meal. Every figure comes from the core.
 */
@Composable
internal fun ForgeFoodPage(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var day by remember { mutableStateOf(LocalDate.now()) }
    var summary by remember { mutableStateOf<CoreFood.Day?>(null) }
    var baseGoals by remember { mutableStateOf<CoreFood.Goals?>(null) }
    // The diet plan (decision 2026-11-09) outranks the base goals; its figures come from the core.
    var dietPlan by remember { mutableStateOf(CoreDietPlan.load(context)) }
    var planResolved by remember { mutableStateOf<CoreDietPlan.Resolved?>(null) }
    var planWeek by remember { mutableStateOf<CoreDietPlan.Outcome?>(null) }
    var planWeekApplied by remember { mutableStateOf(false) }
    var planInputs by remember { mutableStateOf<Pair<Double?, Double?>>(null to null) }
    var planning by remember { mutableStateOf(false) }
    var showPlan by remember { mutableStateOf(false) }
    val goals = planResolved?.let { r ->
        CoreFood.Goals(r.dayKcal, "plan", r.burnKcal, r.averageKcal - r.burnKcal, r.dayProteinG, r.dayCarbsG, r.dayFatG)
    } ?: baseGoals
    val goal = goals?.kcal
    var dayNutrients by remember { mutableStateOf<CoreFood.NutrientReport?>(null) }
    var pinned by remember { mutableStateOf(foodPinned(context)) }
    var burnedByDay by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    var revision by remember { mutableIntStateOf(0) }
    // The first-visit setup (owner, 2026-11-09) comes first; a request to add (Today's Log sheet, the Health & body
    // card) is kept and opens the add page once the setup closes.
    var setup by remember { mutableStateOf(foodSetupNeeded(context)) }
    val arrivedToAdd = remember { FoodArrival.consume() }
    // Held only while the setup stands in front; an add page opened at once is not opened again later.
    var addAfterSetup by remember { mutableStateOf(arrivedToAdd && setup) }
    var adding by remember { mutableStateOf(arrivedToAdd && !setup) }
    var settings by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<CoreFood.Entry?>(null) }
    var nutrients by remember { mutableStateOf<CoreFood.NutrientReport?>(null) }
    var showNutrients by remember { mutableStateOf(false) }
    var week by remember { mutableStateOf<CoreFood.Week?>(null) }
    var habit by remember { mutableStateOf<CoreFood.Habit?>(null) }
    var sentence by remember { mutableStateOf<List<CoreFood.SentencePoint>>(emptyList()) }
    var showScore by remember { mutableStateOf(false) }
    val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current

    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreFood.prepare()
            FoodHealthConnect.importDays(context)
            val plan = CoreEnergyPlan.plan(context, dismissedTrainingWorkouts(context))
            baseGoals = loadFoodGoals(context, plan)
            burnedByDay = plan?.burnedByDay ?: emptyMap()
            planInputs = planInputs(plan)
            // Once a day: the weekly look at the plan. Simple mode with Forge steering applies the change (with undo).
            CoreDietPlan.load(context)?.let { current ->
                val today = LocalDate.now().toString()
                if (current.lastAdjustedDay != today) {
                    val outcome = CoreDietPlan.weekly(current, dietPerson(context), planInputs.first, planInputs.second)
                    planWeek = outcome
                    if (outcome != null && outcome.hold == null && current.mode == "simple" && current.steering == "coached") {
                        val next = current.copy(adjustmentKcal = current.adjustmentKcal + outcome.changeKcal, lastAdjustedDay = today)
                        CoreDietPlan.save(context, next); dietPlan = next; planWeekApplied = true
                    }
                }
            }
        }
    }
    LaunchedEffect(day, dietPlan, planInputs) {
        planResolved = dietPlan?.let { p ->
            withContext(Dispatchers.IO) { CoreDietPlan.resolve(p, dietPerson(context), planInputs.first, planInputs.second, day.toString()) }
        }
    }
    LaunchedEffect(day, revision, goal) {
        summary = withContext(Dispatchers.IO) { CoreFood.day(day.toString()) }
        nutrients = withContext(Dispatchers.IO) {
            val profile = com.noop.ui.ProfileStore.from(context)
            CoreFood.nutrients(day.toString(), profile.sex, profile.age, profile.weightKg, profile.heightCm, goal)
        }
        dayNutrients = withContext(Dispatchers.IO) {
            val profile = com.noop.ui.ProfileStore.from(context)
            CoreFood.nutrients(day.toString(), profile.sex, profile.age, profile.weightKg, profile.heightCm, goal, span = "day")
        }
        withContext(Dispatchers.IO) {
            val profile = com.noop.ui.ProfileStore.from(context)
            val today = LocalDate.now()
            week = CoreFood.week(day.toString(), today.toString(), foodScoreEnabled(context), profile.sex)
            habit = if (day == today && !foodHabitDismissed(context, today.toString())) CoreFood.habit(today.toString(), System.currentTimeMillis() / 1000) else null
            // The evening sentence from 18:00 on today, any time for a past day (iOS `FoodDaySentence.fromHour`).
            sentence = if (day != today || java.time.LocalTime.now().hour >= 18)
                CoreFood.sentence(day.toString(), goals?.proteinG, profile.sex, profile.age, profile.weightKg, profile.heightCm, goal)
            else emptyList()
        }
    }
    // A light tick when the day changes, not when the page opens.
    var shownOnce by remember { mutableStateOf(false) }
    LaunchedEffect(day) {
        if (shownOnce) haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.TextHandleMove)
        shownOnce = true
    }
    fun reload() { revision++ }

    val score = week?.score
    if (showScore && score != null) {
        BackHandler { showScore = false }
        ForgeFoodScorePage(score, male = com.noop.ui.ProfileStore.from(context).sex.lowercase() == "male", onBack = { showScore = false })
        return
    }
    if (planning) {
        BackHandler { planning = false }
        ForgeDietPlanner(dietPlan, planInputs.first, planInputs.second, onClose = { planning = false }) { saved ->
            dietPlan = saved; planWeek = null; planning = false
        }
        return
    }
    val currentPlan = dietPlan
    if (showPlan && currentPlan != null) {
        ForgeDietPlanPage(currentPlan, planResolved, planWeek, planWeekApplied, onBack = { showPlan = false }, onEdit = { planning = true },
            onEnd = { CoreDietPlan.save(context, null); dietPlan = null; planResolved = null; showPlan = false },
            onPlanChange = { CoreDietPlan.save(context, it); dietPlan = it },
            onWeekAccept = { planWeek?.let { w ->
                val next = currentPlan.copy(adjustmentKcal = currentPlan.adjustmentKcal + w.changeKcal, lastAdjustedDay = LocalDate.now().toString())
                CoreDietPlan.save(context, next); dietPlan = next; planWeekApplied = true } },
            onWeekDecline = { planWeek?.let { w ->
                val back = if (planWeekApplied) currentPlan.adjustmentKcal - w.changeKcal else currentPlan.adjustmentKcal
                val next = currentPlan.copy(adjustmentKcal = back, lastAdjustedDay = LocalDate.now().toString())
                CoreDietPlan.save(context, next); dietPlan = next; planWeek = null; planWeekApplied = false } })
        return
    }
    if (showNutrients && nutrients != null && dayNutrients != null) {
        BackHandler { showNutrients = false }
        ForgeFoodNutrientsPage(nutrients!!, dayNutrients!!, pinned, onPin = { key -> pinned = toggleFoodPin(context, key) },
                               onBack = { showNutrients = false })
        return
    }
    fun reloadGoals() {
        scope.launch { baseGoals = withContext(Dispatchers.IO) { loadFoodGoals(context, CoreEnergyPlan.plan(context, dismissedTrainingWorkouts(context))) } }
        revision++
    }
    if (setup) {
        val close = {
            markFoodSetupDone(context); setup = false; reloadGoals()
            if (addAfterSetup) { addAfterSetup = false; adding = true }
        }
        BackHandler(onBack = close)
        ForgeFoodSetupPage(onDone = close)
        return
    }
    if (settings) {
        BackHandler { settings = false; revision++ }
        ForgeFoodDataPage(onBack = { settings = false; reloadGoals() },
                          onSetup = { settings = false; setup = true })
        return
    }
    if (adding) {
        BackHandler { adding = false }
        ForgeFoodAddPage(day = day, onBack = { adding = false; reload() })
        return
    }
    editing?.let { entry ->
        FoodEntryDialog(entry, onDismiss = { editing = null }, onSave = { grams, meal, changeMeal ->
            scope.launch {
                withContext(Dispatchers.IO) {
                    CoreFood.edit(entry.id, grams, null, meal, changeMeal)?.let { (next, old) ->
                        FoodHealthConnect.replaced(context, old, next)
                    }
                }
                editing = null; reload()
            }
        }, onDelete = {
            scope.launch {
                withContext(Dispatchers.IO) { FoodHealthConnect.removed(context, CoreFood.delete(listOf(entry.id))) }
                editing = null; reload()
            }
        })
    }

    // The Food page's picture (iOS `FoodHeroPicture`): a dark still life behind the title, fading out above the plate.
    Box(Modifier.fillMaxSize()) {
        // drawable-night holds the night photo, drawable the daylight one, so it never sits as a dark block on light.
        androidx.compose.foundation.Image(androidx.compose.ui.res.painterResource(R.drawable.food_hero), contentDescription = null,
            contentScale = androidx.compose.ui.layout.ContentScale.Crop, alignment = Alignment.TopEnd,
            modifier = Modifier.fillMaxWidth().height(400.dp)
                .graphicsLayer(compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen)
                .drawWithContent {
                    drawContent()
                    drawRect(androidx.compose.ui.graphics.Brush.verticalGradient(
                        0f to androidx.compose.ui.graphics.Color.Black, 0.4f to androidx.compose.ui.graphics.Color.Black,
                        0.7f to androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.35f), 0.92f to androidx.compose.ui.graphics.Color.Transparent),
                        blendMode = androidx.compose.ui.graphics.BlendMode.DstIn)
                })
        SettingsColumn {
            // Adding sits in the title row, always in reach, instead of a button below the meals.
            PageTitle(stringResource(R.string.food_title), onBack) {
                IconButton(onClick = { settings = true }) {
                    Icon(Icons.Rounded.Settings, stringResource(R.string.food_data_title), tint = Forge.sceneInk.text)
                }
                IconButton(onClick = { adding = true }) {
                    Icon(Icons.Rounded.Add, stringResource(R.string.food_add), tint = Forge.colors.accent)
                }
            }
            Text(dayTitle(day).uppercase(Locale.getDefault()), style = Forge.type.overline, color = Forge.sceneInk.secondary)
            DietPlanLine(dietPlan, planResolved) { if (dietPlan == null) planning = true else showPlan = true }
            FoodHero(day, summary?.totals ?: emptyMap(), goals, burnedByDay[day.toString()], onDay = { day = it })
            if (sentence.isNotEmpty()) FoodSentence(sentence)
            week?.let { w ->
                FoodSectionHeader(stringResource(R.string.food_week))
                FoodWeekStrip(w.days, day.toString(), goals) { day = LocalDate.parse(it) }
                if (foodScoreEnabled(context)) FoodScoreRow(w.score, w.loggedDays) { if (w.score != null) showScore = true }
            }
            val s = summary
            FoodSectionHeader(stringResource(R.string.food_nutrients)) { showNutrients = true }
            FoodNutrientCard(dayNutrients, pinned) { showNutrients = true }
            FoodSectionHeader(stringResource(R.string.food_meals))
            habit?.let { h ->
                FoodHabitCard(h, onAdd = {
                    scope.launch {
                        withContext(Dispatchers.IO) { FoodHealthConnect.wrote(context, CoreFood.copy(h.entries.map { it.id }, listOf(day.toString()))) }
                        haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
                        reload()
                    }
                }, onDismiss = { dismissFoodHabit(context, day.toString()); habit = null })
            }
            if (s != null && s.meals.isNotEmpty()) {
                s.meals.forEach { meal ->
                    MealCard(meal, onEdit = { editing = it }, onCopyTomorrow = {
                        scope.launch {
                            withContext(Dispatchers.IO) {
                                val copies = CoreFood.copy(meal.entries.map { it.id }, listOf(day.plusDays(1).toString()))
                                FoodHealthConnect.wrote(context, copies)
                            }
                            reload()
                        }
                    }, onDelete = {
                        scope.launch {
                            withContext(Dispatchers.IO) { FoodHealthConnect.removed(context, CoreFood.delete(meal.entries.map { it.id })) }
                            reload()
                        }
                    })
                }
            } else {
                ForgeCard(Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.food_empty_title), style = Forge.type.headline, color = Forge.colors.text)
                    Text(stringResource(R.string.food_empty_body), style = Forge.type.body, color = Forge.colors.textSecondary)
                    TextButton(onClick = { adding = true }) { Text(stringResource(R.string.food_add), color = Forge.colors.accent) }
                }
            }
        }
    }
}

/** The goals from the core (`FoodTargets`), with the wearer's fixed goal and split from the shared keys. */
internal fun loadFoodGoals(context: android.content.Context, plan: CoreEnergyPlan.Plan?): CoreFood.Goals? {
    val prefs = com.noop.ui.NoopPrefs.of(context)
    fun pct(key: String) = if (prefs.contains(key)) prefs.getFloat(key, 0f).toDouble() else null
    return CoreFood.goals(plan?.measuredMeanKcal, plan?.allDaysMeanKcal, plan?.formulaTdeeKcal, plan?.dailyDeltaKcal,
                          prefs.getFloat("food.goal.kcal", 0f).toDouble().takeIf { it > 0 },
                          pct("food.goal.proteinPercent"), pct("food.goal.carbsPercent"), pct("food.goal.fatPercent"))
}

/** The nutrients pinned to the Food page, the same key and default as iOS (`FoodTargets.Keys.pinned`). */
internal fun foodPinned(context: android.content.Context): List<String> =
    (com.noop.ui.NoopPrefs.of(context).getString("food.pinnedNutrients", "") ?: "").split(',').filter { it.isNotBlank() }
        .ifEmpty { listOf("fiber_g", "epa_g", "sat_fat_g", "salt_g") }.take(4)

internal fun toggleFoodPin(context: android.content.Context, key: String): List<String> {
    val list = foodPinned(context).toMutableList()
    if (!list.remove(key)) list.add(key)
    val next = list.takeLast(4)
    com.noop.ui.NoopPrefs.of(context).edit().putString("food.pinnedNutrients", next.joinToString(",")).apply()
    return next
}

internal fun kcalText(value: Double?): String =
    value?.let { NumberFormat.getIntegerInstance(Locale.getDefault()).format(it.roundToInt()) } ?: "–"

internal fun gramsText(value: Double?): String {
    val v = value ?: return "–"
    val f = NumberFormat.getNumberInstance(Locale.getDefault())
    f.maximumFractionDigits = if (v < 10) 1 else 0
    // No grouping: this text is also what the amount fields parse back ("1.200" would read as 1.2).
    f.isGroupingUsed = false
    return f.format(v)
}

@Composable
internal fun mealName(kind: String): String = stringResource(when (kind) {
    "breakfast" -> R.string.food_meal_breakfast
    "lunch" -> R.string.food_meal_lunch
    "dinner" -> R.string.food_meal_dinner
    else -> R.string.food_meal_snack
})

@Composable
private fun dayTitle(day: LocalDate): String = if (day == LocalDate.now()) stringResource(R.string.food_today)
    else day.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.FULL).withLocale(Locale.getDefault()))

/**
 * The plate standing free in the scene, as iOS `FoodPlate`: calories eaten as the outer ring, protein, carbohydrate
 * and fat as three finer rings inside it, what is left of the goal in the middle. The day before and after sit on
 * either side; under it the three macronutrients and the day's energy.
 */
@Composable
private fun FoodHero(day: LocalDate, totals: Map<String, Double>, goals: CoreFood.Goals?, burned: Double?,
                     onDay: (LocalDate) -> Unit) {
    val colors = Forge.colors
    val eaten = totals["energy_kcal"] ?: 0.0
    val goal = goals?.kcal
    val macros = listOf(
        PlateMacro(stringResource(R.string.food_protein), totals["protein_g"] ?: 0.0, goals?.proteinG, colors.protein),
        PlateMacro(stringResource(R.string.food_carbs), totals["carbs_g"] ?: 0.0, goals?.carbsG, colors.carbs),
        PlateMacro(stringResource(R.string.food_fat), totals["fat_g"] ?: 0.0, goals?.fatG, colors.fat),
    )
    var showReason by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space2), horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space5)) {
        Row(Modifier.fillMaxWidth().pointerInput(day) {
                var dx = 0f
                detectHorizontalDragGestures(onDragEnd = {
                    if (abs(dx) > 60) onDay(if (dx < 0) day.plusDays(1) else day.minusDays(1))
                    dx = 0f
                }) { _, d -> dx += d }
            }, verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { onDay(day.minusDays(1)) }) {
                Icon(Icons.Rounded.ChevronLeft, stringResource(R.string.food_previous_day), tint = colors.textSecondary)
            }
            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                Box(Modifier.size(262.dp), contentAlignment = Alignment.Center) {
                    Canvas(Modifier.size(262.dp)) {
                        // Outer ring 236 dp at 18 dp, inner rings 199, 169 and 139 dp at 11 dp, each 4 dp apart.
                        fun ring(diameter: Float, line: Float, share: Double, tint: androidx.compose.ui.graphics.Color) {
                            val d = diameter.dp.toPx(); val w = line.dp.toPx()
                            val topLeft = Offset((size.width - d) / 2, (size.height - d) / 2)
                            val box = androidx.compose.ui.geometry.Size(d, d)
                            drawArc(tint.copy(alpha = 0.2f), 0f, 360f, false, topLeft, box, style = Stroke(w))
                            val sweep = (360 * min(1.0, max(0.0, share))).toFloat()
                            if (sweep > 0) {
                                // A soft glow under the arc, then the arc deepening towards its tip.
                                drawArc(tint.copy(alpha = 0.22f), -90f, sweep, false, topLeft, box, style = Stroke(w * 1.9f, cap = StrokeCap.Round))
                                drawArc(tint, -90f, sweep, false, topLeft, box, style = Stroke(w, cap = StrokeCap.Round))
                            }
                            // Past a full turn a second lap in a deeper shade, as iOS `GlowRing(overflow:)` draws it.
                            val lap = (360 * min(1.0, max(0.0, share - 1))).toFloat()
                            if (lap > 0) {
                                val deep = androidx.compose.ui.graphics.lerp(tint, androidx.compose.ui.graphics.Color.Black, 0.28f)
                                drawArc(deep, -90f, lap, false, topLeft, box, style = Stroke(w, cap = StrokeCap.Round))
                            }
                        }
                        ring(236f, 18f, goal?.let { eaten / max(1.0, it) } ?: 0.0, colors.food)
                        listOf(199f, 169f, 139f).zip(macros).forEach { (d, m) ->
                            ring(d, 11f, m.goal?.let { m.grams / max(1.0, it) } ?: 0.0, m.tint)
                        }
                    }
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        val left = goal?.let { it - eaten }
                        Text(kcalText(abs(left ?: eaten)), style = Forge.type.heroNumber.copy(fontSize = 38.sp),
                             color = if ((left ?: 0.0) < 0) colors.effort else colors.text)
                        Text(stringResource(when {
                            left == null -> R.string.food_kcal_eaten_short
                            left >= 0 -> R.string.food_kcal_left_short
                            else -> R.string.food_kcal_over_short
                        }), style = Forge.type.body, color = colors.textSecondary)
                    }
                }
            }
            IconButton(onClick = { onDay(day.plusDays(1)) }) {
                Icon(Icons.Rounded.ChevronRight, stringResource(R.string.food_next_day), tint = colors.textSecondary)
            }
        }
        Row(Modifier.fillMaxWidth()) {
            macros.forEach { m ->
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(8.dp).background(m.tint, CircleShape))
                        Spacer(Modifier.width(6.dp))
                        Text(m.name, style = Forge.type.footnote, color = colors.textSecondary)
                    }
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(gramsText(m.grams), style = Forge.type.title2, color = colors.text)
                        Text(m.goal?.let { " " + stringResource(R.string.food_slash_grams, gramsText(it)) } ?: " " + stringResource(R.string.food_grams_unit), style = Forge.type.footnote, color = colors.textSecondary,
                             modifier = Modifier.padding(bottom = 2.dp))
                    }
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(40.dp)) {
            EnergyFigure(stringResource(R.string.food_eaten_label), kcalText(eaten))
            if (goals != null) {
                EnergyFigure(stringResource(R.string.food_goal_label), kcalText(goals.kcal), info = true,
                             modifier = Modifier.clickable(role = Role.Button) { showReason = true })
            }
            if (burned != null) {
                EnergyFigure(stringResource(if (day == LocalDate.now()) R.string.food_burned_so_far else R.string.food_burned), kcalText(burned))
            }
        }
    }
    if (showReason && goals != null) {
        val usual = stringResource(if (goals.basis == "measured") R.string.food_goal_usual else R.string.food_goal_formula, kcalText(goals.burnKcal))
        val text = when {
            goals.basis == "plan" -> stringResource(R.string.diet_goal_from_plan)
            goals.basis == "fixed" -> stringResource(R.string.food_goal_fixed)
            goals.planDeltaKcal < 0 -> usual + " " + stringResource(R.string.food_goal_plan_off, kcalText(-goals.planDeltaKcal))
            goals.planDeltaKcal > 0 -> usual + " " + stringResource(R.string.food_goal_plan_adds, kcalText(goals.planDeltaKcal))
            else -> usual
        }
        AlertDialog(onDismissRequest = { showReason = false }, title = { Text(stringResource(R.string.food_goal_how)) },
                    text = { Text(text) },
                    confirmButton = { TextButton(onClick = { showReason = false }) { Text(stringResource(R.string.food_done)) } })
    }
}

private data class PlateMacro(val name: String, val grams: Double, val goal: Double?, val tint: androidx.compose.ui.graphics.Color)

@Composable
private fun EnergyFigure(title: String, value: String, info: Boolean = false, modifier: Modifier = Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = Forge.type.footnote, color = Forge.colors.textSecondary)
            if (info) {
                Spacer(Modifier.width(4.dp))
                Icon(Icons.Rounded.Info, null, tint = Forge.colors.textSecondary, modifier = Modifier.size(14.dp))
            }
        }
        Text(value, style = Forge.type.bodyNumber, color = Forge.colors.text)
    }
}

/** A section's title standing in the scene above its card; with an action it opens the section's own page. */
@Composable
internal fun FoodSectionHeader(title: String, onOpen: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space4)
            .then(if (onOpen != null) Modifier.clickable(role = Role.Button, onClick = onOpen) else Modifier),
        verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = Forge.type.title2, color = Forge.sceneInk.text)
        if (onOpen != null) {
            Spacer(Modifier.width(6.dp))
            Icon(Icons.Rounded.ChevronRight, null, tint = Forge.sceneInk.secondary)
        }
    }
}

@Composable
private fun MealCard(meal: CoreFood.Meal, onEdit: (CoreFood.Entry) -> Unit, onCopyTomorrow: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val time = Instant.ofEpochSecond(meal.start).atZone(ZoneId.systemDefault()).toLocalTime()
        .format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(Locale.getDefault()))
    ForgeCard(Modifier.fillMaxWidth()) {
        foodMotifDrawable(meal.motif)?.let { res ->
            FoodMotifPicture(res, Modifier.fillMaxWidth().height(132.dp))
            Spacer(Modifier.height(ForgeMetrics.space3))
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(mealName(meal.kind), style = Forge.type.headline, color = Forge.colors.text)
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(time, style = Forge.type.footnote, color = Forge.colors.textSecondary, modifier = Modifier.weight(1f))
            Text(stringResource(R.string.forge_ed_kcal, kcalText(meal.totals["energy_kcal"])), style = Forge.type.body, color = Forge.colors.textSecondary)
            Box {
                TextButton(onClick = { menu = true }) { Text("···", color = Forge.colors.textSecondary) }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.food_copy_tomorrow)) }, onClick = { menu = false; onCopyTomorrow() })
                    DropdownMenuItem(text = { Text(stringResource(R.string.food_delete_meal)) }, onClick = { menu = false; onDelete() })
                }
            }
        }
        meal.entries.forEach { entry ->
            Row(Modifier.fillMaxWidth().clickable(role = Role.Button) { onEdit(entry) }.padding(vertical = ForgeMetrics.space2),
                verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    // A database name like "Vollmilch frisch, 3,5 % Fett" reads as its first part; the rest goes below.
                    val rest = entry.name.substringAfter(", ", "").ifEmpty { null }
                    Text(entry.name.substringBefore(", "), style = Forge.type.body, color = Forge.colors.text, maxLines = 2)
                    val detail = listOfNotNull(rest, entry.portionLabel ?: entry.grams?.let { "${gramsText(it)} g" }, entry.brand)
                    if (detail.isNotEmpty()) Text(detail.joinToString(" · "), style = Forge.type.footnote, color = Forge.colors.textSecondary,
                                                  maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                }
                Text(kcalText(entry.totals["energy_kcal"]), style = Forge.type.bodyNumber, color = Forge.colors.text)
            }
        }
    }
}

@Composable
private fun FoodEntryDialog(entry: CoreFood.Entry, onDismiss: () -> Unit, onSave: (Double?, String?, Boolean) -> Unit,
                            onDelete: () -> Unit) {
    var grams by remember { mutableStateOf(entry.grams?.let { gramsText(it) } ?: "") }
    var meal by remember { mutableStateOf(entry.meal) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(entry.name) }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2),
               modifier = Modifier.verticalScroll(rememberScrollState())) {
            if (entry.per100g != null) {
                OutlinedTextField(grams, { grams = it }, label = { Text(stringResource(R.string.food_grams)) },
                                  keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), singleLine = true)
            }
            MealChooser(meal) { meal = it }
            // Every nutrient this entry knows, for the amount typed above.
            val g = grams.replace(',', '.').toDoubleOrNull()
            val totals = entry.per100g?.takeIf { g != null }?.mapValues { it.value * g!! / 100.0 } ?: entry.totals
            Text(stringResource(R.string.food_nutrients), style = Forge.type.headline, color = Forge.colors.text)
            (listOf("energy_kcal", "protein_g", "carbs_g", "fat_g") + foodNutrientGroups.flatMap { it.second }).distinct()
                .filter { totals[it] != null }.forEach { key ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        NutrientBadge(key)
                        Spacer(Modifier.width(ForgeMetrics.space2))
                        Text(if (key == "energy_kcal") stringResource(R.string.food_energy) else nutrientName(key),
                             style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
                        Text(nutrientAmount(totals.getValue(key), key), style = Forge.type.bodyNumber, color = Forge.colors.text)
                    }
                }
        }
    }, confirmButton = {
        TextButton(onClick = { onSave(grams.replace(',', '.').toDoubleOrNull()?.takeIf { it > 0 }, meal, meal != entry.meal) }) {
            Text(stringResource(R.string.food_save))
        }
    }, dismissButton = {
        TextButton(onClick = onDelete) { Text(stringResource(R.string.food_delete), color = Forge.colors.effort) }
    })
}

@Composable
internal fun MealChooser(meal: String?, onChange: (String?) -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        (listOf<String?>(null) + listOf("breakfast", "lunch", "dinner", "snack")).forEach { kind ->
            val selected = kind == meal
            Text(if (kind == null) stringResource(R.string.food_by_time) else mealName(kind), style = Forge.type.footnote,
                 color = Forge.colors.text,
                 modifier = Modifier.background(if (selected) Forge.colors.food.copy(alpha = 0.24f) else Forge.colors.inset, RoundedCornerShape(50))
                     .clickable(role = Role.Button) { onChange(kind) }.padding(horizontal = 12.dp, vertical = 7.dp))
        }
    }
}

// MARK: - Adding

/** The add page: search, the three lists, scanner, quick entry, the coach, and a cart checked before saving. */
@Composable
private fun ForgeFoodAddPage(day: LocalDate, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefs = remember { FoodDataPrefs(context) }
    var query by remember { mutableStateOf("") }
    var tab by remember { mutableIntStateOf(0) }
    var results by remember { mutableStateOf<List<CoreFood.Item>>(emptyList()) }
    var online by remember { mutableStateOf<List<CoreFood.Item>>(emptyList()) }
    var onlineFailed by remember { mutableStateOf(false) }
    var recents by remember { mutableStateOf<List<Pair<CoreFood.Item, Double?>>>(emptyList()) }
    var favourites by remember { mutableStateOf<List<CoreFood.Item>>(emptyList()) }
    var mine by remember { mutableStateOf<List<CoreFood.Item>>(emptyList()) }
    val cart = remember { mutableStateListOf<CoreFood.CartLine>() }
    var portionFor by remember { mutableStateOf<CoreFood.Item?>(null) }
    var quick by remember { mutableStateOf(false) }
    var scanning by remember { mutableStateOf(false) }
    var describing by remember { mutableStateOf(false) }
    var meal by remember { mutableStateOf<String?>(null) }
    var coachReads by remember { mutableStateOf(false) }
    var listRevision by remember { mutableIntStateOf(0) }

    LaunchedEffect(listRevision) {
        withContext(Dispatchers.IO) {
            recents = CoreFood.recents(); favourites = CoreFood.favourites(); mine = CoreFood.own()
            coachReads = CoreFood.coachReadsPhotos()
        }
    }
    LaunchedEffect(query) {
        delay(250)
        results = withContext(Dispatchers.IO) { if (query.isBlank()) emptyList() else CoreFood.search(query) }
        online = emptyList(); onlineFailed = false
        if (prefs.mode == FoodDataPrefs.ONLINE && query.trim().length >= 3) {
            delay(650)   // Open Food Facts allows about ten searches a minute: wait for a pause in typing.
            val found = withContext(Dispatchers.IO) { CoreFood.onlineSearch(query, prefs.countries, Locale.getDefault().language) }
            if (found == null) onlineFailed = true else online = found.filter { o -> results.none { it.id == o.id } }
        }
    }
    val atEpoch = remember(day) {
        if (day == LocalDate.now()) Instant.now().epochSecond
        else day.atTime(LocalTime.NOON).atZone(ZoneId.systemDefault()).toEpochSecond()
    }

    if (scanning) {
        BackHandler { scanning = false }
        ForgeFoodScanPage(onBack = { scanning = false }) { found -> scanning = false; portionFor = found; listRevision++ }
        return
    }
    portionFor?.let { item ->
        FoodPortionDialog(item, recents.firstOrNull { it.first.id == item.id }?.second, onDismiss = { portionFor = null }) { line ->
            cart.add(line); portionFor = null
        }
    }
    if (quick) {
        FoodQuickDialog(onDismiss = { quick = false }) { name, kcal, p, c, f ->
            scope.launch {
                withContext(Dispatchers.IO) { FoodHealthConnect.wrote(context, CoreFood.quick(name, kcal, p, c, f, atEpoch, meal)) }
                quick = false; onBack()
            }
        }
    }
    if (describing) {
        FoodDescribeDialog(coachReads, onDismiss = { describing = false }) { lines -> cart.addAll(lines); describing = false }
    }

    SettingsColumn {
        PageTitle(stringResource(R.string.food_add), onBack)
        OutlinedTextField(query, { query = it }, modifier = Modifier.fillMaxWidth(), singleLine = true,
                          placeholder = { Text(stringResource(R.string.food_search_hint)) })
        Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            AddAction(stringResource(R.string.food_scan), Icons.Rounded.QrCodeScanner, Modifier.weight(1f)) { scanning = true }
            AddAction(stringResource(R.string.food_calories), Icons.Rounded.Numbers, Modifier.weight(1f)) { quick = true }
            if (com.noop.ui.NoopPrefs.coachEnabled(context)) {
                AddAction(stringResource(R.string.food_describe), Icons.Rounded.TextSnippet, Modifier.weight(1f)) { describing = true }
            }
        }
        if (prefs.mode == FoodDataPrefs.NONE && query.isEmpty()) {
            Text(stringResource(R.string.food_branded_hint), style = Forge.type.footnote, color = Forge.sceneInk.secondary)
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            if (query.isBlank()) {
                Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                    listOf(R.string.food_recent, R.string.food_favourites, R.string.food_mine).forEachIndexed { index, label ->
                        Text(stringResource(label), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold),
                             color = if (tab == index) Forge.colors.text else Forge.colors.textSecondary,
                             modifier = Modifier.background(if (tab == index) Forge.colors.inset else Forge.colors.surface, RoundedCornerShape(50))
                                 .clickable(role = Role.Tab) { tab = index }.padding(horizontal = 12.dp, vertical = 7.dp))
                    }
                }
                val list = when (tab) { 0 -> recents.map { it.first }; 1 -> favourites; else -> mine }
                if (list.isEmpty()) Text(stringResource(when (tab) { 0 -> R.string.food_recent_empty; 1 -> R.string.food_favourites_empty; else -> R.string.food_mine_empty }),
                                         style = Forge.type.footnote, color = Forge.colors.textSecondary)
                list.forEach { item -> ItemRow(item, onAdd = { portionFor = item }, onFavourite = { on ->
                    scope.launch { withContext(Dispatchers.IO) { CoreFood.setFavourite(item, on) }; listRevision++ }
                }) }
            } else {
                if (results.isEmpty() && online.isEmpty()) Text(stringResource(R.string.food_nothing_found), style = Forge.type.footnote, color = Forge.colors.textSecondary)
                results.forEach { item -> ItemRow(item, onAdd = { portionFor = item }, onFavourite = { on ->
                    scope.launch { withContext(Dispatchers.IO) { CoreFood.setFavourite(item, on) } }
                }) }
                if (prefs.mode == FoodDataPrefs.ONLINE) {
                    Text(stringResource(R.string.food_off_name), style = Forge.type.overline, color = Forge.colors.textSecondary)
                    if (onlineFailed) Text(stringResource(R.string.food_online_failed), style = Forge.type.footnote, color = Forge.colors.textSecondary)
                    online.forEach { item -> ItemRow(item, onAdd = { portionFor = item }, onFavourite = {}) }
                }
            }
        }
        if (cart.isNotEmpty()) {
            ForgeCard(Modifier.fillMaxWidth()) {
                cart.toList().forEach { line ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.food_item_grams, line.item.name, gramsText(line.grams)), style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
                        IconButton(onClick = { cart.remove(line) }) { Icon(Icons.Rounded.Close, stringResource(R.string.food_remove)) }
                    }
                }
                MealChooser(meal) { meal = it }
                val kcal = cart.sumOf { it.item.scaled(it.grams)["energy_kcal"] ?: 0.0 }
                TextButton(onClick = {
                    scope.launch {
                        withContext(Dispatchers.IO) {
                            // An online result is kept as the wearer's own food, so it is there offline next time.
                            var lines = cart.map { line -> if (line.item.source == "online") CoreFood.saveOwn(line.item, "online")?.let { line.copy(item = it) } ?: line else line }
                            // Missing vitamins and minerals from the closest BLS food, only when the wearer chose it.
                            if (prefs.estimateMissing && com.noop.ui.NoopPrefs.coachEnabled(context)) {
                                CoreFood.coachEnrich(lines.map { it.item })?.let { filled -> lines = lines.zip(filled) { l, i -> l.copy(item = i) } }
                            }
                            FoodHealthConnect.wrote(context, CoreFood.logCart(lines, atEpoch, meal))
                        }
                        onBack()
                    }
                }, modifier = Modifier.fillMaxWidth().background(Forge.colors.accent, RoundedCornerShape(50))) {
                    Text(stringResource(R.string.food_add_cart, cart.size, kcalText(kcal)), style = Forge.type.headline, color = Forge.colors.onDark)
                }
            }
        }
    }
}

@Composable
private fun AddAction(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, modifier: Modifier, onClick: () -> Unit) {
    Column(modifier.background(Forge.colors.inset, RoundedCornerShape(16.dp)).clickable(role = Role.Button, onClick = onClick)
        .heightIn(min = 64.dp).padding(ForgeMetrics.space2), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center) {
        Icon(icon, null, tint = Forge.colors.food)
        Text(title, style = Forge.type.footnote, color = Forge.colors.text)
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun ItemRow(item: CoreFood.Item, onAdd: () -> Unit, onFavourite: (Boolean) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.fillMaxWidth().combinedClickable(onClick = onAdd, onLongClick = { menu = true })
            .padding(vertical = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(item.name, style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text, maxLines = 2)
                val source = when (item.source) { "bls" -> "BLS"; "off", "online" -> "Open Food Facts"; "recipe" -> stringResource(R.string.food_recipe); else -> stringResource(R.string.food_yours) }
                Text(listOfNotNull(item.brand, stringResource(R.string.food_kcal_per_100g, kcalText(item.per100g["energy_kcal"])), source).joinToString(" · "),
                     style = Forge.type.footnote, color = Forge.colors.textSecondary, maxLines = 1)
            }
            Icon(Icons.Rounded.AddCircle, stringResource(R.string.food_add), tint = Forge.colors.food)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text(stringResource(R.string.food_favourite_add)) }, onClick = { menu = false; onFavourite(true) })
            DropdownMenuItem(text = { Text(stringResource(R.string.food_favourite_remove)) }, onClick = { menu = false; onFavourite(false) })
        }
    }
}

@Composable
private fun FoodPortionDialog(item: CoreFood.Item, lastGrams: Double?, onDismiss: () -> Unit, onAdd: (CoreFood.CartLine) -> Unit) {
    var text by remember { mutableStateOf(gramsText(lastGrams ?: item.servingG ?: 100.0)) }
    val grams = text.replace(',', '.').toDoubleOrNull() ?: 0.0
    AlertDialog(onDismissRequest = onDismiss, title = { Text(item.name) }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            OutlinedTextField(text, { text = it }, label = { Text(stringResource(R.string.food_grams)) }, singleLine = true,
                              keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                val chips = listOfNotNull(item.servingG?.let { (item.servingLabel ?: "${gramsText(it)} g") to it },
                                          lastGrams?.let { "${gramsText(it)} g" to it }, "100 g" to 100.0, "50 g" to 50.0)
                chips.forEach { (label, value) ->
                    Text(label, style = Forge.type.footnote, color = Forge.colors.text,
                         modifier = Modifier.background(Forge.colors.inset, RoundedCornerShape(50)).clickable { text = gramsText(value) }
                             .padding(horizontal = 12.dp, vertical = 7.dp))
                }
            }
            val totals = item.scaled(grams)
            Text(stringResource(R.string.food_kcal_protein, kcalText(totals["energy_kcal"]), gramsText(totals["protein_g"]), stringResource(R.string.food_protein)),
                 style = Forge.type.body, color = Forge.colors.textSecondary)
            if (item.estimatedFrom != null) Text(
                if (item.estimatedFrom == "ai") stringResource(R.string.food_estimated_ai_note, item.estimatedCount)
                else stringResource(R.string.food_estimated_note, item.estimatedCount, item.estimatedFrom),
                style = Forge.type.caption, color = Forge.colors.textSecondary)
            Text(stringResource(if (item.source == "bls") R.string.food_source_bls else R.string.food_source_off),
                 style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
    }, confirmButton = {
        TextButton(enabled = grams > 0 && grams <= 10_000, onClick = {
            val label = item.servingG?.takeIf { abs(it - grams) < 0.01 }?.let { item.servingLabel }
            onAdd(CoreFood.CartLine(item, grams, label))
        }) { Text(stringResource(R.string.food_add)) }
    }, dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.food_cancel)) } })
}

@Composable
private fun FoodQuickDialog(onDismiss: () -> Unit, onSave: (String, Double, Double?, Double?, Double?) -> Unit) {
    var name by remember { mutableStateOf("") }
    var kcal by remember { mutableStateOf("") }
    var protein by remember { mutableStateOf("") }
    var carbs by remember { mutableStateOf("") }
    var fat by remember { mutableStateOf("") }
    fun num(s: String) = s.replace(',', '.').toDoubleOrNull()
    val defaultName = stringResource(R.string.food_quick_entry)
    AlertDialog(onDismissRequest = onDismiss, title = { Text(stringResource(R.string.food_calories)) }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            OutlinedTextField(name, { name = it }, label = { Text(stringResource(R.string.food_what_was_it)) }, singleLine = true)
            OutlinedTextField(kcal, { kcal = it }, label = { Text("kcal") }, singleLine = true,
                              keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            OutlinedTextField(protein, { protein = it }, label = { Text(stringResource(R.string.food_protein_g)) }, singleLine = true,
                              keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
            OutlinedTextField(carbs, { carbs = it }, label = { Text(stringResource(R.string.food_carbs_g)) }, singleLine = true,
                              keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
            OutlinedTextField(fat, { fat = it }, label = { Text(stringResource(R.string.food_fat_g)) }, singleLine = true,
                              keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
        }
    }, confirmButton = {
        TextButton(enabled = (num(kcal) ?: -1.0) in 0.0..19_999.0, onClick = {
            onSave(name.ifBlank { defaultName }, num(kcal) ?: 0.0, num(protein), num(carbs), num(fat))
        }) { Text(stringResource(R.string.food_save)) }
    }, dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.food_cancel)) } })
}

@Composable
private fun FoodDescribeDialog(readsPhotos: Boolean, onDismiss: () -> Unit, onAdd: (List<CoreFood.CartLine>) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("") }
    var photo by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var lines by remember { mutableStateOf<List<CoreFood.CartLine>>(emptyList()) }
    var unmatched by remember { mutableStateOf<List<String>>(emptyList()) }
    val picker = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) scope.launch { photo = withContext(Dispatchers.IO) { foodPhotoBase64(context, uri) } }
    }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(stringResource(R.string.food_describe_title)) }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2), modifier = Modifier.verticalScrollIfNeeded()) {
            OutlinedTextField(text, { text = it }, placeholder = { Text(stringResource(R.string.food_describe_hint)) })
            if (readsPhotos) {
                TextButton(onClick = { picker.launch(androidx.activity.result.PickVisualMediaRequest(
                    androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageOnly)) }) {
                    Text(stringResource(if (photo == null) R.string.food_add_photo else R.string.food_photo_added))
                }
            }
            TextButton(enabled = !working && (text.isNotBlank() || photo != null), onClick = {
                working = true; failed = false
                scope.launch {
                    val result = withContext(Dispatchers.IO) { CoreFood.coachCart(text, photo) }
                    working = false
                    if (result == null) failed = true else { lines = result.first; unmatched = result.second }
                }
            }) { Text(stringResource(if (working) R.string.food_working else R.string.food_find_foods)) }
            Text(stringResource(R.string.food_describe_note), style = Forge.type.caption, color = Forge.colors.textSecondary)
            if (failed) Text(stringResource(R.string.food_coach_failed), style = Forge.type.footnote, color = Forge.colors.textSecondary)
            lines.forEach { line ->
                Text(stringResource(R.string.food_item_grams_kcal, line.item.name, gramsText(line.grams), kcalText(line.item.scaled(line.grams)["energy_kcal"])),
                     style = Forge.type.body, color = Forge.colors.text)
            }
            if (unmatched.isNotEmpty()) Text(stringResource(R.string.food_not_found_list, unmatched.joinToString(", ")),
                                             style = Forge.type.footnote, color = Forge.colors.textSecondary)
        }
    }, confirmButton = {
        TextButton(enabled = lines.isNotEmpty(), onClick = { onAdd(lines) }) { Text(stringResource(R.string.food_add)) }
    }, dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.food_cancel)) } })
}

private fun Modifier.verticalScrollIfNeeded(): Modifier = this

/** A picked photo as base64 JPEG, longest side 1,280 px, for the coach's provider. */
internal fun foodPhotoBase64(context: android.content.Context, uri: android.net.Uri): String? = runCatching {
    val source = context.contentResolver.openInputStream(uri)?.use { android.graphics.BitmapFactory.decodeStream(it) } ?: return null
    val scale = min(1.0, 1_280.0 / max(source.width, source.height))
    val bitmap = android.graphics.Bitmap.createScaledBitmap(source, (source.width * scale).toInt(), (source.height * scale).toInt(), true)
    val out = java.io.ByteArrayOutputStream()
    bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 70, out)
    android.util.Base64.encodeToString(out.toByteArray(), android.util.Base64.NO_WRAP)
}.getOrNull()

// MARK: - Product data

/** The wearer's product-data choice, under the same keys as iOS `FoodProductDataPrefs`. */
internal class FoodDataPrefs(context: android.content.Context) {
    private val prefs = com.noop.ui.NoopPrefs.of(context)
    var mode: String
        get() = prefs.getString("food.productData.mode", NONE) ?: NONE
        set(value) { prefs.edit().putString("food.productData.mode", value).apply() }
    var countries: List<String>
        get() = (prefs.getString("food.productData.countries", "") ?: "").split(',').filter { it.isNotBlank() }
            .ifEmpty { listOf(countryTag(Locale.getDefault().country) ?: "germany") }
        set(value) { prefs.edit().putString("food.productData.countries", value.sorted().joinToString(",")).apply() }
    var unknownBarcodesOnline: Boolean
        get() = prefs.getBoolean("food.productData.unknownBarcodesOnline", false)
        set(value) { prefs.edit().putBoolean("food.productData.unknownBarcodesOnline", value).apply() }
    var estimateMissing: Boolean
        get() = prefs.getBoolean("food.estimateMissing", false)
        set(value) { prefs.edit().putBoolean("food.estimateMissing", value).apply() }
    var writeHealth: Boolean
        get() = prefs.getBoolean(FoodHealthConnect.PREF_WRITE, true)
        set(value) { prefs.edit().putBoolean(FoodHealthConnect.PREF_WRITE, value).apply() }

    companion object {
        const val NONE = "none"; const val ONLINE = "online"; const val PACKS = "packs"
        /** Region -> Open Food Facts tag for the common countries (the full table is `FoodCountries` in the core). */
        fun countryTag(region: String): String? = mapOf(
            "DE" to "germany", "AT" to "austria", "CH" to "switzerland", "FR" to "france", "IT" to "italy", "ES" to "spain",
            "NL" to "netherlands", "BE" to "belgium", "GB" to "united-kingdom", "US" to "united-states", "PL" to "poland",
            "PT" to "portugal", "RU" to "russia", "CN" to "china").get(region.uppercase())
        fun countryName(tag: String): String {
            val region = mapOf("germany" to "DE", "austria" to "AT", "switzerland" to "CH", "france" to "FR", "italy" to "IT",
                "spain" to "ES", "netherlands" to "NL", "belgium" to "BE", "united-kingdom" to "GB", "united-states" to "US",
                "poland" to "PL", "portugal" to "PT", "russia" to "RU", "china" to "CN")[tag]
            return region?.let { Locale("", it).getDisplayCountry(Locale.getDefault()) }
                ?: tag.split('-').joinToString(" ") { it.replaceFirstChar(Char::uppercase) }
        }
    }
}

/** One pack the release offers (`manifest.json` from `Tools/build_food_packs.py`). */
private data class OfferedPack(val country: String, val rows: Int, val file: String, val bytes: Long, val sha256: String)

private const val PACKS_BASE = "https://github.com/DX23876/noop/releases/download/food-packs/"

@Composable
private fun ForgeFoodDataPage(onBack: () -> Unit, onSetup: () -> Unit) {
    SettingsColumn {
        PageTitle(stringResource(R.string.food_data_title), onBack)
        FoodGoalsCard()
        FoodProductDataCards()
        FoodExtrasCards()
        SettingsCard(null, null) { LinkRow(stringResource(R.string.food_setup_again), null, onClick = onSetup) }
        SettingsCard(stringResource(R.string.food_sources), stringResource(R.string.food_sources_credits)) {}
    }
}

/** Where branded products come from, the countries and the packs: Food data and the first-visit setup share it. */
@Composable
internal fun FoodProductDataCards() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefs = remember { FoodDataPrefs(context) }
    var mode by remember { mutableStateOf(prefs.mode) }
    var installed by remember { mutableStateOf<List<CoreFood.Pack>>(emptyList()) }
    var offered by remember { mutableStateOf<List<OfferedPack>?>(null) }
    var manifestFailed by remember { mutableStateOf(false) }
    var downloading by remember { mutableStateOf<String?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }
    var countries by remember { mutableStateOf(prefs.countries) }
    var unknownOnline by remember { mutableStateOf(prefs.unknownBarcodesOnline) }
    val failedText = stringResource(R.string.food_download_failed)
    val spaceText = stringResource(R.string.food_no_space)

    LaunchedEffect(mode) {
        installed = withContext(Dispatchers.IO) { CoreFood.packs() }
        if (mode != FoodDataPrefs.NONE && offered == null) {
            offered = withContext(Dispatchers.IO) { fetchManifest() }
            manifestFailed = offered == null
        }
    }
    fun download(pack: OfferedPack) {
        downloading = pack.country; failure = null
        scope.launch {
            val error = withContext(Dispatchers.IO) { downloadPack(context, pack) }
            downloading = null
            failure = when (error) { null -> null; "notEnoughSpace" -> spaceText; else -> failedText }
            installed = withContext(Dispatchers.IO) { CoreFood.packs() }
        }
    }

    SettingsCard(stringResource(R.string.food_branded), stringResource(when (mode) {
        FoodDataPrefs.ONLINE -> R.string.food_mode_online_note; FoodDataPrefs.PACKS -> R.string.food_mode_packs_note
        else -> R.string.food_mode_none_note })) {
        listOf(FoodDataPrefs.NONE to R.string.food_mode_none, FoodDataPrefs.ONLINE to R.string.food_mode_online,
               FoodDataPrefs.PACKS to R.string.food_mode_packs).forEach { (value, label) ->
            Row(Modifier.fillMaxWidth().clickable(role = Role.RadioButton) { mode = value; prefs.mode = value }
                .padding(vertical = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
                androidx.compose.material3.RadioButton(selected = mode == value, onClick = { mode = value; prefs.mode = value })
                Text(stringResource(label), style = Forge.type.body, color = Forge.colors.text)
            }
        }
    }
    if (mode == FoodDataPrefs.ONLINE) {
        SettingsCard(stringResource(R.string.food_countries), null) {
            (offered?.map { it.country } ?: listOf("germany", "austria", "switzerland", "france", "united-kingdom", "united-states"))
                .sortedBy { FoodDataPrefs.countryName(it) }.forEach { tag ->
                    Row(Modifier.fillMaxWidth().clickable {
                        countries = if (tag in countries) countries - tag else if (countries.size < 3) countries + tag else countries
                        prefs.countries = countries
                    }.padding(vertical = ForgeMetrics.space2)) {
                        Text(FoodDataPrefs.countryName(tag), style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
                        if (tag in countries) Text("✓", color = Forge.colors.accent)
                    }
                }
        }
    }
    if (mode == FoodDataPrefs.PACKS) {
        SettingsCard(stringResource(R.string.food_on_phone), if (installed.isEmpty()) stringResource(R.string.food_no_pack) else null) {
            installed.forEach { pack ->
                Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(FoodDataPrefs.countryName(pack.country), style = Forge.type.body, color = Forge.colors.text)
                        Text(stringResource(R.string.food_products, NumberFormat.getIntegerInstance().format(pack.rows)),
                             style = Forge.type.footnote, color = Forge.colors.textSecondary)
                    }
                    offered?.firstOrNull { it.country == pack.country && it.sha256 != pack.sha256 }?.let { update ->
                        TextButton(enabled = downloading == null, onClick = { download(update) }) { Text(stringResource(R.string.food_update)) }
                    }
                    TextButton(onClick = { scope.launch { withContext(Dispatchers.IO) { CoreFood.removePack(pack.country) }; installed = withContext(Dispatchers.IO) { CoreFood.packs() } } }) {
                        Text(stringResource(R.string.food_delete), color = Forge.colors.effort)
                    }
                }
            }
        }
        SettingsCard(stringResource(R.string.food_download), stringResource(R.string.food_download_note)) {
            if (manifestFailed) Text(stringResource(R.string.food_manifest_failed), style = Forge.type.footnote, color = Forge.colors.textSecondary)
            offered.orEmpty().filter { o -> installed.none { it.country == o.country } }.forEach { pack ->
                LinkRow(FoodDataPrefs.countryName(pack.country),
                        stringResource(R.string.food_products, NumberFormat.getIntegerInstance().format(pack.rows)) +
                            " · " + android.text.format.Formatter.formatShortFileSize(context, pack.bytes),
                        busy = downloading == pack.country) { if (downloading == null) download(pack) }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.food_unknown_online), style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
                Switch(unknownOnline, { unknownOnline = it; prefs.unknownBarcodesOnline = it })
            }
        }
    }
    failure?.let { Text(it, style = Forge.type.body, color = Forge.colors.effort) }
}

/** Apple Health's twin (Health Connect), filling missing nutrients and the Lab score, as Food data and the setup show them. */
@Composable
internal fun FoodExtrasCards() {
    val context = LocalContext.current
    val prefs = remember { FoodDataPrefs(context) }
    var writeHealth by remember { mutableStateOf(prefs.writeHealth) }
    var estimateMissing by remember { mutableStateOf(prefs.estimateMissing) }
    val permissions = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.health.connect.client.PermissionController.createRequestPermissionResultContract()) { }
    if (com.noop.ui.NoopPrefs.coachEnabled(context)) {
        SettingsCard(stringResource(R.string.food_estimate_title), stringResource(R.string.food_estimate_note)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.food_estimate_toggle), style = Forge.type.body, color = Forge.colors.text)
                    Text(stringResource(R.string.food_recommended), style = Forge.type.caption, color = Forge.colors.accent)
                }
                Switch(estimateMissing, { estimateMissing = it; prefs.estimateMissing = it })
            }
        }
    }
    SettingsCard(stringResource(R.string.food_health_connect), stringResource(R.string.food_health_connect_note)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.food_write_health), style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
            Switch(writeHealth, { writeHealth = it; prefs.writeHealth = it })
        }
        LinkRow(stringResource(R.string.food_allow_health), null) { permissions.launch(FoodHealthConnect.READ + FoodHealthConnect.WRITE) }
    }
    var showScore by remember { mutableStateOf(foodScoreEnabled(context)) }
    SettingsCard(stringResource(R.string.food_lab), stringResource(R.string.food_score_note)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.food_score_title), style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
            Switch(showScore, { showScore = it; com.noop.ui.NoopPrefs.of(context).edit().putBoolean(FOOD_SCORE_KEY, it).apply() })
        }
    }
}

private fun fetchManifest(): List<OfferedPack>? = runCatching {
    val request = okhttp3.Request.Builder().url(PACKS_BASE + "manifest.json")
        .header("User-Agent", "NOOP-Forge/1 (offline-first health app; food search)").build()
    okhttp3.OkHttpClient().newCall(request).execute().use { response ->
        if (!response.isSuccessful) return null
        val json = org.json.JSONObject(response.body?.string() ?: return null)
        if (json.optInt("tableFormat") != 1) return emptyList()
        val packs = json.optJSONArray("packs") ?: return emptyList()
        (0 until packs.length()).mapNotNull { packs.optJSONObject(it) }.map {
            OfferedPack(it.optString("country"), it.optInt("rows"), it.optString("file"), it.optLong("bytes"), it.optString("sha256"))
        }.sortedByDescending { it.rows }
    }
}.getOrNull()

/** Downloads a pack to the cache and hands it to the core, which checks the hash before using it. */
private fun downloadPack(context: android.content.Context, pack: OfferedPack): String? {
    val target = java.io.File(context.cacheDir, "food-pack-${pack.country}.zip")
    return try {
        val request = okhttp3.Request.Builder().url(PACKS_BASE + pack.file)
            .header("User-Agent", "NOOP-Forge/1 (offline-first health app; food search)").build()
        okhttp3.OkHttpClient.Builder().readTimeout(120, java.util.concurrent.TimeUnit.SECONDS).build()
            .newCall(request).execute().use { response ->
                if (!response.isSuccessful) return "download"
                response.body?.byteStream()?.use { input -> target.outputStream().use { input.copyTo(it) } } ?: return "download"
            }
        CoreFood.installPack(target.absolutePath, pack.sha256)
    } catch (e: Exception) {
        "download"
    } finally {
        target.delete()
    }
}

/** The calorie goal (the energy plan's, or a fixed number) and its split, as iOS `FoodGoalsSection`, same keys. */
@Composable
private fun FoodGoalsCard() {
    val context = LocalContext.current
    val prefs = remember { com.noop.ui.NoopPrefs.of(context) }
    var fixed by remember { mutableStateOf(prefs.getFloat("food.goal.kcal", 0f).toDouble()) }
    var protein by remember { mutableStateOf(prefs.getFloat("food.goal.proteinPercent", 25f).toDouble()) }
    var carbs by remember { mutableStateOf(prefs.getFloat("food.goal.carbsPercent", 45f).toDouble()) }
    var fat by remember { mutableStateOf(prefs.getFloat("food.goal.fatPercent", 30f).toDouble()) }
    fun save() {
        prefs.edit().putFloat("food.goal.kcal", fixed.toFloat()).putFloat("food.goal.proteinPercent", protein.toFloat())
            .putFloat("food.goal.carbsPercent", carbs.toFloat()).putFloat("food.goal.fatPercent", fat.toFloat()).apply()
    }
    val total = (protein + carbs + fat).roundToInt()
    SettingsCard(stringResource(R.string.food_goals), stringResource(if (fixed > 0) R.string.food_goal_fixed_note else R.string.food_goal_plan_note) +
        if (total != 100) " " + stringResource(R.string.food_goal_scaled, total) else "") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.food_goal_fixed), style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
            Switch(fixed > 0, { on -> fixed = if (on) maxOf(fixed, 2_000.0) else 0.0; save() })
        }
        if (fixed > 0) GoalStepper(stringResource(R.string.food_goal_kcal), "${kcalText(fixed)} kcal",
                                   { fixed = maxOf(1_200.0, fixed - 50); save() }, { fixed = minOf(6_000.0, fixed + 50); save() })
        GoalStepper(stringResource(R.string.food_protein), "${protein.roundToInt()} %", { protein = maxOf(10.0, protein - 5); save() }, { protein = minOf(40.0, protein + 5); save() })
        GoalStepper(stringResource(R.string.food_carbs), "${carbs.roundToInt()} %", { carbs = maxOf(20.0, carbs - 5); save() }, { carbs = minOf(65.0, carbs + 5); save() })
        GoalStepper(stringResource(R.string.food_fat), "${fat.roundToInt()} %", { fat = maxOf(15.0, fat - 5); save() }, { fat = minOf(45.0, fat + 5); save() })
    }
}

@Composable
private fun GoalStepper(title: String, value: String, minus: () -> Unit, plus: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
        TextButton(onClick = minus) { Text("−", style = Forge.type.headline, color = Forge.colors.accent) }
        Text(value, style = Forge.type.bodyNumber, color = Forge.colors.text)
        TextButton(onClick = plus) { Text("+", style = Forge.type.headline, color = Forge.colors.accent) }
    }
}
