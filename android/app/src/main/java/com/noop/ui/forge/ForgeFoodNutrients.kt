package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.rounded.Eco
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Grain
import androidx.compose.material.icons.rounded.InvertColors
import androidx.compose.material.icons.rounded.Opacity
import androidx.compose.material.icons.rounded.Phishing
import androidx.compose.material.icons.rounded.SetMeal
import androidx.compose.material.icons.rounded.ViewInAr
import androidx.compose.material.icons.rounded.WaterDrop
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.PushPin
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.HelpOutline
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreFood
import java.text.NumberFormat
import java.util.Locale
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Fork (DX23876), decision 2026-11-08: vitamins, minerals and fats over the last seven logged days against the EFSA
 * references, as iOS `ForgeFoodNutrientsView`. The report, references and coverage rule come from the core.
 */
internal val foodNutrientGroups: List<Pair<Int, List<String>>> = listOf(
    R.string.food_group_macros to listOf("protein_g", "fiber_g", "sugar_g", "sat_fat_g", "mono_fat_g", "poly_fat_g", "omega3_g", "epa_g", "cholesterol_mg"),
    R.string.food_group_minerals to listOf("salt_g", "sodium_mg", "potassium_mg", "calcium_mg", "magnesium_mg", "phosphorus_mg", "iron_mg",
                                           "zinc_mg", "iodine_ug", "copper_mg", "manganese_mg"),
    R.string.food_group_vitamins to listOf("vitamin_a_ug", "vitamin_d_ug", "vitamin_e_mg", "vitamin_k_ug", "thiamin_mg", "riboflavin_mg",
                                           "niacin_mg", "vitamin_b6_mg", "folate_ug", "vitamin_b12_ug", "vitamin_c_mg", "pantothenic_mg", "biotin_ug"),
)

@Composable
internal fun nutrientName(key: String): String = when (val id = nutrientNameRes(key)) { null -> key; else -> stringResource(id) }

private fun nutrientNameRes(key: String): Int? = when (key) {
    "protein_g" -> R.string.food_n_protein_g
    "fiber_g" -> R.string.food_n_fiber_g
    "sugar_g" -> R.string.food_n_sugar_g
    "sat_fat_g" -> R.string.food_n_sat_fat_g
    "mono_fat_g" -> R.string.food_n_mono_fat_g
    "poly_fat_g" -> R.string.food_n_poly_fat_g
    "omega3_g" -> R.string.food_n_omega3_g
    "epa_g" -> R.string.food_n_epa_g
    "cholesterol_mg" -> R.string.food_n_cholesterol_mg
    "salt_g" -> R.string.food_n_salt_g
    "sodium_mg" -> R.string.food_n_sodium_mg
    "potassium_mg" -> R.string.food_n_potassium_mg
    "calcium_mg" -> R.string.food_n_calcium_mg
    "magnesium_mg" -> R.string.food_n_magnesium_mg
    "phosphorus_mg" -> R.string.food_n_phosphorus_mg
    "iron_mg" -> R.string.food_n_iron_mg
    "zinc_mg" -> R.string.food_n_zinc_mg
    "iodine_ug" -> R.string.food_n_iodine_ug
    "copper_mg" -> R.string.food_n_copper_mg
    "manganese_mg" -> R.string.food_n_manganese_mg
    "vitamin_a_ug" -> R.string.food_n_vitamin_a_ug
    "vitamin_d_ug" -> R.string.food_n_vitamin_d_ug
    "vitamin_e_mg" -> R.string.food_n_vitamin_e_mg
    "vitamin_k_ug" -> R.string.food_n_vitamin_k_ug
    "thiamin_mg" -> R.string.food_n_thiamin_mg
    "riboflavin_mg" -> R.string.food_n_riboflavin_mg
    "niacin_mg" -> R.string.food_n_niacin_mg
    "vitamin_b6_mg" -> R.string.food_n_vitamin_b6_mg
    "folate_ug" -> R.string.food_n_folate_ug
    "vitamin_b12_ug" -> R.string.food_n_vitamin_b12_ug
    "vitamin_c_mg" -> R.string.food_n_vitamin_c_mg
    "pantothenic_mg" -> R.string.food_n_pantothenic_mg
    "biotin_ug" -> R.string.food_n_biotin_ug
    else -> null
}

internal fun nutrientAmount(value: Double, key: String): String {
    val unit = when (key.substringAfterLast('_')) { "mg" -> "mg"; "ug" -> "µg"; "kcal" -> "kcal"; else -> "g" }
    val f = NumberFormat.getNumberInstance(Locale.getDefault())
    f.maximumFractionDigits = if (value < 1) 2 else if (value < 10) 1 else 0
    return "${f.format(value)} $unit"
}

@Composable
internal fun FoodNutrientCard(day: CoreFood.NutrientReport?, pinned: List<String>, onOpen: () -> Unit) {
    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen)) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space4)) {
            pinned.forEach { key -> PinnedRow(key, day?.rows?.firstOrNull { it.nutrient == key }) }
        }
    }
}

/** One pinned nutrient for the day: the amount eaten against the recommended one, and a thin bar. */
@Composable
private fun PinnedRow(key: String, row: CoreFood.NutrientRow?) {
    val eaten = row?.today ?: 0.0
    val ref = row?.reference
    NutrientLine(key, eaten, ref, row?.atMost == true,
                 tint = if (ref != null && row.atMost && eaten > ref) Forge.colors.effort else nutrientTint(key, Forge.colors.dark))
}

/** Badge, name, the amount against its recommendation, and a thin bar in the nutrient's colour. */
@Composable
private fun NutrientLine(key: String, value: Double, reference: Double?, atMost: Boolean, tint: androidx.compose.ui.graphics.Color,
                         pinned: Boolean = false, attention: Boolean = false, note: String? = null) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        NutrientBadge(key)
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(nutrientName(key), style = Forge.type.body, color = Forge.colors.text)
                if (pinned) {
                    Spacer(Modifier.width(4.dp))
                    androidx.compose.material3.Icon(Icons.Rounded.PushPin, stringResource(R.string.food_pinned),
                        tint = Forge.colors.textTertiary, modifier = Modifier.size(12.dp))
                }
                if (attention) {
                    Spacer(Modifier.width(4.dp))
                    androidx.compose.material3.Icon(Icons.Rounded.Error, null, tint = Forge.colors.effort, modifier = Modifier.size(14.dp))
                }
                Spacer(Modifier.weight(1f))
                Text(nutrientAmount(value, key), style = Forge.type.bodyNumber, color = Forge.colors.text)
                if (reference != null) {
                    Spacer(Modifier.width(4.dp))
                    Text(stringResource(if (atMost) R.string.food_max_amount else R.string.food_of_amount, nutrientAmount(reference, key)),
                         style = Forge.type.footnote, color = Forge.colors.textSecondary)
                }
            }
            if (reference != null) {
                val share = value / maxOf(reference, value, 0.0001)
                Box(Modifier.fillMaxWidth().height(4.dp).background(tint.copy(alpha = 0.24f), RoundedCornerShape(2.dp))) {
                    Box(Modifier.fillMaxWidth(min(1.0, share).toFloat()).height(4.dp).background(tint, RoundedCornerShape(2.dp)))
                }
            }
            if (note != null) Text(note, style = Forge.type.caption, color = Forge.colors.textSecondary)
        }
    }
}

@Composable
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
internal fun ForgeFoodNutrientsPage(week: CoreFood.NutrientReport, day: CoreFood.NutrientReport, pinned: List<String>,
                                    onPin: (String) -> Unit, onBack: () -> Unit) {
    var open by remember { mutableStateOf<String?>(null) }
    var showWeek by remember { mutableStateOf(true) }
    var info by remember { mutableStateOf(false) }
    val report = if (showWeek) week else day
    SettingsColumn {
        PageTitle(stringResource(R.string.food_nutrients), onBack) {
            androidx.compose.material3.IconButton(onClick = { info = true }) {
                androidx.compose.material3.Icon(Icons.Rounded.Info, stringResource(R.string.food_reco_open), tint = Forge.colors.accent)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            listOf(false to R.string.food_span_day, true to R.string.food_span_week).forEach { (isWeek, label) ->
                Text(stringResource(label), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold),
                     color = if (showWeek == isWeek) Forge.colors.text else Forge.colors.textSecondary,
                     modifier = Modifier.background(if (showWeek == isWeek) Forge.colors.inset else Forge.colors.surface, RoundedCornerShape(50))
                         .clickable(role = Role.Tab) { showWeek = isWeek }.padding(horizontal = 12.dp, vertical = 8.dp))
            }
        }
        foodNutrientGroups.forEach { (title, keys) ->
            Text(stringResource(title), style = Forge.type.title2, color = Forge.sceneInk.text,
                 modifier = Modifier.padding(top = ForgeMetrics.space3))
            ForgeCard(Modifier.fillMaxWidth()) {
                keys.mapNotNull { key -> report.rows.firstOrNull { it.nutrient == key } }.forEachIndexed { index, row ->
                    if (index > 0) androidx.compose.material3.HorizontalDivider(color = Forge.colors.divider)
                    val estimated = row.estimatedShare + row.modelShare
                    val tint = when (row.status) {
                        "attention" -> Forge.colors.effort
                        "incomplete", "mostlyModel" -> Forge.colors.textTertiary
                        else -> nutrientTint(row.nutrient, Forge.colors.dark)
                    }
                    Column(Modifier.fillMaxWidth().combinedClickable(onClick = { open = if (open == row.nutrient) null else row.nutrient },
                                                                     onLongClick = { onPin(row.nutrient) })
                        .padding(vertical = ForgeMetrics.space3)) {
                        NutrientLine(row.nutrient, row.average, row.reference, row.atMost, tint, pinned = row.nutrient in pinned,
                                     attention = row.status == "attention", note = when {
                                         row.status == "incomplete" -> stringResource(R.string.food_nutrient_too_few)
                                         row.status == "mostlyModel" -> stringResource(R.string.food_nutrient_mostly_model)
                                         estimated >= 0.25 -> stringResource(R.string.food_nutrients_estimated, (estimated * 100).roundToInt())
                                         else -> null
                                     })
                        if (open == row.nutrient && row.topFoods.isNotEmpty()) {
                            Column(Modifier.padding(start = 44.dp, top = ForgeMetrics.space2), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(stringResource(R.string.food_nutrients_from), style = Forge.type.caption, color = Forge.colors.textSecondary)
                                row.topFoods.forEach { (name, amount) ->
                                    Row {
                                        Text(name, style = Forge.type.footnote, color = Forge.colors.text, modifier = Modifier.weight(1f), maxLines = 1)
                                        Text(nutrientAmount(amount, row.nutrient), style = Forge.type.footnote, color = Forge.colors.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if (info) FoodRecommendationsDialog(week) { info = false }
}

/** What each recommendation is based on, in words, as iOS `FoodRecommendationsSheet`. */
@Composable
private fun FoodRecommendationsDialog(report: CoreFood.NutrientReport, onDismiss: () -> Unit) {
    @Composable
    fun explanation(key: String, text: Int) {
        val row = report.rows.firstOrNull { it.nutrient == key }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            val ref = row?.reference
            if (ref != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    NutrientBadge(key)
                    Spacer(Modifier.width(ForgeMetrics.space2))
                    Text(stringResource(if (row.atMost) R.string.food_recommended_under else R.string.food_recommended_at_least, nutrientAmount(ref, key)),
                         style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
                }
            }
            Text(stringResource(text), style = Forge.type.body, color = Forge.colors.textSecondary)
        }
    }
    @Composable
    fun heading(text: String) = Text(text, style = Forge.type.headline, color = Forge.colors.text, modifier = Modifier.padding(top = ForgeMetrics.space2))
    androidx.compose.material3.AlertDialog(onDismissRequest = onDismiss, title = { Text(stringResource(R.string.food_reco_title)) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Text(stringResource(R.string.food_reco_intro), style = Forge.type.body, color = Forge.colors.text)
            Text(stringResource(R.string.food_reco_tap), style = Forge.type.body, color = Forge.colors.textSecondary)
            heading(nutrientName("protein_g")); explanation("protein_g", R.string.food_reco_protein)
            heading(nutrientName("fiber_g")); explanation("fiber_g", R.string.food_reco_fibre)
            heading(stringResource(R.string.food_reco_fats))
            explanation("sat_fat_g", R.string.food_reco_satfat)
            explanation("epa_g", R.string.food_reco_epa)
            Text(stringResource(R.string.food_reco_other), style = Forge.type.body, color = Forge.colors.textSecondary)
            heading(stringResource(R.string.food_reco_salt_title))
            explanation("salt_g", R.string.food_reco_salt)
            explanation("sodium_mg", R.string.food_reco_sodium)
            heading(stringResource(R.string.food_reco_vitamins_title))
            Text(stringResource(R.string.food_reco_vitamins), style = Forge.type.body, color = Forge.colors.textSecondary)
            Text(stringResource(R.string.food_reco_note), style = Forge.type.caption, color = Forge.colors.textSecondary)
        }
    }, confirmButton = { androidx.compose.material3.TextButton(onClick = onDismiss) { Text(stringResource(R.string.food_done)) } })
}

/**
 * A nutrient's own small mark, as iOS `FoodNutrientBadge`: a symbol for fats, fibre and sugar, the element for
 * minerals (Fe, Ca), the letter for vitamins (D, B12), each in its own colour (`nutrientTint`).
 */
@Composable
internal fun NutrientBadge(key: String) {
    val tint = nutrientTint(key, Forge.colors.dark)
    Box(Modifier.size(32.dp).background(tint.copy(alpha = 0.16f), RoundedCornerShape(10.dp)), contentAlignment = Alignment.Center) {
        when (val mark = nutrientMark(key)) {
            is androidx.compose.ui.graphics.vector.ImageVector ->
                androidx.compose.material3.Icon(mark, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
            else -> Text(mark.toString(), style = Forge.type.caption.copy(fontWeight = FontWeight.Bold), color = tint)
        }
    }
}

private fun nutrientMark(key: String): Any = when (key) {
        "protein_g" -> Icons.Rounded.FitnessCenter
        "fiber_g" -> Icons.Rounded.Eco
        "sugar_g" -> Icons.Rounded.ViewInAr
        "sat_fat_g" -> Icons.Rounded.WaterDrop
        "mono_fat_g" -> Icons.Rounded.Opacity
        "poly_fat_g" -> Icons.Rounded.InvertColors
        "omega3_g" -> "ω3"
        "epa_g" -> Icons.Rounded.Phishing
        "cholesterol_mg" -> Icons.Rounded.Favorite
        "salt_g" -> Icons.Rounded.Grain
        "sodium_mg" -> "Na"
        "potassium_mg" -> "K"
        "calcium_mg" -> "Ca"
        "magnesium_mg" -> "Mg"
        "phosphorus_mg" -> "P"
        "iron_mg" -> "Fe"
        "zinc_mg" -> "Zn"
        "iodine_ug" -> "I"
        "copper_mg" -> "Cu"
        "manganese_mg" -> "Mn"
        "vitamin_a_ug" -> "A"
        "vitamin_d_ug" -> "D"
        "vitamin_e_mg" -> "E"
        "vitamin_k_ug" -> "K"
        "thiamin_mg" -> "B1"
        "riboflavin_mg" -> "B2"
        "niacin_mg" -> "B3"
        "pantothenic_mg" -> "B5"
        "vitamin_b6_mg" -> "B6"
        "biotin_ug" -> "B7"
        "folate_ug" -> "B9"
        "vitamin_b12_ug" -> "B12"
        "vitamin_c_mg" -> "C"
    else -> "•"
}
