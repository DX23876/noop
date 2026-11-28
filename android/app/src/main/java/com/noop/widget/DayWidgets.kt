package com.noop.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.DpSize
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
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.noop.R
import com.noop.ui.EffortScale
import com.noop.ui.MainActivity
import com.noop.ui.UnitPrefs
import org.json.JSONObject
import java.text.NumberFormat
import java.time.LocalDate
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Fork (DX23876), 2026-11-28: the iPhone's day widgets Android lacked: NOOP Rings (`NOOPRingsWidget`), Forge Today
 * (`ForgeTodayWidget`), NOOP Energy (`NOOPEnergyWidget`) and NOOP Nutrition (`NOOPFoodWidget`). The rings draw the
 * same snapshot the main widget draws; energy is read from the shared core when the app comes to the front; the
 * nutrition numbers are published by the Food page, as the iPhone's food model publishes them.
 */
object DayWidgets {
    private const val PREFS = "noop_widget"
    private const val KEY_ENERGY = "energyWidget"
    private const val KEY_FOOD = "foodWidget"

    data class Energy(val day: String, val total: Double?, val active: Double?, val projected: Double?)
    data class Food(val day: String, val eaten: Double, val goal: Double?, val protein: Double, val carbs: Double, val fat: Double,
                    val proteinGoal: Double?, val carbsGoal: Double?, val fatGoal: Double?) {
        val left: Double? get() = goal?.let { maxOf(0.0, it - eaten) }
    }

    private fun placed(context: Context, receiver: Class<*>) =
        AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context, receiver)).isNotEmpty()

    /** Today's energy from the core, stored and redrawn when an energy widget is placed and it changed. */
    suspend fun refreshEnergy(context: Context) {
        val app = context.applicationContext
        if (!placed(app, EnergyWidgetReceiver::class.java) || !com.noop.core.SwiftCore.available) return
        val today = LocalDate.now().toString()
        val dismissed = runCatching { com.noop.ui.forge.dismissedTrainingWorkouts(app) }.getOrDefault(emptyList())
        // The Today card's own read (`energy.today`), so the widget and the card name one figure.
        val summary = runCatching { com.noop.core.CoreEnergyDetail.today(app, dismissed) }.getOrNull()
        val json = JSONObject().put("day", today).apply {
            summary?.total?.let { put("total", it) }; summary?.active?.let { put("active", it) }
            summary?.projected?.let { put("projected", it) }
        }.toString()
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getString(KEY_ENERGY, null) == json) return
        prefs.edit().putString(KEY_ENERGY, json).apply()
        runCatching { EnergyGlanceWidget().updateAll(app) }
    }

    /** Today's eating from the Food page; only today's day is published, as the iPhone does. */
    suspend fun publishFood(context: Context, day: String, totals: Map<String, Double>, goal: Double?, proteinGoal: Double?,
                            carbsGoal: Double?, fatGoal: Double?) {
        val app = context.applicationContext
        if (day != LocalDate.now().toString() || !placed(app, FoodWidgetReceiver::class.java)) return
        val json = JSONObject().put("day", day).put("eaten", totals["energy_kcal"] ?: 0.0)
            .put("protein", totals["protein_g"] ?: 0.0).put("carbs", totals["carbs_g"] ?: 0.0).put("fat", totals["fat_g"] ?: 0.0)
            .apply { goal?.let { put("goal", it) }; proteinGoal?.let { put("proteinGoal", it) }
                     carbsGoal?.let { put("carbsGoal", it) }; fatGoal?.let { put("fatGoal", it) } }.toString()
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getString(KEY_FOOD, null) == json) return
        prefs.edit().putString(KEY_FOOD, json).apply()
        runCatching { FoodGlanceWidget().updateAll(app) }
    }

    /** The rings and Forge Today draw the main widget's snapshot; redraw them with it. */
    suspend fun redrawRings(context: Context) {
        runCatching { RingsGlanceWidget().updateAll(context) }
        runCatching { ForgeTodayGlanceWidget().updateAll(context) }
    }

    internal fun energy(context: Context): Energy? = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        .getString(KEY_ENERGY, null)?.let { raw -> runCatching {
            val o = JSONObject(raw)
            fun d(k: String) = if (o.has(k)) o.getDouble(k) else null
            Energy(o.getString("day"), d("total"), d("active"), d("projected")).takeIf { it.day == LocalDate.now().toString() }
        }.getOrNull() }

    internal fun food(context: Context): Food? = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        .getString(KEY_FOOD, null)?.let { raw -> runCatching {
            val o = JSONObject(raw)
            fun d(k: String) = if (o.has(k)) o.getDouble(k) else null
            Food(o.getString("day"), o.getDouble("eaten"), d("goal"), o.getDouble("protein"), o.getDouble("carbs"), o.getDouble("fat"),
                 d("proteinGoal"), d("carbsGoal"), d("fatGoal")).takeIf { it.day == LocalDate.now().toString() }
        }.getOrNull() }

    /** The coach brief's first sentence, as the iPhone's Forge Today widget shows it. */
    internal fun briefLine(context: Context): String? {
        val text = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("coachBriefText", null)
            ?.replace("**", "")?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val line = text.lineSequence().first()
        val end = line.indexOfFirst { it == '.' || it == '!' || it == '?' }
        return if (end >= 0) line.substring(0, end + 1) else line
    }
}

class RingsGlanceWidget : GlanceAppWidget() {
    // A row of the home screen is about 70 dp tall: the wide size asks for no more than that.
    override val sizeMode = SizeMode.Responsive(setOf(DpSize(100.dp, 60.dp), DpSize(240.dp, 60.dp)))
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val dark = WidgetTheme.isDark(context)
        provideContent { RingsContent(WidgetSnapshotStore.load(context), dark, forge = false, brief = null) }
    }
}

class ForgeTodayGlanceWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(DpSize(100.dp, 60.dp), DpSize(240.dp, 60.dp)))
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val dark = WidgetTheme.isDark(context)
        provideContent { RingsContent(WidgetSnapshotStore.load(context), dark, forge = true, brief = DayWidgets.briefLine(context)) }
    }
}

class EnergyGlanceWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(DpSize(150.dp, 150.dp), DpSize(300.dp, 150.dp)))
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val dark = WidgetTheme.isDark(context)
        provideContent { EnergyContent(DayWidgets.energy(context), dark) }
    }
}

class FoodGlanceWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(DpSize(150.dp, 150.dp), DpSize(300.dp, 150.dp)))
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val dark = WidgetTheme.isDark(context)
        provideContent { FoodContent(DayWidgets.food(context), dark) }
    }
}

class RingsWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = RingsGlanceWidget() }
class ForgeTodayWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = ForgeTodayGlanceWidget() }
class EnergyWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = EnergyGlanceWidget() }
class FoodWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = FoodGlanceWidget() }

private fun kcal(v: Double): String = NumberFormat.getIntegerInstance(Locale.getDefault()).format(v.roundToInt())

@Composable
private fun Ring(value: Int?, shown: String?, label: String, tint: Color, ink: WidgetInk, size: Int) {
    val context = LocalContext.current
    val density = context.resources.displayMetrics.density
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(GlanceModifier.size(size.dp), contentAlignment = Alignment.Center) {
            WidgetCharts.ring(value?.let { it / 100.0 }, tint.toArgb(), ink.track.toArgb(), (size * density).toInt(), density)?.let {
                Image(ImageProvider(it), contentDescription = null, modifier = GlanceModifier.size(size.dp), contentScale = ContentScale.Fit)
            }
            Text(shown ?: value?.toString() ?: "–", maxLines = 1, style = TextStyle(color = ColorProvider(ink.text),
                 fontSize = (size * 0.32).sp, fontWeight = FontWeight.Bold))
        }
        Text(label, maxLines = 1, style = TextStyle(color = ColorProvider(ink.secondary), fontSize = 11.sp, fontWeight = FontWeight.Medium))
    }
}

@Composable
private fun RingsContent(snap: WidgetSnapshot, dark: Boolean, forge: Boolean, brief: String?) {
    val context = LocalContext.current
    val ink = WidgetInk(dark)
    val wide = LocalSize.current.width >= 240.dp
    // The rings grow with the widget's height, from a one-row strip to a larger tile.
    val ringSize = (LocalSize.current.height.value - (if (forge && brief != null && wide) 70 else 34)).toInt().coerceIn(36, 72)
    val charge = snap.recoveryPct
    val chargeTint = charge?.let { ink.charge(it.toDouble()) } ?: ink.green
    val scale = UnitPrefs.effortScale(context)
    val effortShown = snap.effortPct?.let {
        if (scale == EffortScale.WHOOP) com.noop.ui.UnitFormatter.effortDisplay(it.toDouble(), scale) else it.toString()
    }
    Column(
        modifier = GlanceModifier.fillMaxSize().background(ColorProvider(ink.surface)).cornerRadius(16.dp)
            .clickable(actionStartActivity<MainActivity>()).padding(6.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (!wide) {
            Ring(charge, null, context.getString(R.string.fw_charge), chargeTint, ink, ringSize)
        } else {
            Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Box(GlanceModifier.defaultWeight(), contentAlignment = Alignment.Center) {
                    Ring(charge, null, context.getString(R.string.fw_charge), chargeTint, ink, ringSize)
                }
                Box(GlanceModifier.defaultWeight(), contentAlignment = Alignment.Center) {
                    Ring(snap.effortPct, effortShown, context.getString(R.string.fw_effort), ink.effort, ink, ringSize)
                }
                Box(GlanceModifier.defaultWeight(), contentAlignment = Alignment.Center) {
                    Ring(snap.restPct, null, context.getString(R.string.fw_rest), ink.rest, ink, ringSize)
                }
            }
            if (forge && brief != null) {
                Spacer(GlanceModifier.height(8.dp))
                Row(verticalAlignment = Alignment.Top) {
                    Text("✦", style = TextStyle(color = ColorProvider(ink.accent), fontSize = 12.sp))
                    Spacer(GlanceModifier.width(4.dp))
                    Text(brief, maxLines = 2, style = TextStyle(color = ColorProvider(ink.text), fontSize = 12.sp, fontWeight = FontWeight.Medium))
                }
            }
        }
    }
}

@Composable
private fun EnergyContent(energy: DayWidgets.Energy?, dark: Boolean) {
    val context = LocalContext.current
    val ink = WidgetInk(dark)
    val wide = LocalSize.current.width >= 250.dp
    Column(
        modifier = GlanceModifier.fillMaxSize().background(ColorProvider(ink.surface)).cornerRadius(16.dp)
            .clickable(actionStartActivity<MainActivity>()).padding(12.dp),
    ) {
        Text(context.getString(R.string.fw_energy), style = TextStyle(color = ColorProvider(ink.effort), fontSize = 13.sp, fontWeight = FontWeight.Bold))
        val total = energy?.total
        if (total == null) {
            Spacer(GlanceModifier.height(6.dp))
            Text(context.getString(R.string.fw_energy_none), style = TextStyle(color = ColorProvider(ink.secondary), fontSize = 12.sp))
            return@Column
        }
        Text(kcal(total), style = TextStyle(color = ColorProvider(ink.text), fontSize = 30.sp, fontWeight = FontWeight.Bold))
        Text(context.getString(R.string.fw_kcal_so_far), style = TextStyle(color = ColorProvider(ink.secondary), fontSize = 11.sp))
        Spacer(GlanceModifier.height(6.dp))
        energy.active?.let { Text(context.getString(R.string.fw_active, kcal(it)), style = TextStyle(color = ColorProvider(ink.text), fontSize = 12.sp)) }
        if (wide) energy.projected?.let {
            Text(context.getString(R.string.fw_projected, kcal(it)), style = TextStyle(color = ColorProvider(ink.secondary), fontSize = 12.sp))
        }
    }
}

@Composable
private fun FoodContent(food: DayWidgets.Food?, dark: Boolean) {
    val context = LocalContext.current
    val ink = WidgetInk(dark)
    val wide = LocalSize.current.width >= 250.dp
    val density = context.resources.displayMetrics.density
    val protein = Color(if (dark) 0xFFFF6B6B else 0xFFE5484D)
    val carbs = Color(if (dark) 0xFFFFD166 else 0xFFE0A100)
    val fat = Color(if (dark) 0xFF4FC3F7 else 0xFF0A84C6)
    Column(
        modifier = GlanceModifier.fillMaxSize().background(ColorProvider(ink.surface)).cornerRadius(16.dp)
            .clickable(actionStartActivity<MainActivity>()).padding(12.dp),
    ) {
        Text(context.getString(R.string.fw_nutrition), style = TextStyle(color = ColorProvider(ink.green), fontSize = 13.sp, fontWeight = FontWeight.Bold))
        Text(food?.let { kcal(it.left ?: it.eaten) } ?: "–", style = TextStyle(color = ColorProvider(ink.text), fontSize = 30.sp, fontWeight = FontWeight.Bold))
        Text(context.getString(when {
            food == null -> R.string.fw_nothing_logged
            food.left != null -> R.string.fw_kcal_left
            else -> R.string.fw_kcal_eaten
        }), style = TextStyle(color = ColorProvider(ink.secondary), fontSize = 11.sp))
        if (food == null) return@Column
        Spacer(GlanceModifier.height(6.dp))
        val macros = listOf(Triple(R.string.fw_protein, food.protein to food.proteinGoal, protein),
                            Triple(R.string.fw_carbs, food.carbs to food.carbsGoal, carbs),
                            Triple(R.string.fw_fat, food.fat to food.fatGoal, fat))
        macros.forEach { (name, values, tint) ->
            val (value, goal) = values
            if (wide) Row(GlanceModifier.fillMaxWidth()) {
                Text(context.getString(name), modifier = GlanceModifier.defaultWeight(), style = TextStyle(color = ColorProvider(ink.secondary), fontSize = 11.sp))
                Text(goal?.let { context.getString(R.string.fw_grams_of, kcal(value), kcal(it)) } ?: context.getString(R.string.fw_grams, kcal(value)),
                     style = TextStyle(color = ColorProvider(ink.text), fontSize = 11.sp, fontWeight = FontWeight.Medium))
            }
            val fraction = goal?.takeIf { it > 0 }?.let { (value / it).coerceIn(0.0, 1.0) } ?: 0.0
            WidgetCharts.stack(listOf(fraction to tint.toArgb(), (1 - fraction) to ink.track.toArgb()), ink.track.toArgb(),
                               ((if (wide) 260 else 120) * density).toInt(), (5 * density).toInt(), density)?.let {
                Image(ImageProvider(it), contentDescription = context.getString(name),
                      modifier = GlanceModifier.fillMaxWidth().height(5.dp), contentScale = ContentScale.FillBounds)
            }
            Spacer(GlanceModifier.height(4.dp))
        }
    }
}
