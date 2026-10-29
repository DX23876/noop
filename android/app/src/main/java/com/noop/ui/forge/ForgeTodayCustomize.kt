package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Air
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Book
import androidx.compose.material.icons.rounded.Dashboard
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.DirectionsWalk
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.LibraryAdd
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.MonitorWeight
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.Storage
import androidx.compose.material.icons.rounded.Thermostat
import androidx.compose.material.icons.rounded.TrackChanges
import androidx.compose.material.icons.rounded.ViewAgenda
import androidx.compose.material.icons.rounded.WaterDrop
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.HealthAndSafety
import androidx.compose.material.icons.rounded.Opacity
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.noop.R
import com.noop.ui.KeyMetric
import com.noop.ui.KeyMetricPrefs
import com.noop.ui.SleepLayoutPrefs
import com.noop.ui.SleepSection
import com.noop.ui.TodayLayoutPrefs
import com.noop.ui.TodaySection
import com.noop.ui.localizedTitle

/** Where the Today editor opens, after the Apple `TodayCustomizationDestination`. */
enum class TodayCustomizationDestination { Today, KeyMetrics }

/**
 * Fork (DX23876), Android parity: "Customize Today" after the Apple `TodayCustomizationSheet`. The sections page
 * orders and hides Today's sections; Key Metrics (Edit) picks the tiles, their order, tiles per row and the
 * detailed trend tiles. Nothing is written until Save, and Save writes only the groups that changed, so an
 * untouched group keeps its key unset and with it the fresh default. Back on a nested page returns to the
 * sections; on the first page it cancels unless something changed, as the Apple sheet refuses a swipe away then.
 */
@Composable
fun ForgeTodayCustomization(initial: TodayCustomizationDestination, onClose: (saved: Boolean) -> Unit) {
    val context = LocalContext.current
    val start = remember {
        object {
            val orderRaw = TodayLayoutPrefs.orderRaw(context)
            val hiddenRaw = TodayLayoutPrefs.hiddenRaw(context)
            val sections = TodayLayoutDefaults.sectionDraft(orderRaw, hiddenRaw)
            val storedHidden = TodayLayoutDefaults.layout(orderRaw, hiddenRaw).second
            val metrics = EditableLayoutDraft.of(
                KeyMetricPrefs.decodeEnabled(KeyMetricPrefs.enabledRaw(context)
                    ?: KeyMetricPrefs.encode(TodayLayoutDefaults.keyMetrics)),
                KeyMetric.entries.toList(),
            )
            val detailed = KeyMetricPrefs.detailed(context)
            val windowDays = KeyMetricPrefs.detailWindowDays(context)
            val columns = KeyMetricPrefs.columns(KeyMetricPrefs.storedColumns(context) ?: TodayLayoutDefaults.KEY_METRICS_COLUMNS)
        }
    }
    var keyMetricsOpen by rememberSaveable { mutableStateOf(initial == TodayCustomizationDestination.KeyMetrics) }
    var sections by remember { mutableStateOf(start.sections) }
    var metrics by remember { mutableStateOf(start.metrics) }
    var detailed by remember { mutableStateOf(start.detailed) }
    var windowDays by remember { mutableIntStateOf(start.windowDays) }
    var columns by remember { mutableIntStateOf(start.columns) }
    val dirty = sections != start.sections || metrics != start.metrics || detailed != start.detailed ||
        windowDays != start.windowDays || columns != start.columns

    fun save() {
        if (sections != start.sections) {
            val (order, hidden) = TodayLayoutDefaults.encodeSections(sections, start.storedHidden)
            TodayLayoutPrefs.setRaw(context, order, hidden)
        }
        if (metrics != start.metrics) KeyMetricPrefs.setEnabled(context, metrics.visible)
        if (detailed != start.detailed) KeyMetricPrefs.setDetailed(context, detailed)
        if (windowDays != start.windowDays) KeyMetricPrefs.setDetailWindowDays(context, windowDays)
        if (columns != start.columns) KeyMetricPrefs.setColumns(context, columns)
        onClose(true)
    }

    BackHandler {
        if (keyMetricsOpen) keyMetricsOpen = false else if (!dirty) onClose(false)
    }
    ForgeSceneBackdrop(ForgeBackdrop.Sky) {
        if (keyMetricsOpen) {
            ForgeEditorPage(stringResource(R.string.forge_lay_key_metrics), onCancel = null,
                            onBack = { keyMetricsOpen = false }, onSave = ::save) {
                ForgeEditableLayoutList(
                    metrics, { metrics = it },
                    stringResource(R.string.forge_lay_shown), stringResource(R.string.forge_lay_hidden),
                    LayoutRowStyle(title = { stringResource(it.titleRes) }, icon = { it.icon }, tint = { it.tint() }),
                    onReset = {
                        metrics = EditableLayoutDraft.of(TodayLayoutDefaults.keyMetrics, KeyMetric.entries.toList())
                        detailed = false; windowDays = 14; columns = TodayLayoutDefaults.KEY_METRICS_COLUMNS
                    },
                ) {
                    KeyMetricsDisplay(detailed, { detailed = it }, windowDays, { windowDays = it }, columns, { columns = it })
                }
            }
        } else {
            val metricCount = metrics.visible.size
            ForgeEditorPage(stringResource(R.string.forge_lay_customize_today), onCancel = { onClose(false) },
                            onBack = null, onSave = ::save) {
                ForgeEditableLayoutList(
                    sections, { sections = it },
                    stringResource(R.string.forge_lay_shown_on_today), stringResource(R.string.forge_lay_hidden),
                    LayoutRowStyle(
                        title = { stringResource(it.titleRes) },
                        subtitle = {
                            if (it == TodaySection.KEY_METRICS) stringResource(R.string.forge_lay_metrics_shown, metricCount) else null
                        },
                        icon = { it.icon },
                        tint = { it.tint() },
                        configurationLabel = {
                            if (it == TodaySection.KEY_METRICS) stringResource(R.string.forge_lay_edit) else null
                        },
                        onConfigure = { if (it == TodaySection.KEY_METRICS) keyMetricsOpen = true },
                    ),
                    onReset = { sections = TodayLayoutDefaults.defaultSectionDraft() },
                )
            }
        }
    }
}

/** The Key Metrics page's Display group: tiles per row, detailed tiles and their trend window. */
@Composable
private fun KeyMetricsDisplay(detailed: Boolean, onDetailed: (Boolean) -> Unit, windowDays: Int, onWindow: (Int) -> Unit,
                              columns: Int, onColumns: (Int) -> Unit) {
    val colors = Forge.colors
    EditorGroup(stringResource(R.string.forge_lay_display), null) {
        Column(Modifier.padding(ForgeMetrics.space4), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            Text(stringResource(R.string.forge_lay_tiles_per_row), style = Forge.type.body, color = colors.text)
            Segments(KeyMetricPrefs.columnChoices.map { it to it.toString() }, columns, onColumns)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
                    Text(stringResource(R.string.forge_lay_detailed), style = Forge.type.body, color = colors.text)
                    Text(stringResource(R.string.forge_lay_detailed_detail), style = Forge.type.caption, color = colors.textSecondary)
                }
                Switch(detailed, onDetailed, colors = forgeSwitchColors())
            }
            if (detailed) {
                Text(stringResource(R.string.forge_lay_trend_window), style = Forge.type.body, color = colors.text)
                Segments(listOf(7 to stringResource(R.string.forge_lay_1_week), 14 to stringResource(R.string.forge_lay_2_weeks),
                                30 to stringResource(R.string.forge_lay_1_month)), windowDays, onWindow)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Segments(choices: List<Pair<Int, String>>, selected: Int, onSelect: (Int) -> Unit) {
    val colors = Forge.colors
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        choices.forEachIndexed { i, (value, label) ->
            SegmentedButton(
                selected = value == selected, onClick = { onSelect(value) },
                shape = SegmentedButtonDefaults.itemShape(i, choices.size),
                colors = SegmentedButtonDefaults.colors(activeContainerColor = colors.accent.copy(alpha = 0.18f),
                                                        activeContentColor = colors.text, inactiveContentColor = colors.textSecondary),
                icon = {},
            ) { Text(label, style = Forge.type.subhead) }
        }
    }
}

/** "Customize Sleep" after the Apple `SleepCustomizationSheet`: one page, the cards Forge Sleep draws. */
@Composable
fun ForgeSleepCustomization(onClose: (saved: Boolean) -> Unit) {
    val context = LocalContext.current
    val start = remember {
        val order = SleepLayoutPrefs.orderRaw(context); val hidden = SleepLayoutPrefs.hiddenRaw(context)
        Triple(order, hidden, SleepLayoutDefaults.draft(order, hidden))
    }
    var draft by remember { mutableStateOf(start.third) }
    BackHandler { if (draft == start.third) onClose(false) }
    ForgeSceneBackdrop(ForgeBackdrop.Sky) {
        ForgeEditorPage(stringResource(R.string.forge_lay_customize_sleep), onCancel = { onClose(false) }, onBack = null,
                        onSave = {
                            val (order, hidden) = SleepLayoutDefaults.encode(draft, start.first, start.second)
                            SleepLayoutPrefs.setRaw(context, order, hidden)
                            onClose(true)
                        }) {
            ForgeEditableLayoutList(
                draft, { draft = it },
                stringResource(R.string.forge_lay_shown), stringResource(R.string.forge_lay_hidden),
                LayoutRowStyle(title = { it.localizedTitle() }, icon = { it.icon }, tint = { it.tint() }),
                onReset = { draft = SleepLayoutDefaults.defaultDraft() },
            )
        }
    }
}

// MARK: - Row icons and tints, after the Apple `customizationIcon` / `customizationTint`

private val TodaySection.icon: ImageVector
    get() = when (this) {
        TodaySection.COACH, TodaySection.SYNTHESIS -> Icons.Rounded.AutoAwesome
        TodaySection.HERO -> Icons.Rounded.Speed
        TodaySection.LIVE_SESSION, TodaySection.WORKOUTS -> Icons.Rounded.DirectionsRun
        TodaySection.GOALS -> Icons.Rounded.TrackChanges
        TodaySection.KEY_METRICS -> Icons.Rounded.GridView
        TodaySection.TRAINING_LOAD -> Icons.Rounded.BarChart
        TodaySection.ENERGY -> Icons.Rounded.LocalFireDepartment
        TodaySection.HEART_RATE -> Icons.Rounded.MonitorHeart
        TodaySection.RECOVERY_VITALS -> Icons.Rounded.HealthAndSafety
        TodaySection.YOUR_CARDS -> Icons.Rounded.ViewAgenda
        TodaySection.MENSTRUAL_CYCLE -> Icons.Rounded.Opacity
        TodaySection.JOURNAL -> Icons.Rounded.Book
        TodaySection.DATA_SOURCES -> Icons.Rounded.Storage
        TodaySection.ADDED_CARDS -> Icons.Rounded.LibraryAdd
    }

@Composable
private fun TodaySection.tint(): Color {
    val c = Forge.colors
    return when (this) {
        TodaySection.COACH, TodaySection.SYNTHESIS, TodaySection.YOUR_CARDS, TodaySection.ADDED_CARDS -> c.accent
        TodaySection.HERO, TodaySection.GOALS -> c.charge
        TodaySection.LIVE_SESSION, TodaySection.TRAINING_LOAD, TodaySection.RECOVERY_VITALS -> ForgeTokens.Color.systemCyan.resolve()
        TodaySection.KEY_METRICS -> ForgeTokens.Color.systemPurple.resolve()
        TodaySection.ENERGY, TodaySection.JOURNAL -> ForgeTokens.Color.systemOrange.resolve()
        TodaySection.WORKOUTS -> c.effort
        TodaySection.HEART_RATE -> c.heart
        TodaySection.MENSTRUAL_CYCLE -> c.rest
        TodaySection.DATA_SOURCES -> c.textSecondary
    }
}

internal val KeyMetric.icon: ImageVector
    get() = when (this) {
        KeyMetric.CHARGE -> Icons.Rounded.Bolt
        KeyMetric.EFFORT -> Icons.Rounded.DirectionsRun
        KeyMetric.REST -> Icons.Rounded.Bedtime
        KeyMetric.HRV -> Icons.Rounded.MonitorHeart
        KeyMetric.RESTING_HR -> Icons.Rounded.Favorite
        KeyMetric.BLOOD_OXYGEN -> Icons.Rounded.WaterDrop
        KeyMetric.RESPIRATORY -> Icons.Rounded.Air
        KeyMetric.STEPS -> Icons.Rounded.DirectionsWalk
        KeyMetric.WEIGHT -> Icons.Rounded.MonitorWeight
        KeyMetric.CALORIES -> Icons.Rounded.LocalFireDepartment
        KeyMetric.SKIN_TEMP -> Icons.Rounded.Thermostat
    }

@Composable
internal fun KeyMetric.tint(): Color {
    val c = Forge.colors
    return when (this) {
        KeyMetric.CHARGE -> c.charge
        KeyMetric.EFFORT -> c.effort
        KeyMetric.REST, KeyMetric.HRV -> ForgeTokens.Color.systemPurple.resolve()
        KeyMetric.RESTING_HR -> c.heart
        KeyMetric.BLOOD_OXYGEN, KeyMetric.STEPS -> ForgeTokens.Color.systemCyan.resolve()
        KeyMetric.RESPIRATORY, KeyMetric.WEIGHT -> c.accent
        KeyMetric.CALORIES, KeyMetric.SKIN_TEMP -> ForgeTokens.Color.systemOrange.resolve()
    }
}

private val SleepSection.icon: ImageVector
    get() = if (this == SleepSection.SLEEP_DEBT) Icons.Rounded.Dashboard else Icons.Rounded.BarChart

@Composable
private fun SleepSection.tint(): Color = if (this == SleepSection.SLEEP_DEBT) Forge.colors.effort else Forge.colors.rest
