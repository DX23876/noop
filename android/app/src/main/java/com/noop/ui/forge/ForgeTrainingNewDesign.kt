package com.noop.ui.forge

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.EventNote
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.Flag
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreTraining
import com.noop.data.WorkoutRow

/*
 * Fork (DX23876), Forge parity 2026-11: the Training tab's cards in the new design, rebuilt from iOS's
 * `ForgeTrainingView`: today's planned routine with its Start, "Your week" over the week's training goals, the
 * routines as a sideways row of cards, the recent activities as one grouped list with Effort on the right, the
 * grouped analysis rows under Key metrics and the Tools group.
 */

/** A section head with a link on the right, as iOS's `sectionHeader(_:link:route:)`. */
@Composable
internal fun TrainingSectionHead(title: String, link: String?, onLink: () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space1).padding(top = ForgeMetrics.space3),
        verticalAlignment = Alignment.Bottom) {
        Text(title, style = Forge.type.title2, color = Forge.sceneInk.text, modifier = Modifier.weight(1f))
        if (link != null) Text(link, style = Forge.type.subhead, color = Forge.colors.effort,
                               modifier = Modifier.clickable(role = Role.Button, onClick = onLink).padding(vertical = 4.dp))
    }
}

/** Today's routine from the plan with its Start, as iOS's `todayPlan`; nothing when no routine is planned today. */
@Composable
internal fun TrainingPlannedToday(routine: CoreTraining.Routine, onStart: () -> Unit) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.CalendarMonth, contentDescription = null, tint = colors.effort, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text(stringResource(R.string.forge_tr_planned_today), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = colors.effort)
        }
        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth().background(colors.inset.copy(alpha = 0.6f), RoundedCornerShape(12.dp)).padding(12.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(38.dp).background(colors.effort.copy(alpha = 0.15f), CircleShape), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.FitnessCenter, contentDescription = null, tint = colors.effort, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(ForgeMetrics.space3))
            Column(Modifier.weight(1f)) {
                Text(routine.title, style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = colors.text,
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(pluralStringResource(R.plurals.forge_nx_exercises, routine.exerciseIds.size, routine.exerciseIds.size),
                     style = Forge.type.caption, color = colors.textSecondary)
            }
            Row(Modifier.heightIn(min = 40.dp).background(colors.effort, CircleShape)
                    .clickable(role = Role.Button, onClick = onStart).padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.PlayArrow, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text(stringResource(R.string.forge_nx_start), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                     color = Color.White)
            }
        }
    }
}

/** The routines as a sideways row of cards, as iOS's `routines`: a tap starts one, a long press edits it. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun TrainingRoutineRow(routines: List<CoreTraining.Routine>, onStart: (CoreTraining.Routine) -> Unit,
                                onEdit: (CoreTraining.Routine) -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        routines.forEach { routine ->
            val label = stringResource(R.string.forge_tr_start_named, routine.title)
            Column(Modifier.width(150.dp).height(140.dp).background(colors.surface, RoundedCornerShape(12.dp))
                       .combinedClickable(role = Role.Button, onClick = { onStart(routine) }, onLongClick = { onEdit(routine) })
                       .semantics { contentDescription = label }.padding(14.dp)) {
                Box(Modifier.size(40.dp).background(colors.effort.copy(alpha = 0.16f), CircleShape), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.FitnessCenter, contentDescription = null, tint = colors.effort, modifier = Modifier.size(20.dp))
                }
                Spacer(Modifier.weight(1f))
                Text(routine.title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text,
                     maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(pluralStringResource(R.plurals.forge_nx_exercises, routine.exerciseIds.size, routine.exerciseIds.size),
                     style = Forge.type.caption, color = colors.textSecondary, maxLines = 1)
            }
        }
    }
}

/** The last five sessions of any kind as one grouped list, as iOS's `recentActivities`, Effort on the right. */
@Composable
internal fun TrainingRecentList(workouts: List<WorkoutRow>, onOpen: (WorkoutRow) -> Unit) {
    val colors = Forge.colors
    val now = System.currentTimeMillis() / 1000
    val rows = workouts.filter { it.startTs >= now - 30 * 86_400 }.sortedByDescending { it.startTs }.take(5)
    if (rows.isEmpty()) {
        Text(stringResource(R.string.forge_tr_recent_empty), style = Forge.type.body, color = colors.textSecondary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        return
    }
    val effortFormat = rememberEffortFormat()
    val zone = java.time.ZoneId.systemDefault()
    val locale = java.util.Locale.getDefault()
    val dayFormat = java.time.format.DateTimeFormatter.ofPattern(android.text.format.DateFormat.getBestDateTimePattern(locale, "EEEdMMM"), locale)
    val clock = rememberClockFormatter()
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
        rows.forEachIndexed { i, row ->
            if (i > 0) Box(Modifier.padding(start = 64.dp).fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider))
            val start = java.time.Instant.ofEpochSecond(row.startTs).atZone(zone)
            val minutes = ((row.durationS ?: (row.endTs - row.startTs).coerceAtLeast(0).toDouble()) / 60).toInt()
            Row(Modifier.fillMaxWidth().clickable(role = Role.Button) { onOpen(row) }.padding(horizontal = 14.dp, vertical = 12.dp)
                    .semantics(mergeDescendants = true) { }, verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(38.dp).background(colors.accent.copy(alpha = 0.15f), CircleShape), contentAlignment = Alignment.Center) {
                    Icon(com.noop.ui.sportIcon(row.sport), contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
                }
                Spacer(Modifier.width(ForgeMetrics.space3))
                Column(Modifier.weight(1f)) {
                    Text(com.noop.ui.WorkoutEditing.displaySport(row.sport), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                         color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(stringResource(R.string.forge_lw_when, start.format(dayFormat), start.format(clock),
                                        stringResource(R.string.forge_tw_min, minutes)),
                         style = Forge.type.caption, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                row.strain?.let { e ->
                    Spacer(Modifier.width(ForgeMetrics.space2))
                    Column(horizontalAlignment = Alignment.End) {
                        Text(effortFormat(e), style = Forge.type.headline, color = colors.text)
                        Text(stringResource(R.string.forge_effort), style = Forge.type.caption, color = colors.textSecondary)
                    }
                }
                Spacer(Modifier.width(ForgeMetrics.space2))
                Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
            }
        }
    }
}

/** One row of a grouped list: a coloured icon tile, title and subtitle, the chevron, as iOS's `ForgeRow`. */
@Composable
internal fun TrainingGroupRow(icon: ImageVector, tint: Color, title: String, subtitle: String, divider: Boolean, onClick: () -> Unit) {
    val colors = Forge.colors
    if (divider) Box(Modifier.padding(start = 56.dp).fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider))
    Row(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onClick).padding(horizontal = ForgeMetrics.space4, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(28.dp).background(tint, RoundedCornerShape(7.dp)), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(Modifier.weight(1f)) {
            Text(title, style = Forge.type.body, color = colors.text)
            Text(subtitle, style = Forge.type.caption, color = colors.textSecondary, maxLines = 2)
        }
        Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
    }
}

/** The four analysis rows under Key metrics, as iOS's `analysis` group. */
@Composable
internal fun TrainingAnalysisGroup(onLoad: () -> Unit, onStrength: () -> Unit, onCardio: () -> Unit, onGoals: () -> Unit) {
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
        TrainingGroupRow(Icons.Rounded.BarChart, ForgeTokens.Color.systemRed.resolve(), stringResource(R.string.forge_w_training_load),
                         stringResource(R.string.forge_tr_load_sub), false, onLoad)
        TrainingGroupRow(Icons.Rounded.FitnessCenter, ForgeTokens.Color.systemOrange.resolve(), stringResource(R.string.forge_th_strength),
                         stringResource(R.string.forge_tr_strength_sub), true, onStrength)
        TrainingGroupRow(Icons.Rounded.DirectionsRun, ForgeTokens.Color.systemGreen.resolve(), stringResource(R.string.forge_tl_cardio),
                         stringResource(R.string.forge_tr_cardio_sub), true, onCardio)
        TrainingGroupRow(Icons.Rounded.Flag, ForgeTokens.Color.systemBlue.resolve(), stringResource(R.string.forge_tr_goals),
                         stringResource(R.string.forge_tr_goals_sub), true, onGoals)
    }
}

/** The two planning rows iOS's Tools group opens with: this week's plan and the plan and library. */
@Composable
internal fun TrainingPlanRows(onWeekPlan: () -> Unit, onLibrary: () -> Unit) {
    val tint = Forge.colors.effort
    TrainingGroupRow(Icons.Rounded.EventNote, tint, stringResource(R.string.forge_tr_week_plan),
                     stringResource(R.string.forge_tr_week_plan_sub), false, onWeekPlan)
    TrainingGroupRow(Icons.Rounded.CalendarMonth, tint, stringResource(R.string.forge_tr_plan_library),
                     stringResource(R.string.forge_tr_plan_library_sub), true, onLibrary)
}
