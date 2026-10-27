package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.noop.R
import com.noop.core.CoreRead
import com.noop.core.CoreTraining
import com.noop.core.CoreTrainingLibrary
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.UnitFormatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

private const val AVAILABLE_EQUIPMENT = "training.availableEquipment"

private const val FAVORITES = "training.favoriteExerciseIds"

/** One offline library for browsing and the workout/routine pickers. Rows are virtualized, not capped. */
@Composable
fun ForgeExerciseLibrary(onClose: () -> Unit, multiple: Boolean = false,
                         onPicked: ((List<String>) -> Unit)? = null, onAdded: (() -> Unit)? = null) {
    val context = LocalContext.current
    val prefs = remember(context) { NoopPrefs.of(context) }
    val scope = rememberCoroutineScope()
    var catalog by remember { mutableStateOf<CoreTrainingLibrary.Catalog?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var revision by remember { mutableIntStateOf(0) }
    var query by rememberSaveable { mutableStateOf("") }
    var region by rememberSaveable { mutableStateOf<String?>(null) }
    var muscle by rememberSaveable { mutableStateOf<String?>(null) }
    var equipment by rememberSaveable { mutableStateOf<String?>(null) }
    var mode by rememberSaveable { mutableStateOf<String?>(null) }
    var favoritesOnly by rememberSaveable { mutableStateOf(false) }
    var favoritesPayload by remember { mutableStateOf(prefs.getString(FAVORITES, "").orEmpty()) }
    val favorites = remember(favoritesPayload) { favoritesPayload.lineSequence().filter { it.isNotBlank() }.toSet() }
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    var creating by rememberSaveable { mutableStateOf(false) }
    var filtersOpen by rememberSaveable { mutableStateOf(false) }
    var equipmentDialog by rememberSaveable { mutableStateOf(false) }
    var availablePayload by remember { mutableStateOf(prefs.getString(AVAILABLE_EQUIPMENT, "").orEmpty()) }
    val available = remember(availablePayload) { availablePayload.lineSequence().filter { it.isNotBlank() }.toSet() }
    var mapSide by rememberSaveable { mutableStateOf("front") }
    var muscleChoices by remember { mutableStateOf<List<String>>(emptyList()) }
    var picked by rememberSaveable { mutableStateOf(arrayListOf<String>()) }
    var importing by remember { mutableStateOf(false) }
    var importResult by remember { mutableStateOf<Int?>(null) }
    var importFailed by remember { mutableStateOf(false) }
    LaunchedEffect(revision, availablePayload) {
        loaded = false
        catalog = withContext(Dispatchers.IO) { CoreRead.open(context); CoreTrainingLibrary.catalog(available.toList()) }
        loaded = true
    }
    fun toggleFavorite(id: String) {
        val values = favorites.toMutableSet()
        if (!values.add(id)) values.remove(id)
        favoritesPayload = values.sorted().joinToString("\n")
        prefs.edit().putString(FAVORITES, favoritesPayload).apply()
    }
    fun choose(id: String) {
        if (multiple) picked = ArrayList(picked.toMutableList().also { if (!it.remove(id)) it.add(id) })
        else onPicked?.invoke(listOf(id))
    }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            importing = true
            val count = withContext(Dispatchers.IO) {
                runCatching {
                    val json = context.contentResolver.openInputStream(uri)!!.use { input ->
                        val output = ByteArrayOutputStream()
                        val buffer = ByteArray(8 * 1024)
                        while (true) {
                            val size = input.read(buffer)
                            if (size < 0) break
                            check(output.size() + size <= 25 * 1024 * 1024)
                            output.write(buffer, 0, size)
                        }
                        output.toString(Charsets.UTF_8.name())
                    }
                    CoreTrainingLibrary.importCatalog(json)
                }.getOrNull()
            }
            importing = false
            if (count == null) importFailed = true else { importResult = count; revision++ }
        }
    }
    BackHandler { when { creating -> creating = false; selected != null -> selected = null; else -> onClose() } }
    if (creating) {
        catalog?.let { choices -> CustomExercisePage(choices, onClose = { creating = false }) { id ->
            creating = false; selected = id; revision++
        } }
        return
    }
    selected?.let { id ->
        LibraryExercisePage(id, id in favorites, { toggleFavorite(id) }, { selected = null },
            if (onPicked != null) ({ choose(id); if (multiple) selected = null }) else null, onAdded)
        return
    }
    if (importResult != null || importFailed) AlertDialog(onDismissRequest = { importResult = null; importFailed = false },
        title = { Text(stringResource(R.string.forge_library_title)) },
        text = { Text(if (importFailed) stringResource(R.string.forge_library_import_failed)
            else stringResource(R.string.forge_library_imported_count, importResult ?: 0)) },
        confirmButton = { TextButton(onClick = { importResult = null; importFailed = false }) { Text(stringResource(R.string.forge_library_ok)) } })
    val c = catalog
    if (equipmentDialog && c != null) AvailableEquipmentDialog(c.equipment, available,
        onDismiss = { equipmentDialog = false }) { values ->
        availablePayload = values.sorted().joinToString("\n")
        prefs.edit().putString(AVAILABLE_EQUIPMENT, availablePayload).apply()
        if (values.isEmpty() && equipment == "available") equipment = null
        equipmentDialog = false
    }
    if (muscleChoices.isNotEmpty()) AlertDialog(onDismissRequest = { muscleChoices = emptyList() },
        title = { Text(stringResource(R.string.forge_library_muscle)) },
        text = { Column { muscleChoices.forEach { id ->
            TextButton(onClick = { muscle = id; muscleChoices = emptyList() }) { Text(muscleName(id)) }
        } } },
        confirmButton = { TextButton(onClick = { muscleChoices = emptyList() }) { Text(stringResource(R.string.forge_library_ok)) } })
    val muscleLabels = c?.muscles.orEmpty().associateWith { muscleName(it) }
    val equipmentLabels = c?.equipment.orEmpty().associateWith { equipmentName(it) }
    val shown = remember(c, query, region, muscle, equipment, mode, favoritesOnly, favorites, muscleLabels, equipmentLabels) {
        ExerciseLibraryFilters(query, region, muscle, equipment, mode, favoritesOnly)
            .apply(c?.exercises.orEmpty(), favorites, muscleLabels, equipmentLabels, c?.availableExerciseIds.orEmpty().toSet())
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
    LazyColumn(Modifier.fillMaxHeight().widthIn(max = ForgeMetrics.maxContentWidth).fillMaxWidth()
            .statusBarsPadding().navigationBarsPadding().imePadding(), contentPadding = PaddingValues(ForgeMetrics.screenPadding),
        verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        item {
            PageTitle(stringResource(R.string.forge_library_title), onClose, trailing = if (multiple && picked.isNotEmpty()) {
                { TextButton(onClick = { onPicked?.invoke(picked.toList()) }) { Text(stringResource(R.string.forge_training_selected, picked.size)) } }
            } else null)
        }
        item {
            OutlinedTextField(query, { query = it }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                label = { Text(stringResource(R.string.forge_library_search)) },
                leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null) })
        }
        if (!loaded || importing) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        if (loaded && c == null) item { ForgeCard(Modifier.fillMaxWidth()) {
            ReportNote(stringResource(R.string.forge_library_unavailable))
            TextButton(onClick = { revision++ }) { Text(stringResource(R.string.forge_report_retry)) }
        } }
        if (c != null) {
            item {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                    item { LibraryChip(region == null && !favoritesOnly, { region = null; favoritesOnly = false }, stringResource(R.string.forge_report_all)) }
                    item { LibraryChip(favoritesOnly, { favoritesOnly = !favoritesOnly }, stringResource(R.string.forge_library_favorites)) }
                    items(c.regions) { id -> LibraryChip(region == id, { region = if (region == id) null else id }, regionName(id)) }
                }
            }
            item {
                TextButton(onClick = { filtersOpen = !filtersOpen }) {
                    Text(stringResource(if (filtersOpen) R.string.forge_library_hide_filters else R.string.forge_library_filter))
                }
                if (filtersOpen) ForgeCard(Modifier.fillMaxWidth()) {
                    ReportNote(stringResource(R.string.forge_library_choose_muscle))
                    ForgeSegmented(listOf(stringResource(R.string.forge_th_front), stringResource(R.string.forge_th_back)),
                        if (mapSide == "front") 0 else 1, Modifier.fillMaxWidth()) { mapSide = if (it == 0) "front" else "back" }
                    val selectedSlug = muscle?.let(MuscleMapArt::muscle)
                    val fills = selectedSlug?.let { mapOf(it to Forge.colors.accent) }.orEmpty()
                    ForgeBodyMap(if (ProfileStore.from(context).sex == "female") "female" else "male", mapSide, fills,
                        Modifier.fillMaxWidth().height(ForgeMetrics.chartHeight), stringResource(R.string.forge_library_choose_muscle)) { slug ->
                        val choices = MuscleMapArt.ids(slug, c.muscles)
                        if (choices.size == 1) muscle = choices.single() else muscleChoices = choices
                    }
                    ReportNote(stringResource(R.string.forge_library_muscle))
                    ReportPicker(muscle?.let { muscleName(it) } ?: stringResource(R.string.forge_library_any_muscle),
                        listOf(stringResource(R.string.forge_library_any_muscle)) + c.muscles.map { muscleName(it) }) { muscle = c.muscles.getOrNull(it - 1) }
                    ReportNote(stringResource(R.string.forge_library_equipment))
                    val equipmentIds = (if (available.isNotEmpty()) listOf("available") else emptyList()) + c.equipment
                    fun equipmentLabel(id: String): String = if (id == "available") context.getString(R.string.forge_library_my_equipment) else equipmentLabels[id] ?: id
                    ReportPicker(equipment?.let(::equipmentLabel) ?: stringResource(R.string.forge_library_any_equipment),
                        listOf(stringResource(R.string.forge_library_any_equipment)) + equipmentIds.map(::equipmentLabel)) { equipment = equipmentIds.getOrNull(it - 1) }
                    TextButton(onClick = { equipmentDialog = true }) { Text(stringResource(R.string.forge_library_available_equipment)) }
                    ReportNote(stringResource(R.string.forge_library_type))
                    ReportPicker(mode?.let { measurementName(it) } ?: stringResource(R.string.forge_library_any_type),
                        listOf(stringResource(R.string.forge_library_any_type)) + c.modes.map { measurementName(it) }) { mode = c.modes.getOrNull(it - 1) }
                    TextButton(onClick = { query = ""; region = null; muscle = null; equipment = null; mode = null; favoritesOnly = false }) {
                        Text(stringResource(R.string.forge_library_clear_filters))
                    }
                }
            }
            if (onPicked == null) item {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
                    TextButton(onClick = { creating = true }, modifier = Modifier.weight(1f)) { Text(stringResource(R.string.forge_library_new)) }
                    TextButton(enabled = !importing, onClick = { importer.launch(arrayOf("application/json", "text/plain")) }, modifier = Modifier.weight(1f)) {
                        Text(stringResource(R.string.forge_library_import))
                    }
                }
            }
            item { OverlineHeader(stringResource(R.string.forge_library_all_exercises), stringResource(R.string.forge_library_count, shown.size)) }
            if (shown.isEmpty()) item { ForgeCard(Modifier.fillMaxWidth()) {
                ReportHeading(stringResource(R.string.forge_library_no_match))
                ReportNote(stringResource(R.string.forge_library_try_another))
            } }
            items(shown, key = { it.id }) { row ->
                ForgeCard(Modifier.fillMaxWidth()) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f).heightIn(min = ForgeMetrics.minHitTarget).clickable { selected = row.id }) {
                            ReportHeading(row.title)
                            ReportNote(listOfNotNull(row.primaryMuscle?.let { muscleName(it) }, measurementName(row.mode)).joinToString(" · "))
                            if (row.equipment.isNotEmpty()) ReportNote(row.equipment.joinToString(", ") { equipmentLabels[it] ?: it })
                        }
                        IconButton(onClick = { toggleFavorite(row.id) }) { Icon(if (row.id in favorites) Icons.Rounded.Star else Icons.Rounded.StarBorder,
                            stringResource(if (row.id in favorites) R.string.forge_library_unfavorite else R.string.forge_library_favorite),
                            tint = if (row.id in favorites) Forge.colors.accent else Forge.colors.textTertiary) }
                        if (onPicked != null) IconButton(onClick = { choose(row.id) }) { Icon(if (row.id in picked) Icons.Rounded.Check else Icons.Rounded.Add,
                            stringResource(R.string.forge_library_add), tint = Forge.colors.accent) }
                        else IconButton(onClick = { selected = row.id }) { Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                            stringResource(R.string.forge_library_open), tint = Forge.colors.textTertiary) }
                    }
                }
            }
            item { ForgeCard(Modifier.fillMaxWidth()) {
                ReportHeading(stringResource(R.string.forge_library_content_source))
                ReportNote("${c.provider} · ${c.licence}")
                c.attribution?.let { ReportNote(it) }
            } }
        }
        item { Spacer(Modifier.height(ForgeMetrics.tabBarClearance)) }
    }
    }
}

@Composable
private fun LibraryChip(selected: Boolean, onClick: () -> Unit, label: String) {
    FilterChip(selected, onClick, label = { Text(label) }, shape = RoundedCornerShape(ForgeMetrics.groupedRadius),
        colors = FilterChipDefaults.filterChipColors(containerColor = Forge.colors.canvas, labelColor = Forge.colors.textSecondary,
            selectedContainerColor = Forge.colors.surface, selectedLabelColor = Forge.colors.text),
        border = BorderStroke(ForgeMetrics.hairline, if (selected) Forge.colors.accent else Forge.colors.border))
}

@Composable
private fun LibraryExercisePage(id: String, favorite: Boolean, toggleFavorite: () -> Unit, onClose: () -> Unit,
                                onPick: (() -> Unit)?, onAdded: (() -> Unit)?) {
    val context = LocalContext.current
    val units = strengthUnits()
    val scope = rememberCoroutineScope()
    var detail by remember(id) { mutableStateOf<CoreTrainingLibrary.Detail?>(null) }
    var loaded by remember(id) { mutableStateOf(false) }
    var revision by remember { mutableIntStateOf(0) }
    var side by rememberSaveable(id) { mutableStateOf("front") }
    var adding by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    LaunchedEffect(id, revision) {
        loaded = false
        detail = withContext(Dispatchers.IO) { CoreTrainingLibrary.detail(id, dismissedTrainingWorkouts(context)) }
        loaded = true
    }
    BackHandler { if (!adding) onClose() }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_report_exercise), onClose)
        if (!loaded) { LinearProgressIndicator(Modifier.fillMaxWidth()); return@SettingsColumn }
        val d = detail ?: run {
            ForgeCard(Modifier.fillMaxWidth()) {
                ReportNote(stringResource(R.string.forge_library_unavailable))
                TextButton(onClick = { revision++ }) { Text(stringResource(R.string.forge_report_retry)) }
            }
            return@SettingsColumn
        }
        val e = d.exercise
        ForgeCard(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(e.title, style = Forge.type.title2, color = Forge.colors.text, modifier = Modifier.weight(1f))
                IconButton(onClick = toggleFavorite) { Icon(if (favorite) Icons.Rounded.Star else Icons.Rounded.StarBorder,
                    stringResource(if (favorite) R.string.forge_library_unfavorite else R.string.forge_library_favorite), tint = Forge.colors.accent) }
            }
            ReportNote(measurementName(e.mode))
            ReportFact(stringResource(R.string.forge_report_primary_muscle), if (e.primary.isEmpty()) "—" else e.primary.map { muscleName(it) }.joinToString(", "))
            if (e.secondary.isNotEmpty()) ReportFact(stringResource(R.string.forge_library_also_involved), e.secondary.map { muscleName(it) }.joinToString(", "))
            ReportFact(stringResource(R.string.forge_library_equipment), if (e.equipment.isEmpty()) stringResource(R.string.forge_library_no_equipment)
                else e.equipment.map { equipmentName(it) }.joinToString(", "))
            if (d.unilateral) ReportNote(stringResource(R.string.forge_library_unilateral))
        }
        val tint = TrainingLane.Strength.color
        val fills = remember(e, tint) {
            buildMap {
                e.secondary.mapNotNull(MuscleMapArt::muscle).forEach { put(it, tint.copy(alpha = 0.35f)) }
                e.primary.mapNotNull(MuscleMapArt::muscle).forEach { put(it, tint) }
            }
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            ForgeSegmented(listOf(stringResource(R.string.forge_th_front), stringResource(R.string.forge_th_back)),
                if (side == "front") 0 else 1, Modifier.fillMaxWidth()) { side = if (it == 0) "front" else "back" }
            ForgeBodyMap(if (ProfileStore.from(context).sex == "female") "female" else "male", side, fills,
                Modifier.fillMaxWidth().height(ForgeMetrics.chartHeight), e.title)
        }
        OverlineHeader(stringResource(R.string.forge_library_how), stringResource(R.string.forge_library_instructions))
        ForgeCard(Modifier.fillMaxWidth()) {
            if (d.instructions.isEmpty()) ReportNote(stringResource(R.string.forge_library_no_instructions))
            d.instructions.forEachIndexed { index, text ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
                    Text((index + 1).toString(), style = Forge.type.headline, color = Forge.colors.accent)
                    Text(text, style = Forge.type.subhead, color = Forge.colors.text, modifier = Modifier.weight(1f))
                }
            }
        }
        OverlineHeader(stringResource(R.string.forge_library_your_history), stringResource(R.string.forge_library_this_exercise))
        ForgeCard(Modifier.fillMaxWidth()) {
            if (d.records.sessions == 0) ReportNote(stringResource(R.string.forge_library_no_history))
            else {
                ReportFact(stringResource(R.string.forge_report_sessions), d.records.sessions.toString())
                d.records.heaviestKg?.let { ReportFact(stringResource(R.string.forge_library_heaviest), UnitFormatter.massFromKilograms(it, units)) }
                d.records.estimatedOneRepMaxKg?.let {
                    ReportFact(stringResource(R.string.forge_report_best_e1rm), UnitFormatter.massFromKilograms(it, units))
                    ReportNote(stringResource(R.string.forge_library_estimate_note))
                }
                d.recent.forEach { recent ->
                    ReportFact(sessionDate(recent.startTs), stringResource(R.string.forge_library_sets, recent.workingSets))
                    if (!recent.isNative) ReportNote(stringResource(R.string.forge_library_imported))
                    recent.heaviestKg?.let { ReportNote(UnitFormatter.massFromKilograms(it, units)) }
                }
            }
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            ReportHeading(stringResource(R.string.forge_library_content_source))
            ReportNote(librarySourceName(e.source))
            ReportNote(stringResource(when (e.source) {
                "user" -> R.string.forge_library_user_source
                "exercise_db" -> R.string.forge_library_provider_source
                "imported" -> R.string.forge_library_import_source
                else -> R.string.forge_library_noop_source
            }))
            d.attribution?.let { ReportNote(it) }
        }
        if (onPick != null) Button(onClick = onPick, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.forge_library_add)) }
        else if (d.hasDraft && onAdded != null) Button(enabled = !adding, modifier = Modifier.fillMaxWidth(), onClick = {
            scope.launch {
                adding = true
                val saved = withContext(Dispatchers.IO) { CoreTraining.addExercise(id) != null }
                adding = false
                if (saved) onAdded() else failed = true
            }
        }) { Text(stringResource(R.string.forge_library_add_workout)) }
        if (failed) ReportNote(stringResource(R.string.forge_library_add_failed))
        Spacer(Modifier.height(ForgeMetrics.space4))
    }
}

@Composable
private fun CustomExercisePage(catalog: CoreTrainingLibrary.Catalog, onClose: () -> Unit, onCreated: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var title by rememberSaveable { mutableStateOf("") }
    var mode by rememberSaveable { mutableStateOf("weight_reps") }
    var primary by rememberSaveable { mutableStateOf("chest") }
    var equipment by rememberSaveable { mutableStateOf("") }
    var instructions by rememberSaveable { mutableStateOf("") }
    var unilateral by rememberSaveable { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    BackHandler { if (!saving) onClose() }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_library_new), onBack = { if (!saving) onClose() })
        ForgeCard(Modifier.fillMaxWidth()) {
            OutlinedTextField(title, { title = it }, label = { Text(stringResource(R.string.forge_library_name)) }, enabled = !saving, modifier = Modifier.fillMaxWidth())
            ReportNote(stringResource(R.string.forge_library_tracking))
            if (!saving) ReportPicker(measurementName(mode), catalog.modes.map { measurementName(it) }) {
                mode = catalog.modes[it]
                if (mode == "duration" || mode == "distance_duration") unilateral = false
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.forge_library_unilateral), style = Forge.type.subhead, color = Forge.colors.text, modifier = Modifier.weight(1f))
                Switch(unilateral, { unilateral = it }, enabled = !saving && mode != "duration" && mode != "distance_duration")
            }
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            ReportNote(stringResource(R.string.forge_report_primary_muscle))
            if (!saving) ReportPicker(muscleName(primary), catalog.muscles.map { muscleName(it) }) { primary = catalog.muscles[it] }
            OutlinedTextField(equipment, { equipment = it }, label = { Text(stringResource(R.string.forge_library_equipment_optional)) }, enabled = !saving, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(instructions, { instructions = it }, label = { Text(stringResource(R.string.forge_library_instruction_optional)) }, enabled = !saving, modifier = Modifier.fillMaxWidth())
            ReportNote(stringResource(R.string.forge_library_custom_local))
        }
        if (failed) ReportNote(stringResource(R.string.forge_library_save_failed))
        Button(enabled = !saving && title.isNotBlank(), modifier = Modifier.fillMaxWidth(), onClick = {
            scope.launch {
                saving = true
                val id = withContext(Dispatchers.IO) { CoreTrainingLibrary.create(title, mode, primary, equipment, instructions, unilateral) }
                saving = false
                if (id != null) onCreated(id) else failed = true
            }
        }) { Text(stringResource(R.string.forge_report_save)) }
        if (saving) LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}

@Composable
private fun AvailableEquipmentDialog(equipment: List<String>, saved: Set<String>, onDismiss: () -> Unit,
                                     onSave: (Set<String>) -> Unit) {
    var selected by remember(saved) { mutableStateOf(saved) }
    AlertDialog(onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.forge_library_available_equipment)) },
        text = { Column {
            ReportNote(stringResource(R.string.forge_library_equipment_help))
            LazyColumn(Modifier.heightIn(max = ForgeMetrics.chartHeight)) {
                items(equipment.filter { it != "bodyweight" }) { id ->
                    Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget).clickable {
                        selected = if (id in selected) selected - id else selected + id
                    }, verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(id in selected, onCheckedChange = null)
                        Text(equipmentName(id), style = Forge.type.subhead, color = Forge.colors.text)
                    }
                }
            }
        } },
        confirmButton = { TextButton(onClick = { onSave(selected) }) { Text(stringResource(R.string.forge_library_ok)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.forge_report_cancel)) } })
}
