package com.noop.ui.forge

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreFood
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate

/** Set once the first-visit setup has been closed, by Done, Later or Back. Same key as iOS `FoodProductDataPrefs.setupDoneKey`. */
private const val FOOD_SETUP_DONE_KEY = "food.setup.done"

/**
 * Whether the food log should open its setup: never closed yet, and no product source picked in Food data, so a
 * wearer who already chose there is not asked again (iOS `FoodProductDataPrefs.setupNeeded`).
 */
internal fun foodSetupNeeded(context: android.content.Context): Boolean =
    !com.noop.ui.NoopPrefs.of(context).getBoolean(FOOD_SETUP_DONE_KEY, false) && FoodDataPrefs(context).mode == FoodDataPrefs.NONE

internal fun markFoodSetupDone(context: android.content.Context) {
    com.noop.ui.NoopPrefs.of(context).edit().putBoolean(FOOD_SETUP_DONE_KEY, true).apply()
}

/**
 * A request to open the food log with its add page (iOS `ForgeRoute.foodAdd`): set by Today's Log sheet and the
 * Health & body card just before they push the Food destination, taken once by the page.
 */
internal object FoodArrival {
    @Volatile private var pending = false
    fun requestAdd() { pending = true }
    fun consume(): Boolean = pending.also { pending = false }
}

/**
 * Fork (DX23876), owner 2026-11-09: the food log's first-visit setup after iOS `FoodSetupSheet`. Step one is where
 * branded products come from, step two the extras; both reuse Food data's own cards, so the two places write the
 * same keys and say the same words.
 */
@Composable
internal fun ForgeFoodSetupPage(onDone: () -> Unit) {
    var step by remember { mutableStateOf(0) }
    SettingsColumn {
        PageTitle(stringResource(R.string.food_setup_title), onBack = { if (step == 0) onDone() else step = 0 }) {
            if (step == 0) TextButton(onClick = onDone) { Text(stringResource(R.string.food_setup_later), color = Forge.colors.accent) }
        }
        if (step == 0) {
            SetupHeader(R.drawable.food_hero, stringResource(R.string.food_setup_products_title), stringResource(R.string.food_setup_products_body))
            FoodProductDataCards()
        } else {
            SetupHeader(R.drawable.food_score_hero, stringResource(R.string.food_setup_extras_title), stringResource(R.string.food_setup_extras_body))
            FoodExtrasCards()
        }
        Button(onClick = { if (step == 0) step = 1 else onDone() }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
               colors = ButtonDefaults.buttonColors(containerColor = Forge.colors.accent)) {
            Text(stringResource(if (step == 0) R.string.food_setup_continue else R.string.food_setup_done))
        }
        Spacer(Modifier.height(ForgeMetrics.space5))
    }
}

/** A setup step's picture, title and one sentence (iOS `FoodSetupHeader`). */
@Composable
private fun SetupHeader(image: Int, title: String, body: String) {
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        Image(painterResource(image), null, contentScale = ContentScale.Crop,
              modifier = Modifier.fillMaxWidth().height(150.dp).clip(RoundedCornerShape(ForgeMetrics.cardRadius)))
        Text(title, style = Forge.type.title2, color = Forge.colors.text)
        Text(body, style = Forge.type.body, color = Forge.colors.textSecondary)
    }
}

/**
 * The Health & body page's way into the food log, after iOS `FoodHealthCard`: what today holds so far, the Food
 * page's picture and a button straight to adding. It reads only today's log, never the goal, so it states nothing
 * the Food page could state differently.
 */
@Composable
internal fun FoodTodayCard(onOpen: () -> Unit, onAdd: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    var summary by remember { mutableStateOf<CoreFood.Day?>(null) }
    LaunchedEffect(Unit) {
        summary = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreFood.prepare()
            CoreFood.day(LocalDate.now().toString())
        }
    }
    val totals = summary?.totals.orEmpty()
    val logged = summary?.meals?.isNotEmpty() == true
    ForgeCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            Row(Modifier.fillMaxWidth().clickable(onClick = onOpen), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.food_title), style = Forge.type.headline, color = colors.text)
                        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
                    }
                    Text(if (logged) stringResource(R.string.food_card_kcal_today, kcalText(totals["energy_kcal"]))
                         else stringResource(R.string.food_card_nothing), style = Forge.type.title2, color = colors.text)
                    Text(if (logged) stringResource(R.string.food_card_macros, gramsText(totals["protein_g"] ?: 0.0),
                                                    gramsText(totals["carbs_g"] ?: 0.0), gramsText(totals["fat_g"] ?: 0.0))
                         else stringResource(R.string.food_card_empty_detail), style = Forge.type.caption, color = colors.textSecondary)
                }
                Spacer(Modifier.width(ForgeMetrics.space3))
                Image(painterResource(R.drawable.food_hero), null, contentScale = ContentScale.Crop, alignment = Alignment.CenterEnd,
                      modifier = Modifier.size(76.dp).clip(RoundedCornerShape(12.dp)))
            }
            Row(Modifier.fillMaxWidth().heightIn(min = 40.dp).clip(RoundedCornerShape(50))
                    .background(colors.inset).clickable(onClick = onAdd).padding(vertical = ForgeMetrics.space2),
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.AddCircle, null, tint = colors.food, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text(stringResource(R.string.food_log_food), style = Forge.type.subhead, color = colors.text)
            }
        }
    }
}
