package com.noop.widget

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.ui.forge.Forge
import com.noop.ui.forge.ForgeCard
import com.noop.ui.forge.ForgeMetrics
import com.noop.ui.forge.ForgeTheme
import kotlinx.coroutines.launch

/**
 * Fork (DX23876), owner decisions 2026-11-26: a weight widget's colour, and for the countdown which date, chosen
 * when the widget is placed or edited, as iOS's widget configuration. Saving with nothing changed keeps the
 * widget's default colour.
 */
class WeightWidgetConfigureActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val id = intent?.extras?.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        // Backing out leaves a new widget unplaced, as the system expects.
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id))
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) { finish(); return }
        val provider = AppWidgetManager.getInstance(this).getAppWidgetInfo(id)?.provider?.className
        val receiver = WeightWidgets.defaults.keys.firstOrNull { it.name == provider }
        val fallback = receiver?.let { WeightWidgets.defaults[it] } ?: WeightWidgets.Tint.Pink
        val isEvent = receiver == WeightEventWidgetReceiver::class.java
        val events = if (isEvent) WeightWidgets.stored(this)?.events.orEmpty() else emptyList()
        setContent {
            ForgeTheme {
                val scope = rememberCoroutineScope()
                var tint by remember { mutableStateOf(WeightWidgets.tint(this, id, fallback)) }
                var event by remember { mutableStateOf(WeightWidgets.eventChoice(this, id)) }
                Column(Modifier.fillMaxSize().background(Forge.colors.canvas).padding(ForgeMetrics.screenPadding),
                       verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
                    Text(stringResource(R.string.wt_widget_colour), style = Forge.type.title1, color = Forge.colors.text)
                    ForgeCard(Modifier.fillMaxWidth()) {
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            WeightWidgets.Tint.entries.forEach { t ->
                                val label = stringResource(t.label)
                                Box(Modifier.size(32.dp).background(t.color(Forge.colors.dark), CircleShape)
                                        .border(3.dp, if (t == tint) Forge.colors.text else Forge.colors.surface, CircleShape)
                                        .semantics { contentDescription = label; selected = t == tint }
                                        .clickable { tint = t })
                            }
                        }
                    }
                    if (isEvent) {
                        Text(stringResource(R.string.wt_widget_which_date), style = Forge.type.headline, color = Forge.colors.text)
                        ForgeCard(Modifier.fillMaxWidth()) {
                            (listOf(null to stringResource(R.string.wt_widget_next_date)) + events.map { it.id to it.name }).forEach { (eid, name) ->
                                Row(Modifier.fillMaxWidth().clickable { event = eid }.padding(vertical = ForgeMetrics.space2),
                                    verticalAlignment = Alignment.CenterVertically) {
                                    Text(name, style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
                                    if (event == eid) Text("✓", style = Forge.type.headline, color = tint.color(Forge.colors.dark))
                                }
                            }
                        }
                    }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        TextButton(onClick = { finish() }) { Text(stringResource(R.string.forge_lay_cancel)) }
                        TextButton(onClick = {
                            WeightWidgets.setTint(this@WeightWidgetConfigureActivity, id, tint, event)
                            scope.launch {
                                WeightWidgets.redraw(applicationContext)
                                setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id))
                                finish()
                            }
                        }) { Text(stringResource(R.string.forge_lay_save)) }
                    }
                }
            }
        }
    }
}
