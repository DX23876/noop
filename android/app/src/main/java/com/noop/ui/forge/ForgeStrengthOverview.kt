package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.EventAvailable
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.Accessibility
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreRead
import com.noop.core.CoreShadow
import com.noop.core.CoreTraining
import com.noop.ui.NoopPrefs
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.abs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The new design's Strength page, as iOS `ForgeStrengthView`: the next planned routine with Start, the tonnes lifted in
 * each of the last eight finished weeks (the shared `StrengthWeeklyVolume`, read through the training snapshot), the
 * three latest sessions, then the plan, the muscles and the full strength report. Every link opens a page that exists.
 */
@Composable
internal fun ForgeStrengthHub(onClose: () -> Unit, onStart: (String) -> Unit, onOpenPlan: () -> Unit) {
    val context = LocalContext.current
    var sub by rememberSaveable { mutableStateOf<String?>(null) }
    val revision by CoreShadow.dataRevision.collectAsState()
    val snapshot by produceState<CoreTraining.Snapshot?>(null, revision) {
        value = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val sunday = NoopPrefs.of(context).getString("training.weekStartsOn", null) == "sunday"
            CoreTraining.snapshot(dismissedTrainingWorkouts(context), weekStartsOn = if (sunday) "sunday" else "monday")
        }
    }
    when (sub) {
        SUB_DETAILS -> { BackHandler { sub = null }; ForgeStrengthPage(onClose = { sub = null }); return }
        SUB_MUSCLES -> snapshot?.let { BackHandler { sub = null }; MuscleAnalyticsPage(it.muscles, onClose = { sub = null }); return }
    }
    BackHandler(onBack = onClose)
    ForgeStrengthOverview(snapshot, onClose, onStart, onOpenPlan, onOpenMuscles = { sub = SUB_MUSCLES },
                          onOpenDetails = { sub = SUB_DETAILS })
}

private const val SUB_DETAILS = "details"
private const val SUB_MUSCLES = "muscles"

@Composable
private fun ForgeStrengthOverview(snapshot: CoreTraining.Snapshot?, onClose: () -> Unit, onStart: (String) -> Unit,
                                  onOpenPlan: () -> Unit, onOpenMuscles: () -> Unit, onOpenDetails: () -> Unit) {
    val colors = Forge.colors
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_so_strength), onClose)
        val s = snapshot ?: return@SettingsColumn
        NextUp(s, onStart, onOpenPlan)
        Volume(s.weeklyTonnes, s.fourWeekChange)
        val recent = s.sessions.sortedByDescending { it.startTs }.take(3)
        if (recent.isNotEmpty()) {
            SectionHeader(stringResource(R.string.forge_so_recent))
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
                recent.forEachIndexed { i, session ->
                    ValueRow(Icons.Rounded.FitnessCenter, colors.effort, session.title, sessionDetail(session),
                             session.workingSets.toString(), stringResource(R.string.forge_so_sets), onOpenDetails)
                    if (i < recent.lastIndex) HubDivider()
                }
            }
        }
        SectionHeader(stringResource(R.string.forge_so_plan_library))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
            HubRow(Icons.Rounded.CalendarMonth, colors.effort, stringResource(R.string.forge_so_routines),
                   stringResource(R.string.forge_so_routine_count, s.routines.size), onOpenPlan)
            HubDivider()
            HubRow(Icons.Rounded.Accessibility, colors.effort, stringResource(R.string.forge_so_muscles),
                   stringResource(R.string.forge_so_muscles_detail), onOpenMuscles)
            HubDivider()
            HubRow(Icons.Rounded.BarChart, colors.effort, stringResource(R.string.forge_so_all_details),
                   stringResource(R.string.forge_so_all_details_detail), onOpenDetails)
        }
    }
}

/** The next seven days' first planned routine (a day's own plan before the weekly schedule), as the Today card reads it. */
private fun nextPlanned(s: CoreTraining.Snapshot): Pair<LocalDate, CoreTraining.Routine>? {
    val today = com.noop.ui.logicalDayNow()
    val byId = s.routines.associateBy { it.id }
    val planned = s.week.associate { it.day to it.routineIds }
    for (offset in 0L until 7L) {
        val day = today.plusDays(offset)
        val ids = planned[day.toString()] ?: s.routines.filter { day.dayOfWeek.value in it.weekdays }.map { it.id }
        ids.firstNotNullOfOrNull { byId[it] }?.let { return day to it }
    }
    return null
}

@Composable
private fun NextUp(s: CoreTraining.Snapshot, onStart: (String) -> Unit, onOpenPlan: () -> Unit) {
    val colors = Forge.colors
    val next = nextPlanned(s)
    if (next == null) {
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
            HubRow(Icons.Rounded.EventAvailable, colors.effort, stringResource(R.string.forge_so_plan_day),
                   stringResource(R.string.forge_so_plan_day_detail), onOpenPlan)
        }
        return
    }
    val (day, routine) = next
    val today = com.noop.ui.logicalDayNow()
    val dayText = when (day) {
        today -> stringResource(R.string.forge_so_today)
        today.plusDays(1) -> stringResource(R.string.forge_so_tomorrow)
        else -> day.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.getDefault())
    }
    val startLabel = stringResource(R.string.forge_so_start_routine, routine.title)
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.forge_so_next_up), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = colors.text, modifier = Modifier.weight(1f))
            Text(dayText, style = Forge.type.caption, color = colors.textSecondary)
        }
        Text(routine.title, style = Forge.type.title2.copy(fontWeight = FontWeight.Bold), color = colors.text)
        Text(pluralStringResource(R.plurals.forge_nx_exercises, routine.exerciseCount, routine.exerciseCount),
             style = Forge.type.caption, color = colors.textSecondary)
        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth().heightIn(min = 50.dp).background(colors.effort, CircleShape)
                .clickable(role = Role.Button) { onStart(routine.id) }.semantics { contentDescription = startLabel },
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.PlayArrow, contentDescription = null, tint = colors.onDark, modifier = Modifier.size(20.dp))
            Text(stringResource(R.string.forge_so_start), style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold),
                 color = colors.onDark, modifier = Modifier.padding(start = ForgeMetrics.space1))
        }
    }
}

/** Eight bars of tonnes per finished week, last week full strength, with the four-week comparison under them. */
@Composable
private fun Volume(tonnes: List<Double>, change: Int?) {
    if (tonnes.none { it > 0 }) return
    val colors = Forge.colors
    val top = maxOf(tonnes.maxOrNull() ?: 1.0, 0.1)
    val spoken = stringResource(R.string.forge_so_volume_spoken)
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(stringResource(R.string.forge_so_volume), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = colors.text, modifier = Modifier.weight(1f))
            Text(stringResource(R.string.forge_so_tonnes_week), style = Forge.type.caption, color = colors.textSecondary)
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Row(Modifier.fillMaxWidth().height(90.dp).semantics(mergeDescendants = true) {
                contentDescription = spoken + ": " + tonnes.joinToString(", ") { String.format(Locale.getDefault(), "%.1f", it) }
            },
            horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Bottom) {
            tonnes.forEachIndexed { i, t ->
                Box(Modifier.weight(1f).height(maxOf(4.0, 90 * t / top).dp)
                        .background(colors.effort.copy(alpha = if (i == tonnes.lastIndex) 1f else 0.55f), RoundedCornerShape(5.dp)))
            }
        }
        change?.let { pct ->
            Spacer(Modifier.height(ForgeMetrics.space2))
            Text(when {
                abs(pct) < 3 -> stringResource(R.string.forge_so_change_same)
                pct > 0 -> stringResource(R.string.forge_so_change_up, pct)
                else -> stringResource(R.string.forge_so_change_down, -pct)
            }, style = Forge.type.caption, color = colors.textSecondary)
        }
    }
}

@Composable
private fun sessionDetail(session: CoreTraining.Session): String {
    val locale = Locale.getDefault()
    val day = Instant.ofEpochSecond(session.startTs).atZone(ZoneId.systemDefault())
    val date = day.format(DateTimeFormatter.ofPattern(android.text.format.DateFormat.getBestDateTimePattern(locale, WEEKDAY_DAY_MONTH), locale))
    val minutes = (session.durationS / 60).toInt()
    return if (minutes > 0) stringResource(R.string.forge_join_dot, date, stringResource(R.string.forge_so_minutes, minutes)) else date
}

private const val WEEKDAY_DAY_MONTH = "EEEdMMM"

/** A row with a value at its end (iOS `ForgeRow` with `value` and `unit`): icon tile, title over subtitle, the figure. */
@Composable
private fun ValueRow(icon: androidx.compose.ui.graphics.vector.ImageVector, tint: androidx.compose.ui.graphics.Color,
                     title: String, subtitle: String, value: String, unit: String, onClick: () -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = ForgeMetrics.space4, vertical = ForgeMetrics.space3),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(30.dp).background(tint, RoundedCornerShape(8.4.dp)), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = colors.onDark, modifier = Modifier.size(15.dp))
        }
        Column(Modifier.weight(1f).padding(horizontal = ForgeMetrics.space3)) {
            Text(title, style = Forge.type.body, color = colors.text)
            Text(subtitle, style = Forge.type.subhead, color = colors.textSecondary)
        }
        Text(value, style = Forge.type.bodyNumber.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
        Text(unit, style = Forge.type.caption, color = colors.textSecondary, modifier = Modifier.padding(start = ForgeMetrics.space1))
    }
}
