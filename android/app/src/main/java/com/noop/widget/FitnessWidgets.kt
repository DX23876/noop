package com.noop.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.noop.R
import com.noop.ui.EffortScale
import com.noop.ui.MainActivity
import com.noop.ui.UnitPrefs
import com.noop.ui.UnitSystem
import org.json.JSONArray
import org.json.JSONObject
import java.text.NumberFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle as DayStyle
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Fork (DX23876), 2026-11-28: the iPhone's ten fitness widgets (`StrandiOSWidgets/Fitness`) on Android, which had
 * none: Sleep, HRV, Resting HR, Charge week, Effort week, Steps, Weight, Training week, Consistency and Vitals. The
 * numbers come from the shared core (`widgets.fitness`, read as the iPhone's `FitnessWidgetPublisher` reads them),
 * are stored once in the widget prefs when the app comes to the front, and every widget draws from that copy; the
 * widgets never read the store. Words come from the iPhone's catalogue (`fw_*` strings).
 */
object FitnessWidgets {
    private const val PREFS = "noop_widget"
    private const val KEY = "fitnessWidget"
    private const val KEY_AT = "fitnessWidgetAt"

    enum class Kind { Sleep, Hrv, RestingHr, ChargeWeek, EffortWeek, Steps, Weight, Workouts, Consistency, Vitals }

    data class Usual(val low: Double, val high: Double) { fun contains(v: Double) = v in low..high }
    data class Night(val day: String, val totalMin: Double, val needMin: Double?, val deepMin: Double?, val remMin: Double?,
                     val lightMin: Double?)
    data class Week(val count: Int, val minutes: Int, val weekDays: List<String>, val trainedDays: List<Boolean>,
                    val todayIndex: Int, val lastSport: String?, val lastDay: String?)
    data class Vital(val id: String, val value: Double, val usual: Usual?)
    data class Payload(
        val days: List<String>, val charge: List<Double?>, val effort: List<Double?>, val hrv: List<Double?>,
        val rhr: List<Double?>, val sleepHours: List<Double?>, val steps: List<Double?>, val hrvUsual: Usual?,
        val rhrUsual: Usual?, val sleep: Night?, val stepsGoal: Double?, val weight: List<Pair<String, Double>>,
        val workouts: Week?, val activeDays: List<Boolean?>, val vitals: List<Vital>, val updatedMs: Long,
    )

    private val receivers = listOf(
        SleepFitnessWidgetReceiver::class.java, HrvFitnessWidgetReceiver::class.java, RestingHrFitnessWidgetReceiver::class.java,
        ChargeWeekFitnessWidgetReceiver::class.java, EffortWeekFitnessWidgetReceiver::class.java, StepsFitnessWidgetReceiver::class.java,
        WeightFitnessWidgetReceiver::class.java, WorkoutsFitnessWidgetReceiver::class.java,
        ConsistencyFitnessWidgetReceiver::class.java, VitalsFitnessWidgetReceiver::class.java,
    )

    fun placed(context: Context): Boolean {
        val manager = AppWidgetManager.getInstance(context)
        return receivers.any { manager.getAppWidgetIds(ComponentName(context, it)).isNotEmpty() }
    }

    /** Reads the core's numbers and redraws placed widgets when they changed; called when the app comes to the front,
     *  as the iPhone publishes with its main glance. Blocking work runs on the caller's dispatcher. */
    suspend fun refresh(context: Context) {
        val app = context.applicationContext
        if (!placed(app) || !com.noop.core.SwiftCore.available) return
        runCatching { com.noop.core.CoreRead.open(app) }
        val dismissed = runCatching { com.noop.ui.forge.dismissedTrainingWorkouts(app) }.getOrDefault(emptyList())
        val json = com.noop.core.SwiftCore.call("widgets.fitness",
            JSONObject().put("dismissedWorkouts", JSONArray(dismissed)).toString())
        // Rare-event evidence: a widget that stays empty says why in the log.
        if (json == null || parse(json, 0L) == null) {
            android.util.Log.w("FitnessWidgets", "widgets.fitness gave no readable answer: ${json?.take(160)}")
            return
        }
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getString(KEY, null) == json) return
        prefs.edit().putString(KEY, json).putLong(KEY_AT, System.currentTimeMillis()).apply()
        redraw(app)
    }

    suspend fun redraw(context: Context) {
        listOf(SleepFitnessWidget(), HrvFitnessWidget(), RestingHrFitnessWidget(), ChargeWeekFitnessWidget(),
               EffortWeekFitnessWidget(), StepsFitnessWidget(), WeightFitnessWidget(), WorkoutsFitnessWidget(),
               ConsistencyFitnessWidget(), VitalsFitnessWidget()).forEach { runCatching { it.updateAll(context) } }
    }

    fun stored(context: Context): Payload? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return prefs.getString(KEY, null)?.let { parse(it, prefs.getLong(KEY_AT, 0L)) }
    }

    internal fun parse(json: String, updatedMs: Long): Payload? = runCatching {
        val o = JSONObject(json)
        fun doubles(k: String): List<Double?> = o.optJSONArray(k)?.let { a -> (0 until a.length()).map { if (a.isNull(it)) null else a.getDouble(it) } }.orEmpty()
        fun usual(k: String) = o.optJSONObject(k)?.let { Usual(it.getDouble("low"), it.getDouble("high")) }
        fun optD(j: JSONObject, k: String) = if (j.has(k) && !j.isNull(k)) j.getDouble(k) else null
        val days = o.getJSONArray("days").let { a -> (0 until a.length()).map { a.getString(it) } }
        val sleep = o.optJSONObject("sleep")?.let { Night(it.getString("day"), it.getDouble("totalMin"), optD(it, "needMin"),
                                                          optD(it, "deepMin"), optD(it, "remMin"), optD(it, "lightMin")) }
        val weight = o.optJSONArray("weight")?.let { a -> (0 until a.length()).map { a.getJSONObject(it).let { r -> r.getString("day") to r.getDouble("kg") } } }.orEmpty()
        val week = o.optJSONObject("workouts")?.let { w ->
            Week(w.getInt("count"), w.getInt("minutes"),
                 w.getJSONArray("weekDays").let { a -> (0 until a.length()).map { a.getString(it) } },
                 w.getJSONArray("trainedDays").let { a -> (0 until a.length()).map { a.getBoolean(it) } },
                 w.optInt("todayIndex"), w.optString("lastSport").takeIf { it.isNotEmpty() && !w.isNull("lastSport") },
                 w.optString("lastDay").takeIf { it.isNotEmpty() && !w.isNull("lastDay") })
        }
        val active = o.optJSONArray("activeDays")?.let { a -> (0 until a.length()).map { if (a.isNull(it)) null else a.getBoolean(it) } }.orEmpty()
        val vitals = o.optJSONArray("vitals")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) }.map { v ->
            Vital(v.getString("id"), v.getDouble("value"), v.optJSONObject("usual")?.let { Usual(it.getDouble("low"), it.getDouble("high")) }) } }.orEmpty()
        Payload(days, doubles("charge"), doubles("effort"), doubles("hrv"), doubles("rhr"), doubles("sleepHours"),
                doubles("steps"), usual("hrvUsual"), usual("rhrUsual"), sleep,
                if (o.has("stepsGoal") && !o.isNull("stepsGoal")) o.getDouble("stepsGoal") else null,
                weight, week, active, vitals, updatedMs)
    }.getOrNull()
}

// MARK: - Widgets and receivers

abstract class FitnessGlanceWidget(private val kind: FitnessWidgets.Kind) : GlanceAppWidget() {
    // The real size, so a chart takes the room its widget has rather than a fixed strip (owner, 2026-11-28).
    override val sizeMode = SizeMode.Exact
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val dark = WidgetTheme.isDark(context)
        if (FitnessWidgets.stored(context) == null) runCatching { FitnessWidgets.refresh(context) }
        provideContent { FitnessWidgetContent(kind, FitnessWidgets.stored(context), dark) }
    }
}

class SleepFitnessWidget : FitnessGlanceWidget(FitnessWidgets.Kind.Sleep)
class HrvFitnessWidget : FitnessGlanceWidget(FitnessWidgets.Kind.Hrv)
class RestingHrFitnessWidget : FitnessGlanceWidget(FitnessWidgets.Kind.RestingHr)
class ChargeWeekFitnessWidget : FitnessGlanceWidget(FitnessWidgets.Kind.ChargeWeek)
class EffortWeekFitnessWidget : FitnessGlanceWidget(FitnessWidgets.Kind.EffortWeek)
class StepsFitnessWidget : FitnessGlanceWidget(FitnessWidgets.Kind.Steps)
class WeightFitnessWidget : FitnessGlanceWidget(FitnessWidgets.Kind.Weight)
class WorkoutsFitnessWidget : FitnessGlanceWidget(FitnessWidgets.Kind.Workouts)
class ConsistencyFitnessWidget : FitnessGlanceWidget(FitnessWidgets.Kind.Consistency)
class VitalsFitnessWidget : FitnessGlanceWidget(FitnessWidgets.Kind.Vitals)

class SleepFitnessWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = SleepFitnessWidget() }
class HrvFitnessWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = HrvFitnessWidget() }
class RestingHrFitnessWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = RestingHrFitnessWidget() }
class ChargeWeekFitnessWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = ChargeWeekFitnessWidget() }
class EffortWeekFitnessWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = EffortWeekFitnessWidget() }
class StepsFitnessWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = StepsFitnessWidget() }
class WeightFitnessWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = WeightFitnessWidget() }
class WorkoutsFitnessWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = WorkoutsFitnessWidget() }
class ConsistencyFitnessWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = ConsistencyFitnessWidget() }
class VitalsFitnessWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = VitalsFitnessWidget() }

// MARK: - Drawing

/** The widgets' colours: the app's Forge hues, light and dark. */
internal class WidgetInk(val dark: Boolean) {
    private fun pick(light: Long, dark: Long) = Color(if (this.dark) dark else light)
    val surface = pick(0xFFF4F1EA, 0xFF0A1322)
    val text = pick(0xFF1A2230, 0xFFF4F6F8)
    val secondary = pick(0xFF7C8696, 0xFF8A94A4)
    val track = pick(0xFFE2E6EC, 0xFF243044)
    val effort = pick(0xFFFF9500, 0xFFFF9F0A)
    val rest = pick(0xFF5856D6, 0xFF5E5CE6)
    val hrv = pick(0xFF0A9DB5, 0xFF2EE6F5)
    val heart = pick(0xFFFF2D55, 0xFFFF375F)
    val steps = pick(0xFF30B0C7, 0xFF40C8E0)
    val sleep = pick(0xFF5856D6, 0xFF8B80FF)
    val deep = pick(0xFF3634A3, 0xFF5E5CE6)
    val rem = pick(0xFFAF52DE, 0xFFBF5AF2)
    val light = pick(0xFF8987E8, 0xFF9492F0)
    val accent = pick(0xFF007AFF, 0xFF0A84FF)
    val green = pick(0xFF34C759, 0xFF30D158)
    val weight = pick(0xFFFF2D55, 0xFFFF375F)
    /** The iPhone's `chargeRingColor`: red below 34, yellow below 67, green above. */
    fun charge(v: Double) = when {
        v >= 67 -> green
        v >= 34 -> pick(0xFFFFCC00, 0xFFFFD60A)
        else -> pick(0xFFFF3B30, 0xFFFF453A)
    }
}

private fun whole(v: Double): String = NumberFormat.getIntegerInstance(Locale.getDefault()).format(v.roundToInt())
private fun oneDecimal(v: Double): String = NumberFormat.getNumberInstance(Locale.getDefault())
    .apply { minimumFractionDigits = 1; maximumFractionDigits = 1 }.format(v)
private fun hm(context: Context, minutes: Double): String {
    val m = minutes.roundToInt()
    return context.getString(R.string.forge_duration_hm, m / 60, m % 60)
}
private fun dayText(key: String): String = runCatching {
    val locale = Locale.getDefault()
    LocalDate.parse(key).format(DateTimeFormatter.ofPattern(android.text.format.DateFormat.getBestDateTimePattern(locale, "EEEdMMM"), locale))
}.getOrDefault(key)
private fun letter(key: String): String = runCatching {
    LocalDate.parse(key).dayOfWeek.getDisplayName(DayStyle.NARROW, Locale.getDefault())
}.getOrDefault("")

/**
 * A widget's room for its chart: the full inner width in pixels, and the height left in dp once the header, the hero
 * figure and [lines] lines of text have theirs, so the chart grows with the widget instead of leaving the bottom empty.
 */
internal class Dims(private val widthDp: Float, private val heightDp: Float, val density: Float) {
    val w: Int get() = ((widthDp - 24f) * density).toInt().coerceAtLeast(60)
    fun h(lines: Int): Int = (heightDp - 24f - 18f - 34f - 15f * lines - 12f).toInt().coerceIn(28, 220)
    fun px(dp: Int): Int = (dp * density).toInt()
}

/** The latest value of a series and whether it is the last day's. */
private fun latest(series: List<Double?>): Pair<Double, Boolean>? =
    series.indexOfLast { it != null }.takeIf { it >= 0 }?.let { series[it]!! to (it == series.lastIndex) }

@Composable
private fun chart(bitmap: Bitmap?, description: String, height: Int) {
    if (bitmap == null) return
    Image(ImageProvider(bitmap), contentDescription = description,
          modifier = GlanceModifier.fillMaxWidth().height(height.dp), contentScale = ContentScale.FillBounds)
}

@Composable
private fun Header(title: String, tint: Color) {
    Text(title, maxLines = 1, style = TextStyle(color = ColorProvider(tint), fontSize = 13.sp, fontWeight = FontWeight.Bold))
}

@Composable
private fun Hero(value: String, unit: String?, ink: WidgetInk) {
    Row(verticalAlignment = Alignment.Bottom) {
        Text(value, maxLines = 1, style = TextStyle(color = ColorProvider(ink.text), fontSize = 26.sp, fontWeight = FontWeight.Bold))
        if (!unit.isNullOrEmpty()) {
            Spacer(GlanceModifier.width(4.dp))
            Text(unit, maxLines = 1, style = TextStyle(color = ColorProvider(ink.secondary), fontSize = 12.sp))
        }
    }
}

@Composable
private fun Caption(text: String?, ink: WidgetInk, lines: Int = 1) {
    if (text.isNullOrEmpty()) return
    Text(text, maxLines = lines, style = TextStyle(color = ColorProvider(ink.secondary), fontSize = 11.sp))
}

@Composable
private fun Footnote(context: Context, payload: FitnessWidgets.Payload, caption: String?, ink: WidgetInk) {
    Caption(caption, ink)
    if (payload.updatedMs > 0) {
        val locale = Locale.getDefault()
        val at = Instant.ofEpochMilli(payload.updatedMs).atZone(ZoneId.systemDefault())
            .format(DateTimeFormatter.ofPattern(android.text.format.DateFormat.getBestDateTimePattern(locale, "EEE jj:mm"), locale))
        Caption(context.getString(R.string.fw_as_of, at), ink)
    }
}

@Composable
private fun NoData(title: String, tint: Color, message: String, ink: WidgetInk) {
    Header(title, tint)
    Spacer(GlanceModifier.height(6.dp))
    Text(message, maxLines = 4, style = TextStyle(color = ColorProvider(ink.secondary), fontSize = 12.sp))
}

@Composable
internal fun FitnessWidgetContent(kind: FitnessWidgets.Kind, payload: FitnessWidgets.Payload?, dark: Boolean) {
    val context = LocalContext.current
    val ink = WidgetInk(dark)
    val size = LocalSize.current
    val wide = size.width >= 250.dp
    val dims = Dims(size.width.value, size.height.value, context.resources.displayMetrics.density)
    Column(
        modifier = GlanceModifier.fillMaxSize().background(ColorProvider(ink.surface)).cornerRadius(16.dp)
            .clickable(actionStartActivity<MainActivity>()).padding(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        when (kind) {
            FitnessWidgets.Kind.Hrv, FitnessWidgets.Kind.RestingHr -> TrendBody(context, kind, payload, ink, wide, dims)
            FitnessWidgets.Kind.ChargeWeek, FitnessWidgets.Kind.EffortWeek -> WeekBody(context, kind, payload, ink, wide, dims)
            FitnessWidgets.Kind.Steps -> StepsBody(context, payload, ink, wide, dims)
            FitnessWidgets.Kind.Sleep -> SleepBody(context, payload, ink, wide, dims)
            FitnessWidgets.Kind.Weight -> WeightBody(context, payload, ink, wide, dims)
            FitnessWidgets.Kind.Workouts -> WorkoutsBody(context, payload, ink, wide)
            FitnessWidgets.Kind.Consistency -> ConsistencyBody(context, payload, ink, wide, dims)
            FitnessWidgets.Kind.Vitals -> VitalsBody(context, payload, ink)
        }
    }
}

@Composable
private fun TrendBody(context: Context, kind: FitnessWidgets.Kind, p: FitnessWidgets.Payload?, ink: WidgetInk, wide: Boolean, dims: Dims) {
    val hrv = kind == FitnessWidgets.Kind.Hrv
    val title = context.getString(if (hrv) R.string.fw_name_hrv else R.string.fw_name_rhr)
    val tint = if (hrv) ink.hrv else ink.heart
    val unit = if (hrv) "ms" else "bpm"
    val series = (if (hrv) p?.hrv else p?.rhr).orEmpty()
    val usual = if (hrv) p?.hrvUsual else p?.rhrUsual
    val last = latest(series)
    if (p == null || last == null) return NoData(title, tint, context.getString(R.string.fw_no_scored_night), ink)
    val usualLine = usual?.let { context.getString(R.string.fw_usual_range, whole(it.low), whole(it.high), unit) }
    val shown = if (wide) series else series.takeLast(7)
    val bmp = WidgetCharts.line(shown, usual?.low, usual?.high, tint.toArgb(), dims.w, dims.px(dims.h(if (wide) 4 else 2)), dims.density)
    Header(title, tint)
    Hero(whole(last.first), unit, ink)
    if (wide && usual != null) {
        Caption(context.getString(when {
            usual.contains(last.first) -> R.string.fw_in_usual
            last.first > usual.high -> R.string.fw_above_usual
            else -> R.string.fw_below_usual
        }), ink)
        Caption(context.getString(R.string.fw_last_14), ink)
    }
    Spacer(GlanceModifier.height(4.dp))
    chart(bmp, title, dims.h(if (wide) 4 else 2))
    Spacer(GlanceModifier.height(4.dp))
    Footnote(context, p, usualLine, ink)
}

@Composable
private fun WeekBody(context: Context, kind: FitnessWidgets.Kind, p: FitnessWidgets.Payload?, ink: WidgetInk, wide: Boolean, dims: Dims) {
    val charge = kind == FitnessWidgets.Kind.ChargeWeek
    val title = context.getString(if (charge) R.string.fw_charge else R.string.fw_effort)
    val series = (if (charge) p?.charge else p?.effort).orEmpty()
    val last = latest(series)
    val tint = if (charge) ink.charge(last?.first ?: 70.0) else ink.effort
    if (p == null || last == null) return NoData(title, tint, context.getString(R.string.fw_no_scored_day), ink)
    val scale = UnitPrefs.effortScale(context)
    fun text(v: Double) = if (charge) "${whole(v)} %" else if (scale == EffortScale.WHOOP) com.noop.ui.UnitFormatter.effortDisplay(v, scale) else whole(v)
    val week = series.takeLast(7)
    val bmp = WidgetCharts.bars(week, 100.0, null, ink.track.toArgb(), { v -> (if (charge) ink.charge(v) else ink.effort).toArgb() },
                                dims.w, dims.px(dims.h(if (wide) 4 else 2)), dims.density)
    Header(title, tint)
    Hero(text(last.first), null, ink)
    if (wide) week.filterNotNull().takeIf { it.isNotEmpty() }?.average()?.let { mean ->
        Caption(if (charge) "Ø ${whole(mean)} %" else "Ø ${text(mean)}", ink)
    }
    Spacer(GlanceModifier.height(4.dp))
    chart(bmp, title, dims.h(if (wide) 4 else 2))
    if (wide) Caption(p.days.takeLast(7).joinToString("   ") { letter(it) }, ink)
    Spacer(GlanceModifier.height(4.dp))
    Footnote(context, p, if (last.second) null else context.getString(R.string.fw_today_not_scored), ink)
}

@Composable
private fun StepsBody(context: Context, p: FitnessWidgets.Payload?, ink: WidgetInk, wide: Boolean, dims: Dims) {
    val title = context.getString(R.string.fw_name_steps)
    val series = p?.steps.orEmpty()
    val last = latest(series)
    if (p == null || last == null) return NoData(title, ink.steps, context.getString(R.string.fw_steps_none), ink)
    val goal = p.stepsGoal
    val muted = ink.steps.copy(alpha = 0.5f).toArgb()
    val bmp = WidgetCharts.bars(series.takeLast(7), null, goal, ink.track.toArgb(),
                                { v -> if (goal != null && v >= goal) ink.steps.toArgb() else muted },
                                dims.w, dims.px(dims.h(if (wide) 3 else 2)), dims.density)
    val dayLine = if (!last.second) series.indexOfLast { it != null }.let { p.days.getOrNull(it) }?.let { dayText(it) } else null
    val goalLine = goal?.let { context.getString(R.string.fw_of_goal, whole(it)) }
    Header(title, ink.steps)
    Hero(whole(last.first), null, ink)
    if (wide) Caption(context.getString(R.string.fw_last_7), ink)
    Spacer(GlanceModifier.height(4.dp))
    chart(bmp, title, dims.h(if (wide) 3 else 2))
    Spacer(GlanceModifier.height(4.dp))
    Footnote(context, p, dayLine ?: goalLine, ink)
}

@Composable
private fun SleepBody(context: Context, p: FitnessWidgets.Payload?, ink: WidgetInk, wide: Boolean, dims: Dims) {
    val title = context.getString(R.string.fw_name_sleep)
    val night = p?.sleep
    if (p == null || night == null) return NoData(title, ink.sleep, context.getString(R.string.fw_sleep_none), ink)
    Header(title, ink.sleep)
    Hero(hm(context, night.totalMin), null, ink)
    Caption(night.needMin?.let { context.getString(R.string.fw_of_need, hm(context, it)) }, ink)
    Spacer(GlanceModifier.height(4.dp))
    val parts = listOfNotNull(night.deepMin?.let { it to ink.deep.toArgb() }, night.lightMin?.let { it to ink.light.toArgb() },
                              night.remMin?.let { it to ink.rem.toArgb() })
    if (parts.isNotEmpty()) chart(WidgetCharts.stack(parts, ink.track.toArgb(), dims.w, dims.px(10), dims.density), title, 10)
    if (wide) {
        Spacer(GlanceModifier.height(4.dp))
        Caption(listOfNotNull(night.deepMin?.let { context.getString(R.string.fw_deep, hm(context, it)) },
                              night.remMin?.let { context.getString(R.string.fw_rem, hm(context, it)) }).joinToString(" · "), ink)
        Caption(context.getString(R.string.fw_last_7_nights), ink)
        chart(WidgetCharts.bars(p.sleepHours.takeLast(7), night.needMin?.let { it / 60 }, night.needMin?.let { it / 60 },
                                ink.track.toArgb(), { ink.sleep.toArgb() }, dims.w, dims.px(dims.h(6)), dims.density), title, dims.h(6))
    }
    Spacer(GlanceModifier.height(4.dp))
    Footnote(context, p, null, ink)
}

@Composable
private fun WeightBody(context: Context, p: FitnessWidgets.Payload?, ink: WidgetInk, wide: Boolean, dims: Dims) {
    val title = context.getString(R.string.fw_name_weight)
    val readings = p?.weight.orEmpty()
    if (p == null || readings.isEmpty()) return NoData(title, ink.weight, context.getString(R.string.fw_weight_none), ink)
    val imperial = UnitPrefs.system(context) == UnitSystem.IMPERIAL
    val unit = if (imperial) "lb" else "kg"
    val values = readings.map { if (imperial) it.second * 2.20462 else it.second }
    val change = if (values.size >= 2) values.last() - values.first() else null
    val changeLine = change?.let {
        val sign = if (it > 0.05) "+" else if (it < -0.05) "−" else "±"
        context.getString(R.string.fw_weight_change, sign, oneDecimal(abs(it)), unit)
    }
    Header(title, ink.weight)
    Hero(oneDecimal(values.last()), unit, ink)
    Caption(if (wide) context.getString(R.string.fw_weighed, dayText(readings.last().first)) else dayText(readings.last().first), ink)
    Spacer(GlanceModifier.height(4.dp))
    chart(WidgetCharts.line(values, null, null, ink.weight.toArgb(), dims.w, dims.px(dims.h(if (wide) 4 else 3)), dims.density), title, dims.h(if (wide) 4 else 3))
    if (wide) Caption(context.getString(R.string.fw_weigh_ins_30, readings.size), ink)
    Spacer(GlanceModifier.height(4.dp))
    Footnote(context, p, changeLine, ink)
}

@Composable
private fun WorkoutsBody(context: Context, p: FitnessWidgets.Payload?, ink: WidgetInk, wide: Boolean) {
    val title = context.getString(R.string.fw_name_workouts)
    val week = p?.workouts
    if (p == null || week == null || (week.count == 0 && week.lastSport == null)) {
        return NoData(title, ink.effort, context.getString(R.string.fw_workouts_none), ink)
    }
    Header(title, ink.effort)
    Hero(week.count.toString(), context.getString(R.string.fw_workouts_unit), ink)
    Caption(context.getString(R.string.fw_min_this_week, week.minutes), ink)
    Spacer(GlanceModifier.height(6.dp))
    Row(GlanceModifier.fillMaxWidth()) {
        week.weekDays.forEachIndexed { i, day ->
            Column(GlanceModifier.defaultWeight(), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(if (week.trainedDays.getOrNull(i) == true) "●" else "○", style = TextStyle(
                    color = ColorProvider(if (week.trainedDays.getOrNull(i) == true) ink.effort else ink.track), fontSize = 14.sp))
                Text(letter(day), style = TextStyle(color = ColorProvider(if (i == week.todayIndex) ink.text else ink.secondary), fontSize = 10.sp,
                     fontWeight = if (i == week.todayIndex) FontWeight.Bold else FontWeight.Normal))
            }
        }
    }
    Spacer(GlanceModifier.height(4.dp))
    val lastLine = if (week.lastSport != null && week.lastDay != null)
        context.getString(R.string.fw_last_workout, week.lastSport, dayText(week.lastDay)) else null
    Footnote(context, p, if (wide) lastLine else week.lastSport, ink)
}

@Composable
private fun ConsistencyBody(context: Context, p: FitnessWidgets.Payload?, ink: WidgetInk, wide: Boolean, dims: Dims) {
    val title = context.getString(R.string.fw_name_consistency)
    val days = p?.activeDays.orEmpty()
    if (p == null || days.none { it != null }) return NoData(title, ink.green, context.getString(R.string.fw_consistency_none), ink)
    val recent = days.takeLast(28).count { it == true }
    // Whole weeks ending today, the grid's columns: the last 4 weeks small, 12 when wide.
    val shown = days.takeLast(if (wide) 84 else 28)
    Header(title, ink.green)
    Hero(recent.toString(), context.getString(R.string.fw_of_28), ink)
    if (wide) Caption(context.getString(R.string.fw_training_days_4w), ink)
    Spacer(GlanceModifier.height(4.dp))
    chart(WidgetCharts.heatGrid(shown, ink.green.toArgb(), ink.track.toArgb(), dims.w,
                                dims.px(dims.h(if (wide) 2 else 1)), dims.density), title, dims.h(if (wide) 2 else 1))
    Spacer(GlanceModifier.height(4.dp))
    Footnote(context, p, null, ink)
}

@Composable
private fun VitalsBody(context: Context, p: FitnessWidgets.Payload?, ink: WidgetInk) {
    val title = context.getString(R.string.fw_name_vitals)
    val vitals = p?.vitals.orEmpty()
    if (p == null || vitals.isEmpty()) return NoData(title, ink.accent, context.getString(R.string.fw_vitals_none), ink)
    val judged = vitals.filter { it.usual != null }
    val outside = judged.count { !it.usual!!.contains(it.value) }
    Header(title, ink.accent)
    Text(when {
        judged.isEmpty() -> context.getString(R.string.fw_learning_usual)
        outside == 0 -> context.getString(R.string.fw_all_in_usual)
        else -> context.getString(R.string.fw_outside_usual, outside)
    }, maxLines = 2, style = TextStyle(color = ColorProvider(ink.text), fontSize = 13.sp, fontWeight = FontWeight.Medium))
    Spacer(GlanceModifier.height(6.dp))
    val imperial = UnitPrefs.system(context) == UnitSystem.IMPERIAL
    vitals.forEach { v ->
        val (name, value) = when (v.id) {
            "spo2" -> context.getString(R.string.fw_blood_oxygen) to "${whole(v.value)} %"
            "resp" -> context.getString(R.string.fw_respiratory) to "${oneDecimal(v.value)} rpm"
            else -> {
                val shown = if (imperial) v.value * 1.8 else v.value
                val sign = if (shown > 0.05) "+" else if (shown < -0.05) "−" else "±"
                context.getString(R.string.fw_skin_temp) to "$sign${oneDecimal(abs(shown))} ${if (imperial) "°F" else "°C"}"
            }
        }
        val off = v.usual?.let { !it.contains(v.value) } == true
        Row(GlanceModifier.fillMaxWidth()) {
            Text(name, maxLines = 1, modifier = GlanceModifier.defaultWeight(), style = TextStyle(color = ColorProvider(ink.secondary), fontSize = 11.sp))
            Text(value, maxLines = 1, style = TextStyle(color = ColorProvider(if (off) ink.effort else ink.text), fontSize = 12.sp,
                 fontWeight = FontWeight.Medium))
        }
    }
    Spacer(GlanceModifier.height(4.dp))
    Footnote(context, p, null, ink)
}
