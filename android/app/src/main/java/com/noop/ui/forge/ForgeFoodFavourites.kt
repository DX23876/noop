package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.LibraryAdd
import androidx.compose.material.icons.rounded.Restaurant
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreFood
import com.noop.core.CoreFoodNotes
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Fork (DX23876), owner 2026-11-21: favourites, kept meals and the meal builder on Android, as iOS's
 * `FoodItemRow`, `FoodSavedMealRow`, `FoodFavouritesBar` and `FoodMealEditor`. A kept meal stays its foods: logging
 * it adds one entry per food, so nutrients and the note count each food as itself.
 */

/** The small square picture of a food or meal: the still life of its group, or a quiet plate without one. */
@Composable
internal fun FoodThumb(motif: String?, size: Dp = 44.dp) {
    val res = foodMotifDrawable(motif)
    Box(Modifier.size(size).clip(RoundedCornerShape(10.dp)).background(Forge.colors.inset), contentAlignment = Alignment.Center) {
        if (res != null) {
            Image(painterResource(res), contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.size(size))
        } else {
            Icon(Icons.Rounded.Restaurant, null, tint = Forge.colors.textSecondary)
        }
    }
}

/** A small pill button: an amount or energy and a plus, one tap to add. */
@Composable
private fun AddPill(text: String, description: String, onClick: () -> Unit) {
    Row(Modifier.heightIn(min = 44.dp).clip(RoundedCornerShape(50)).clickable(role = Role.Button, onClickLabel = description, onClick = onClick),
        verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.background(Forge.colors.inset, RoundedCornerShape(50)).padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(text, style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.food)
            Icon(Icons.Rounded.Add, null, tint = Forge.colors.food, modifier = Modifier.size(16.dp))
        }
    }
}

/** One food to pick: its picture, name and energy, a visible star, and its last amount as a one-tap add. */
@Composable
internal fun FoodPickRow(item: CoreFood.Item, motif: String?, lastGrams: Double?, favourite: Boolean,
                         onPick: () -> Unit, onFavourite: (Boolean) -> Unit, onQuickAdd: ((Double) -> Unit)?) {
    Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space1), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        Row(Modifier.weight(1f).clickable(role = Role.Button, onClick = onPick), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            FoodThumb(motif)
            Column(Modifier.weight(1f)) {
                Text(item.name, style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text, maxLines = 2)
                val extra = when (item.source) { "recipe" -> stringResource(R.string.food_recipe); "own" -> stringResource(R.string.food_yours); else -> null }
                Text(listOfNotNull(item.brand, stringResource(R.string.food_kcal_per_100g, kcalText(item.per100g["energy_kcal"])), extra).joinToString(" · "),
                     style = Forge.type.footnote, color = Forge.colors.textSecondary, maxLines = 1)
            }
        }
        IconButton(onClick = { onFavourite(!favourite) }) {
            Icon(if (favourite) Icons.Rounded.Star else Icons.Rounded.StarBorder,
                 stringResource(if (favourite) R.string.food_favourite_remove else R.string.food_favourite_add),
                 tint = if (favourite) Forge.colors.fat else Forge.colors.textSecondary)
        }
        if (lastGrams != null && onQuickAdd != null) {
            AddPill(stringResource(R.string.food_grams_value, gramsText(lastGrams)),
                    stringResource(R.string.food_add_again, gramsText(lastGrams))) { onQuickAdd(lastGrams) }
        } else {
            IconButton(onClick = onPick) { Icon(Icons.Rounded.AddCircle, stringResource(R.string.food_add), tint = Forge.colors.food) }
        }
    }
}

/** A kept meal in the add page: tap the row to change it, the pill to log it again. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
internal fun SavedMealRow(meal: CoreFoodNotes.Meal, onLog: () -> Unit, onEdit: () -> Unit, onRemove: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space1), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Row(Modifier.weight(1f).combinedClickable(onClick = onEdit, onLongClick = { menu = true }),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                FoodThumb(meal.motif)
                Column(Modifier.weight(1f)) {
                    Text(meal.name, style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text, maxLines = 1)
                    Text(meal.foods, style = Forge.type.footnote, color = Forge.colors.textSecondary, maxLines = 1)
                }
            }
            AddPill(stringResource(R.string.food_kcal_value, kcalText(meal.kcal)), stringResource(R.string.food_log_again, meal.name), onLog)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text(stringResource(R.string.food_meal_edit)) }, onClick = { menu = false; onEdit() })
            DropdownMenuItem(text = { Text(stringResource(R.string.food_favourite_remove)) }, onClick = { menu = false; onRemove() })
        }
    }
}

/** The Food page's favourites: kept meals log in one tap, starred foods open their amount. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
internal fun FoodFavouritesBar(meals: List<CoreFoodNotes.Meal>, foods: List<CoreFood.Item>, motifs: Map<String, String>,
                               onLogMeal: (CoreFoodNotes.Meal) -> Unit, onPickFood: (CoreFood.Item) -> Unit,
                               onEditMeal: (CoreFoodNotes.Meal) -> Unit, onRemoveMeal: (CoreFoodNotes.Meal) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        meals.forEach { meal ->
            var menu by remember { mutableStateOf(false) }
            Box {
                FavouriteTile(meal.motif, meal.name, stringResource(R.string.food_kcal_value, kcalText(meal.kcal)),
                              Modifier.combinedClickable(onClick = { onLogMeal(meal) }, onLongClick = { menu = true }))
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.food_meal_edit)) }, onClick = { menu = false; onEditMeal(meal) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.food_favourite_remove)) }, onClick = { menu = false; onRemoveMeal(meal) })
                }
            }
        }
        foods.forEach { food ->
            FavouriteTile(motifs[food.id], food.name, stringResource(R.string.food_kcal_per_100g, kcalText(food.per100g["energy_kcal"])),
                          Modifier.clickable(role = Role.Button) { onPickFood(food) })
        }
    }
}

@Composable
private fun FavouriteTile(motif: String?, title: String, detail: String, modifier: Modifier) {
    Row(modifier.widthIn(max = 240.dp).background(Forge.colors.surface, RoundedCornerShape(ForgeMetrics.cardRadius))
            .padding(start = ForgeMetrics.space2, end = ForgeMetrics.space3, top = ForgeMetrics.space2, bottom = ForgeMetrics.space2),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        FoodThumb(motif, 40.dp)
        Column(Modifier.weight(1f, fill = false)) {
            Text(title, style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text, maxLines = 1)
            Text(detail, style = Forge.type.footnote, color = Forge.colors.textSecondary, maxLines = 1)
        }
        Icon(Icons.Rounded.Add, null, tint = Forge.colors.food, modifier = Modifier.size(16.dp))
    }
}

/**
 * The meal builder: a name (the meal of the hour to start with), the foods with their amounts, what they bring
 * together, and one save. [meal] null starts a new meal.
 */
@Composable
internal fun ForgeMealBuilderPage(meal: CoreFoodNotes.Meal?, defaultName: String, onBack: () -> Unit, onSaved: () -> Unit) {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(meal?.name ?: defaultName) }
    val items = remember { mutableStateListOf<CoreFoodNotes.MealItem>().apply { meal?.items?.let { addAll(it) } } }
    var picking by remember { mutableStateOf(false) }
    if (picking) {
        BackHandler { picking = false }
        ForgeFoodPickPage(onBack = { picking = false }) { line ->
            items.add(CoreFoodNotes.MealItem(line.item.id, line.item.name, line.grams, line.item.per100g)); picking = false
        }
        return
    }
    SettingsColumn {
        PageTitle(stringResource(if (meal == null) R.string.food_meal_new else R.string.food_meal_edit), onBack) {
            TextButton(enabled = name.isNotBlank() && items.any { it.grams > 0 }, onClick = {
                scope.launch {
                    val saved = withContext(Dispatchers.IO) { CoreFoodNotes.saveItems(meal?.id, name, items.toList(), meal?.createdAt) }
                    if (saved != null) onSaved()
                }
            }) { Text(stringResource(R.string.food_save), color = Forge.colors.accent) }
        }
        OutlinedTextField(name, { name = it }, modifier = Modifier.fillMaxWidth(), singleLine = true,
                          label = { Text(stringResource(R.string.food_name)) })
        FoodSectionHeader(stringResource(R.string.food_foods))
        ForgeCard(Modifier.fillMaxWidth()) {
            items.toList().forEachIndexed { index, item ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                    FoodThumb(null, 40.dp)
                    Column(Modifier.weight(1f)) {
                        Text(item.name, style = Forge.type.body, color = Forge.colors.text, maxLines = 2)
                        Text(stringResource(R.string.food_kcal_value, kcalText(item.kcal)), style = Forge.type.footnote, color = Forge.colors.textSecondary)
                    }
                    var typed by remember(item.name, index) { mutableStateOf("") }
                    OutlinedTextField(typed, { text ->
                        typed = text
                        text.replace(',', '.').toDoubleOrNull()?.takeIf { it > 0 }?.let { items[index] = item.copy(grams = it) }
                    }, modifier = Modifier.width(96.dp), singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                       placeholder = { Text(gramsText(item.grams)) }, suffix = { Text("g") })
                    IconButton(onClick = { items.removeAt(index) }) { Icon(Icons.Rounded.Close, stringResource(R.string.food_remove)) }
                }
            }
            TextButton(onClick = { picking = true }) {
                Icon(Icons.Rounded.AddCircle, null, tint = Forge.colors.food)
                Text(stringResource(R.string.food_add_a_food), color = Forge.colors.food)
            }
        }
        if (items.isNotEmpty()) {
            Text(stringResource(R.string.food_together, kcalText(items.sumOf { it.kcal }), gramsText(items.sumOf { it.proteinG })),
                 style = Forge.type.footnote, color = Forge.colors.textSecondary)
        }
        if (meal != null) {
            TextButton(onClick = {
                scope.launch { withContext(Dispatchers.IO) { CoreFoodNotes.delete(meal.id) }; onSaved() }
            }) {
                Icon(Icons.Rounded.Delete, null, tint = Forge.colors.food)
                Text(stringResource(R.string.food_delete_meal), color = Forge.colors.food)
            }
        }
    }
}

/** Picks one food for the builder: search, or the recent and starred foods, then its amount. */
@Composable
internal fun ForgeFoodPickPage(onBack: () -> Unit, onPick: (CoreFood.CartLine) -> Unit) {
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<CoreFood.Item>>(emptyList()) }
    var recents by remember { mutableStateOf<List<Pair<CoreFood.Item, Double?>>>(emptyList()) }
    var favourites by remember { mutableStateOf<List<CoreFood.Item>>(emptyList()) }
    var motifs by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var portionFor by remember { mutableStateOf<CoreFood.Item?>(null) }
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            recents = CoreFood.recents(); favourites = CoreFood.favourites()
            motifs = CoreFoodNotes.motifs(recents.map { it.first } + favourites)
        }
    }
    LaunchedEffect(query) {
        delay(250)
        results = withContext(Dispatchers.IO) { if (query.isBlank()) emptyList() else CoreFood.search(query) }
        motifs = motifs + withContext(Dispatchers.IO) { CoreFoodNotes.motifs(results) }
    }
    portionFor?.let { item ->
        FoodPortionDialog(item, recents.firstOrNull { it.first.id == item.id }?.second, onDismiss = { portionFor = null }) { line ->
            portionFor = null; onPick(line)
        }
    }
    val last = recents.associate { it.first.id to it.second }
    SettingsColumn {
        PageTitle(stringResource(R.string.food_add_a_food), onBack)
        OutlinedTextField(query, { query = it }, modifier = Modifier.fillMaxWidth(), singleLine = true,
                          placeholder = { Text(stringResource(R.string.food_search_hint)) })
        ForgeCard(Modifier.fillMaxWidth()) {
            val list = if (query.isBlank()) (favourites + recents.map { it.first }).distinctBy { it.id } else results
            list.forEach { item ->
                FoodPickRow(item, motifs[item.id], last[item.id], favourites.any { it.id == item.id },
                            onPick = { portionFor = item }, onFavourite = {}, onQuickAdd = { grams -> onPick(CoreFood.CartLine(item, grams)) })
            }
        }
    }
}

/** A meal kind's name outside composition, for a dialog's starting text. */
internal fun mealNameText(context: android.content.Context, kind: String): String = context.getString(when (kind) {
    "breakfast" -> R.string.food_meal_breakfast
    "lunch" -> R.string.food_meal_lunch
    "dinner" -> R.string.food_meal_dinner
    else -> R.string.food_meal_snack
})

/** The warning while logging; on unless turned off (iOS `FoodReminders.warnKey`, the same key). */
internal fun foodWarnOn(context: android.content.Context): Boolean =
    com.noop.ui.NoopPrefs.of(context).getBoolean("food.warn.enabled", true)
