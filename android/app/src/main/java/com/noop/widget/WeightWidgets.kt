package com.noop.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.ColorFilter
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.layout.ContentScale
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.appwidget.SizeMode
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.currentState
import androidx.glance.state.GlanceStateDefinition
import androidx.glance.state.PreferencesGlanceStateDefinition
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.size
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.noop.R
import com.noop.core.CoreWeight
import com.noop.ui.MainActivity
import com.noop.ui.UnitFormatter
import com.noop.ui.UnitPrefs
import com.noop.ui.UnitSystem
import org.json.JSONArray
import org.json.JSONObject
import java.text.NumberFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

/**
 * Fork (DX23876), owner decisions 2026-11-26: the weight widgets as iOS's (`WeightTrackerWidgets.swift`): the trend,
 * the month, the key figures and a countdown to one of the wearer's dates, each in its own colour, changeable when the
 * widget is edited (`WeightWidgetConfigureActivity`). Drawn from what the weight page stored (`publish`), worded from
 * the core's snapshot; the widgets never read the store.
 */
object WeightWidgets {
    internal const val PREFS = "noop_widget"
    private const val KEY = "weightWidget"
    private fun tintKey(id: Int) = "weightWidgetTint.$id"
    private fun eventKey(id: Int) = "weightWidgetEvent.$id"

    /** The widget colours: the Forge palette's system hues, light and dark. */
    enum class Tint(val label: Int, val lightArgb: Long, val darkArgb: Long) {
        Pink(R.string.wt_tint_pink, 0xFFFF2D55, 0xFFFF375F), Orange(R.string.wt_tint_orange, 0xFFFF9500, 0xFFFF9F0A),
        Yellow(R.string.wt_tint_yellow, 0xFFFFCC00, 0xFFFFD60A), Green(R.string.wt_tint_green, 0xFF34C759, 0xFF30D158),
        Teal(R.string.wt_tint_teal, 0xFF30B0C7, 0xFF40C8E0), Blue(R.string.wt_tint_blue, 0xFF007AFF, 0xFF0A84FF),
        Indigo(R.string.wt_tint_indigo, 0xFF5856D6, 0xFF5E5CE6), Purple(R.string.wt_tint_purple, 0xFFAF52DE, 0xFFBF5AF2);
        fun color(dark: Boolean) = Color(if (dark) darkArgb else lightArgb)
    }

    data class Figure(val label: String, val value: String)
    data class Event(val id: String, val name: String, val day: String, val expected: String?, val rateLine: String?)
    data class Payload(val unit: String, val trend: String, val rateLine: String?, val latest: String, val monthLabel: String,
                       val month: List<Figure>, val figures: List<Figure>, val line: List<Double>, val events: List<Event>)

    /** The widget kinds and each one's default colour, as iOS. */
    internal val defaults = mapOf(
        WeightTrendWidgetReceiver::class.java to Tint.Pink, WeightMonthWidgetReceiver::class.java to Tint.Orange,
        WeightFiguresWidgetReceiver::class.java to Tint.Indigo, WeightEventWidgetReceiver::class.java to Tint.Teal,
    )

    fun tint(context: Context, id: Int, fallback: Tint): Tint =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(tintKey(id), null)
            ?.let { n -> Tint.entries.firstOrNull { it.name == n } } ?: fallback

    fun setTint(context: Context, id: Int, tint: Tint, eventId: String?) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(tintKey(id), tint.name)
            .apply { if (eventId == null) remove(eventKey(id)) else putString(eventKey(id), eventId) }.apply()
    }

    fun eventChoice(context: Context, id: Int): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(eventKey(id), null)

    internal fun placed(context: Context): Boolean {
        val manager = AppWidgetManager.getInstance(context)
        return defaults.keys.any { manager.getAppWidgetIds(ComponentName(context, it)).isNotEmpty() }
    }

    /**
     * Republishes from a fresh snapshot when a weight widget is placed: when the app comes to the front, as iOS does,
     * so a weigh-in logged anywhere (or a countdown's new day) reaches the home screen without visiting the page.
     */
    suspend fun refresh(context: Context, redrawAfter: Boolean = true) {
        val app = context.applicationContext
        if (!placed(app)) return
        runCatching { com.noop.core.CoreRead.open(app) }
        publish(app, CoreWeight.page(app), redrawAfter)
    }

    /** Words the page's snapshot for the widgets and Today's tile, and redraws placed widgets when something changed. */
    suspend fun publish(context: Context, page: CoreWeight.Page?, redrawAfter: Boolean = true) {
        val app = context.applicationContext
        // No page: the core did not answer, so what is shown stays. A page without a snapshot: no weigh-ins are
        // left, so the widgets and Today's tile drop the weight they showed instead of keeping a deleted one.
        if (page == null) return
        val s = page.snapshot ?: run {
            val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (prefs.contains(KEY)) {
                prefs.edit().remove(KEY).commit()
                if (redrawAfter && placed(app)) redraw(app)
            }
            return
        }
        // Worded even with no widget placed: Today's two-column weight tile reads the same lines.
        val units = UnitPrefs.system(app)
        val unit = UnitFormatter.massUnit(units)
        val one = NumberFormat.getNumberInstance(Locale.getDefault()).apply { minimumFractionDigits = 1; maximumFractionDigits = 1 }
        fun v(kg: Double) = if (units == UnitSystem.IMPERIAL) UnitFormatter.kgToPounds(kg) else kg
        fun n(kg: Double) = one.format(v(kg))
        fun signed(kg: Double) = (if (kg > 0.05) "+" else if (kg < -0.05) "−" else "") + one.format(kotlin.math.abs(v(kg)))
        val rate = s.forecast.rateKgPerWeek ?: s.rates.current
        val rateLine = rate?.let { app.getString(R.string.wt_widget_rate, signed(it), unit) }
        val month = s.months.firstOrNull()
        val previous = s.months.getOrNull(1)
        val monthFmt = DateTimeFormatter.ofPattern("LLLL", Locale.getDefault())
        val monthFigures = buildList {
            if (month != null && month.enough) {
                month.low?.let { add(Figure(app.getString(R.string.wt_lowest), n(it.kg))) }
                month.averageKg?.let { add(Figure(app.getString(R.string.wt_average), n(it))) }
                if (month.vsPreviousKg != null && previous != null) {
                    val name = Instant.ofEpochSecond(previous.start).atZone(ZoneId.systemDefault()).format(
                        DateTimeFormatter.ofPattern("LLL", Locale.getDefault()))
                    add(Figure(app.getString(R.string.wt_widget_vs, name), signed(month.vsPreviousKg)))
                }
                month.trendChangeKg?.let { add(Figure(app.getString(R.string.wt_trend_change), signed(it))) }
            }
        }
        val figures = buildList {
            add(Figure(app.getString(R.string.wt_latest), n(s.latest.kg)))
            add(Figure(app.getString(R.string.wt_trend_label), n(s.trendKg)))
            s.rates.current?.let { add(Figure(app.getString(R.string.wt_per_week_label), signed(it))) }
            s.week?.let { add(Figure(app.getString(R.string.wt_week_low), n(it.low.kg))) }
            val m = s.milestones
            if (m != null) {
                add(Figure(app.getString(R.string.wt_progress), "${(m.progress * 100).toInt()} %"))
                m.next?.let { add(Figure(app.getString(R.string.wt_next_stop), n(it))) }
            } else s.changes.firstOrNull { it.days == 30 }?.let {
                add(Figure(app.resources.getQuantityString(R.plurals.wt_days, 30, 30), signed(it.kg)))
            }
        }
        val cutoff = Instant.now().epochSecond - 30 * 86_400L
        val events = s.events.filter { it.phase == "upcoming" }.map { e ->
            Event(e.event.id, e.event.name, e.event.day, e.predictedKg?.let(::n),
                  rate?.let { app.getString(R.string.wt_widget_at_rate, signed(it), unit) })
        }
        val payload = JSONObject().put("unit", unit).put("trend", n(s.trendKg)).put("rateLine", rateLine ?: JSONObject.NULL)
            .put("latest", n(s.latest.kg))
            .put("monthLabel", (month?.let { Instant.ofEpochSecond(it.start).atZone(ZoneId.systemDefault()) }
                ?: Instant.now().atZone(ZoneId.systemDefault())).format(monthFmt).replaceFirstChar { it.titlecase() })
            .put("month", JSONArray(monthFigures.map { JSONObject().put("label", it.label).put("value", it.value) }))
            .put("figures", JSONArray(figures.map { JSONObject().put("label", it.label).put("value", it.value) }))
            .put("line", JSONArray(s.trend.filter { it.at >= cutoff }.map { v(it.kg) }))
            .put("events", JSONArray(events.map {
                JSONObject().put("id", it.id).put("name", it.name).put("day", it.day)
                    .put("expected", it.expected ?: JSONObject.NULL).put("rateLine", it.rateLine ?: JSONObject.NULL)
            }))
            .toString()
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getString(KEY, null) == payload) return
        prefs.edit().putString(KEY, payload).commit()
        if (redrawAfter && placed(app)) redraw(app)
    }

    /** Bumped in each placed widget's Glance state on every redraw; see [WeightGlanceWidget.provideGlance]. */
    internal val STAMP = longPreferencesKey("weightRedraw")

    /**
     * Redraws every placed weight widget. A plain `updateAll` reached a running session without changing anything it
     * read, so the composition was skipped and a new colour or payload waited for the session to end; bumping a
     * value in each widget's Glance state is what makes that session recompose.
     */
    suspend fun redraw(context: Context) {
        val manager = GlanceAppWidgetManager(context)
        val stamp = System.currentTimeMillis()
        listOf(WeightTrendWidget(), WeightMonthWidget(), WeightFiguresWidget(), WeightEventWidget()).forEach { widget ->
            runCatching {
                manager.getGlanceIds(widget.javaClass).forEach { id ->
                    updateAppWidgetState(context, id) { it[STAMP] = stamp }
                    widget.update(context, id)
                }
            }
        }
    }

    fun stored(context: Context): Payload? = runCatching {
        val o = JSONObject(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null) ?: return null)
        fun figs(k: String) = o.optJSONArray(k)?.let { a -> (0 until a.length()).map { Figure(a.getJSONObject(it).getString("label"), a.getJSONObject(it).getString("value")) } }.orEmpty()
        fun str(j: JSONObject, k: String) = if (j.isNull(k)) null else j.optString(k)
        Payload(o.getString("unit"), o.getString("trend"), str(o, "rateLine"), o.getString("latest"), o.getString("monthLabel"),
                figs("month"), figs("figures"),
                o.optJSONArray("line")?.let { a -> (0 until a.length()).map { a.getDouble(it) } }.orEmpty(),
                o.optJSONArray("events")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) }.map {
                    Event(it.getString("id"), it.getString("name"), it.getString("day"), str(it, "expected"), str(it, "rateLine"))
                } }.orEmpty())
    }.getOrNull()
}

/** One weight widget: its stored colour and the payload, drawn by [content]. */
abstract class WeightGlanceWidget(private val fallback: WeightWidgets.Tint) : GlanceAppWidget() {
    override val stateDefinition: GlanceStateDefinition<*> = PreferencesGlanceStateDefinition

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val dark = WidgetTheme.isDark(context)
        val appWidgetId = runCatching { GlanceAppWidgetManager(context).getAppWidgetId(id) }.getOrDefault(-1)
        // The app writes the payload only while a weight widget is placed, so the first one placed finds none yet:
        // word it here once, without a redraw, since this session is about to draw anyway.
        if (WeightWidgets.stored(context) == null) runCatching { WeightWidgets.refresh(context, redrawAfter = false) }
        provideContent {
            // Everything the widget shows is read here, at the top of the composition that the stamp invalidates.
            currentState<Preferences>()[WeightWidgets.STAMP]  // read so a redraw's new stamp recomposes this
            val tint = WeightWidgets.tint(context, appWidgetId, fallback)
            val p = WeightWidgets.stored(context)
            val chosen = WeightWidgets.eventChoice(context, appWidgetId)
            WeightWidgetFrame(tint.color(dark), dark) {
                if (p == null) NoData(dark) else content(p, tint.color(dark), dark, chosen)
            }
        }
    }

    @Composable
    abstract fun content(p: WeightWidgets.Payload, tint: Color, dark: Boolean, chosenEvent: String?)
}

private fun ink(dark: Boolean) = ColorProvider(if (dark) Color(0xFFF4F6F8) else Color(0xFF1A2230))
private fun inkSecondary(dark: Boolean) = ColorProvider(if (dark) Color(0xFFA3ACBA) else Color(0xFF5E6878))

@Composable
private fun WeightWidgetFrame(tint: Color, dark: Boolean, body: @Composable () -> Unit) {
    // A soft wash of the widget's colour over the page surface, as iOS's `WeightWidgetBackground`.
    val surface = if (dark) Color(0xFF0A1322) else Color(0xFFF7F5F0)
    val wash = Color(
        red = surface.red + (tint.red - surface.red) * (if (dark) 0.28f else 0.20f),
        green = surface.green + (tint.green - surface.green) * (if (dark) 0.28f else 0.20f),
        blue = surface.blue + (tint.blue - surface.blue) * (if (dark) 0.28f else 0.20f),
    )
    Column(GlanceModifier.fillMaxSize().background(wash).cornerRadius(18.dp)
               .clickable(actionStartActivity<MainActivity>()).padding(horizontal = 14.dp, vertical = 12.dp),
           horizontalAlignment = Alignment.Start, verticalAlignment = Alignment.Top) { body() }
}

@Composable
private fun Pill(text: String, tint: Color) {
    Text(text, maxLines = 1, modifier = GlanceModifier.background(tint.copy(alpha = 0.22f)).cornerRadius(10.dp)
        .padding(horizontal = 8.dp, vertical = 2.dp),
        style = TextStyle(color = ColorProvider(tint), fontSize = 11.sp, fontWeight = FontWeight.Bold))
}

@Composable
private fun NoData(dark: Boolean) = EmptyNote(R.drawable.ic_widget_weight, R.string.wt_widget_no_data, dark)

/** An empty widget's mark and line, as iOS's `WeightNoData`. */
@Composable
private fun EmptyNote(icon: Int, text: Int, dark: Boolean) {
    Image(ImageProvider(icon), contentDescription = null, colorFilter = ColorFilter.tint(ink(dark)),
          modifier = GlanceModifier.size(22.dp))
    Spacer(GlanceModifier.height(6.dp))
    Text(LocalContext.current.getString(text), style = TextStyle(color = inkSecondary(dark), fontSize = 12.sp))
}

class WeightTrendWidget : WeightGlanceWidget(WeightWidgets.Tint.Pink) {
    // The line is a bitmap: drawn at the size the launcher gives, a resized widget would stretch its stroke.
    override val sizeMode: SizeMode = SizeMode.Exact

    @Composable
    override fun content(p: WeightWidgets.Payload, tint: Color, dark: Boolean, chosenEvent: String?) {
        val context = LocalContext.current
        Pill(context.getString(R.string.wt_trend_label), tint)
        Spacer(GlanceModifier.height(6.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(p.trend, style = TextStyle(color = ink(dark), fontSize = 30.sp, fontWeight = FontWeight.Bold))
            Spacer(GlanceModifier.width(3.dp))
            Text(p.unit, style = TextStyle(color = inkSecondary(dark), fontSize = 13.sp, fontWeight = FontWeight.Medium))
        }
        p.rateLine?.let { Text(it, maxLines = 1, style = TextStyle(color = ColorProvider(tint), fontSize = 12.sp, fontWeight = FontWeight.Bold)) }
        Spacer(GlanceModifier.height(6.dp))
        // The last 30 days of the trend as a line, as iOS's `WidgetLineChart`; the latest weigh-in when there is
        // too little to draw.
        val density = context.resources.displayMetrics.density
        val widthDp = (LocalSize.current.width.value - 28f).coerceAtLeast(60f)  // less the frame's padding
        val line = trendLine(p.line, (widthDp * density).toInt(), (34 * density).toInt(), tint, 2.2f * density)
        if (line != null) {
            Image(ImageProvider(line), contentDescription = null, contentScale = ContentScale.FillBounds,
                  modifier = GlanceModifier.fillMaxWidth().height(34.dp))
        } else {
            Text(context.getString(R.string.wt_widget_latest, p.latest, p.unit), style = TextStyle(color = inkSecondary(dark), fontSize = 11.sp))
        }
    }
}

class WeightMonthWidget : WeightGlanceWidget(WeightWidgets.Tint.Orange) {
    @Composable
    override fun content(p: WeightWidgets.Payload, tint: Color, dark: Boolean, chosenEvent: String?) {
        val context = LocalContext.current
        Pill(p.monthLabel, tint)
        Spacer(GlanceModifier.height(8.dp))
        if (p.month.isEmpty()) {
            Text(context.getString(R.string.wt_widget_month_empty), style = TextStyle(color = inkSecondary(dark), fontSize = 12.sp))
        }
        p.month.take(4).forEach { f ->
            Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(f.label, maxLines = 1, modifier = GlanceModifier.defaultWeight(),
                     style = TextStyle(color = inkSecondary(dark), fontSize = 11.sp, fontWeight = FontWeight.Medium))
                Text(f.value, style = TextStyle(color = ink(dark), fontSize = 14.sp, fontWeight = FontWeight.Bold))
            }
            Spacer(GlanceModifier.height(4.dp))
        }
    }
}

class WeightFiguresWidget : WeightGlanceWidget(WeightWidgets.Tint.Indigo) {
    @Composable
    override fun content(p: WeightWidgets.Payload, tint: Color, dark: Boolean, chosenEvent: String?) {
        val context = LocalContext.current
        Pill(context.getString(R.string.wt_widget_figures_title, p.unit), tint)
        Spacer(GlanceModifier.height(8.dp))
        p.figures.take(6).chunked(3).forEach { row ->
            Row(GlanceModifier.fillMaxWidth()) {
                row.forEach { f ->
                    Column(GlanceModifier.defaultWeight()) {
                        Text(f.label, maxLines = 1, style = TextStyle(color = inkSecondary(dark), fontSize = 11.sp, fontWeight = FontWeight.Medium))
                        Text(f.value, maxLines = 1, style = TextStyle(color = ink(dark), fontSize = 18.sp, fontWeight = FontWeight.Bold))
                    }
                }
            }
            Spacer(GlanceModifier.height(8.dp))
        }
    }
}

class WeightEventWidget : WeightGlanceWidget(WeightWidgets.Tint.Teal) {
    @Composable
    override fun content(p: WeightWidgets.Payload, tint: Color, dark: Boolean, chosenEvent: String?) {
        val context = LocalContext.current
        val today = LocalDate.now()
        val upcoming = p.events.filter { runCatching { !LocalDate.parse(it.day).isBefore(today) }.getOrDefault(false) }
        val e = upcoming.firstOrNull { it.id == chosenEvent } ?: upcoming.minByOrNull { it.day }
        if (e == null) {
            EmptyNote(R.drawable.ic_widget_event, R.string.wt_widget_event_empty, dark)
            return
        }
        val days = ChronoUnit.DAYS.between(today, LocalDate.parse(e.day)).toInt()
        Pill(e.name, tint)
        Spacer(GlanceModifier.height(10.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(e.expected ?: "—", style = TextStyle(color = ink(dark), fontSize = 30.sp, fontWeight = FontWeight.Bold))
            Spacer(GlanceModifier.width(3.dp))
            Text(p.unit, style = TextStyle(color = inkSecondary(dark), fontSize = 13.sp, fontWeight = FontWeight.Medium))
        }
        Text(if (days == 0) context.getString(R.string.wt_today) else context.resources.getQuantityString(R.plurals.wt_in_days, days, days),
             style = TextStyle(color = ColorProvider(tint), fontSize = 12.sp, fontWeight = FontWeight.Bold))
        e.rateLine?.let { Text(it, maxLines = 1, style = TextStyle(color = inkSecondary(dark), fontSize = 11.sp)) }
    }
}

class WeightTrendWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = WeightTrendWidget() }
class WeightMonthWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = WeightMonthWidget() }
class WeightFiguresWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = WeightFiguresWidget() }
class WeightEventWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = WeightEventWidget() }

/**
 * The trend line for the trend widget, drawn to a transparent bitmap because Glance cannot draw: the values scaled into
 * the box with a little headroom, a round-capped stroke in the widget's colour and a dot on the newest point. Null
 * when there are fewer than two values or the bitmap cannot be made, so the widget shows the latest weigh-in instead.
 */
private fun trendLine(values: List<Double>, widthPx: Int, heightPx: Int, tint: Color, strokePx: Float): Bitmap? {
    if (values.size < 2 || widthPx < 4 || heightPx < 4) return null
    val bmp = runCatching { Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888) }.getOrNull() ?: return null
    val lo = values.min()
    val hi = values.max()
    val span = (hi - lo).takeIf { it > 1e-6 } ?: 1.0
    val inset = strokePx * 1.6f
    val w = widthPx - 2 * inset
    val h = heightPx - 2 * inset
    fun x(i: Int) = inset + w * i / (values.size - 1)
    fun y(v: Double) = inset + h * (1 - ((v - lo) / span)).toFloat()
    val path = Path().apply {
        moveTo(x(0), y(values[0]))
        for (i in 1 until values.size) lineTo(x(i), y(values[i]))
    }
    val argb = tint.toArgb()
    val canvas = Canvas(bmp)
    canvas.drawPath(path, Paint().apply {
        isAntiAlias = true; style = Paint.Style.STROKE; strokeWidth = strokePx
        strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND; color = argb
    })
    canvas.drawCircle(x(values.size - 1), y(values.last()), strokePx * 1.5f, Paint().apply { isAntiAlias = true; color = argb })
    return bmp
}
