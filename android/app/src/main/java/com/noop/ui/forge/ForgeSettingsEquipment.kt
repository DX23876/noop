package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.noop.R
import com.noop.core.CoreProfile
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// Settings › Training › Available equipment (iOS `TrainingEquipmentSettingsView`): the pieces of equipment the wearer can
// use, which the exercise library and the plan builder filter by. The key is the one the library's own filter writes.

/** The key the exercise library and the plan builder read: the ids of the equipment in use, one per line; none means every exercise stays available. */
internal const val AVAILABLE_EQUIPMENT_KEY = "training.availableEquipment"

/** A list of switches, one per piece of equipment, saved as they are flipped. */
@Composable
internal fun EquipmentSettingsPage(onBack: () -> Unit) {
    val context = LocalContext.current
    val prefs = remember { NoopPrefs.of(context) }
    var choices by remember { mutableStateOf<List<String>>(emptyList()) }
    var selected by remember {
        mutableStateOf(prefs.getString(AVAILABLE_EQUIPMENT_KEY, "").orEmpty().lineSequence().filter { it.isNotBlank() }.toSet())
    }
    LaunchedEffect(Unit) { choices = withContext(Dispatchers.IO) { CoreProfile.equipmentChoices() }.orEmpty() }
    BackHandler(onBack = onBack)

    SettingsColumn {
        PageTitle(stringResource(R.string.fsp1_equipment_title), onBack)
        SettingsCard(null, null) {
            choices.forEachIndexed { index, id ->
                if (index > 0) RowDivider()
                ToggleRow(equipmentName(id), null, id in selected) { value ->
                    selected = if (value) selected + id else selected - id
                    prefs.edit().putString(AVAILABLE_EQUIPMENT_KEY, selected.sorted().joinToString("\n")).apply()
                }
            }
            androidx.compose.material3.Text(stringResource(R.string.fsp1_equipment_note), style = Forge.type.caption,
                                            color = Forge.colors.textTertiary)
        }
    }
}
