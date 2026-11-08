package com.noop.ui.forge

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
internal fun FoodNutrientCard(report: CoreFood.NutrientReport?, onOpen: () -> Unit) {
    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen)) {
        Text(stringResource(R.string.food_nutrients), style = Forge.type.headline, color = Forge.colors.text)
        if (report != null && report.judged > 0) {
            Text(stringResource(R.string.food_nutrients_in_range, report.fine, report.judged, report.loggedDays),
                 style = Forge.type.body, color = Forge.colors.textSecondary)
            report.rows.filter { it.status == "attention" }.take(3).forEach { row ->
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = ForgeMetrics.space1)) {
                    Box(Modifier.size(7.dp).background(Forge.colors.effort, CircleShape))
                    Spacer(Modifier.width(ForgeMetrics.space2))
                    Text(nutrientName(row.nutrient), style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
                    row.reference?.let { ref -> Text("${(row.average / ref * 100).roundToInt()} %", style = Forge.type.bodyNumber, color = Forge.colors.effort) }
                }
            }
        } else {
            Text(stringResource(R.string.food_nutrients_empty), style = Forge.type.body, color = Forge.colors.textSecondary)
        }
    }
}

@Composable
internal fun ForgeFoodNutrientsPage(report: CoreFood.NutrientReport, onBack: () -> Unit) {
    var open by remember { mutableStateOf<String?>(null) }
    SettingsColumn {
        PageTitle(stringResource(R.string.food_nutrients), onBack)
        Text(stringResource(R.string.food_nutrients_note), style = Forge.type.footnote, color = Forge.sceneInk.secondary)
        foodNutrientGroups.forEach { (title, keys) ->
            ForgeCard(Modifier.fillMaxWidth()) {
                Text(stringResource(title), style = Forge.type.headline, color = Forge.colors.text)
                keys.mapNotNull { key -> report.rows.firstOrNull { it.nutrient == key } }.forEach { row ->
                    val share = row.reference?.let { row.average / maxOf(0.0001, it) } ?: 0.0
                    val tint = when (row.status) { "fine" -> Forge.colors.charge; "attention" -> Forge.colors.effort; else -> Forge.colors.textTertiary }
                    Column(Modifier.fillMaxWidth().clickable { open = if (open == row.nutrient) null else row.nutrient }
                        .padding(vertical = ForgeMetrics.space2), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row {
                            Text(nutrientName(row.nutrient), style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold),
                                 color = Forge.colors.text, modifier = Modifier.weight(1f))
                            Text(nutrientAmount(row.average, row.nutrient), style = Forge.type.bodyNumber, color = Forge.colors.text)
                        }
                        val ref = row.reference
                        if (ref != null) {
                            Box(Modifier.fillMaxWidth().height(6.dp).background(Forge.colors.inset, RoundedCornerShape(3.dp))) {
                                Box(Modifier.fillMaxWidth(min(1.0, share).toFloat()).height(6.dp).background(tint, RoundedCornerShape(3.dp)))
                            }
                            Text(when {
                                row.status == "incomplete" -> stringResource(R.string.food_nutrients_incomplete, (row.coverage * 100).roundToInt())
                                row.atMost -> stringResource(R.string.food_nutrients_limit, nutrientAmount(ref, row.nutrient), row.source ?: "")
                                else -> stringResource(R.string.food_nutrients_reference, nutrientAmount(ref, row.nutrient), row.source ?: "")
                            } + if (row.status != "incomplete" && row.estimatedShare >= 0.05)
                                " · " + stringResource(R.string.food_nutrients_estimated, (row.estimatedShare * 100).roundToInt()) else "", style = Forge.type.footnote, color = Forge.colors.textSecondary)
                        }
                        if (open == row.nutrient && row.topFoods.isNotEmpty()) {
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
        Text(stringResource(R.string.food_nutrients_sources), style = Forge.type.caption, color = Forge.sceneInk.secondary)
    }
}
