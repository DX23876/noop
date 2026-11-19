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
import androidx.compose.material.icons.rounded.Restaurant
import androidx.compose.material.icons.rounded.Mood
import androidx.compose.material.icons.rounded.Scale
import androidx.compose.material.icons.rounded.HourglassBottom
import androidx.compose.material.icons.rounded.Terrain
import androidx.compose.material.icons.automirrored.rounded.ShowChart
import androidx.compose.material.icons.rounded.Lightbulb
import androidx.compose.material.icons.rounded.ChatBubble
import androidx.compose.material.icons.rounded.CalendarMonth
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.foundation.Canvas
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreDietPlan
import com.noop.core.CoreEnergyPlan
import com.noop.core.CoreRead
import com.noop.core.CoreStress
import com.noop.core.CoreTile
import com.noop.analytics.SkinTempDisplay
import com.noop.ui.AppViewModel
import com.noop.ui.KeyMetric
import com.noop.ui.KeyMetricPrefs
import com.noop.ui.NoopPrefs
import com.noop.ui.UnitPrefs
import kotlin.math.roundToInt
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
    /**
     * Across the whole row instead of a tile. Null means "as this kind is placed": a card that can shrink
     * starts wide, so null must not read as small, or every tile placed before 2026-11-18 would have been
     * rearranged overnight.
     */
    val wide: Boolean? = null,
) {
    enum class Kind(val raw: String) {
        Measure("measure"), TrainingLoad("trainingLoad"), Goals("goals"), Energy("energy"), LiveHeart("liveHeart"),
        Momentum("momentum"), LastWorkout("lastWorkout"), Cycle("cycle"), LastNight("lastNight"),
        Tonight("tonight"), WeekPlan("weekPlan"), Breathe("breathe"), Strap("strap"), NextSession("nextSession"), WhatWorks("whatWorks"),
        Changes("changes"), Water("water"), CoachNote("coachNote"), AgeLess("ageless"), DietGoal("dietGoal"),
        /** The day's eating against its goal, with the macros (owner, 2026-11-18). */
        Nutrition("nutrition");
        companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
    }

    enum class Size { Small, Medium, Wide }

    /**
     * Whether this is one of the measures that exist only across the whole row, iOS's `wholeRowMeasures`:
     * Charge, Effort and Rest. The three rings stand directly above them and already say today's number,
     * so a small tile would be the same fact twice on one screen; across the row, with its thirty days,
     * the tile says something the rings do not.
     */
    val isWholeRowMeasure: Boolean get() = kind == Kind.Measure && key in WHOLE_ROW_MEASURES

    val size: Size get() = when {
        // Never Small: a card has two facts, not one, and two columns is where they fit.
        kind in SHRINKABLE_CARDS -> if (wide != false) Size.Wide else Size.Medium
        kind !in TILE_KINDS -> Size.Wide
        isWholeRowMeasure -> Size.Wide
        (kind == Kind.LiveHeart || kind == Kind.AgeLess || kind == Kind.Measure) && wide == true -> Size.Wide
        span == 2 -> Size.Medium
        else -> Size.Small
    }

    /** The narrow size a shrunk card is drawn at, or null while it is wide. */
    val compactSize: TileSize? get() = when (size) {
        Size.Wide -> null
        Size.Medium -> TileSize.Medium
        Size.Small -> TileSize.Small
    }

    /**
     * A whole-row measure answers false: it has one size, so a size control on it would be a button that
     * does nothing, and a control that does nothing says something untrue about the thing it sits on.
     */
    val resizable: Boolean get() = (kind in TILE_KINDS || kind in SHRINKABLE_CARDS) && !isWholeRowMeasure

    /** Drawn as a tile in a row (iOS's non-wide kinds), so its row takes the tallest tile's height. */
    val isTile: Boolean get() = size != Size.Wide

    /** One tap on the size control: small, two columns, the whole row where the kind has a card for it, small. */
    fun nextSize(): TodayWidget = when (size) {
        Size.Small -> copy(span = 2, wide = false)
        // A measure grows across the row too since 2026-11-18, where it draws its thirty days; a card that
        // can shrink returns to the width it was placed at.
        Size.Medium -> if (kind == Kind.LiveHeart || kind == Kind.AgeLess || kind == Kind.Measure ||
                           kind in SHRINKABLE_CARDS) copy(span = 1, wide = true)
                       else copy(span = 1, wide = false)
        // A card has only the two sizes, so its control goes back to two columns rather than to a small
        // form it does not have.
        Size.Wide -> if (kind in SHRINKABLE_CARDS) copy(span = 2, wide = false) else copy(span = 1, wide = false)
    }

    companion object {
        const val SLEEP_KEY = "sleep_total_min"
        /** Charge, Effort and Rest as the catalogue keys them; iOS's `wholeRowMeasures`. */
        val WHOLE_ROW_MEASURES = setOf("recovery", "strain", "sleep_performance")
        /**
         * Cards that can be drawn over TWO COLUMNS, each saying the two facts the owner's table gives it
         * (2026-11-19): last night's hours and its span, tonight's bedtime and its alarm, the latest
         * session's length and sport, the day's burn with its resting and active parts.
         *
         * Two columns, never one. A card has no change chip and no sparkline, so it can never meet the
         * floor a SMALL tile has to meet, and a single figure on a square was exactly what the owner
         * rejected the evening before. Over two columns it says two things, which is what that size is for.
         */
        val SHRINKABLE_CARDS = setOf(Kind.LastNight, Kind.Tonight, Kind.LastWorkout, Kind.Energy,
                                     Kind.Nutrition)
        /** iOS's kinds drawn as a tile, small or over two columns (`isWide` false). */
        val TILE_KINDS = setOf(Kind.Measure, Kind.LiveHeart, Kind.Breathe, Kind.Strap, Kind.Water, Kind.AgeLess)
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

    /**
     * Measures read by their catalogue key instead of as a Key Metric, the way every iOS tile is read
     * (2026-11-18). All three already have their number on Android — stress in the core, VO₂max in the
     * Training tab, the fitness age in AgeLess — they simply had no tile, so the two galleries offered
     * different things and "the same customisation on both phones" was not true.
     */
    val catalogMeasures: List<String> = listOf("vo2max_est", "stress", "calories_in", "fitness_age",
                                               "sleep_debt_min", "hr_zones13_min", "hr_zones45_min",
                                               "body_fat", "lean_mass", "vitality", "body_age", "mood",
                                               "protein_g",
                                               "recovery", "strain", "sleep_performance")

    /**
     * The measures whose two-column form says a fact about the wearer's own recent past instead of the
     * usual-and-range line (owner, 2026-11-18). The rest keep that line until their fact is built, so
     * nothing loses what it already said. iOS's twin is `ForgeMeasureWidget.factsLine`.
     */
    val factMeasures: Set<String> = setOf(KeyMetric.HRV.raw, KeyMetric.RESTING_HR.raw, KeyMetric.BLOOD_OXYGEN.raw,
                                          KeyMetric.RESPIRATORY.raw, KeyMetric.SKIN_TEMP.raw, KeyMetric.STEPS.raw,
                                          KeyMetric.CALORIES.raw, KeyMetric.WEIGHT.raw)

    /** The gallery's sections, the catalogue's own groups, in its order (`TileMeasures.Section`). */
    enum class Section(val raw: String) {
        Charge("charge"), Rest("rest"), Effort("effort"), Heart("heart"),
        Body("body"), Food("food"), Mind("mind")
    }

    /**
     * The measures the gallery offers, grouped as the catalogue groups them: a list of twenty-odd in one
     * run is a list nobody reads to the end (owner, 2026-11-18).
     *
     * The list is `TileMeasures.all` in Swift, which the iPhone reads and which answers this phone's reads;
     * `Tools/test_today_tile_gallery.py` holds the two against each other on every push, since a measure
     * added to one side alone is exactly how they drifted apart before.
     */
    val sections: List<Pair<Section, List<String>>> = listOf(
        Section.Charge to listOf("recovery"),
        Section.Rest to listOf("sleep_performance", TodayWidget.SLEEP_KEY, "sleep_debt_min"),
        Section.Effort to listOf("strain", KeyMetric.STEPS.raw, KeyMetric.CALORIES.raw,
                                 "hr_zones13_min", "hr_zones45_min"),
        Section.Heart to listOf(KeyMetric.HRV.raw, KeyMetric.RESTING_HR.raw, KeyMetric.BLOOD_OXYGEN.raw,
                                KeyMetric.RESPIRATORY.raw, "vo2max_est", "stress"),
        Section.Body to listOf(KeyMetric.WEIGHT.raw, "body_fat", "lean_mass", KeyMetric.SKIN_TEMP.raw,
                               "fitness_age", "vitality", "body_age"),
        Section.Food to listOf("calories_in", "protein_g"),
        Section.Mind to listOf("mood"),
    )

    val measures: List<String> = sections.flatMap { it.second }

    fun encode(list: List<TodayWidget>): String = JSONArray(list.map { w ->
        JSONObject().put("id", w.id).put("kind", w.kind.raw).apply {
            w.key?.let { put("key", it) }
            if (w.span != 1) put("span", w.span)
            w.wide?.let { put("wide", it) }
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
                            o.optString("key").ifEmpty { null }, o.optInt("span", 1),
                            if (o.has("wide")) o.optBoolean("wide") else null)
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

    /**
     * The tiles a wearer starts the new design with, iOS's `ForgeTodayWidgetStore.firstTiles`.
     *
     * With no saved Key-Metrics layout ([selection] null or blank) this is the fixed [firstSet], as it has
     * been. With one, it is THAT layout, in its order: the new design arrives without rearranging anybody's
     * Today, which is the whole promise of the 2026-11-18 switch-over. A metric with no tile to carry is
     * dropped ([KeyMetric.measureKey]), and so is one the gallery does not offer.
     */
    fun firstTiles(selection: String?): List<TodayWidget> {
        if (selection?.trim().isNullOrEmpty()) return firstSet
        return KeyMetricPrefs.decodeEnabled(selection)
            .mapNotNull { it.measureKey }
            .filter { it in measures }
            .map { TodayWidget(kind = TodayWidget.Kind.Measure, key = it) }
    }

    internal fun load(context: Context): List<TodayWidget> {
        val prefs = context.getSharedPreferences(NoopPrefs.NAME, Context.MODE_PRIVATE)
        val stored = decode(prefs.getString(KEY, null))
        if (prefs.getBoolean(SEEDED_KEY, false)) return stored
        val seeded = firstTiles(KeyMetricPrefs.enabledRaw(context)) + stored
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
        TodayWidget(kind = TodayWidget.Kind.Breathe), TodayWidget(kind = TodayWidget.Kind.Water),
        TodayWidget(kind = TodayWidget.Kind.AgeLess), TodayWidget(kind = TodayWidget.Kind.CoachNote),
        TodayWidget(kind = TodayWidget.Kind.Strap), TodayWidget(kind = TodayWidget.Kind.Cycle),
        TodayWidget(kind = TodayWidget.Kind.Measure, key = KeyMetric.HRV.raw),
        TodayWidget(kind = TodayWidget.Kind.Measure, key = KeyMetric.RESTING_HR.raw),
        TodayWidget(kind = TodayWidget.Kind.Energy), TodayWidget(kind = TodayWidget.Kind.LastWorkout),
        TodayWidget(kind = TodayWidget.Kind.Momentum), TodayWidget(kind = TodayWidget.Kind.LastNight),
        TodayWidget(kind = TodayWidget.Kind.WeekPlan), TodayWidget(kind = TodayWidget.Kind.Goals),
        TodayWidget(kind = TodayWidget.Kind.Measure, key = KeyMetric.WEIGHT.raw),
        TodayWidget(kind = TodayWidget.Kind.Measure, key = TodayWidget.SLEEP_KEY),
        TodayWidget(kind = TodayWidget.Kind.TrainingLoad),
        // The kit round's two Food tiles, so a demo layout shows them as the iPhone's does.
        TodayWidget(kind = TodayWidget.Kind.Nutrition),
        TodayWidget(kind = TodayWidget.Kind.Measure, key = "protein_g"),
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
                                  onOpenInsights: () -> Unit = {}, onOpenTrends: () -> Unit = {},
                                  onOpenHydration: () -> Unit = {}, onOpenAgeLess: () -> Unit = {},
                                  onOpenFood: () -> Unit = {}) {
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
    // The measures whose two-column form says a fact about the wearer's own recent past rather than the
    // usual-and-range line (owner, 2026-11-18). Read with their days, because "last weighed" is a date.
    // EVERY placed measure, not only the ones with a fact line: the change chip is read from this series
    // too. Until 2026-11-18 it was read from the drawn spark, whose length is the wearer's chosen trend
    // window (7, 14 or 30 days), while the iPhone read 60 — so the same shared reading was handed
    // different histories and the two phones printed different chips for the same measure (+25 against
    // +26 for HRV, on identical data). Same window, same answer.
    val factPlaced = widgets.mapNotNull { it.key }
        .filter { KeyMetric.fromRaw(it) != null || it in TodayWidgets.catalogMeasures || it == TodayWidget.SLEEP_KEY }
        .distinct().sorted()
    val skinTempPreferred = remember { com.noop.ui.UnitPrefs.skinTempPreferred(context) }
    val factSeries by produceState(emptyMap<String, CoreTile.History>(), date, factPlaced, coreRevision) {
        value = if (factPlaced.isEmpty()) emptyMap() else withContext(Dispatchers.IO) {
            factPlaced.associateWith { raw ->
                // One door, one route per measure, decided in the core (`StoreReader.tileHistory`). Asking
                // for every measure under the strap's source was how the weight tile came to read nothing
                // at all while the iPhone's said "Weighed today · ±0,0 kg this week", and how steps were
                // read here by a different layering than the steps page uses.
                runCatching {
                    CoreTile.history(KeyMetric.fromRaw(raw)?.catalogKey() ?: raw, skinTempPreferred.raw)
                }.getOrDefault(CoreTile.History.none)
            }
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
                        (it.kind != TodayWidget.Kind.Cycle || cycleOn) &&
                            (it.kind != TodayWidget.Kind.AgeLess || com.noop.core.CoreFeatures.healthspan(context)) &&
                            (it.kind != TodayWidget.Kind.CoachNote || com.noop.ui.BottomBarStyleStore.coachEnabled)
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
                            TodayWidget.Kind.Measure -> MeasureTile(w.key, keyTiles, sleepMinutes, sleepTrend,
                                                                     factSeries, date.toString(), noData,
                                                                     dense = columns > 2, Modifier.fillMaxSize(),
                                                                     detailed = w.size == TodayWidget.Size.Medium,
                                                                     wide = w.size == TodayWidget.Size.Wide,
                                                                     onOpenSleep = onOpenSleep) { open = it }
                            TodayWidget.Kind.TrainingLoad -> TodayTrainingLoadForge(onOpenTrainingLoad)
                            TodayWidget.Kind.Goals -> TodayGoals()
                            TodayWidget.Kind.Energy -> TodayEnergy(w.compactSize)
                            TodayWidget.Kind.Nutrition -> TodayNutrition(w.compactSize, onOpenFood)
                            TodayWidget.Kind.LiveHeart ->
                                if (w.size == TodayWidget.Size.Wide) HeartCard(viewModel, date, live = date == com.noop.ui.logicalDayNow())
                                else LiveHeartTile(viewModel, showsCurve = w.size == TodayWidget.Size.Medium, dense = columns > 2,
                                                   modifier = Modifier.fillMaxSize(), onOpen = { open = CoreRead.Metric.RestingHr })
                            TodayWidget.Kind.Momentum -> ForgeTodayMomentum(viewModel)
                            TodayWidget.Kind.LastWorkout -> TodayWorkoutsForge(viewModel, w.compactSize)
                            TodayWidget.Kind.Cycle -> TodayCycleForge(viewModel)
                            TodayWidget.Kind.LastNight -> TodayLastNightForge(onOpenSleep, w.compactSize)
                            TodayWidget.Kind.Tonight -> TodayTonightForge(viewModel, onOpenAlarms, w.compactSize)
                            TodayWidget.Kind.WeekPlan -> TodayWeekPlanForge(viewModel, onOpenTraining)
                            TodayWidget.Kind.Breathe -> TodayBreatheTile(onOpenBreathe, dense = columns > 2, modifier = Modifier.fillMaxSize())
                            TodayWidget.Kind.NextSession -> TodayNextSessionForge(onOpenTraining)
                            TodayWidget.Kind.WhatWorks -> TodayWhatWorksForge(viewModel, onOpenInsights)
                            TodayWidget.Kind.Changes -> TodayChangesForge(onOpenTrends, viewModel.activeStrapId)
                            TodayWidget.Kind.Strap -> TodayStrapTile(viewModel, onOpenStrap, dense = columns > 2, modifier = Modifier.fillMaxSize(), detailed = w.size == TodayWidget.Size.Medium)
                            TodayWidget.Kind.Water -> WaterTile(viewModel, dense = columns > 2, modifier = Modifier.fillMaxSize(), onOpen = onOpenHydration, detailed = w.size == TodayWidget.Size.Medium)
                            TodayWidget.Kind.AgeLess -> if (w.size == TodayWidget.Size.Wide) AgeLessWideCard(onOpenAgeLess)
                                else AgeLessTile(dense = columns > 2, modifier = Modifier.fillMaxSize(), onOpen = onOpenAgeLess, detailed = w.size == TodayWidget.Size.Medium)
                            TodayWidget.Kind.CoachNote -> CoachNoteCard()
                            TodayWidget.Kind.DietGoal -> TodayDietGoalCard(onOpenFood)
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
    ForgeMetricDetail(open, viewModel) { open = null }
    if (gallery) {
        ForgeOverlayPage(onDismiss = { gallery = false }) {
            WidgetGallery(cycleOn = viewModel.cycleTrackingEnabled.collectAsState().value, onAdd = { update(widgets + it); gallery = false },
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
 * Skin temperature's figure and unit from the window the card draws, or null for any other measure and for
 * an empty window.
 *
 * One resolver for both the small and the row-wide form (owner's rule, and the fork's): the scale is carried
 * by the history rather than guessed from the size of the number, and the figure is then the newest reading
 * ON that scale, which is also the last point of the chart and the subject of its caption.
 */
@Composable
private fun skinLead(history: CoreTile.History?): KeyTile? {
    val context = LocalContext.current
    val fahrenheit = remember { UnitPrefs.temperature(context) == com.noop.ui.TemperatureUnit.FAHRENHEIT }
    val kind = SkinTempDisplay.Kind.fromRaw(history?.skinKind) ?: return null
    val value = history?.values?.lastOrNull() ?: return null
    return KeyTile(SkinTempDisplay.numberString(value, kind, fahrenheit),
                   SkinTempDisplay.unitSymbol(kind, fahrenheit))
}

/**
 * The skin-temperature window on ONE scale, the one the tile leads with.
 *
 * The caption and the chart under a figure have to be about that figure: with the stored column alone the
 * row-wide card said "33.8 °C" over "usually +0.1 · range -0.4 to +0.5", which is two scales in one card
 * (seen in the side-by-side on 2026-11-19). The wearer's choice decides which is tried first, and the
 * other is the fallback, so a window that measured only one still draws (`SkinTempDisplay.leadReading`).
 */
private suspend fun skinTempSeries(viewModel: AppViewModel, from: String, to: String,
                                   prefer: com.noop.analytics.SkinTempDisplay.Kind): List<Pair<String, Double>> {
    val abs = CoreRead.series(CoreRead.Metric.SkinTempAbs, from, to).map { it.day to it.value }
    val dev = runCatching {
        viewModel.repo.resolvedSeries("skin_temp", "my-whoop", from, to, strapDeviceId = viewModel.activeStrapId)
            .points.map { it.day to it.value }
    }.getOrDefault(emptyList())
    val first = if (prefer == com.noop.analytics.SkinTempDisplay.Kind.ABSOLUTE) abs else dev
    return first.ifEmpty { if (prefer == com.noop.analytics.SkinTempDisplay.Kind.ABSOLUTE) dev else abs }
        .sortedBy { it.first }
}

/**
 * A measure's tile, drawn as iOS's `ForgeMeasureWidget`: the figure from the same reading as Key Metrics, the change
 * against the wearer's usual and its colour from the shared core, the last 30 values as the trend. Sleep reads the
 * latest night as the Sleep tab does.
 */
@Composable
private fun MeasureTile(key: String?, keyTiles: KeyTiles, sleepMinutes: Double?, sleepTrend: List<Double>,
                        factSeries: Map<String, CoreTile.History>, today: String, noData: String,
                        dense: Boolean, modifier: Modifier, detailed: Boolean = false, wide: Boolean = false,
                        onOpenSleep: () -> Unit = {}, onOpen: (CoreRead.Metric) -> Unit) {
    // The row-wide form, and its two named exceptions (2026-11-18). For sleep and stress thirty days is
    // the weaker answer, so each shows the card this app already draws for it: a choice of card, not a
    // second way of drawing the same thing.
    if (wide) {
        when (key) {
            TodayWidget.SLEEP_KEY -> TodayLastNightForge(onOpenSleep)
            "stress" -> StressDayWideCard()
            // Width, not size: the row-wide form is as tall as what it holds. With `fillMaxSize` a measure
            // with nothing stored stretched into a tall empty card, which reads as broken rather than empty.
            else -> WideMeasureCard(key, keyTiles, factSeries[key] ?: CoreTile.History.none, today, noData,
                                    Modifier.fillMaxWidth())
        }
        return
    }
    if (key != null && key in TodayWidgets.catalogMeasures) {
        CatalogMeasureTile(key, factSeries[key] ?: CoreTile.History.none, today, noData, dense, modifier, detailed)
        return
    }
    if (key == TodayWidget.SLEEP_KEY) {
        val sleepSummary = if (detailed) rememberTileDelta("sleep_total_min", sleepTrend.takeLast(60))?.summary else null
        // The nights' own fact first, as every other measure has it; the range line stays as the fallback.
        val sleepFacts = if (detailed) rememberFactsLine(key, factSeries[key], today, "h") else null
        ForgeTodayTile(Icons.Rounded.Bedtime, Forge.colors.rest, stringResource(R.string.forge_sleep),
                       sleepMinutes?.let { TodayTimeline.hoursMinutes(it) }, "h",
                       if (detailed) (sleepFacts ?: sleepSummary?.let { summaryLine(it, "h") }) else null, noData, dense,
                       modifier.clickable { onOpen(CoreRead.Metric.SleepMinutes) }, trend = sleepTrend.takeLast(30))
        return
    }
    val metric = KeyMetric.fromRaw(key) ?: return
    val base = keyTiles.tiles[metric] ?: return
    // Skin temperature leads with the newest reading of the scale the card is DRAWN on, not with today's
    // row read on its own. Both go through `SkinTempDisplay.leadReading`, but a row that measured only the
    // baseline move while the window is on wrist temperature would otherwise put a Δ figure over a °C
    // caption and chart — one fact, two readouts, which is the thing the fork rules forbid first.
    val t = if (key == KeyMetric.SKIN_TEMP.raw) skinLead(factSeries[key]) ?: base else base
    val spark = keyTiles.sparks[metric]
    // The 60-day series where it was read, the drawn spark otherwise: the chip must not depend on how
    // many days the wearer chose to SEE.
    val change = rememberTileDelta(metric.catalogKey(), factSeries[key]?.values?.ifEmpty { null } ?: spark)
    // The measure's own fact first; the usual-and-range line stays for the measures whose fact is not
    // built yet, so nothing loses what it already said.
    val facts = if (detailed) rememberFactsLine(key, factSeries[key], today, t.unit.orEmpty()) else null
    ForgeTodayTile(metric.icon, metric.tileTint(), metric.tileLabel(), t.value, t.unit.orEmpty(),
                   if (detailed) (facts ?: change?.summary?.let { summaryLine(it, t.unit.orEmpty()) }) else null, noData, dense,
                   modifier.then(t.opens?.let { m -> Modifier.clickable { onOpen(m) } } ?: Modifier),
                   delta = change?.text, deltaTone = change?.tone, trend = spark?.takeLast(30))
}

/**
 * A measure the Key Metrics reading does not carry: VO₂max, stress and the fitness age, read as a plain
 * series by catalogue key (2026-11-18). Same tile, same change chip and same thirty-day trend as its
 * siblings; only where the number comes from differs.
 *
 * Stress reads as a word rather than a figure, as the Health tab says it: the scale is 0 to 3 and "1.8"
 * tells nobody anything.
 */
@Composable
private fun CatalogMeasureTile(key: String, history: CoreTile.History, today: String, noData: String,
                               dense: Boolean, modifier: Modifier, detailed: Boolean) {
    val colors = Forge.colors
    val series = history.values
    val latest = series.lastOrNull()
    val decimal = remember { java.text.DecimalFormat("#.#") }
    // One facts read for the whole tile: the figure, the caption and the goal all stand on it.
    val tileFacts = rememberFacts(key, history, today)
    val value = when {
        latest == null -> null
        key == "stress" -> stringResource(when {
            latest < 1.0 -> R.string.forge_vt_low
            latest < 2.0 -> R.string.forge_vt_medium
            else -> R.string.forge_vt_high
        })
        // The figure as the CORE writes it (`MeasureTileReading.figure`), which decides the decimals per
        // measure. Formatting it here as well printed 91,1 g of protein beside the iPhone's 91 g, from
        // one number (2026-11-19). The local format is only what stands there until the core answers.
        else -> tileFacts?.todayText ?: tileFacts?.lastValueText ?: decimal.format(latest)
    }
    val tint = measureTint(key)
    // The measure's unit, from the one catalogue (`CoreTile.units`), so the tile and the facts line under
    // it write what the iPhone writes.
    val unit = CoreTile.units[key].orEmpty()
    val change = rememberTileDelta(key, series)
    // The measure's own fact first, as every other tile has it; the range line stays as the fallback. Until
    // 2026-11-19 these four were the only tiles whose two-column form could say nothing about the week.
    val context = LocalContext.current
    // The wearer's years live in the profile prefs, not the app's ("noop_profile", the file Settings
    // writes). Reading them from the wrong file answered zero, so the age line never appeared at all.
    val calendarAge = remember {
        context.getSharedPreferences("noop_profile", android.content.Context.MODE_PRIVATE)
            .getInt("age", 0).takeIf { it > 0 }?.toDouble()
    }
    // Stress over two columns says how much of today was calm (owner's table, 2026-11-19): a daily stress
    // figure as a word says what it is, the share of the day says how it got there. Read only where a
    // stress tile is actually placed and detailed.
    val calm by androidx.compose.runtime.produceState<Double?>(null, key, detailed) {
        // `this.value`, not `value`: the tile's own figure is called that too, and the outer one wins.
        this.value = if (key != "stress" || !detailed) null else withContext(Dispatchers.IO) {
            runCatching { CoreStress.day(NoopPrefs.stressPersonalBaseline(context))?.calmShare }.getOrNull()
        }
    }
    val factsLine = if (!detailed) null
                    else if (key == "stress") calm?.let { stringResource(R.string.forge_tile_calm_share, (it * 100).roundToInt()) }
                    else rememberFactsLine(key, history, today, unit, calendarAge)
    ForgeTodayTile(measureIcon(key), tint, measureLabel(key), value, if (key == "stress") "" else unit,
                   if (detailed) (factsLine ?: change?.summary?.let { summaryLine(it, unit) }) else null, noData, dense, modifier,
                   // The word carries no direction, so a change chip beside it would be two readings of one
                   // thing in two languages.
                   delta = if (key == "stress") null else change?.text,
                   deltaTone = if (key == "stress") null else change?.tone,
                   trend = series.takeLast(30))
}

/**
 * A measure across the whole row: everything the two-column tile says, and under it the thirty days those
 * words describe, drawn with room to be read (2026-11-18, iOS's `wideChart`).
 *
 * The range stays the caption rather than becoming a second thing drawn beside the curve: one resolver,
 * one claim. A row-wide tile has its row to itself, so the taller curve stretches nothing else.
 */
@Composable
private fun WideMeasureCard(key: String?, keyTiles: KeyTiles, history: CoreTile.History, today: String,
                            noData: String, modifier: Modifier) {
    val days = history.days
    val catalog = history.values
    val metric = KeyMetric.fromRaw(key)
    // The 60-day series it was handed, never the drawn spark: the spark is as long as the wearer's chosen
    // trend window, and reading the change from it made this tile print +26 where the small one beside it
    // printed +25, on the same measure and the same day.
    val series = catalog.ifEmpty { keyTiles.sparks[metric].orEmpty() }
    val tile = (if (key == KeyMetric.SKIN_TEMP.raw) skinLead(history) else null)
        ?: metric?.let { keyTiles.tiles[it] }
    // The Key Metric's own unit where it has one, else the catalogue's, which is where a measure that is
    // not a Key Metric keeps it. Without the second half this card wrote a bare "91" where the iPhone
    // wrote "91 g", and its caption said "130 a day" (2026-11-19).
    val unit = tile?.unit?.takeIf { it.isNotEmpty() } ?: CoreTile.units[key].orEmpty()
    // Charge, Effort and Rest are whole numbers, as their rings say them; a Charge of "51.1" is noise.
    val whole = wholeRowMetric(key) != null
    val change = key?.let { rememberTileDelta(if (metric != null) metric.catalogKey() else it, series) }
    val displayMetric = metric ?: wholeRowMetric(key)
    val tint = displayMetric?.tileTint() ?: measureTint(key.orEmpty())
    val shown = series.takeLast(30)
    // One facts read for the whole card: the goal under the bars, the blocks under the chart, the caption
    // and the figure itself all stand on the same numbers (`MeasureFacts`), so they cannot disagree.
    val facts = rememberFacts(key, history, today)
    // The figure as the CORE writes it, which decides the decimals per measure; the local format is only
    // what stands there until the core answers.
    val value = tile?.value ?: facts?.todayText ?: facts?.lastValueText ?: series.lastOrNull()?.let {
        if (whole) kotlin.math.round(it).toInt().toString() else java.text.DecimalFormat("#.#").format(it)
    }
    // The caption describes the picture under it. Thirty days of line keep the usual and the range; the
    // week's seven bars take the week's daily average instead, which is the window the bars show and the
    // one thing the strip beside them does not already carry (iOS's `wideCaption`, 2026-11-19).
    val caption = if (isDayTotal(key)) facts?.weekAverageText?.let {
        stringResource(R.string.forge_tile_a_day, if (unit.isEmpty() || unit.startsWith("/")) it else "$it $unit")
    } else change?.summary?.let { summaryLine(it, unit) }
    ForgeTodayTile(measureIcon(key.orEmpty()), tint, measureLabel(key.orEmpty()),
                   value, unit, caption, noData, dense = false,
                   modifier = modifier, delta = change?.text, deltaTone = change?.tone,
                   // The row-wide form draws the dated chart below instead of the tile's own sparkline:
                   // "the whole row shows the course" includes WHEN it was, which a bare curve does not say.
                   trend = null,
                   below = if (value != null && shown.size > 1) ({
                       if (isDayTotal(key)) {
                           // A day total asks which DAYS, so its row-wide picture is the week.
                           ForgeWeekBars(days, catalog, today, facts?.target, tint)
                       } else {
                           WideMeasureChart(days.takeLast(shown.size), shown, tint)
                       }
                       // The kit's floor for this size (owner, 2026-11-19): a chart and two more blocks,
                       // never under five things said. Figure, change, caption and chart are four.
                       ForgeFactStrip(key, facts)
                   }) else null)
}

/**
 * The row of extra facts under a row-wide tile's chart: a quiet label with its figure, and a date under the
 * one figure that has one. iOS's twin is `ForgeFactStrip`.
 *
 * WHICH facts, and in what order, is decided in the core (`MeasureFacts.strip`) and arrives with the
 * figures already formatted, so the two phones say the same things in the same order and round them alike.
 * Only the words around them are written here. Up to three, side by side on one baseline: a block that
 * wraps turns the strip into a paragraph. Nothing is drawn when a short history answers none of them.
 */
@Composable
private fun ForgeFactStrip(key: String?, facts: CoreTile.Facts?) {
    val strip = facts?.strip.orEmpty()
    if (key == null || strip.isEmpty()) return
    val lower = key in LOWER_IS_BETTER
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().padding(top = 2.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        strip.take(3).forEach { entry ->
            val label: String?
            var value: String? = null
            var detail: String? = null
            when (entry.item) {
                "best" -> {
                    label = stringResource(if (lower) R.string.forge_strip_lowest else R.string.forge_strip_highest)
                    value = entry.text
                    detail = entry.day?.let { shortDayLabel(it) }
                }
                "weekAverage" -> { label = stringResource(R.string.forge_strip_week_average); value = entry.text }
                "weekTotal" -> { label = stringResource(R.string.forge_strip_this_week); value = entry.text }
                "range" -> {
                    label = stringResource(R.string.forge_strip_range)
                    value = entry.text?.let { low -> entry.text2?.let { high -> "$low–$high" } }
                }
                "weekChange", "quarterChange" -> {
                    label = stringResource(if (entry.item == "weekChange") R.string.forge_strip_this_week
                                           else R.string.forge_strip_over_90_days)
                    // The sign is the fact: "0.4" alone does not say which way the week went.
                    val sign = if ((entry.count ?: 0) > 0) "+" else if ((entry.count ?: 0) < 0) "−" else "±"
                    value = entry.text?.let { sign + it }
                }
                "daysOverGoal", "daysWithEntry", "aboveUsual" -> {
                    label = stringResource(when (entry.item) {
                        "daysOverGoal" -> R.string.forge_strip_over_goal
                        "daysWithEntry" -> R.string.forge_strip_days_logged
                        else -> R.string.forge_strip_above_usual
                    })
                    value = entry.count?.let { c -> entry.total?.let { t -> stringResource(R.string.forge_strip_count, c, t) } }
                }
                "targetLeft" -> { label = stringResource(R.string.forge_strip_left_today); value = entry.text }
                else -> label = null
            }
            if (label != null && value != null) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Text(label, style = Forge.type.caption, color = colors.textTertiary)
                    Text(value, style = Forge.type.captionNumber.copy(fontWeight = FontWeight.SemiBold),
                         color = colors.text)
                    if (detail != null) Text(detail, style = Forge.type.caption, color = colors.textSecondary)
                }
            }
        }
    }
}

/**
 * The measures whose best mark is their LOWEST reading, so the strip names it for what it is. The same list
 * the core keeps as `MeasureFacts.direction`; only a measure that has a best mark at all can reach here,
 * and the core already decided that.
 */
private val LOWER_IS_BETTER = setOf("rhr", "resp_rate", "fitness_age", "body_age", "vitality", "stress",
                                    "sleep_debt_min", "body_fat")

/** A day key as the strip writes it: day and month, no year, since every mark is inside thirty days. */
private fun shortDayLabel(day: String): String? = runCatching {
    java.time.LocalDate.parse(day).format(
        java.time.format.DateTimeFormatter.ofPattern("d MMM", java.util.Locale.getDefault()))
}.getOrNull()

/** Which of the two narrow sizes a shrunk card is drawn at, iOS's `TileSize`. */
internal enum class TileSize { Small, Medium }

/**
 * A card shrunk to its one leading figure (owner, 2026-11-18), iOS's `ForgeCardTile`.
 *
 * One tile for all of them, so a shrunk Last night and a shrunk Energy sit on the same grid as the measures
 * beside them rather than each inventing its own small card.
 */
@Composable
internal fun ForgeCardTile(icon: ImageVector, label: String, value: String?, unit: String, caption: String?,
                           tint: Color, onOpen: () -> Unit) {
    ForgeTodayTile(icon, tint, label, value, unit, caption, stringResource(R.string.forge_no_data),
                   dense = false, modifier = Modifier.fillMaxWidth().clickable(onClick = onOpen), trend = null)
}

/**
 * Seven bars, one for each day of the week ending [today], the weekday letters under them and a dashed rule
 * where there is a goal. iOS's twin is `ForgeWeekBars`.
 *
 * For a measure that is a DAY TOTAL this is the better row-wide picture than thirty days of line (owner,
 * 2026-11-19): steps, the energy burned and the water drunk are things you do in a day, and the question is
 * which days you did them on. A day with nothing recorded is an empty slot rather than a day left out, so
 * the week keeps its shape and a gap reads as a gap.
 */
@Composable
private fun ForgeWeekBars(days: List<String>, values: List<Double>, today: String, goal: Double?, tint: Color) {
    val colors = Forge.colors
    val byDay = days.zip(values).toMap()
    val week = (6 downTo 0).map { back ->
        val day = runCatching { java.time.LocalDate.parse(today).minusDays(back.toLong()).toString() }
            .getOrDefault(today)
        day to byDay[day]
    }
    val top = maxOf(week.mapNotNull { it.second }.maxOrNull() ?: 0.0, goal ?: 0.0)
    val letters = remember { java.time.format.DateTimeFormatter.ofPattern("EEEEE", java.util.Locale.getDefault()) }
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
        Canvas(Modifier.fillMaxWidth().height(96.dp)) {
            val slot = size.width / week.size
            val w = slot * 0.62f
            week.forEachIndexed { i, (day, value) ->
                val fraction = if (top > 0) ((value ?: 0.0) / top).coerceIn(0.0, 1.0) else 0.0
                val h = maxOf(2f, (fraction * size.height).toFloat())
                // Today solid, the days behind it quieter: the bar still being filled is the one asked about.
                drawRoundRect(tint.copy(alpha = if (day == today) 1f else 0.5f),
                              Offset(i * slot + (slot - w) / 2, size.height - h), Size(w, h),
                              CornerRadius(4.dp.toPx(), 4.dp.toPx()))
            }
            if (goal != null && top > 0 && goal <= top) {
                // One dashed rule for the goal, so "over the goal" can be SEEN and not only read below.
                val y = (size.height - goal / top * size.height).toFloat()
                drawLine(colors.textSecondary, Offset(0f, y), Offset(size.width, y), 1.dp.toPx(),
                         pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx())))
            }
        }
        Row(Modifier.fillMaxWidth()) {
            week.forEach { (day, _) ->
                Text(runCatching { java.time.LocalDate.parse(day).format(letters) }.getOrDefault(""),
                     style = Forge.type.caption, color = colors.textTertiary,
                     textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
            }
        }
    }
}

/**
 * The measures that are a day total rather than a reading: what you did that day, not what you were. Their
 * row-wide form draws the week as bars instead of thirty days as a line.
 */
private fun isDayTotal(key: String?): Boolean =
    key in setOf("steps", KeyMetric.STEPS.raw, "active_kcal", KeyMetric.CALORIES.raw, "calories_in",
                 "water_ml", "protein_g", "hr_zones13_min", "hr_zones45_min")

/**
 * The row-wide form's chart: the thirty days with their gridlines and the span written under it, so the
 * curve says WHEN as well as how much (a bare curve was the gap the side-by-side showed).
 *
 * No dashed mean drawn in, which is where this differed from the iPhone's (2026-11-19): the usual and the
 * range are already in the caption over the chart, resolved once by `MeasureFacts`. A second rule derived
 * from the plotted points is a second answer to the same question, and the two can part company — the
 * caption reads the 60-day series while the picture shows thirty.
 *
 * Reuses `ForgeTrends`' own chart rather than a second drawing of the same thing.
 */
@Composable
private fun WideMeasureChart(days: List<String>, values: List<Double>, tint: Color) {
    if (days.size != values.size || values.size < 2) return
    val points = days.zip(values).map { (d, v) -> CoreRead.Point(d, v) }
    val lo = values.min(); val hi = values.max()
    val pad = ((hi - lo) * 0.1).takeIf { it > 0 } ?: 1.0
    val formatter = remember { java.time.format.DateTimeFormatter.ofPattern("d. MMM") }
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
        LineChart(points, days = points.size, lo = lo - pad, hi = hi + pad,
                  average = null, tint = tint,
                  modifier = Modifier.fillMaxWidth().height(96.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            listOf(days.first(), days[days.size / 2], days.last()).forEach { day ->
                Text(runCatching { java.time.LocalDate.parse(day).format(formatter) }.getOrDefault(day),
                     style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
        }
    }
}

/**
 * Today's stress by the hour: the stress tile's row-wide form, one of the two named exceptions. Thirty
 * daily stress figures say very little; the shape of today says most of what there is to say.
 */
@Composable
private fun StressDayWideCard() {
    val context = LocalContext.current
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val personal = remember { NoopPrefs.stressPersonalBaseline(context) }
    val day by produceState<com.noop.core.CoreStress.Day?>(null, coreRevision, personal) {
        value = withContext(Dispatchers.IO) { com.noop.core.CoreStress.day(personal) }
    }
    ForgeCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Rounded.Bolt, contentDescription = null, tint = Forge.colors.effort, modifier = Modifier.size(18.dp))
                Text(stringResource(R.string.forge_vt_stress), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                     color = Forge.colors.text)
            }
            val hours = day?.result?.timeline.orEmpty()
            // The honest blank: only waking hours score, and an hour needs enough heart rate.
            if (hours.any { it.level != null }) com.noop.ui.DaytimeStressLine(hours)
            else Text(stringResource(R.string.forge_no_data), style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
    }
}

/**
 * One name and one symbol per measure key, for the tile AND the gallery row.
 *
 * Both used to resolve it through `KeyMetric.fromRaw`, which answers null for sleep and for the three
 * catalogue measures; the gallery's fallback was the sleep tile, so adding them would have listed three
 * rows all called "Sleep".
 */
@Composable
private fun measureLabel(key: String): String = when (key) {
    TodayWidget.SLEEP_KEY -> stringResource(R.string.forge_sleep)
    "vo2max_est" -> stringResource(R.string.forge_th_vo2max)
    "stress" -> stringResource(R.string.forge_vt_stress)
    "fitness_age" -> stringResource(R.string.today_card_fitness_age)
    "calories_in" -> stringResource(R.string.forge_mc_calories_in)
    "protein_g" -> stringResource(R.string.food_protein)
    "sleep_debt_min" -> stringResource(R.string.forge_m_sleep_debt)
    "hr_zones13_min" -> stringResource(R.string.forge_m_zones13)
    "hr_zones45_min" -> stringResource(R.string.forge_m_zones45)
    "body_fat" -> stringResource(R.string.forge_m_body_fat)
    "lean_mass" -> stringResource(R.string.forge_m_lean_mass)
    "vitality" -> stringResource(R.string.forge_m_vitality)
    "body_age" -> stringResource(R.string.forge_m_body_age)
    "mood" -> stringResource(R.string.forge_m_mood)
    else -> (KeyMetric.fromRaw(key) ?: wholeRowMetric(key))?.tileLabel() ?: key
}

/**
 * A catalogue measure's colour, for every size it is drawn at.
 *
 * One resolver, because the two forms used to answer differently: the two-column Fitness Age came out in
 * the Rest colour and the row-wide one in Charge's, so one measure wore two colours on one screen (seen in
 * the side-by-side on 2026-11-19).
 *
 * WHICH colour is decided once, in the shared table (`TileMeasures.tint`, through `CoreTile.tints`); this
 * only says what that name is in this phone's palette. The two tables had drifted apart on four measures
 * (2026-11-19): Charge, Effort and Rest, and protein, the weight and the skin temperature.
 */
@Composable
private fun measureTint(key: String): Color = when (CoreTile.tints[key]) {
    "charge" -> Forge.colors.charge
    "effort" -> Forge.colors.effort
    "cyan" -> ForgeTokens.StrandPalette.metricCyan.resolve()
    "rose" -> ForgeTokens.StrandPalette.metricRose.resolve()
    "amber" -> ForgeTokens.StrandPalette.metricAmber.resolve()
    "energy" -> ForgeTokens.StrandPalette.energyHighlight.resolve()
    else -> Forge.colors.rest
}

private fun measureIcon(key: String): ImageVector = when (key) {
    "vo2max_est" -> Icons.Rounded.Air
    "stress" -> Icons.Rounded.Bolt
    "fitness_age" -> Icons.Rounded.Favorite
    "calories_in" -> Icons.Rounded.LocalFireDepartment
    "protein_g" -> Icons.Rounded.Restaurant
    "sleep_debt_min", "body_age" -> Icons.Rounded.HourglassBottom
    "hr_zones13_min", "hr_zones45_min" -> Icons.Rounded.Favorite
    "body_fat", "lean_mass" -> Icons.Rounded.Scale
    "vitality" -> Icons.Rounded.Bolt
    "mood" -> Icons.Rounded.Mood
    else -> (KeyMetric.fromRaw(key) ?: wholeRowMetric(key))?.icon ?: Icons.Rounded.Bedtime
}

/** What a gallery section is called on screen; the catalogue's own words, so a measure sits under the same
 *  heading here as on the page it opens. */
private fun sectionTitle(section: TodayWidgets.Section): Int = when (section) {
    TodayWidgets.Section.Charge -> R.string.today_metric_charge
    TodayWidgets.Section.Rest -> R.string.today_metric_rest
    TodayWidgets.Section.Effort -> R.string.today_metric_effort
    TodayWidgets.Section.Heart -> R.string.forge_sec_heart
    TodayWidgets.Section.Body -> R.string.forge_sec_body
    TodayWidgets.Section.Food -> R.string.forge_sec_food
    TodayWidgets.Section.Mind -> R.string.forge_sec_mind
}

/**
 * The Key Metric behind a whole-row catalogue key, so Charge, Effort and Rest keep the name, symbol and
 * colour they have everywhere else. Without it the tile was headed "recovery", the catalogue's own
 * spelling, which is a word no wearer has ever seen in this app.
 */
private fun wholeRowMetric(key: String?): KeyMetric? = when (key) {
    "recovery" -> KeyMetric.CHARGE
    "strain" -> KeyMetric.EFFORT
    "sleep_performance" -> KeyMetric.REST
    else -> null
}

/**
 * What a two-column tile adds, per measure (owner, 2026-11-18): a fact about the wearer's own recent past
 * rather than the same figure over a longer span. iOS's twin is `ForgeMeasureWidget.factsLine`.
 *
 * Null for a measure whose fact is not built yet, and the caller then keeps the usual-and-range line. The
 * numbers come from the shared `MeasureFacts` through the core; only the words are written here.
 */
@Composable
private fun rememberFacts(key: String?, history: CoreTile.History?, today: String): CoreTile.Facts? {
    if (key == null || history == null || history.isEmpty) return null
    val catalogKey = KeyMetric.fromRaw(key)?.catalogKey() ?: key
    val context = LocalContext.current
    val facts by androidx.compose.runtime.produceState<CoreTile.Facts?>(null, key, history, today) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                // Protein's goal is not stored anywhere: it is the day's macro goal, resolved by the core
                // in the one order the app resolves it in. The tile asks for it rather than working one
                // out, so the two Food tiles beside each other on Today cannot name different goals.
                val target = if (CoreTile.resolvesItsTarget(catalogKey)) proteinGoal(context, today) else null
                CoreTile.facts(catalogKey, history.days, history.values, today, target)
            }.getOrNull()
        }
    }
    return facts
}

/** The day's protein goal, from the core's one goal resolver. Blocking; called off the main thread. */
private suspend fun proteinGoal(context: android.content.Context, today: String): Double? {
    val dismissed = dismissedTrainingWorkouts(context)
    val plan = CoreEnergyPlan.plan(context, dismissed)
    val inputs = planInputs(plan)
    return CoreDietPlan.dayGoal(context, CoreDietPlan.load(context), dietPerson(context), inputs.first,
                                inputs.second, plan?.burnedByDay ?: emptyMap(), today, dismissed, plan)?.proteinG
}

@Composable
private fun rememberFactsLine(key: String?, history: CoreTile.History?, today: String,
                              unit: String, calendarAge: Double? = null): String? {
    if (key == null) return null
    val f = rememberFacts(key, history, today) ?: return null
    fun withUnit(text: String) = if (unit.isEmpty() || unit.startsWith("/")) text else "$text $unit"
    return when (key) {
        // Day totals: the week and its daily average.
        KeyMetric.STEPS.raw, KeyMetric.CALORIES.raw, "hr_zones13_min", "hr_zones45_min" -> {
            val total = f.weekTotalText ?: return null
            val average = f.weekAverageText ?: return null
            stringResource(R.string.forge_tile_week_total, total, average)
        }
        // Measured now and then rather than daily, like the weigh-in: when it was taken, and which way it
        // has gone since.
        KeyMetric.WEIGHT.raw, "body_fat", "lean_mass" -> {
            val days = f.daysSinceLast ?: return null
            val whenText = when {
                days <= 0 -> stringResource(R.string.forge_tile_today)
                days == 1 -> stringResource(R.string.forge_tile_yesterday)
                else -> androidx.compose.ui.res.pluralStringResource(R.plurals.forge_tile_days_ago, days, days)
            }
            val change = f.weekChange ?: return stringResource(R.string.forge_tile_weighed, whenText)
            // Signed on purpose: which way it went is the fact, and "0.4 kg" alone would not say it.
            val sign = if (change > 0) "+" else if (change < 0) "−" else "±"
            val moved = withUnit(sign + (f.weekChangeText ?: return null))
            stringResource(R.string.forge_tile_weighed_change, whenText, moved)
        }
        // Protein, the one macro with a goal of its own in the core: today against that goal, and how many
        // of the week's logged days reached it. Without a goal it says the week, as the day totals do.
        "protein_g" -> {
            val eaten = f.todayText ?: f.lastValue?.let { java.text.DecimalFormat("#").format(it) } ?: return null
            val goal = f.target ?: return run {
                val total = f.weekTotalText ?: return null
                val average = f.weekAverageText ?: return null
                stringResource(R.string.forge_tile_week_total, total, average)
            }
            val line = stringResource(R.string.forge_tile_of_goal_today, eaten,
                                      withUnit(java.text.DecimalFormat("#").format(goal)))
            val reached = f.daysAboveTarget
            if (reached == null || f.weekDaysWithEntry <= 0) line
            else line + " · " + stringResource(R.string.forge_tile_days_reached, reached, f.weekDaysWithEntry)
        }
        // The energy eaten is a day total like the two above, under its catalogue spelling.
        "calories_in" -> {
            val total = f.weekTotalText ?: return null
            val average = f.weekAverageText ?: return null
            stringResource(R.string.forge_tile_week_total, total, average)
        }
        // The two measures that ARE an age: how far the body's reading sits from the wearer's own years,
        // which is what the figure is for (owner's table, 2026-11-19). Vitality is a score rather than an
        // age, whatever the table grouped it with, so it keeps the quarter's change below.
        "fitness_age", "body_age" -> {
            val age = calendarAge ?: return null
            val reading = f.today ?: f.lastValue ?: return null
            val gap = kotlin.math.round(age - reading).toInt()
            val line = when {
                gap > 0 -> androidx.compose.ui.res.pluralStringResource(R.plurals.forge_tile_years_under, gap, gap)
                gap < 0 -> androidx.compose.ui.res.pluralStringResource(R.plurals.forge_tile_years_over, -gap, -gap)
                else -> stringResource(R.string.forge_tile_years_same)
            }
            val change = f.quarterChange ?: return line
            val text = f.quarterChangeText ?: return line
            val sign = if (change > 0) "+" else if (change < 0) "−" else "±"
            line + " · " + stringResource(R.string.forge_tile_over_90_days, sign + text)
        }
        // Measures a week cannot move: the quarter's change is the only honest fact about their recent
        // past, and it is the one the owner's table asks for (2026-11-19).
        "vo2max_est", "vitality" -> {
            val change = f.quarterChange ?: return null
            val text = f.quarterChangeText ?: return null
            val sign = if (change > 0) "+" else if (change < 0) "−" else "±"
            stringResource(R.string.forge_tile_over_90_days, sign + text)
        }
        // Readings taken once a day: the wearer's own last seven, and the span they moved in.
        KeyMetric.HRV.raw, KeyMetric.RESTING_HR.raw, KeyMetric.BLOOD_OXYGEN.raw, KeyMetric.RESPIRATORY.raw,
        KeyMetric.SKIN_TEMP.raw, TodayWidget.SLEEP_KEY, "mood", "sleep_debt_min" -> {
            val average = f.weekAverageText ?: return null
            val line = stringResource(R.string.forge_tile_week_average, withUnit(average))
            // Two facts, because two columns must add a block to the small form and not only a line
            // (owner, 2026-11-19); the span is the one every measure of this kind can answer.
            val summary = rememberTileDelta(KeyMetric.fromRaw(key)?.catalogKey() ?: key, history!!.values)?.summary
                ?: return line
            line + " · " + stringResource(R.string.forge_tile_range, summary.low, summary.high)
        }
        else -> null
    }
}

/** "usually 53 bpm · range 51 to 58", from the shared `MeasureTileReading.summary`, as iOS's `summaryLine`. */
@Composable
private fun summaryLine(s: com.noop.core.CoreTile.Summary, unit: String): String {
    val usual = if (unit.isEmpty() || unit.startsWith("/")) s.usual else "${s.usual} $unit"
    return stringResource(R.string.forge_tile_usually, usual) + " · " + stringResource(R.string.forge_tile_range, s.low, s.high)
}

/**
 * "Add a widget" as iOS's `ForgeWidgetGallery`: every measure as a small tile, then the cards in iOS's order, each
 * size its own row with what it shows; a row adds its widget and closes the gallery.
 */
@Composable
private fun WidgetGallery(cycleOn: Boolean, onAdd: (TodayWidget) -> Unit, onClose: () -> Unit) {
    val colors = Forge.colors
    val context = LocalContext.current
    ForgeSceneBackdrop(ForgeBackdrop.Sky) {
        Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState())
                   .padding(horizontal = ForgeMetrics.screenPadding),
               verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            Box(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space4)) {
                Text(stringResource(R.string.forge_g_add), style = Forge.type.headline, color = colors.text, modifier = Modifier.align(Alignment.Center))
                Text(stringResource(R.string.forge_g_done), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                     color = colors.accent, modifier = Modifier.align(Alignment.CenterEnd).clickable(role = Role.Button, onClick = onClose)
                         .padding(ForgeMetrics.space2))
            }
            // One group per catalogue section, as iOS lists them: twenty-odd measures in a single run is a
            // list nobody reads to the end.
            val measureSub = stringResource(R.string.forge_g_measure_sub)
            val wideSub = stringResource(R.string.forge_g_measure_wide_sub)
            TodayWidgets.sections.forEach { (section, keys) ->
                GalleryHeading(stringResource(sectionTitle(section)))
                ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
                    keys.forEachIndexed { i, key ->
                        if (i > 0) HubDivider()
                        GalleryRow(measureIcon(key), measureLabel(key),
                                   if (key in TodayWidget.WHOLE_ROW_MEASURES) wideSub else measureSub) {
                            onAdd(TodayWidget(kind = TodayWidget.Kind.Measure, key = key))
                        }
                    }
                }
            }
            val coach = com.noop.ui.BottomBarStyleStore.coachEnabled
            val ageless = com.noop.core.CoreFeatures.healthspan(context)
            val foodLogged = rememberNutritionReading(0)?.logged == true
            data class Entry(val icon: androidx.compose.ui.graphics.vector.ImageVector, val title: String, val sub: String, val widget: TodayWidget)
            fun w(kind: TodayWidget.Kind, wide: Boolean = false) = TodayWidget(kind = kind, wide = wide)
            val agelessTitle = stringResource(R.string.forge_ageless_title)
            val cards = listOfNotNull(
                Entry(Icons.Rounded.BarChart, stringResource(R.string.forge_g_training_load), stringResource(R.string.forge_g_training_load_sub), w(TodayWidget.Kind.TrainingLoad)),
                Entry(Icons.Rounded.Flag, stringResource(R.string.forge_g_goals), stringResource(R.string.forge_g_goals_sub), w(TodayWidget.Kind.Goals)),
                Entry(Icons.Rounded.LocalFireDepartment, stringResource(R.string.forge_g_energy), stringResource(R.string.forge_g_energy_sub), w(TodayWidget.Kind.Energy)),
                Entry(Icons.Rounded.DirectionsRun, stringResource(R.string.forge_g_last_workout), stringResource(R.string.forge_g_last_workout_sub), w(TodayWidget.Kind.LastWorkout)),
                if (ageless) Entry(Icons.Rounded.HourglassBottom, agelessTitle, stringResource(R.string.forge_al_small_sub), w(TodayWidget.Kind.AgeLess)) else null,
                if (ageless) Entry(Icons.Rounded.HourglassBottom, agelessTitle, stringResource(R.string.forge_al_wide_sub), w(TodayWidget.Kind.AgeLess, wide = true)) else null,
                Entry(Icons.Rounded.Bedtime, stringResource(R.string.forge_g_last_night), stringResource(R.string.forge_g_last_night_sub), w(TodayWidget.Kind.LastNight)),
                Entry(Icons.Rounded.CalendarMonth, stringResource(R.string.forge_g_week_plan), stringResource(R.string.forge_g_week_plan_sub), w(TodayWidget.Kind.WeekPlan)),
                Entry(Icons.Rounded.Terrain, stringResource(R.string.forge_dg_title), stringResource(R.string.forge_dg_sub), w(TodayWidget.Kind.DietGoal)),
                if (coach) Entry(Icons.Rounded.ChatBubble, stringResource(R.string.forge_g_coach_note), stringResource(R.string.forge_g_coach_note_sub), w(TodayWidget.Kind.CoachNote)) else null,
                Entry(Icons.Rounded.Bedtime, stringResource(R.string.forge_g_tonight), stringResource(R.string.forge_g_tonight_sub), w(TodayWidget.Kind.Tonight)),
                Entry(Icons.Rounded.FitnessCenter, stringResource(R.string.forge_g_next), stringResource(R.string.forge_g_next_sub), w(TodayWidget.Kind.NextSession)),
                Entry(Icons.AutoMirrored.Rounded.ShowChart, stringResource(R.string.forge_g_changes), stringResource(R.string.forge_g_changes_sub), w(TodayWidget.Kind.Changes)),
                Entry(Icons.Rounded.Lightbulb, stringResource(R.string.forge_g_what_works), stringResource(R.string.forge_g_what_works_sub), w(TodayWidget.Kind.WhatWorks)),
                Entry(Icons.Rounded.Air, stringResource(R.string.forge_g_breathe), stringResource(R.string.forge_g_breathe_sub), w(TodayWidget.Kind.Breathe)),
                Entry(Icons.Rounded.BatteryFull, stringResource(R.string.forge_g_strap), stringResource(R.string.forge_g_strap_sub), w(TodayWidget.Kind.Strap)),
                if (cycleOn) Entry(Icons.Rounded.WaterDrop, stringResource(R.string.forge_g_cycle), stringResource(R.string.forge_g_cycle_sub), w(TodayWidget.Kind.Cycle)) else null,
                Entry(Icons.Rounded.Bolt, stringResource(R.string.forge_g_momentum), stringResource(R.string.forge_g_momentum_sub), w(TodayWidget.Kind.Momentum)),
                Entry(Icons.Rounded.WaterDrop, stringResource(R.string.forge_g_hydration), stringResource(R.string.forge_g_hydration_sub), w(TodayWidget.Kind.Water)),
                Entry(Icons.Rounded.Favorite, stringResource(R.string.forge_g_live), stringResource(R.string.forge_g_live_sub), w(TodayWidget.Kind.LiveHeart)),
                Entry(Icons.Rounded.MonitorHeart, stringResource(R.string.forge_g_live), stringResource(R.string.forge_g_live_wide_sub), w(TodayWidget.Kind.LiveHeart, wide = true)),
            )
            GalleryHeading(stringResource(R.string.forge_g_cards))
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
                cards.forEachIndexed { i, e ->
                    if (i > 0) HubDivider()
                    GalleryRow(e.icon, e.title, e.sub) { onAdd(e.widget.copy(id = UUID.randomUUID().toString())) }
                }
            }
            Spacer(Modifier.heightIn(min = ForgeMetrics.space8))
        }
    }
}

/** iOS's gallery row: the symbol on an accent wash, the name over its size and content, a plus at the end. */
@Composable
private fun GalleryRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, subtitle: String, onAdd: () -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onAdd).padding(horizontal = ForgeMetrics.space4, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(36.dp).background(colors.accent.copy(alpha = 0.14f), CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = colors.accent, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
            Text(subtitle, style = Forge.type.caption, color = colors.textSecondary)
        }
        Icon(Icons.Rounded.AddCircle, contentDescription = null, tint = colors.accent, modifier = Modifier.size(24.dp))
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

/** iOS's `ForgeWaterWidget`: water today in litres against the day's goal, the week as the trend. */
@Composable
private fun WaterTile(viewModel: AppViewModel, dense: Boolean, modifier: Modifier, onOpen: () -> Unit, detailed: Boolean = false) {
    val context = LocalContext.current
    val today by viewModel.today.collectAsState()
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val read by produceState<Pair<Double, List<Double>>?>(null, coreRevision) {
        value = withContext(Dispatchers.IO) {
            runCatching { com.noop.analytics.HydrationStore.total(viewModel.repo) to
                com.noop.analytics.HydrationStore.history(viewModel.repo, days = 7).map { it.second } }.getOrNull()
        }
    }
    val goalMl = com.noop.analytics.HydrationGoal.dailyGoalMl(com.noop.ui.ProfileStore.from(context).sex, today?.strain)
    val litres = { ml: Double -> String.format(java.util.Locale.getDefault(), "%.1f", ml / 1000) }
    ForgeTodayTile(Icons.Rounded.WaterDrop, ForgeTokens.StrandPalette.metricCyan.resolve(), stringResource(R.string.forge_w_hydration),
                   litres(read?.first ?: 0.0), "L", stringResource(R.string.forge_w_of_litres, litres(goalMl.toDouble())) +
                       (if (detailed && goalMl > 0) " · " + java.text.NumberFormat.getPercentInstance(java.util.Locale.getDefault())
                           .format((read?.first ?: 0.0) / goalMl.toDouble()) else ""), "", dense,
                   modifier.clickable(onClick = onOpen), trend = read?.second?.takeIf { it.size > 1 })
}

/** iOS's `ForgeAgeLessWidget`: the AgeLess age of the latest week against the actual age. */
@Composable
private fun AgeLessTile(dense: Boolean, modifier: Modifier, onOpen: () -> Unit, detailed: Boolean = false) {
    val context = LocalContext.current
    val week by produceState<com.noop.core.CoreAgeLess.Week?>(null) {
        value = withContext(Dispatchers.IO) {
            CoreRead.open(context); runCatching { com.noop.core.CoreAgeLess.snapshot(context)?.weeks?.lastOrNull() }.getOrNull()
        }
    }
    val years = { v: Double -> String.format(java.util.Locale.getDefault(), "%.1f", v) }
    val tint = week?.let { if (it.age <= it.actualAge) Forge.colors.charge else Forge.colors.effort } ?: Forge.colors.accent
    ForgeTodayTile(Icons.Rounded.HourglassBottom, tint, stringResource(R.string.forge_ageless_title), week?.let { years(it.age) },
                   stringResource(R.string.forge_w_years), week?.let { stringResource(R.string.forge_w_age_n, years(it.actualAge)) }, "",
                   dense, modifier.clickable(onClick = onOpen),
                   delta = if (detailed) week?.let { agelessGap(it.age - it.actualAge) } else null,
                   deltaTone = week?.let { if (it.age <= it.actualAge) "good" else "large" })
}

/** The AgeLess age against the calendar age as a signed change, as iOS's `gapText`. */
private fun agelessGap(gap: Double): String {
    val n = String.format(java.util.Locale.getDefault(), "%.1f", kotlin.math.abs(gap))
    return if (kotlin.math.abs(gap) < 0.05) "±0" else if (gap < 0) "↘ −$n" else "↗ +$n"
}

/** iOS's `ForgeAgeLessWideWidget`: the top of the AgeLess page on its age line, across the row. */
@Composable
private fun AgeLessWideCard(onOpen: () -> Unit) {
    val context = LocalContext.current
    val revision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val week by produceState<com.noop.core.CoreAgeLess.Week?>(null, revision) {
        value = withContext(Dispatchers.IO) {
            CoreRead.open(context); runCatching { com.noop.core.CoreAgeLess.snapshot(context)?.weeks?.lastOrNull() }.getOrNull()
        }
    }
    ForgeAgeLessSummary(week, onOpen)
}

/** iOS's `ForgeCoachNoteWidget`: the coach's latest line, the same note Today's rail shows first. */
@Composable
private fun CoachNoteCard() {
    val colors = Forge.colors
    val note by produceState<String?>(null) {
        value = withContext(Dispatchers.IO) {
            runCatching { com.noop.core.CoreCoach.notes().maxByOrNull { it.date }?.headline?.replace("**", "")?.trim() }
                .getOrNull()?.takeIf { it.isNotEmpty() }
        }
    }
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(40.dp).background(colors.accent.copy(alpha = 0.14f), CircleShape), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.Bolt, contentDescription = null, tint = colors.accent, modifier = Modifier.size(20.dp))
            }
            Spacer(Modifier.width(ForgeMetrics.space3))
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.forge_w_coach_note), style = Forge.type.caption, color = colors.textSecondary)
                Text(note ?: stringResource(R.string.forge_w_no_note), style = Forge.type.subhead.copy(fontWeight = FontWeight.Medium),
                     color = if (note == null) colors.textSecondary else colors.text)
            }
        }
    }
}
