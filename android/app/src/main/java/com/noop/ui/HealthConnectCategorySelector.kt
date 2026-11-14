package com.noop.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.ingest.HealthConnectImporter.ImportCategory
import com.noop.ingest.HealthConnectImporter.ImportType

/**
 * Shared Health Connect consent surface for onboarding and Data Sources (#645). Keeping the same selector
 * in both entry points prevents onboarding from quietly requesting a broader permission set than the
 * settings flow.
 *
 * The selection is per type; a group's switch turns all of its types on or off at once, and its arrow
 * opens one switch per type. Nothing is locked: an empty selection is allowed and the screens disable
 * their import button while it lasts, with the note below saying why (2026-11-14, a tester could not
 * pick Activity on its own because the last switch on was greyed out).
 */
@Composable
internal fun HealthConnectCategorySelector(
    selected: Set<ImportType>,
    onSelectionChange: (Set<ImportType>) -> Unit,
    routesAwaitingConsent: Int = 0,
    onOpenHealthConnect: (() -> Unit)? = null,
) {
    var expanded by remember { mutableStateOf(emptySet<ImportCategory>()) }

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            uiString(R.string.health_connect_categories_title),
            style = NoopType.subhead,
            color = Palette.textPrimary,
        )
        Text(
            uiString(R.string.health_connect_categories_detail),
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )

        ImportCategory.entries.forEach { category ->
            val chosen = category.types.count { it in selected }
            val several = category.types.size > 1
            val open = category in expanded
            val detail = if (several && chosen in 1 until category.types.size) {
                uiString(R.string.health_connect_selected_count, chosen, category.types.size)
            } else {
                uiString(category.detailRes())
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .then(
                        if (several) {
                            Modifier.clickable { expanded = if (open) expanded - category else expanded + category }
                        } else {
                            Modifier
                        },
                    ),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(uiString(category.titleRes()), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(detail, style = NoopType.footnote, color = Palette.textTertiary)
                }
                if (several) {
                    Icon(
                        if (open) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                        contentDescription = uiString(
                            if (open) R.string.health_connect_hide_types else R.string.health_connect_show_types,
                        ),
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(22.dp),
                    )
                }
                SelectorSwitch(checked = chosen > 0) { on ->
                    onSelectionChange(if (on) selected + category.types else selected - category.types.toSet())
                }
            }

            if (several && open) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(start = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    category.types.forEach { type ->
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Text(
                                uiString(type.titleRes()),
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                                modifier = Modifier.weight(1f),
                            )
                            SelectorSwitch(checked = type in selected) { on ->
                                onSelectionChange(if (on) selected + type else selected - type)
                            }
                        }
                    }
                }
            }

            // Routes need a permission Health Connect's normal dialog cannot ask for, so the last import's
            // count of held-back routes is the only cue the wearer gets to allow them there.
            if (category == ImportCategory.TRAINING && ImportType.WORKOUTS in selected && routesAwaitingConsent > 0) {
                Text(
                    uiString(R.string.health_connect_routes_held_back),
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        if (selected.isEmpty()) {
            Text(
                uiString(R.string.health_connect_nothing_selected),
                style = NoopType.footnote,
                color = Palette.statusWarning,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (onOpenHealthConnect != null) {
            TextButton(onClick = onOpenHealthConnect) {
                Text(uiString(R.string.health_connect_open_settings), style = NoopType.subhead, color = Palette.accent)
            }
        }
    }
}

@Composable
private fun SelectorSwitch(checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Switch(
        checked = checked,
        onCheckedChange = onCheckedChange,
        colors = SwitchDefaults.colors(
            checkedThumbColor = Palette.surfaceBase,
            checkedTrackColor = Palette.accent,
            uncheckedThumbColor = Palette.textSecondary,
            uncheckedTrackColor = Palette.surfaceInset,
            uncheckedBorderColor = Palette.hairline,
        ),
    )
}

@StringRes
private fun ImportCategory.titleRes(): Int = when (this) {
    ImportCategory.RECOVERY -> R.string.health_connect_category_recovery
    ImportCategory.STEPS -> R.string.health_connect_category_steps
    ImportCategory.TRAINING -> R.string.health_connect_category_training
    ImportCategory.CALORIES -> R.string.health_connect_category_calories
    ImportCategory.BODY_COMPOSITION -> R.string.health_connect_category_body_composition
}

@StringRes
private fun ImportCategory.detailRes(): Int = when (this) {
    ImportCategory.RECOVERY -> R.string.health_connect_category_recovery_detail
    ImportCategory.STEPS -> R.string.health_connect_category_steps_detail
    ImportCategory.TRAINING -> R.string.health_connect_category_training_detail
    ImportCategory.CALORIES -> R.string.health_connect_category_calories_detail
    ImportCategory.BODY_COMPOSITION -> R.string.health_connect_category_body_composition_detail
}

@StringRes
private fun ImportType.titleRes(): Int = when (this) {
    ImportType.HEART_RATE -> R.string.health_connect_type_heart_rate
    ImportType.RESTING_HEART_RATE -> R.string.health_connect_type_resting_heart_rate
    ImportType.HRV -> R.string.health_connect_type_hrv
    ImportType.SLEEP -> R.string.health_connect_type_sleep
    ImportType.OXYGEN_SATURATION -> R.string.health_connect_type_oxygen_saturation
    ImportType.RESPIRATORY_RATE -> R.string.health_connect_type_respiratory_rate
    ImportType.HYDRATION -> R.string.health_connect_type_hydration
    ImportType.STEPS -> R.string.health_connect_type_steps
    ImportType.WORKOUTS -> R.string.health_connect_type_workouts
    ImportType.DISTANCE -> R.string.health_connect_type_distance
    ImportType.VO2_MAX -> R.string.health_connect_type_vo2_max
    ImportType.TOTAL_CALORIES -> R.string.health_connect_type_total_calories
    ImportType.ACTIVE_CALORIES -> R.string.health_connect_type_active_calories
    ImportType.WEIGHT -> R.string.health_connect_type_weight
    ImportType.BODY_FAT -> R.string.health_connect_type_body_fat
    ImportType.LEAN_BODY_MASS -> R.string.health_connect_type_lean_body_mass
}
