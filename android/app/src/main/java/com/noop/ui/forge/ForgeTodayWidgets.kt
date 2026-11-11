package com.noop.ui.forge

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.Air
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.BatteryFull
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.ChevronLeft
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.Flag
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material.icons.rounded.OpenInFull
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.WaterDrop
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.toSize
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
        Momentum("momentum"), LastWorkout("lastWorkout"), Cycle("cycle"), LastNight("lastNight"),
        Tonight("tonight"), WeekPlan("weekPlan"), Breathe("breathe"), Strap("strap"), NextSession("nextSession"), WhatWorks("whatWorks"),
        Changes("changes");
        companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
    }

    enum class Size { Small, Medium, Wide }

    val size: Size get() = when {
        kind != Kind.Measure && kind != Kind.LiveHeart && kind != Kind.Breathe && kind != Kind.Strap -> Size.Wide
        kind == Kind.LiveHeart && wide -> Size.Wide
        span == 2 -> Size.Medium
        else -> Size.Small
    }

    val resizable: Boolean get() = kind == Kind.Measure || kind == Kind.LiveHeart || kind == Kind.Breathe || kind == Kind.Strap

    /** Drawn as a tile in a row (iOS's non-wide kinds), so its row takes the tallest tile's height. */
    val isTile: Boolean get() = size != Size.Wide

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

    /**
     * Every card kind once, for emulator comparisons in a debug build, as iOS's `--demo-widgets` seeds its
     * gallery (same order where Android has the card). Started with `--ez demo_widgets true`; replaces the list.
     */
    const val DEMO_EXTRA = "demo_widgets"
    val demoSet: List<TodayWidget> = listOf(
        TodayWidget(kind = TodayWidget.Kind.Tonight), TodayWidget(kind = TodayWidget.Kind.NextSession),
        TodayWidget(kind = TodayWidget.Kind.Changes), TodayWidget(kind = TodayWidget.Kind.WhatWorks),
        TodayWidget(kind = TodayWidget.Kind.Breathe),
        TodayWidget(kind = TodayWidget.Kind.Strap), TodayWidget(kind = TodayWidget.Kind.Cycle),
        TodayWidget(kind = TodayWidget.Kind.Measure, key = KeyMetric.HRV.raw),
        TodayWidget(kind = TodayWidget.Kind.Measure, key = KeyMetric.RESTING_HR.raw),
        TodayWidget(kind = TodayWidget.Kind.Energy), TodayWidget(kind = TodayWidget.Kind.LastWorkout),
        TodayWidget(kind = TodayWidget.Kind.Momentum), TodayWidget(kind = TodayWidget.Kind.LastNight),
        TodayWidget(kind = TodayWidget.Kind.WeekPlan), TodayWidget(kind = TodayWidget.Kind.Goals),
        TodayWidget(kind = TodayWidget.Kind.Measure, key = KeyMetric.WEIGHT.raw),
        TodayWidget(kind = TodayWidget.Kind.Measure, key = TodayWidget.SLEEP_KEY),
        TodayWidget(kind = TodayWidget.Kind.TrainingLoad),
    )

    internal fun seedDemoIfRequested(context: Context, intent: android.content.Intent?) {
        if (!com.noop.BuildConfig.DEBUG || intent?.getBooleanExtra(DEMO_EXTRA, false) != true) return
        context.getSharedPreferences(NoopPrefs.NAME, Context.MODE_PRIVATE).edit()
            .putBoolean(SEEDED_KEY, true).putString(KEY, encode(demoSet)).apply()
    }

    /** iOS's `showsTimelineKey` and `belowTimelineKey`: whether Today shows its timeline, and the tiles after it. */
    val showsTimeline = kotlinx.coroutines.flow.MutableStateFlow<Boolean?>(null)
    val belowTimeline = kotlinx.coroutines.flow.MutableStateFlow<Boolean?>(null)
    private const val SHOWS_TIMELINE_KEY = "forge.today.showsTimeline"
    private const val BELOW_TIMELINE_KEY = "forge.today.tilesBelowTimeline"

    internal fun loadLayout(context: Context) {
        val prefs = context.getSharedPreferences(NoopPrefs.NAME, Context.MODE_PRIVATE)
        if (showsTimeline.value == null) showsTimeline.value = prefs.getBoolean(SHOWS_TIMELINE_KEY, true)
        if (belowTimeline.value == null) belowTimeline.value = prefs.getBoolean(BELOW_TIMELINE_KEY, false)
    }

    internal fun setShowsTimeline(context: Context, on: Boolean) {
        showsTimeline.value = on
        context.getSharedPreferences(NoopPrefs.NAME, Context.MODE_PRIVATE).edit().putBoolean(SHOWS_TIMELINE_KEY, on).apply()
    }

    internal fun setBelowTimeline(context: Context, below: Boolean) {
        belowTimeline.value = below
        context.getSharedPreferences(NoopPrefs.NAME, Context.MODE_PRIVATE).edit().putBoolean(BELOW_TIMELINE_KEY, below).apply()
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
                                  onEditing: (Boolean) -> Unit, onOpenTrainingLoad: () -> Unit, onOpenSleep: () -> Unit = {},
                                  onOpenAlarms: () -> Unit = {}, onOpenTraining: () -> Unit = {},
                                  onOpenBreathe: () -> Unit = {}, onOpenStrap: () -> Unit = {},
                                  onOpenInsights: () -> Unit = {}, onOpenTrends: () -> Unit = {}) {
    val context = LocalContext.current
    val widgets = remember { mutableStateListOf<TodayWidget>().apply { addAll(TodayWidgets.load(context)) } }
    fun update(list: List<TodayWidget>) { widgets.clear(); widgets.addAll(list); TodayWidgets.save(context, list) }
    var gallery by remember { mutableStateOf(false) }
    // Moving by drag in edit mode, as iOS: hold a tile, drag it over another, let go to put it there.
    val bounds = remember { androidx.compose.runtime.mutableStateMapOf<String, androidx.compose.ui.geometry.Rect>() }
    var dragging by remember { mutableStateOf<String?>(null) }
    var dragOffset by remember { mutableStateOf(androidx.compose.ui.geometry.Offset.Zero) }
    // As iOS's drop delegate: a tile carried over another takes its place at once, so the board rearranges under the
    // finger. The lifted tile keeps following the finger: its offset moves by the distance its slot just moved.
    fun swapUnder() {
        val id = dragging ?: return
        val own = bounds[id] ?: return
        val center = own.center + dragOffset
        val placed = widgets.map { it.id }.toSet()
        val target = bounds.entries.firstOrNull { (k, r) -> k != id && k in placed && r.contains(center) } ?: return
        update(TodayWidgets.move(widgets, id, target.key))
        dragOffset -= target.value.topLeft - own.topLeft
        bounds[id] = target.value
    }
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
    val keyTiles = rememberKeyTiles(model, metrics, detailed = true, windowDays = 30, latestFallback = true)
    var open by remember { mutableStateOf<CoreRead.Metric?>(null) }
    val noData = stringResource(R.string.forge_no_data)
    val date = model?.date ?: com.noop.ui.logicalDayNow()
    // The latest night as the Sleep tab shows it, read only while a sleep tile is placed (iOS `withLatestNight`).
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    // The sleep tile's 30 nights, as iOS draws its trend.
    val sleepTrend by produceState(emptyList<Double>(), date, widgets.any { it.key == TodayWidget.SLEEP_KEY }, coreRevision) {
        value = if (widgets.none { it.key == TodayWidget.SLEEP_KEY }) emptyList() else withContext(Dispatchers.IO) {
            CoreRead.series(CoreRead.Metric.SleepMinutes, date.minusDays(29).toString(), date.toString()).map { it.value / 60 }
        }
    }
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
    // Arranging is watched on the whole area, not on one tile: a tile that trades places mid-drag moves to another
    // slot (or row), and a gesture on the tile itself would end there.
    var areaOrigin by remember { mutableStateOf(androidx.compose.ui.geometry.Offset.Zero) }
    Column(Modifier.onGloballyPositioned { areaOrigin = it.positionInRoot() }
            .then(if (!editing) Modifier else Modifier.pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    val at = down.position + areaOrigin
                    val placed = widgets.map { it.id }.toSet()
                    val id = bounds.entries.firstOrNull { (k, r) -> k in placed && r.contains(at) }?.key
                    if (id == null) return@awaitEachGesture
                    // A hold lifts the tile, and from then on every move is the drag's; a tap or a move before the hold
                    // stays the tile's (its remove and size controls).
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
                    dragging = id; dragOffset = androidx.compose.ui.geometry.Offset.Zero
                    while (true) {
                        val e = awaitPointerEvent(PointerEventPass.Initial)
                        val c = e.changes.firstOrNull { it.id == down.id } ?: break
                        // Read before consuming: a consumed change reports no movement.
                        dragOffset += c.positionChange()
                        c.consume()
                        if (!c.pressed) break
                        swapUnder()
                    }
                    drop()
                }
            }), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        if (editing) {
            // iOS's editor: one card with the title and Done, tiles per row, whether the timeline shows and where the
            // tiles start.
            val showsTimeline by TodayWidgets.showsTimeline.collectAsState()
            val belowTimeline by TodayWidgets.belowTimeline.collectAsState()
            ForgeCard(Modifier.fillMaxWidth(), radius = 14.dp, contentPadding = ForgeMetrics.space4) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.forge_w_edit_today), style = Forge.type.headline, color = Forge.colors.text,
                         modifier = Modifier.weight(1f))
                    Text(stringResource(R.string.forge_w_done), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                         color = Forge.colors.onDark,
                         modifier = Modifier.heightIn(min = 36.dp).background(Forge.colors.accent, CircleShape)
                             .clickable(role = Role.Button) { onEditing(false) }
                             .padding(horizontal = ForgeMetrics.space4, vertical = ForgeMetrics.space2))
                }
                Spacer(Modifier.height(ForgeMetrics.space3))
                Text(stringResource(R.string.forge_lay_tiles_per_row), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold),
                     color = Forge.colors.textSecondary)
                Spacer(Modifier.height(ForgeMetrics.space1))
                val choices = com.noop.ui.KeyMetricPrefs.columnChoices
                ForgeSegmented(choices.map { it.toString() }, choices.indexOf(columnsChoice).coerceAtLeast(0), Modifier.fillMaxWidth()) { i ->
                    columnsChoice = choices[i]; com.noop.ui.KeyMetricPrefs.setColumns(context, choices[i])
                }
                Spacer(Modifier.height(ForgeMetrics.space2))
                ToggleRow(stringResource(R.string.forge_w_show_timeline), null, showsTimeline != false) {
                    TodayWidgets.setShowsTimeline(context, it)
                }
                if (showsTimeline != false) {
                    Text(stringResource(R.string.forge_w_tiles_start), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold),
                         color = Forge.colors.textSecondary)
                    Spacer(Modifier.height(ForgeMetrics.space1))
                    ForgeSegmented(listOf(stringResource(R.string.forge_w_under_rings), stringResource(R.string.forge_w_after_timeline)),
                                   if (belowTimeline == true) 1 else 0, Modifier.fillMaxWidth()) { i ->
                        TodayWidgets.setBelowTimeline(context, i == 1)
                    }
                }
            }
        }
        // As iOS's `shown`: outside editing, a widget for something switched off holds no row; while editing it
        // stays, so it can be moved or removed.
        // The cycle only while tracking is on, as iOS's `shown` (cycleEnabled), not a set-up card for everyone.
        val cycleOn by viewModel.cycleTrackingEnabled.collectAsState()
        val shown = if (editing) widgets.toList()
                    else widgets.filter {
                        it.kind != TodayWidget.Kind.Cycle || cycleOn
                    }
        TodayWidgets.rows(shown, columns).forEach { row ->
            // The row holding the dragged tile draws over the others, so the tile stays on top wherever it goes.
            // A row of tiles is as tall as its tallest tile, as iOS draws it: every tile's surface fills the row.
            val tileRow = row.all { it.isTile }
            Row(Modifier.fillMaxWidth().then(if (tileRow) Modifier.height(IntrinsicSize.Max) else Modifier)
                    .zIndex(if (row.any { it.id == dragging }) 1f else 0f),
                horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
                row.forEach { w -> androidx.compose.runtime.key(w.id) {
                    val span = TodayWidgets.columnsOf(w, columns)
                    val lifted = dragging == w.id
                    WidgetCell(w, editing, Modifier.weight(span.toFloat()).then(if (tileRow) Modifier.fillMaxHeight() else Modifier)
                        .zIndex(if (lifted) 1f else 0f)
                        .onGloballyPositioned {
                            // Unclipped: a tile scrolled half out of view keeps its true place, as the finger reads it.
                            bounds[w.id] = androidx.compose.ui.geometry.Rect(it.positionInRoot(), it.size.toSize())
                        }
                        .graphicsLayer {
                            if (lifted) { translationX = dragOffset.x; translationY = dragOffset.y; scaleX = 1.04f; scaleY = 1.04f }
                        }
                        .then(if (!editing) Modifier.pointerInput(w.id) {
                            // Held, a tile starts the editor, as on iOS; a plain tap still opens its page.
                            awaitEachGesture {
                                val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                                val held = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
                                    while (true) {
                                        val e = awaitPointerEvent(PointerEventPass.Initial)
                                        val c = e.changes.firstOrNull { it.id == down.id } ?: break
                                        if (!c.pressed || (c.position - down.position).getDistance() > viewConfiguration.touchSlop) break
                                    }
                                } == null
                                if (!held) return@awaitEachGesture
                                onEditing(true)
                                // The finger's lift belongs to the hold, not to a tap on the tile.
                                while (true) {
                                    val e = awaitPointerEvent(PointerEventPass.Initial)
                                    val c = e.changes.firstOrNull { it.id == down.id } ?: break
                                    c.consume()
                                    if (!c.pressed) break
                                }
                            }
                        } else Modifier),
                               onRemove = { bounds.remove(w.id); update(widgets.filter { it.id != w.id }) },
                               onSize = { update(widgets.map { if (it.id == w.id) it.nextSize() else it }) },
                               onShift = { by -> update(TodayWidgets.shift(widgets, w.id, by)) }) {
                        when (w.kind) {
                            TodayWidget.Kind.Measure -> MeasureTile(w.key, keyTiles, sleepMinutes, sleepTrend, noData, dense = columns > 2, Modifier.fillMaxSize()) { open = it }
                            TodayWidget.Kind.TrainingLoad -> TodayTrainingLoadForge(onOpenTrainingLoad)
                            TodayWidget.Kind.Goals -> TodayGoals()
                            TodayWidget.Kind.Energy -> TodayEnergy()
                            TodayWidget.Kind.LiveHeart ->
                                if (w.size == TodayWidget.Size.Wide) HeartCard(viewModel, date, live = date == com.noop.ui.logicalDayNow())
                                else LiveHeartTile(viewModel, showsCurve = w.size == TodayWidget.Size.Medium, dense = columns > 2,
                                                   modifier = Modifier.fillMaxSize(), onOpen = { open = CoreRead.Metric.RestingHr })
                            TodayWidget.Kind.Momentum -> ForgeTodayMomentum(viewModel)
                            TodayWidget.Kind.LastWorkout -> TodayWorkoutsForge(viewModel)
                            TodayWidget.Kind.Cycle -> TodayCycleForge(viewModel)
                            TodayWidget.Kind.LastNight -> TodayLastNightForge(onOpenSleep)
                            TodayWidget.Kind.Tonight -> TodayTonightForge(viewModel, onOpenAlarms)
                            TodayWidget.Kind.WeekPlan -> TodayWeekPlanForge(viewModel, onOpenTraining)
                            TodayWidget.Kind.Breathe -> TodayBreatheTile(onOpenBreathe, dense = columns > 2, modifier = Modifier.fillMaxSize())
                            TodayWidget.Kind.NextSession -> TodayNextSessionForge(onOpenTraining)
                            TodayWidget.Kind.WhatWorks -> TodayWhatWorksForge(viewModel, onOpenInsights)
                            TodayWidget.Kind.Changes -> TodayChangesForge(onOpenTrends, viewModel.activeStrapId)
                            TodayWidget.Kind.Strap -> TodayStrapTile(viewModel, onOpenStrap, dense = columns > 2, modifier = Modifier.fillMaxSize())
                        }
                    }
                } }
                // As iOS: a short last row shares the width by span instead of leaving a hole; while arranging every row
                // keeps to the column grid, so a tile lines up with the slot it is carried to.
                val used = row.sumOf { TodayWidgets.columnsOf(it, columns) }
                if (used < columns && editing) Spacer(Modifier.weight((columns - used).toFloat()))
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
            // As iOS: remove in the top corner, size in the other; moving is by drag, and earlier and later stay as
            // the screen reader's actions above. Nothing sits on the figure or the curve.
            EditButton(Icons.Rounded.Remove, removeLabel, onRemove, tint = Forge.colors.textSecondary,
                       modifier = Modifier.align(Alignment.TopStart).offset((-10).dp, (-10).dp))
            if (w.resizable) EditButton(Icons.Rounded.OpenInFull, sizeLabel, onSize,
                                        modifier = Modifier.align(Alignment.TopEnd).offset(10.dp, (-10).dp))
        }
    }
}

@Composable
private fun EditButton(icon: ImageVector, label: String, onClick: () -> Unit,
                       tint: androidx.compose.ui.graphics.Color = Forge.colors.accent, modifier: Modifier = Modifier) {
    // As iOS draws them: a white glyph on a filled disc, grey to remove, the accent to resize.
    Box(modifier.size(ForgeMetrics.minHitTarget).clickable(role = Role.Button, onClickLabel = label, onClick = onClick),
        contentAlignment = Alignment.Center) {
        Box(Modifier.size(26.dp).background(tint, CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = label, tint = androidx.compose.ui.graphics.Color.White, modifier = Modifier.size(16.dp))
        }
    }
}

/**
 * A measure's tile, drawn as iOS's `ForgeMeasureWidget`: the figure from the same reading as Key Metrics, the change
 * against the wearer's usual and its colour from the shared core, the last 30 values as the trend. Sleep reads the
 * latest night as the Sleep tab does.
 */
@Composable
private fun MeasureTile(key: String?, keyTiles: KeyTiles, sleepMinutes: Double?, sleepTrend: List<Double>, noData: String,
                        dense: Boolean, modifier: Modifier, onOpen: (CoreRead.Metric) -> Unit) {
    if (key == TodayWidget.SLEEP_KEY) {
        ForgeTodayTile(Icons.Rounded.Bedtime, Forge.colors.rest, stringResource(R.string.forge_sleep),
                       sleepMinutes?.let { TodayTimeline.hoursMinutes(it) }, "h", null, noData, dense,
                       modifier.clickable { onOpen(CoreRead.Metric.SleepMinutes) }, trend = sleepTrend.takeLast(30))
        return
    }
    val metric = KeyMetric.fromRaw(key) ?: return
    val t = keyTiles.tiles[metric] ?: return
    val spark = keyTiles.sparks[metric]
    val change = rememberTileDelta(metric.catalogKey(), spark)
    ForgeTodayTile(metric.icon, metric.tileTint(), metric.tileLabel(), t.value, t.unit.orEmpty(), null, noData, dense,
                   modifier.then(t.opens?.let { m -> Modifier.clickable { onOpen(m) } } ?: Modifier),
                   delta = change?.text, deltaTone = change?.tone, trend = spark?.takeLast(30))
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
                Triple(TodayWidget.Kind.LastNight, Icons.Rounded.Bedtime, R.string.forge_w_last_night to R.string.forge_w_last_night_sub),
                Triple(TodayWidget.Kind.Tonight, Icons.Rounded.Bedtime, R.string.forge_w_tonight to R.string.forge_w_tonight_sub),
                Triple(TodayWidget.Kind.WeekPlan, Icons.Rounded.BarChart, R.string.forge_w_week_plan to R.string.forge_w_week_plan_sub),
                Triple(TodayWidget.Kind.Changes, Icons.Rounded.BarChart, R.string.forge_w_changes to R.string.forge_w_changes_sub),
                Triple(TodayWidget.Kind.WhatWorks, Icons.Rounded.Bolt, R.string.forge_w_what_works to R.string.forge_w_what_works_sub),
                Triple(TodayWidget.Kind.NextSession, Icons.Rounded.FitnessCenter, R.string.forge_w_next to R.string.forge_w_next_sub),
                Triple(TodayWidget.Kind.Breathe, Icons.Rounded.Air, R.string.forge_w_breathe to R.string.forge_w_breathe_sub),
                Triple(TodayWidget.Kind.Strap, Icons.Rounded.BatteryFull, R.string.forge_w_strap to R.string.forge_w_strap_sub),
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

/**
 * iOS's `ForgeLiveHeartWidget`: the heart rate right now while a strap streams one, else why there is none; over two
 * columns it also draws the pulse, the last minutes while streaming, today's banked trace otherwise.
 */
@Composable
private fun LiveHeartTile(viewModel: AppViewModel, showsCurve: Boolean, dense: Boolean, modifier: Modifier, onOpen: () -> Unit) {
    val context = LocalContext.current
    val live by viewModel.live.collectAsState()
    val bpm = live.heartRate?.takeIf { live.connected && it > 0 }
    val samples = remember { androidx.compose.runtime.mutableStateListOf<Double>() }
    LaunchedEffect(bpm, showsCurve) {
        if (!showsCurve || bpm == null) { samples.clear(); return@LaunchedEffect }
        samples.add(bpm.toDouble()); if (samples.size > 90) samples.removeAt(0)
    }
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val banked by produceState(emptyList<Double>(), showsCurve, coreRevision) {
        value = if (!showsCurve) emptyList() else withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val from = java.time.LocalDate.now().atStartOfDay(java.time.ZoneId.systemDefault()).toEpochSecond()
            CoreRead.heartRate(from, System.currentTimeMillis() / 1000).map { it.bpm }
        }
    }
    val curve = if (!showsCurve) null else (if (samples.size >= 2) samples.toList() else banked).takeIf { it.size >= 2 }
    val rose = ForgeTokens.StrandPalette.metricRose.resolve()
    ForgeTodayTile(Icons.Rounded.MonitorHeart, rose, stringResource(R.string.forge_live), bpm?.toString(), "bpm",
                   if (bpm == null) stringResource(if (live.connected) R.string.forge_w_waiting_pulse else R.string.forge_w_strap_not_connected) else null,
                   "", dense, modifier.clickable(onClick = onOpen), trend = curve)
}
