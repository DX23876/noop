package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreTrainingLibrary
import com.noop.ui.ProfileStore

/**
 * "Find by muscle" (`ExerciseMusclePickerView`): the front and back figures side by side, every muscle group as a chip
 * with how many exercises train it, and for the chosen group the exercises that target it and those that also train
 * it. The groups and who trains them come from the core (`ExerciseMuscleGroup`), so they match the muscle analytics.
 */
@Composable
internal fun ForgeExerciseMusclePicker(catalog: CoreTrainingLibrary.Catalog, onClose: () -> Unit, onOpen: (String) -> Unit,
                                       onPick: ((String) -> Unit)?, picked: Set<String>) {
    val context = LocalContext.current
    val colors = Forge.colors
    var selection by rememberSaveable { mutableStateOf<String?>(null) }
    var query by rememberSaveable { mutableStateOf("") }
    val gender = remember { if (ProfileStore.from(context).sex == "female") "female" else "male" }
    val rows = remember(catalog) { catalog.exercises.associateBy { it.id } }
    val muscleLabels = catalog.muscles.associateWith { muscleName(it) }
    val equipmentLabels = catalog.equipment.associateWith { equipmentName(it) }
    val group = catalog.groups.firstOrNull { it.id == selection }
    // The artwork slug of every group, so a tap on the body finds its group and the chosen one lights up.
    val slugs = remember(catalog) { catalog.groups.associate { g -> g.id to g.muscleIds.mapNotNull(MuscleMapArt::muscle).toSet() } }
    val fills = group?.let { g -> slugs[g.id].orEmpty().associateWith { colors.accent } }.orEmpty()
    fun toggle(id: String) { selection = if (selection == id) null else id }
    fun tapped(slug: String) { catalog.groups.firstOrNull { slug in slugs[it.id].orEmpty() }?.let { toggle(it.id) } }
    val needle = query.trim()
    fun matches(id: String): Boolean {
        if (needle.isEmpty()) return true
        val row = rows[id] ?: return false
        return row.title.contains(needle, ignoreCase = true) ||
            row.equipment.any { (equipmentLabels[it] ?: it).contains(needle, ignoreCase = true) }
    }
    val primary = group?.primary.orEmpty().filter(::matches).mapNotNull(rows::get)
    val secondary = group?.secondary.orEmpty().filter(::matches).mapNotNull(rows::get)
    val chips = rememberLazyListState()
    LaunchedEffect(selection) {
        val index = catalog.groups.indexOfFirst { it.id == selection }
        if (index >= 0) chips.animateScrollToItem(maxOf(0, index - 1))
    }

    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        LazyColumn(Modifier.fillMaxHeight().widthIn(max = ForgeMetrics.maxContentWidth).fillMaxWidth()
                .statusBarsPadding().navigationBarsPadding().imePadding(), contentPadding = PaddingValues(ForgeMetrics.screenPadding)) {
            section { PageTitle(stringResource(R.string.forge_library_find_muscle), onClose) }
            section {
                OutlinedTextField(query, { query = it }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text(stringResource(R.string.forge_library_search_muscle)) },
                    leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null) }, colors = forgeFieldColors(Forge.colors.surface),
                    shape = RoundedCornerShape(ForgeMetrics.groupedRadius))
            }
            section {
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(ForgeMetrics.groupedRadius)).background(colors.surface).padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                    Row(Modifier.fillMaxWidth().height(280.dp), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                        ForgeBodyMap(gender, "front", fills, Modifier.weight(1f).fillMaxHeight(),
                            stringResource(R.string.forge_library_front_body), ::tapped)
                        ForgeBodyMap(gender, "back", fills, Modifier.weight(1f).fillMaxHeight(),
                            stringResource(R.string.forge_library_back_body), ::tapped)
                    }
                    LazyRow(state = chips, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(catalog.groups, key = { it.id }) { g ->
                            GroupChip("${g.title} ${g.primary.size + g.secondary.size}", selection == g.id) { toggle(g.id) }
                        }
                    }
                }
            }
            section {
                Text(stringResource(R.string.forge_library_choose_muscle), style = Forge.type.caption, color = colors.textTertiary,
                     modifier = Modifier.padding(horizontal = 4.dp))
            }
            if (group != null) {
                section {
                    Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space2, start = 4.dp, end = 4.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.forge_library_exercises_for, group.title).uppercase(), style = Forge.type.overline,
                             color = colors.textTertiary, modifier = Modifier.weight(1f))
                        Text(stringResource(R.string.forge_provider_clear_selection),
                             style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.accent,
                             modifier = Modifier.clickable(role = Role.Button) { selection = null })
                    }
                }
                val all = primary.map { it to true } + secondary.map { it to false }
                if (all.isEmpty()) section {
                    Text(stringResource(R.string.forge_library_no_exercises_match), style = Forge.type.body, color = colors.textSecondary,
                         modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(ForgeMetrics.groupedRadius))
                             .background(colors.surface).padding(16.dp))
                }
                itemsIndexed(all, key = { _, (row, main) -> (if (main) "p-" else "s-") + row.id }) { index, (row, main) ->
                    // Equipment is dropped here, as on iOS: the muscle filter already narrows the list.
                    val involvement = stringResource(if (main) R.string.forge_library_main_target else R.string.forge_library_also_trains)
                    val muscle = row.primaryMuscle?.let { muscleLabels[it] ?: it }
                    LibraryRow(row, listOfNotNull(involvement, muscle).joinToString(" · "), false, index, all.size,
                        onOpen = { onOpen(row.id) }, onPick = onPick?.let { pick -> { pick(row.id) } }, picked = row.id in picked)
                }
            }
            section { Spacer(Modifier.height(ForgeMetrics.tabBarClearance)) }
        }
    }
}

@Composable
private fun GroupChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val colors = Forge.colors
    Text(label, style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold),
         color = if (selected) Color.White else colors.textSecondary, maxLines = 1,
         modifier = Modifier.clip(CircleShape).background(if (selected) colors.accent else colors.inset)
             .clickable(role = Role.Tab, onClick = onClick).padding(horizontal = 12.dp, vertical = 7.dp))
}
