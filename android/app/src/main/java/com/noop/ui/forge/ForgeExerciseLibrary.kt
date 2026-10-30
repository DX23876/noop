package com.noop.ui.forge


import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.rounded.AccessibilityNew
import androidx.compose.material.icons.rounded.AddBox
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.FilterAlt
import androidx.compose.material.icons.rounded.FilterList
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Route
import androidx.compose.material.icons.rounded.SportsGymnastics
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material.icons.rounded.UnfoldMore
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
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
    var mediaSettings by rememberSaveable { mutableStateOf(false) }
    var providerPage by rememberSaveable { mutableStateOf(false) }
    var filtersOpen by rememberSaveable { mutableStateOf(false) }
    var equipmentDialog by rememberSaveable { mutableStateOf(false) }
    var availablePayload by remember { mutableStateOf(prefs.getString(AVAILABLE_EQUIPMENT, "").orEmpty()) }
    val available = remember(availablePayload) { availablePayload.lineSequence().filter { it.isNotBlank() }.toSet() }
    var musclePicker by rememberSaveable { mutableStateOf(false) }
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
    BackHandler { when { creating -> creating = false; selected != null -> selected = null; musclePicker -> musclePicker = false; else -> onClose() } }
    if (providerPage) { ForgeExerciseProviderPage(onClose = { providerPage = false }, onImported = { providerPage = false; revision++ }); return }
    if (mediaSettings) { ForgeExerciseMediaSettings { mediaSettings = false; revision++ }; return }
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
    if (musclePicker) catalog?.let { cat ->
        ForgeExerciseMusclePicker(cat, onClose = { musclePicker = false }, onOpen = { selected = it },
            onPick = if (onPicked != null) ({ id: String -> choose(id) }) else null, picked = picked.toSet())
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
    val muscleLabels = c?.muscles.orEmpty().associateWith { muscleName(it) }
    val equipmentLabels = c?.equipment.orEmpty().associateWith { equipmentName(it) }
    val shown = remember(c, query, region, muscle, equipment, mode, favoritesOnly, favorites, muscleLabels, equipmentLabels) {
        ExerciseLibraryFilters(query, region, muscle, equipment, mode, favoritesOnly)
            .apply(c?.exercises.orEmpty(), favorites, muscleLabels, equipmentLabels, c?.availableExerciseIds.orEmpty().toSet())
    }
    val filtersActive = region != null || muscle != null || mode != null || equipment != null || favoritesOnly
    val favoriteRows = remember(c, favorites) { c?.exercises.orEmpty().filter { it.id in favorites } }
    val showFavorites = !favoritesOnly && favoriteRows.isNotEmpty() && query.isBlank() && !filtersActive
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
    LazyColumn(Modifier.fillMaxHeight().widthIn(max = ForgeMetrics.maxContentWidth).fillMaxWidth()
            .statusBarsPadding().navigationBarsPadding().imePadding(), contentPadding = PaddingValues(ForgeMetrics.screenPadding)) {
        section {
            // The title with the filter and "More" menus where iOS has them, in the navigation bar.
            PageTitle(stringResource(R.string.forge_library_title), onClose) {
                if (multiple && picked.isNotEmpty()) {
                    TextButton(onClick = { onPicked?.invoke(picked.toList()) }) {
                        Text(stringResource(R.string.forge_training_selected, picked.size), color = Forge.colors.accent)
                    }
                }
                IconButton(onClick = { filtersOpen = true }, enabled = c != null) {
                    Icon(if (filtersActive) Icons.Rounded.FilterAlt else Icons.Rounded.FilterList,
                         stringResource(R.string.forge_library_filter), tint = Forge.colors.accent)
                }
                Box {
                    var more by remember { mutableStateOf(false) }
                    IconButton(onClick = { more = true }) {
                        Icon(Icons.Rounded.MoreHoriz, stringResource(R.string.forge_library_more), tint = Forge.colors.accent)
                    }
                    DropdownMenu(more, { more = false }) {
                        if (onPicked == null) {
                            DropdownMenuItem({ Text(stringResource(R.string.forge_library_new)) }, { more = false; creating = true })
                            DropdownMenuItem({ Text(stringResource(R.string.forge_provider_title)) }, { more = false; providerPage = true })
                            DropdownMenuItem({ Text(stringResource(R.string.forge_library_import)) }, enabled = !importing,
                                onClick = { more = false; importer.launch(arrayOf("application/json", "text/plain")) })
                        }
                        DropdownMenuItem({ Text(stringResource(R.string.forge_media_title)) }, { more = false; mediaSettings = true })
                    }
                }
            }
        }
        section {
            OutlinedTextField(query, { query = it }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                placeholder = { Text(stringResource(R.string.forge_library_search)) },
                leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null) }, colors = forgeFieldColors(Forge.colors.surface),
                shape = RoundedCornerShape(ForgeMetrics.groupedRadius))
        }
        if (!loaded || importing) section { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        if (loaded && c == null) section { ForgeCard(Modifier.fillMaxWidth()) {
            ReportNote(stringResource(R.string.forge_library_unavailable))
            TextButton(onClick = { revision++ }) { Text(stringResource(R.string.forge_report_retry)) }
        } }
        if (c != null) {
            section {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                    item { LibraryChip(region == null && !favoritesOnly, { region = null; favoritesOnly = false }, stringResource(R.string.forge_report_all)) }
                    if (favorites.isNotEmpty()) item {
                        LibraryChip(favoritesOnly, { favoritesOnly = !favoritesOnly }, stringResource(R.string.forge_library_favorites), Icons.Rounded.Star)
                    }
                    items(c.regions) { id -> LibraryChip(region == id, { region = if (region == id) null else id }, regionName(id)) }
                }
            }
            section {
                val equipmentIds = (if (available.isNotEmpty()) listOf("available") else emptyList()) + c.equipment
                LazyRow(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                    item { LibraryChip(equipment == null, { equipment = null }, stringResource(R.string.forge_library_any_equipment)) }
                    items(equipmentIds) { id ->
                        LibraryChip(equipment == id, { equipment = id },
                            if (id == "available") stringResource(R.string.forge_library_my_equipment) else equipmentLabels[id] ?: id)
                    }
                }
            }
            section { ExerciseMediaCard { mediaSettings = true } }
            section {
                GroupedRows(listOfNotNull<Pair<ImageVector, Pair<String, () -> Unit>>>(
                    Icons.Rounded.AccessibilityNew to (stringResource(R.string.forge_library_find_muscle) to { musclePicker = true }),
                    if (onPicked == null) Icons.Rounded.AddBox to (stringResource(R.string.forge_library_create_own) to { creating = true }) else null,
                ))
            }
            if (showFavorites) {
                section { LibrarySectionTitle(stringResource(R.string.forge_library_favorites)) }
                itemsIndexed(favoriteRows, key = { _, row -> "fav-" + row.id }) { index, row ->
                    LibraryRow(row, libraryMetadata(row, muscleLabels, equipmentLabels), true, index, favoriteRows.size,
                        onOpen = { selected = row.id }, onPick = if (onPicked != null) ({ choose(row.id) }) else null,
                        picked = row.id in picked)
                }
            }
            section { LibrarySectionTitle(stringResource(R.string.forge_library_all_exercises), stringResource(R.string.forge_library_count, shown.size)) }
            if (shown.isEmpty()) section { ForgeCard(Modifier.fillMaxWidth()) {
                ReportHeading(stringResource(R.string.forge_library_no_match))
                ReportNote(stringResource(R.string.forge_library_try_another))
            } }
            itemsIndexed(shown, key = { _, row -> row.id }) { index, row ->
                LibraryRow(row, libraryMetadata(row, muscleLabels, equipmentLabels), row.id in favorites, index, shown.size,
                    onOpen = { selected = row.id }, onPick = if (onPicked != null) ({ choose(row.id) }) else null,
                    picked = row.id in picked)
            }
            section { Spacer(Modifier.height(ForgeMetrics.space3)) }
            section { ForgeCard(Modifier.fillMaxWidth()) {
                ReportHeading(stringResource(R.string.forge_library_content_source))
                ReportNote("${c.provider} · ${c.licence}")
                c.attribution?.let { ReportNote(it) }
            } }
        }
        section { Spacer(Modifier.height(ForgeMetrics.tabBarClearance)) }
    }
    }
    if (filtersOpen && c != null) LibraryFilterSheet(c, region, muscle, mode, filtersActive, muscleLabels,
        onRegion = { region = it }, onMuscle = { muscle = it }, onMode = { mode = it },
        onAvailableEquipment = { filtersOpen = false; equipmentDialog = true },
        onClear = { region = null; muscle = null; equipment = null; mode = null; favoritesOnly = false },
        onDismiss = { filtersOpen = false })
}

/** A list item that keeps the section gap below itself; rows of one grouped card are plain items and sit flush. */
internal fun LazyListScope.section(content: @Composable () -> Unit) =
    item { Box(Modifier.fillMaxWidth().padding(bottom = ForgeMetrics.space2)) { content() } }

/** iOS's `filterChips`: a filled capsule when chosen, a quiet raised one otherwise, never an outline. */
@Composable
private fun LibraryChip(selected: Boolean, onClick: () -> Unit, label: String, icon: ImageVector? = null) {
    val colors = Forge.colors
    Row(Modifier.clip(CircleShape).background(if (selected) colors.accent else colors.surface)
            .clickable(role = Role.Tab, onClick = onClick).padding(horizontal = 12.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        val tint = if (selected) Color.White else colors.textSecondary
        icon?.let { Icon(it, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp)) }
        Text(label, style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = tint, maxLines = 1)
    }
}

@Composable
internal fun LibrarySectionTitle(title: String, trailing: String? = null) {
    Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space2, start = 4.dp, end = 4.dp), verticalAlignment = Alignment.Bottom) {
        Text(title.uppercase(), style = Forge.type.overline, color = Forge.colors.textTertiary, modifier = Modifier.weight(1f))
        trailing?.let { Text(it, style = Forge.type.caption, color = Forge.colors.textTertiary) }
    }
}

/** The shape of row [index] of [count] in one grouped card, as an inset grouped list draws it. */
internal fun groupedShape(index: Int, count: Int): RoundedCornerShape {
    val r = ForgeMetrics.groupedRadius
    return when {
        count == 1 -> RoundedCornerShape(r)
        index == 0 -> RoundedCornerShape(topStart = r, topEnd = r)
        index == count - 1 -> RoundedCornerShape(bottomStart = r, bottomEnd = r)
        else -> RoundedCornerShape(0.dp)
    }
}

/** "Find by muscle" and "Create your own exercise": one grouped card of tappable rows with their icons. */
@Composable
private fun GroupedRows(rows: List<Pair<ImageVector, Pair<String, () -> Unit>>>) {
    val colors = Forge.colors
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(ForgeMetrics.groupedRadius)).background(colors.surface)) {
        rows.forEachIndexed { index, (icon, entry) ->
            if (index > 0) Box(Modifier.padding(start = 52.dp).fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider.copy(alpha = 0.4f)))
            Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget).clickable(role = Role.Button, onClick = entry.second)
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Icon(icon, contentDescription = null, tint = colors.accent, modifier = Modifier.size(22.dp))
                Text(entry.first, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.accent)
            }
        }
    }
}

/** The row's second line (`ExerciseLibraryRow.metadata`): main muscle and first equipment. */
@Composable
internal fun libraryMetadata(row: CoreTrainingLibrary.Row, muscles: Map<String, String>, equipment: Map<String, String>): String {
    val muscle = row.primaryMuscle?.let { muscles[it] ?: muscleName(it) } ?: ""
    val tool = row.equipment.firstOrNull()?.let { equipment[it] ?: equipmentName(it) } ?: stringResource(R.string.forge_library_no_equipment)
    return listOf(muscle, tool).filter { it.isNotBlank() }.joinToString(" · ")
}

/** The measurement's symbol on its tinted tile when there is no media (`ExerciseLibraryRow.modeIcon`). */
private fun modeIcon(mode: String): ImageVector = when (mode) {
    "duration", "weight_duration" -> Icons.Rounded.Timer
    "distance_duration", "distance_weight" -> Icons.Rounded.Route
    "bodyweight_reps", "repetitions" -> Icons.Rounded.SportsGymnastics
    else -> Icons.Rounded.FitnessCenter
}

/** One exercise as `ExerciseLibraryRow` draws it, a segment of the grouped card it belongs to. */
@Composable
internal fun LibraryRow(row: CoreTrainingLibrary.Row, subtitle: String, favorite: Boolean, index: Int, count: Int,
                        onOpen: () -> Unit, onPick: (() -> Unit)?, picked: Boolean = false) {
    val colors = Forge.colors
    Column(Modifier.fillMaxWidth().clip(groupedShape(index, count)).background(colors.surface)) {
        if (index > 0) Box(Modifier.padding(start = 76.dp).fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider.copy(alpha = 0.4f)))
        Row(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen).padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.size(48.dp).clip(RoundedCornerShape(10.dp)).background(colors.accent.copy(alpha = 0.10f)),
                contentAlignment = Alignment.Center) {
                Icon(modeIcon(row.mode), contentDescription = null, tint = colors.accent, modifier = Modifier.size(22.dp))
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(row.title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
                Text(subtitle, style = Forge.type.caption, color = colors.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (favorite) Icon(Icons.Rounded.Star, stringResource(R.string.forge_library_favorites),
                tint = ForgeTokens.Color.systemYellow.resolve(), modifier = Modifier.size(16.dp))
            if (onPick != null) {
                Row(Modifier.clip(CircleShape).background(colors.accent.copy(alpha = 0.14f)).clickable(role = Role.Button, onClick = onPick)
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(if (picked) Icons.Rounded.Check else Icons.Rounded.AddCircle, contentDescription = null,
                         tint = colors.accent, modifier = Modifier.size(14.dp))
                    Text(stringResource(R.string.forge_library_add), style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold),
                         color = colors.accent)
                }
            } else {
                Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(16.dp))
            }
        }
    }
}

/** iOS's `ExerciseMediaDownloadCard`: the optional animation pack, offered until it is installed, disabled or hidden. */
@Composable
private fun ExerciseMediaCard(onOpen: () -> Unit) {
    val context = LocalContext.current
    val prefs = remember(context) { NoopPrefs.of(context) }
    var dismissed by remember { mutableStateOf(prefs.getBoolean(MEDIA_BANNER_DISMISSED, false)) }
    var info by remember { mutableStateOf<com.noop.core.CoreExerciseMedia.Info?>(null) }
    LaunchedEffect(Unit) { info = withContext(Dispatchers.IO) { com.noop.core.CoreExerciseMedia.info(context) } }
    val i = info ?: return
    if (dismissed || i.state == "ready" || i.disabled || i.withdrawn) return
    val colors = Forge.colors
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(ForgeMetrics.groupedRadius)).background(colors.surface).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Rounded.FitnessCenter, contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
            Text(stringResource(R.string.forge_library_animations), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = colors.text, modifier = Modifier.weight(1f))
            Icon(Icons.Rounded.Close, stringResource(R.string.forge_library_hide), tint = colors.textTertiary,
                 modifier = Modifier.size(18.dp).clickable(role = Role.Button) {
                     dismissed = true; prefs.edit().putBoolean(MEDIA_BANNER_DISMISSED, true).apply()
                 })
        }
        when (i.state) {
            "downloading", "installing" -> LinearProgressIndicator({ i.progress ?: 0f }, Modifier.fillMaxWidth())
            else -> Text(stringResource(R.string.forge_library_animations_text), style = Forge.type.caption, color = colors.textSecondary)
        }
        Row(Modifier.clickable(role = Role.Button, onClick = onOpen), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Rounded.Download, contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
            Text(stringResource(R.string.forge_media_download) + " · " +
                     android.text.format.Formatter.formatShortFileSize(context, i.provider.approximateBytes),
                 style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.accent)
        }
    }
}

@Composable
private fun FilterDivider() = Box(Modifier.fillMaxWidth().height(ForgeMetrics.hairline).background(Forge.colors.divider.copy(alpha = 0.4f)))

/** One line of iOS's filter menu: the facet on the left, its value on the right, the choices in a menu. */
@Composable
private fun FilterRow(label: String, value: String?, any: String, choices: List<Pair<String, String>>, onPick: (String?) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget).clickable(role = Role.Button) { open = true }
                .padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(label, style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
            Text(value ?: any, style = Forge.type.body, color = if (value != null) Forge.colors.accent else Forge.colors.textSecondary,
                 maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 200.dp))
            Spacer(Modifier.width(4.dp))
            Icon(Icons.Rounded.UnfoldMore, contentDescription = null, tint = Forge.colors.textTertiary, modifier = Modifier.size(16.dp))
        }
        DropdownMenu(open, { open = false }, Modifier.heightIn(max = 420.dp)) {
            DropdownMenuItem({ Text(any) }, { open = false; onPick(null) },
                trailingIcon = if (value == null) ({ Icon(Icons.Rounded.Check, null, tint = Forge.colors.accent) }) else null)
            choices.forEach { (id, name) ->
                DropdownMenuItem({ Text(name) }, { open = false; onPick(id) },
                    trailingIcon = if (value == name) ({ Icon(Icons.Rounded.Check, null, tint = Forge.colors.accent) }) else null)
            }
        }
    }
}

private const val MEDIA_BANNER_DISMISSED = "training.exerciseMedia.bannerDismissed"

/** iOS's filter menu: body region, muscle and type, then clear; the equipment chips sit on the page itself. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LibraryFilterSheet(c: CoreTrainingLibrary.Catalog, region: String?, muscle: String?, mode: String?, active: Boolean,
                               muscleLabels: Map<String, String>, onRegion: (String?) -> Unit, onMuscle: (String?) -> Unit,
                               onMode: (String?) -> Unit, onAvailableEquipment: () -> Unit, onClear: () -> Unit, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Forge.colors.canvas) {
        Column(Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.screenPadding).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Text(stringResource(R.string.forge_library_filter), style = Forge.type.headline, color = Forge.colors.text)
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(ForgeMetrics.groupedRadius)).background(Forge.colors.surface)
                    .padding(horizontal = 16.dp)) {
                FilterRow(stringResource(R.string.forge_library_region), region?.let { regionName(it) },
                    stringResource(R.string.forge_library_any_region), c.regions.map { it to regionName(it) }, onRegion)
                FilterDivider()
                FilterRow(stringResource(R.string.forge_library_muscle), muscle?.let { muscleLabels[it] ?: it },
                    stringResource(R.string.forge_library_any_muscle), c.muscles.map { it to (muscleLabels[it] ?: it) }, onMuscle)
                FilterDivider()
                FilterRow(stringResource(R.string.forge_library_type), mode?.let { measurementName(it) },
                    stringResource(R.string.forge_library_any_type), c.modes.map { it to measurementName(it) }, onMode)
                FilterDivider()
                LinkRow(stringResource(R.string.forge_library_available_equipment), null, onAvailableEquipment)
            }
            if (active) TextButton(onClick = { onClear(); onDismiss() }) {
                Text(stringResource(R.string.forge_library_clear_filters), color = Forge.colors.accent)
            }
        }
    }
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
        ForgeLocalExerciseMedia(e.id, e.title)
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
            OutlinedTextField(title, { title = it }, label = { Text(stringResource(R.string.forge_library_name)) }, enabled = !saving, modifier = Modifier.fillMaxWidth(), colors = forgeFieldColors())
            ReportNote(stringResource(R.string.forge_library_tracking))
            if (!saving) ReportPicker(measurementName(mode), catalog.modes.map { measurementName(it) }) {
                mode = catalog.modes[it]
                if (mode == "duration" || mode == "distance_duration") unilateral = false
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.forge_library_unilateral), style = Forge.type.subhead, color = Forge.colors.text, modifier = Modifier.weight(1f))
                Switch(unilateral, { unilateral = it }, colors = forgeSwitchColors(), enabled = !saving && mode != "duration" && mode != "distance_duration")
            }
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            ReportNote(stringResource(R.string.forge_report_primary_muscle))
            if (!saving) ReportPicker(muscleName(primary), catalog.muscles.map { muscleName(it) }) { primary = catalog.muscles[it] }
            OutlinedTextField(equipment, { equipment = it }, label = { Text(stringResource(R.string.forge_library_equipment_optional)) }, enabled = !saving, modifier = Modifier.fillMaxWidth(), colors = forgeFieldColors())
            OutlinedTextField(instructions, { instructions = it }, label = { Text(stringResource(R.string.forge_library_instruction_optional)) }, enabled = !saving, modifier = Modifier.fillMaxWidth(), colors = forgeFieldColors())
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
