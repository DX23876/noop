package com.noop.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.LocalContext
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.noop.R
import com.noop.ui.MainActivity
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 2.3: the goals widget (iOS `NOOPGoalWidget`): the goals Today's card picks
 * (`GoalSpotlight`, up to three that need a look first), each with its progress, and how many daily goals are done.
 * Renders purely from the `noop_widget` preferences the app writes whenever it shows the goals; never reads the store.
 */
class GoalsGlanceWidget : GlanceAppWidget() {
    data class Goal(val name: String, val progress: String, val fraction: Double, val state: String)

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val dark = WidgetTheme.isDark(context)
        // Read inside the composition: `publish`'s `updateAll` recomposes a session that is still running rather
        // than calling `provideGlance` again, so a read out here kept showing what the session started with.
        provideContent {
            val (goals, summary) = stored(context)
            GoalsWidgetContent(goals, summary, dark)
        }
    }

    private fun stored(context: Context): Pair<List<Goal>, String> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
        val o = raw?.let { runCatching { JSONObject(it) }.getOrNull() }
        val goals = o?.optJSONArray("goals")?.let { a ->
            (0 until a.length()).map { a.getJSONObject(it) }
                .map { Goal(it.getString("name"), it.getString("progress"), it.optDouble("fraction", 0.0), it.optString("state")) }
        }.orEmpty()
        return goals to o?.optString("summary").orEmpty()
    }

    companion object {
        private const val PREFS = "noop_widget"
        private const val KEY = "goalsWidget"

        /** Stores what the widget draws and redraws it, only when a goals widget is placed and something changed. */
        suspend fun publish(context: Context, goals: List<Goal>, summary: String) {
            val app = context.applicationContext
            val ids = AppWidgetManager.getInstance(app).getAppWidgetIds(ComponentName(app, GoalsWidgetReceiver::class.java))
            if (ids.isEmpty()) return
            val json = JSONObject().put("summary", summary).put("goals", JSONArray(goals.map {
                JSONObject().put("name", it.name).put("progress", it.progress).put("fraction", it.fraction).put("state", it.state)
            })).toString()
            val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (prefs.getString(KEY, null) == json) return
            prefs.edit().putString(KEY, json).apply()
            runCatching { GoalsGlanceWidget().updateAll(app) }
        }
    }
}

/** Manifest entry point for the goals widget. */
class GoalsWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = GoalsGlanceWidget()
}

@Composable
private fun GoalsWidgetContent(goals: List<GoalsGlanceWidget.Goal>, summary: String, dark: Boolean) {
    val context = LocalContext.current
    val surface = ColorProvider(if (dark) Color(0xFF0A1322) else Color(0xFFF4F1EA))
    val textPrimary = ColorProvider(if (dark) Color(0xFFF4F6F8) else Color(0xFF1A2230))
    val textSecondary = ColorProvider(if (dark) Color(0xFF8A94A4) else Color(0xFF7C8696))
    val accent = if (dark) Color(0xFF4F9BFF) else Color(0xFF0A6CFF)
    val track = if (dark) Color(0xFF243044) else Color(0xFFE2E6EC)
    Column(
        modifier = GlanceModifier.fillMaxSize().background(surface).cornerRadius(16.dp)
            .clickable(actionStartActivity<MainActivity>()).padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalAlignment = Alignment.Start, verticalAlignment = Alignment.Top,
    ) {
        Text(context.getString(R.string.forge_goals_more_title),
             style = TextStyle(color = ColorProvider(accent), fontSize = 13.sp, fontWeight = FontWeight.Bold))
        if (summary.isNotEmpty()) Text(summary, style = TextStyle(color = textSecondary, fontSize = 11.sp))
        Spacer(GlanceModifier.height(8.dp))
        if (goals.isEmpty()) {
            Text(context.getString(R.string.forge_gw_empty),
                 style = TextStyle(color = textSecondary, fontSize = 12.sp))
        }
        goals.take(3).forEach { goal ->
            Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(goal.name, maxLines = 1, modifier = GlanceModifier.defaultWeight(),
                     style = TextStyle(color = textPrimary, fontSize = 13.sp, fontWeight = FontWeight.Medium))
                Text(goal.progress, style = TextStyle(color = textPrimary, fontSize = 13.sp))
            }
            LinearProgressIndicator(progress = goal.fraction.coerceIn(0.0, 1.0).toFloat(),
                                    modifier = GlanceModifier.fillMaxWidth().height(4.dp),
                                    color = ColorProvider(accent), backgroundColor = ColorProvider(track))
            if (goal.state.isNotEmpty()) Text(goal.state, style = TextStyle(color = textSecondary, fontSize = 10.sp))
            Spacer(GlanceModifier.height(6.dp))
        }
    }
}
