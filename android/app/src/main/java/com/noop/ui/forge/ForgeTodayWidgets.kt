package com.noop.ui.forge

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.ChevronLeft
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.Flag
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material.icons.rounded.OpenInFull
import androidx.compose.material.icons.rounded.RemoveCircle
import androidx.compose.material.icons.rounded.WaterDrop
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.zIndex
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreRead
import com.noop.ui.AppViewModel
import com.noop.ui.KeyMetric
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.util.UUID

/**
 * Fork (DX23876), Forge parity 2026-11: Today's widgets in the new design, the twin of iOS's `ForgeTodayWidgets`.
 * Tiles between the hint and the timeline: a first set comes on its own, the wearer adds from a gallery, removes,
 * moves and resizes them in place. Measures are the Key Metrics tiles (`rememberKeyTiles`), so a widget never shows
 * a number differently from Key Metrics; wide widgets are the Today cards Android already draws.
 *
 * Kept as JSON under iOS's key, `forge.today.widgets`. Android carries the kinds it has cards for; iOS's other
 * kinds (water, last night, the week's plan, coach note, AgeLess, tonight, next session, what changed, what works,
 * breathe, strap) are listed in docs/fork/android/FORGE-PARITY.md.
 */
internal data class TodayWidget(
    val id: String = UUID.randomUUID().toString(),
    val kind: Kind,
    /** A measure's tile: a [KeyMetric.raw], or [SLEEP_KEY] for the latest night. */
    val key: String? = null,
    /** 2: a small tile over two columns. */
    val span: Int = 1,
    /** Live heart rate across the whole row instead of a tile. */
    val wide: Boolean = false,
) {
    enum class Kind(val raw: String) {
        Measure("measure"), TrainingLoad("trainingLoad"), Goals("goals"), Energy("energy"), LiveHeart("liveHeart"),
        Momentum("momentum"), LastWorkout("lastWorkout"), Cycle("cycle");
        companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
    }

    enum class Size { Small, Medium, Wide }

    val size: Size get() = when {
        kind != Kind.Measure && kind != Kind.LiveHeart -> Size.Wide
        kind == Kind.LiveHeart && wide -> Size.Wide
        span == 2 -> Size.Medium
        else -> Size.Small
    }

    val resizable: Boolean get() = kind == Kind.Measure || kind == Kind.LiveHeart

    /** One tap on the size control: small, two columns, the whole row where the kind has a card for it, small. */
    fun nextSize(): TodayWidget = when (size) {
        Size.Small -> copy(span = 2, wide = false)
        Size.Medium -> if (kind == Kind.LiveHeart) copy(span = 1, wide = true) else copy(span = 1, wide = false)
        Size.Wide -> copy(span = 1, wide = false)
    }

    companion object {
        const val SLEEP_KEY = "sleep_total_min"
    }
}

/** The widget list's pure rules: the first set, moving, and how the tiles fill rows. */
internal object TodayWidgets {
    const val KEY = "forge.today.widgets"
    private const val SEEDED_KEY = "forge.today.widgetsSeeded"

    /** iOS's first set (hrv, rhr, steps, sleep, stress, weight) without stress, which Android has no tile for. */
    val firstSet: List<TodayWidget> = listOf(KeyMetric.HRV.raw, KeyMetric.RESTING_HR.raw, KeyMetric.STEPS.raw,
                                             TodayWidget.SLEEP_KEY, KeyMetric.WEIGHT.raw)
        .map { TodayWidget(kind = TodayWidget.Kind.Measure, key = it) }

    /** The measures the gallery offers, in iOS's order where Android has the tile. */
    val measures: List<String> = listOf(KeyMetric.HRV.raw, KeyMetric.RESTING_HR.raw, KeyMetric.STEPS.raw,
                                        TodayWidget.SLEEP_KEY, KeyMetric.WEIGHT.raw, KeyMetric.BLOOD_OXYGEN.raw,
                                        KeyMetric.RESPIRATORY.raw, KeyMetric.SKIN_TEMP.raw, KeyMetric.CALORIES.raw,
                                        KeyMetric.CHARGE.raw, KeyMetric.EFFORT.raw, KeyMetric.REST.raw)

    fun encode(list: List<TodayWidget>): String = JSONArray(list.map { w ->
        JSONObject().put("id", w.id).put("kind", w.kind.raw).apply {
            w.key?.let { put("key", it) }
            if (w.span != 1) put("span", w.span)
            if (w.wide) put("wide", true)
        }
    }).toString()

    fun decode(raw: String?): List<TodayWidget> {
        if (raw.isNullOrEmpty()) return emptyList()
        return runCatching {
            val a = JSONArray(raw)
            (0 until a.length()).mapNotNull { i ->
                val o = a.getJSONObject(i)
                val kind = TodayWidget.Kind.of(o.optString("kind")) ?: return@mapNotNull null
                TodayWidget(o.optString("id").ifEmpty { UUID.randomUUID().toString() }, kind,
                            o.optString("key").ifEmpty { null }, o.optInt("span", 1), o.optBoolean("wide"))
            }
        }.getOrDefault(emptyList())
    }

    /** [id] taken out and put where [targetId] stands, the others closing up, as a drag drops it; unchanged if either is missing. */
    fun move(list: List<TodayWidget>, id: String, targetId: String): List<TodayWidget> {
        val from = list.indexOfFirst { it.id == id }
        val to = list.indexOfFirst { it.id == targetId }
        if (from < 0 || to < 0 || from == to) return list
        return list.toMutableList().also { it.add(to, it.removeAt(from)) }
    }

    /** [id] one place earlier (-1) or later (+1); the list unchanged at either end. */
    fun shift(list: List<TodayWidget>, id: String, by: Int): List<TodayWidget> {
        val from = list.indexOfFirst { it.id == id }
        val to = from + by
        if (from < 0 || to !in list.indices) return list
        return list.toMutableList().also { java.util.Collections.swap(it, from, to) }
    }

    /**
     * The rows the tiles fill in order, [columns] wide: a wide widget takes a row of its own, a medium one two
     * columns (the whole row on a two-column phone), and a tile that no longer fits starts the next row.
     */
    fun rows(list: List<TodayWidget>, columns: Int): List<List<TodayWidget>> {
        val out = mutableListOf<List<TodayWidget>>()
        var row = mutableListOf<TodayWidget>(); var used = 0
        fun flush() { if (row.isNotEmpty()) { out += row; row = mutableListOf(); used = 0 } }
        for (w in list) {
            val width = when (w.size) {
                TodayWidget.Size.Wide -> columns
                TodayWidget.Size.Medium -> minOf(2, columns)
                TodayWidget.Size.Small -> 1
            }
            if (used + width > columns) flush()
            row += w; used += width
            if (used >= columns) flush()
        }
        flush()
        return out
    }

    fun columnsOf(w: TodayWidget, columns: Int): Int = when (w.size) {
        TodayWidget.Size.Wide -> columns
        TodayWidget.Size.Medium -> minOf(2, columns)
        TodayWidget.Size.Small -> 1
    }

    internal fun load(context: Context): List<TodayWidget> {
        val prefs = context.getSharedPreferences(NoopPrefs.NAME, Context.MODE_PRIVATE)
        val stored = decode(prefs.getString(KEY, null))
        if (prefs.getBoolean(SEEDED_KEY, false)) return stored
        val seeded = firstSet + stored
        prefs.edit().putBoolean(SEEDED_KEY, true).putString(KEY, encode(seeded)).apply()
        return seeded
    }

    internal fun save(context: Context, list: List<TodayWidget>) {
        context.getSharedPreferences(NoopPrefs.NAME, Context.MODE_PRIVATE).edit().putString(KEY, encode(list)).apply()
    }
}

/**
 * The widget area: the tiles in rows, and while [editing] the editor's bar (Edit Today, Done), a remove and a size
 * control on each tile, moving by the arrows or the accessibility actions, and "Add a widget" opening the gallery.
 */
@Composable
internal fun ForgeTodayWidgetArea(model: TodayModel?, viewModel: AppViewModel, width: ForgeWidth, editing: Boolean,
                                  onEditing: (Boolean) -> Unit, onOpenTrainingLoad: () -> Unit) {
    val context = LocalContext.current
    val widgets = remember { mutableStateListOf<TodayWidget>().apply { addAll(TodayWidgets.load(context)) } }
    fun update(list: List<TodayWidget>) { widgets.clear(); widgets.addAll(list); TodayWidgets.save(context, list) }
    var gallery by remember { mutableStateOf(false) }
    // Moving by drag in edit mode, as iOS: hold a tile, drag it over another, let go to put it there.
    val bounds = remember { androidx.compose.runtime.mutableStateMapOf<String, androidx.compose.ui.geometry.Rect>() }
    var dragging by remember { mutableStateOf<String?>(null) }
    var dragOffset by remember { mutableStateOf(androidx.compose.ui.geometry.Offset.Zero) }
    fun drop() {
        val id = dragging ?: return
        val center = bounds[id]?.center?.plus(dragOffset)
        // Only tiles still placed: a removed tile's last bounds stay in the map and must not catch the drop.
        val placed = widgets.map { it.id }.toSet()
        val target = center?.let { c -> bounds.entries.firstOrNull { (k, r) -> k != id && k in placed && r.contains(c) }?.key }
        if (target != null) update(TodayWidgets.move(widgets, id, target))
        dragging = null; dragOffset = androidx.compose.ui.geometry.Offset.Zero
    }
    // Tiles per row as iOS: the choice shared with Key Metrics (`KeyMetricPrefs`, three until chosen), two at the
    // largest text sizes where three cut their figures off.
    var columnsChoice by remember {
        androidx.compose.runtime.mutableIntStateOf(com.noop.ui.KeyMetricPrefs.columns(com.noop.ui.KeyMetricPrefs.storedColumns(context) ?: 3))
    }
    val largeText = androidx.compose.ui.platform.LocalDensity.current.fontScale >= 1.3f
    val columns = if (largeText) minOf(columnsChoice, 2) else columnsChoice
    val metrics = remember(widgets.toList()) {
        widgets.mapNotNull { w -> w.key?.let { KeyMetric.fromRaw(it) } }.toSet()
    }
    val keyTiles = rememberKeyTiles(model, metrics, detailed = true, windowDays = 30)
    var open by remember { mutableStateOf<CoreRead.Metric?>(null) }
    val noData = stringResource(R.string.forge_no_data)
    val date = model?.date ?: com.noop.ui.logicalDayNow()
    // The latest night as the Sleep tab shows it, read only while a sleep tile is placed (iOS `withLatestNight`).
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val sleepMinutes by produceState<Double?>(null, date, widgets.any { it.key == TodayWidget.SLEEP_KEY }, coreRevision) {
        value = if (widgets.none { it.key == TodayWidget.SLEEP_KEY }) null else withContext(Dispatchers.IO) {
            val end = date.plusDays(1).atStartOfDay(java.time.ZoneId.systemDefault()).toEpochSecond()
            CoreRead.nights(end - 3 * 86_400, end).maxByOrNull { it.endTs }?.minutes
                ?.let { m -> (m["light"] ?: 0.0) + (m["deep"] ?: 0.0) + (m["rem"] ?: 0.0) }?.takeIf { it > 0 }
        }
    }

    // The cards' own headings (Training load, Goals, Momentum, Cycle) were written for the shipped Today, where they
    // sit on the scene; here they sit below the hero on the canvas, so they take the canvas ink, as iOS's section
    // titles take the text colour. Scene-white headings all but vanished on a light canvas.
    val colors = Forge.colors
    androidx.compose.runtime.CompositionLocalProvider(
        LocalSceneInk provides SceneInk(colors.text, colors.textSecondary, colors.textTertiary, colors.dark)) {
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        if (editing) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                // On its own plate: the bar sits on the scene picture or the canvas, depending on what is above it.
                Box(Modifier.weight(1f)) {
                    Text(stringResource(R.string.forge_w_edit_today), style = Forge.type.headline, color = Forge.colors.text,
                         modifier = Modifier.background(Forge.colors.surface, CircleShape)
                             .padding(horizontal = ForgeMetrics.space4, vertical = ForgeMetrics.space2))
                }
                Text(stringResource(R.string.forge_w_done), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                     color = Forge.colors.onDark,
                     modifier = Modifier.background(Forge.colors.accent, CircleShape)
                         .clickable(role = Role.Button) { onEditing(false) }
                         .padding(horizontal = ForgeMetrics.space4, vertical = ForgeMetrics.space2))
            }
        }
        if (editing) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.forge_lay_tiles_per_row), style = Forge.type.subhead, color = Forge.colors.text,
                     modifier = Modifier.weight(1f).background(Forge.colors.surface, CircleShape)
                         .padding(horizontal = ForgeMetrics.space4, vertical = ForgeMetrics.space2))
                Spacer(Modifier.size(ForgeMetrics.space2))
                val choices = com.noop.ui.KeyMetricPrefs.columnChoices
                ForgeSegmented(choices.map { it.toString() }, choices.indexOf(columnsChoice).coerceAtLeast(0),
                               Modifier.width(140.dp)) { i ->
                    columnsChoice = choices[i]; com.noop.ui.KeyMetricPrefs.setColumns(context, choices[i])
                }
            }
        }
        // As iOS's `shown`: outside editing, a widget with nothing to draw holds no row (the latest workout before
        // the first one); while editing it stays, so it can be moved or removed.
        val workouts by viewModel.workouts.collectAsState()
        val shown = if (editing) widgets.toList()
                    else widgets.filter { it.kind != TodayWidget.Kind.LastWorkout || com.noop.ui.lastWorkoutsFeed(workouts).isNotEmpty() }
        TodayWidgets.rows(shown, columns).forEach { row ->
            // The row holding the dragged tile draws over the others, so the tile stays on top wherever it goes.
            Row(Modifier.fillMaxWidth().zIndex(if (row.any { it.id == dragging }) 1f else 0f),
                horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
                row.forEach { w ->
                    val span = TodayWidgets.columnsOf(w, columns)
                    val lifted = dragging == w.id
                    WidgetCell(w, editing, Modifier.weight(span.toFloat()).zIndex(if (lifted) 1f else 0f)
                        .onGloballyPositioned { bounds[w.id] = it.boundsInRoot() }
                        .graphicsLayer {
                            if (lifted) { translationX = dragOffset.x; translationY = dragOffset.y; scaleX = 1.04f; scaleY = 1.04f }
                        }
                        .then(if (!editing) Modifier else Modifier.pointerInput(w.id) {
                            // Watched in the initial pass, ahead of the tile's own tap: a hold lifts the tile, and
                            // from then on every move is the drag's; a tap or a move before the hold stays the tile's.
                            awaitEachGesture {
                                val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                                val held = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
                                    while (true) {
                                        val e = awaitPointerEvent(PointerEventPass.Initial)
                                        val c = e.changes.firstOrNull { it.id == down.id } ?: break
                                        // A move after the hold time still counts as held, by the events' own clock.
                                        if (c.uptimeMillis - down.uptimeMillis >= viewConfiguration.longPressTimeoutMillis) return@withTimeoutOrNull null
                                        if (!c.pressed || (c.position - down.position).getDistance() > viewConfiguration.touchSlop) break
                                    }
                                } == null
                                if (!held) return@awaitEachGesture
                                dragging = w.id; dragOffset = androidx.compose.ui.geometry.Offset.Zero
                                while (true) {
                                    val e = awaitPointerEvent(PointerEventPass.Initial)
                                    val c = e.changes.firstOrNull { it.id == down.id } ?: break
                                    // Read before consuming: a consumed change reports no movement.
                                    dragOffset += c.positionChange()
                                    c.consume()
                                    if (!c.pressed) break
                                }
                                drop()
                            }
                        }),
                               onRemove = { bounds.remove(w.id); update(widgets.filter { it.id != w.id }) },
                               onSize = { update(widgets.map { if (it.id == w.id) it.nextSize() else it }) },
                               onShift = { by -> update(TodayWidgets.shift(widgets, w.id, by)) }) {
                        when (w.kind) {
                            TodayWidget.Kind.Measure -> MeasureTile(w.key, keyTiles, sleepMinutes, noData) { open = it }
                            TodayWidget.Kind.TrainingLoad -> TodayTrainingLoadForge(onOpenTrainingLoad)
                            TodayWidget.Kind.Goals -> TodayGoals()
                            TodayWidget.Kind.Energy -> TodayEnergy()
                            TodayWidget.Kind.LiveHeart -> HeartCard(viewModel, date, live = date == com.noop.ui.logicalDayNow())
                            TodayWidget.Kind.Momentum -> ForgeTodayMomentum(viewModel)
                            TodayWidget.Kind.LastWorkout -> TodayWorkoutsForge(viewModel)
                            TodayWidget.Kind.Cycle -> TodayCycleForge(viewModel)
                        }
                    }
                }
                val used = row.sumOf { TodayWidgets.columnsOf(it, columns) }
                if (used < columns) Spacer(Modifier.weight((columns - used).toFloat()))
            }
        }
        if (editing) {
            Row(Modifier.fillMaxWidth().clickable(role = Role.Button) { gallery = true }.padding(vertical = ForgeMetrics.space3),
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.AddCircle, contentDescription = null, tint = Forge.colors.accent)
                Spacer(Modifier.size(ForgeMetrics.space2))
                Text(stringResource(R.string.forge_w_add), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                     color = Forge.colors.accent)
            }
        }
    }
    }
    ForgeMetricDetail(open) { open = null }
    if (gallery) {
        ForgeOverlayPage(onDismiss = { gallery = false }) {
            WidgetGallery(placed = widgets.toList(), onAdd = { update(widgets + it); gallery = false },
                          onClose = { gallery = false })
        }
    }
}

@Composable
private fun WidgetCell(w: TodayWidget, editing: Boolean, modifier: Modifier, onRemove: () -> Unit, onSize: () -> Unit,
                       onShift: (Int) -> Unit, content: @Composable () -> Unit) {
    val removeLabel = stringResource(R.string.forge_w_remove)
    val sizeLabel = stringResource(R.string.forge_w_size)
    val earlier = stringResource(R.string.forge_w_earlier)
    val later = stringResource(R.string.forge_w_later)
    Box(modifier.semantics {
        if (editing) customActions = listOf(
            CustomAccessibilityAction(earlier) { onShift(-1); true },
            CustomAccessibilityAction(later) { onShift(1); true },
        )
    }) {
        content()
        if (editing) {
            // As iOS places them: remove in the top corner, the order and the size at the bottom, so the tile's name
            // stays readable. Each control keeps the full hit target around its small plate.
            EditButton(Icons.Rounded.RemoveCircle, removeLabel, onRemove, tint = Forge.colors.effort,
                       modifier = Modifier.align(Alignment.TopStart))
            Row(Modifier.align(Alignment.BottomEnd)) {
                EditButton(Icons.Rounded.ChevronLeft, earlier, onClick = { onShift(-1) })
                EditButton(Icons.Rounded.ChevronRight, later, onClick = { onShift(1) })
                if (w.resizable) EditButton(Icons.Rounded.OpenInFull, sizeLabel, onSize)
            }
        }
    }
}

@Composable
private fun EditButton(icon: ImageVector, label: String, onClick: () -> Unit,
                       tint: androidx.compose.ui.graphics.Color = Forge.colors.text, modifier: Modifier = Modifier) {
    Box(modifier.size(ForgeMetrics.minHitTarget).clickable(role = Role.Button, onClickLabel = label, onClick = onClick),
        contentAlignment = Alignment.Center) {
        Box(Modifier.size(32.dp).background(Forge.colors.surface, CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = label, tint = tint, modifier = Modifier.size(18.dp))
        }
    }
}

/** A measure's tile, from the same reading as Key Metrics; sleep reads the latest night as the Sleep tab does. */
@Composable
private fun MeasureTile(key: String?, keyTiles: KeyTiles, sleepMinutes: Double?, noData: String,
                        onOpen: (CoreRead.Metric) -> Unit) {
    if (key == TodayWidget.SLEEP_KEY) {
        MetricTile(Icons.Rounded.Bedtime, Forge.colors.rest, stringResource(R.string.forge_sleep),
                   sleepMinutes?.let { TodayTimeline.hoursMinutes(it) }, null, noData,
                   Modifier.fillMaxWidth().clickable { onOpen(CoreRead.Metric.SleepMinutes) })
        return
    }
    val metric = KeyMetric.fromRaw(key) ?: return
    val t = keyTiles.tiles[metric] ?: return
    val tint = metric.tileTint()
    MetricTile(metric.icon, tint, metric.tileLabel(), t.value, t.unit, noData,
               Modifier.fillMaxWidth().then(t.opens?.let { m -> Modifier.clickable { onOpen(m) } } ?: Modifier), t.delta,
               below = keyTiles.sparks[metric]?.let { values -> @Composable { KeyTileSpark(values, tint) } })
}

/** "Add a widget": the measures not placed yet, then the cards, each with its size and what it shows. */
@Composable
private fun WidgetGallery(placed: List<TodayWidget>, onAdd: (TodayWidget) -> Unit, onClose: () -> Unit) {
    val colors = Forge.colors
    val placedKeys = placed.mapNotNull { it.key }.toSet()
    val placedKinds = placed.map { it.kind }.toSet()
    ForgeSceneBackdrop(ForgeBackdrop.Sky) {
        Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState())
                   .padding(horizontal = ForgeMetrics.screenPadding),
               verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space4), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.forge_w_add), style = Forge.type.title2.copy(fontWeight = FontWeight.Bold),
                     color = colors.text, modifier = Modifier.weight(1f))
                Text(stringResource(R.string.forge_w_done), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                     color = colors.accent, modifier = Modifier.clickable(role = Role.Button, onClick = onClose)
                         .padding(ForgeMetrics.space2))
            }
            val measures = TodayWidgets.measures.filter { it !in placedKeys }
            if (measures.isNotEmpty()) {
                GalleryHeading(stringResource(R.string.forge_w_measures))
                ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
                    measures.forEachIndexed { i, key ->
                        if (i > 0) HubDivider()
                        val metric = KeyMetric.fromRaw(key)
                        val title = metric?.tileLabel() ?: stringResource(R.string.forge_sleep)
                        HubRow(metric?.icon ?: Icons.Rounded.Bedtime, metric?.tileTint() ?: colors.rest, title,
                               stringResource(R.string.forge_w_measure_sub)) {
                            onAdd(TodayWidget(kind = TodayWidget.Kind.Measure, key = key))
                        }
                    }
                }
            }
            val cards = listOf(
                Triple(TodayWidget.Kind.TrainingLoad, Icons.Rounded.BarChart, R.string.forge_w_training_load to R.string.forge_w_training_load_sub),
                Triple(TodayWidget.Kind.Goals, Icons.Rounded.Flag, R.string.forge_w_goals to R.string.forge_w_goals_sub),
                Triple(TodayWidget.Kind.Energy, Icons.Rounded.LocalFireDepartment, R.string.forge_w_energy to R.string.forge_w_energy_sub),
                Triple(TodayWidget.Kind.LastWorkout, Icons.Rounded.DirectionsRun, R.string.forge_w_last_workout to R.string.forge_w_last_workout_sub),
                Triple(TodayWidget.Kind.Cycle, Icons.Rounded.WaterDrop, R.string.forge_w_cycle to R.string.forge_w_cycle_sub),
                Triple(TodayWidget.Kind.Momentum, Icons.Rounded.Bolt, R.string.forge_w_momentum to R.string.forge_w_momentum_sub),
                Triple(TodayWidget.Kind.LiveHeart, Icons.Rounded.Favorite, R.string.forge_w_live_heart to R.string.forge_w_live_heart_sub),
            ).filter { it.first !in placedKinds }
            if (cards.isNotEmpty()) {
                GalleryHeading(stringResource(R.string.forge_w_cards))
                ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
                    cards.forEachIndexed { i, (kind, icon, texts) ->
                        if (i > 0) HubDivider()
                        HubRow(icon, colors.accent, stringResource(texts.first), stringResource(texts.second)) {
                            onAdd(TodayWidget(kind = kind))
                        }
                    }
                }
            }
            Spacer(Modifier.heightIn(min = ForgeMetrics.space8))
        }
    }
}

@Composable
private fun GalleryHeading(text: String) {
    Text(text, style = Forge.type.headline.copy(fontWeight = FontWeight.Bold), color = Forge.colors.text,
         modifier = Modifier.padding(top = ForgeMetrics.space2))
}
