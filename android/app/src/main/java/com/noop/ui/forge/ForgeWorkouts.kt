package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.FilterList
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.data.WorkoutRow
import com.noop.ui.AppViewModel
import com.noop.ui.NoopPrefs
import com.noop.ui.UnitFormatter
import com.noop.ui.UnitPrefs
import com.noop.ui.WorkoutEditing
import com.noop.ui.WorkoutSource
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.TemporalAdjusters
import java.util.Locale

/**
 * Fork (DX23876), Forge parity 2026-11: the Workouts page as iOS's `ForgeWorkoutsView`: thirteen weeks of activity as a
 * calendar, this week in numbers, and the sessions grouped by week. Each session opens its detail; holding one edits,
 * relabels or removes it as the classic list allows; a session can be added afterwards. The classic list stays one
 * tap away under "Manage sessions" for its filters, multi-select and merging. Analysis migration required: no.
 */
@Composable
internal fun ForgeWorkoutsPage(viewModel: AppViewModel, onBack: () -> Unit) {
    val context = LocalContext.current
    var managing by remember { mutableStateOf(false) }
    if (managing) {
        BackHandler { managing = false }
        Hosted(stringResource(R.string.forge_wk_manage), onBack = { managing = false }) { com.noop.ui.WorkoutsScreen(viewModel) }
        return
    }
    val onManage = { managing = true }
    val colors = Forge.colors
    val all by viewModel.workouts.collectAsState()
    val zone = ZoneId.systemDefault()
    val today = LocalDate.now(zone)
    val sundayFirst = remember { NoopPrefs.of(context).getString("training.weekStartsOn", null) == "sunday" }
    val firstDay = if (sundayFirst) DayOfWeek.SUNDAY else DayOfWeek.MONDAY
    fun weekStart(d: LocalDate): LocalDate = d.with(TemporalAdjusters.previousOrSame(firstDay))
    fun dayOf(r: WorkoutRow): LocalDate = Instant.ofEpochSecond(r.startTs).atZone(zone).toLocalDate()
    val thisWeek = weekStart(today)
    val first = thisWeek.minusWeeks(12)
    val rows = all.filter { !dayOf(it).isBefore(first) }.sortedByDescending { it.startTs }
    var editing by remember { mutableStateOf<Pair<WorkoutRow?, Boolean>?>(null) }
    var detail by remember { mutableStateOf<WorkoutRow?>(null) }
    BackHandler(onBack = onBack)
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_wk_title), onBack)
        Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            ActionChip(Icons.Rounded.Add, stringResource(R.string.forge_wk_add), prominent = true) { editing = null to false }
            ActionChip(Icons.Rounded.FilterList, stringResource(R.string.forge_wk_manage), prominent = false, onClick = onManage)
        }
        val weekOfFormat = DateTimeFormatter.ofPattern(android.text.format.DateFormat.getBestDateTimePattern(Locale.getDefault(), DAY_MONTH_ONLY), Locale.getDefault())
        CalendarCard(rows, first, today, ::dayOf)
        WeekNumbers(rows.filter { !dayOf(it).isBefore(thisWeek) })
        rows.groupBy { weekStart(dayOf(it)) }.toSortedMap(compareByDescending { it }).forEach { (start, week) ->
            Text(when (start) {
                thisWeek -> stringResource(R.string.forge_wk_this_week)
                thisWeek.minusWeeks(1) -> stringResource(R.string.forge_wk_last_week)
                else -> stringResource(R.string.forge_wk_week_of, start.format(weekOfFormat))
            }, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.sceneInk.secondary,
                 modifier = Modifier.padding(start = ForgeMetrics.space1, top = ForgeMetrics.space1))
            ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
                week.forEachIndexed { i, row ->
                    if (i > 0) Box(Modifier.padding(start = 64.dp).fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider))
                    SessionRow(viewModel, row, onOpen = { detail = row }, onEdit = { r, copy -> editing = r to copy })
                }
            }
        }
        if (rows.isEmpty()) {
            Text(stringResource(R.string.forge_wk_empty), style = Forge.type.body, color = Forge.sceneInk.secondary,
                 modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        }
    }
    detail?.let { row -> com.noop.ui.WorkoutDetailSheet(vm = viewModel, row = row, onDismiss = { detail = null }) }
    editing?.let { (row, copy) ->
        com.noop.ui.ManualWorkoutDialog(editing = row, isCopy = copy, onDismiss = { editing = null }, onSave = { saved, replacing ->
            viewModel.saveManualWorkout(saved, if (copy) null else replacing)
            editing = null
        })
    }
}

/** The day and month skeleton for "Week of …", localised by `getBestDateTimePattern`. */
private const val DAY_MONTH_ONLY = "dMMM"

/** A capsule action at the top of the page, as iOS's `ForgeWorkoutActionChip`. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ActionChip(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, prominent: Boolean, onClick: () -> Unit) {
    val colors = Forge.colors
    val fill = if (prominent) colors.charge else colors.inset
    val ink = if (prominent) Color.White else colors.text
    Row(Modifier.heightIn(min = 44.dp).clip(CircleShape).background(fill).combinedClickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = ForgeMetrics.space4), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(icon, null, tint = ink, modifier = Modifier.size(18.dp))
        Text(title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = ink)
    }
}

/** Active energy (or Effort when energy is missing) per day for the last 13 weeks, one column per week. */
@Composable
private fun CalendarCard(rows: List<WorkoutRow>, first: LocalDate, today: LocalDate, dayOf: (WorkoutRow) -> LocalDate) {
    val colors = Forge.colors
    val load = rows.groupBy(dayOf).mapValues { (_, r) -> r.sumOf { it.energyKcal ?: (it.strain ?: 0.0) * 8 } }
    val top = (load.values.maxOrNull() ?: 1.0).coerceAtLeast(1.0)
    val dark = colors.dark
    val steps = if (dark) listOf(0xFF6E2412, 0xFFA83A16, 0xFFE0601E, 0xFFFF9447) else listOf(0xFFFFD8BF, 0xFFFFB07A, 0xFFF5803A, 0xFFD4560F)
    val label = stringResource(R.string.forge_wk_cal_label)
    val value = stringResource(R.string.forge_wk_cal_value, load.keys.size)
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = ForgeMetrics.space4) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(stringResource(R.string.forge_wk_13), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text,
                 modifier = Modifier.weight(1f))
            Text(stringResource(R.string.forge_wk_13_sub), style = Forge.type.caption, color = colors.textSecondary)
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Row(Modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = label; stateDescription = value },
            horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            repeat(13) { w ->
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    repeat(7) { d ->
                        val day = first.plusDays((w * 7 + d).toLong())
                        val v = load[day] ?: 0.0
                        val fill = when {
                            day.isAfter(today) -> Color.Transparent
                            v > 0 -> Color(steps[minOf(3, (v / top * 4).toInt())])
                            else -> colors.inset
                        }
                        Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(4.dp)).background(fill))
                    }
                }
            }
        }
    }
}

/** This week's count, time and Effort total, as iOS's `weekNumbers`. */
@Composable
private fun WeekNumbers(week: List<WorkoutRow>) {
    val effortFormat = rememberEffortFormat()
    val minutes = week.sumOf { (it.durationS ?: (it.endTs - it.startTs).coerceAtLeast(0).toDouble()) / 60 }.let { Math.round(it).toInt() }
    val time = if (minutes < 60) stringResource(R.string.forge_wk_min, minutes)
               else stringResource(R.string.forge_wk_h_min, minutes / 60, "%02d".format(minutes % 60))
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = ForgeMetrics.space4) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Stat(week.size.toString(), stringResource(R.string.forge_wk_this_week_n), Modifier.weight(1f))
            Stat(time, stringResource(R.string.forge_wk_time), Modifier.weight(1f))
            Stat(effortFormat(week.mapNotNull { it.strain }.sum()), stringResource(R.string.forge_wk_effort_total), Modifier.weight(1f))
        }
    }
}

@Composable
private fun Stat(value: String, label: String, modifier: Modifier) {
    Column(modifier.semantics(mergeDescendants = true) {}) {
        Text(value, style = Forge.type.title2.copy(fontWeight = FontWeight.Bold), color = Forge.colors.text, maxLines = 1)
        Text(label, style = Forge.type.caption, color = Forge.colors.textSecondary)
    }
}

/** One session: its sport, when and how long (and how far), its Effort; holding it shows what can be done with it. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionRow(viewModel: AppViewModel, row: WorkoutRow, onOpen: () -> Unit, onEdit: (WorkoutRow, Boolean) -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val effortFormat = rememberEffortFormat()
    val clock = rememberClockFormatter()
    val zone = ZoneId.systemDefault()
    val locale = Locale.getDefault()
    val start = Instant.ofEpochSecond(row.startTs).atZone(zone)
    val minutes = ((row.durationS ?: (row.endTs - row.startTs).coerceAtLeast(0).toDouble()) / 60).toInt()
    val parts = listOfNotNull(start.format(DateTimeFormatter.ofPattern("EEE", locale)) + " " + start.format(clock),
                              stringResource(R.string.forge_wk_min, minutes),
                              row.distanceM?.takeIf { it > 0 }?.let { UnitFormatter.distanceFromMeters(it, UnitPrefs.distanceSystem(context)) })
    var menu by remember { mutableStateOf(false) }
    var relabel by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.fillMaxWidth().combinedClickable(role = Role.Button, onClick = onOpen, onLongClick = { menu = true })
                .padding(horizontal = 14.dp, vertical = 12.dp).semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(38.dp).background(colors.effort.copy(alpha = 0.15f), CircleShape), contentAlignment = Alignment.Center) {
                Icon(com.noop.ui.sportIcon(row.sport), contentDescription = null, tint = colors.effort, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(ForgeMetrics.space3))
            Column(Modifier.weight(1f)) {
                Text(WorkoutEditing.displaySport(row.sport), style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold),
                     color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(parts.joinToString(" · "), style = Forge.type.caption, color = colors.textSecondary, maxLines = 1,
                     overflow = TextOverflow.Ellipsis)
            }
            row.strain?.let { e ->
                Spacer(Modifier.width(ForgeMetrics.space2))
                Column(horizontalAlignment = Alignment.End) {
                    Text(effortFormat(e), style = Forge.type.headline, color = colors.effort)
                    Text(stringResource(R.string.forge_effort), style = Forge.type.caption, color = colors.textSecondary)
                }
            }
            Spacer(Modifier.width(ForgeMetrics.space2))
            Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
        }
        // The classic list's choices: imported history stays read-only and can only be copied.
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            when (WorkoutEditing.classify(row.source)) {
                WorkoutSource.DETECTED -> {
                    DropdownMenuItem(text = { Text(stringResource(R.string.l10n_workouts_screen_re_label_as_33fec7b2)) },
                                     onClick = { menu = false; relabel = true })
                    DropdownMenuItem(text = { Text(stringResource(R.string.l10n_workouts_screen_edit_details_9e62bb59)) },
                                     onClick = { menu = false; onEdit(row, false) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.l10n_workouts_screen_dismiss_not_a_workout_560c7bb5), color = colors.effort) },
                                     onClick = { menu = false; viewModel.dismissDetected(row) })
                }
                WorkoutSource.MANUAL -> {
                    DropdownMenuItem(text = { Text(stringResource(R.string.l10n_workouts_screen_edit_b454359e)) },
                                     onClick = { menu = false; onEdit(row, false) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.l10n_workouts_screen_delete_f6fdbe48), color = colors.effort) },
                                     onClick = { menu = false; viewModel.deleteWorkout(row) })
                }
                else -> DropdownMenuItem(text = { Text(stringResource(R.string.l10n_workouts_screen_duplicate_as_manual_2d580d46)) },
                                         onClick = { menu = false; onEdit(WorkoutEditing.asManualCopy(row), true) })
            }
        }
        DropdownMenu(expanded = relabel, onDismissRequest = { relabel = false }) {
            WorkoutEditing.relabelSports.forEach { sport ->
                DropdownMenuItem(text = { Text(sport) }, onClick = { relabel = false; viewModel.relabelDetected(row, sport) })
            }
        }
    }
}
