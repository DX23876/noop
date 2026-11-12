package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreCoach
import com.noop.core.CoreRead
import com.noop.core.CoreTraining
import com.noop.data.WorkoutRow
import com.noop.ui.AppViewModel
import com.noop.ui.UnitPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale

/**
 * Fork (DX23876), Forge parity 2026-11: "This week's plan" as iOS's `ForgeWeekPlanView`: each day's Effort, done as a
 * filled column and planned as a dashed outline, then the week day by day with what was done or what is planned (the
 * coach's agreed and proposed sessions and the routines on the schedule), and the way to the schedule. Analysis
 * migration required: no.
 */
@Composable
internal fun ForgeWeekPlanPage(viewModel: AppViewModel, onBack: () -> Unit, onSchedule: () -> Unit, onAsk: ((String) -> Unit)?) {
    val context = LocalContext.current
    val colors = Forge.colors
    val workouts by viewModel.workouts.collectAsState()
    val effortFormat = rememberEffortFormat()
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    data class Planned(val label: String, val effort: Double?)
    data class Loaded(val week: List<CoreTraining.PlannedDay>, val routines: Map<String, String>, val plan: List<CoreCoach.PlanRow>,
                      val effort: Map<String, Double>)
    val rest = stringResource(R.string.forge_wp_rest_day)
    val loaded by produceState<Loaded?>(null, coreRevision) {
        value = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val snap = runCatching { CoreTraining.snapshot(dismissedTrainingWorkouts(context), days = 14) }.getOrNull()
            val plan = runCatching { CoreCoach.plan(UnitPrefs.effortScale(context).raw) }.getOrNull()
            val today = LocalDate.now()
            val effort = CoreRead.series(CoreRead.Metric.Effort, today.minusDays(8).toString(), today.plusDays(7).toString())
                .associate { it.day to it.value }
            Loaded(snap?.week.orEmpty(), snap?.routines.orEmpty().associate { it.id to it.title },
                   plan?.let { it.pending + it.agreed + it.recent }.orEmpty(), effort)
        }
    }
    val l = loaded
    val zone = ZoneId.systemDefault()
    val today = LocalDate.now(zone)
    val locale = Locale.getDefault()
    val days = l?.week?.map { LocalDate.parse(it.day) } ?: emptyList()
    fun done(d: LocalDate): List<WorkoutRow> = workouts.filter { java.time.Instant.ofEpochSecond(it.startTs).atZone(zone).toLocalDate() == d }
    fun planned(d: LocalDate): List<Planned> {
        val key = d.toString()
        val coach = l?.plan.orEmpty().filter { it.day == key && it.status in setOf("proposed", "accepted", "completed", "swapped") }
            .map { Planned(if (it.intent == "rest") rest else it.summary, it.targetEffort) }
        val routines = l?.week?.firstOrNull { it.day == key }?.routineIds.orEmpty().mapNotNull { l?.routines?.get(it) }.map { Planned(it, null) }
        return coach + routines
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_tr_week_plan), onBack)
        // Effort per day: filled for what was done, dashed for a day still to come with a target.
        ForgeCard(Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(stringResource(R.string.forge_wp_effort), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                     color = colors.text, modifier = Modifier.weight(1f))
                Text(stringResource(R.string.forge_wp_legend), style = Forge.type.caption, color = colors.textSecondary)
            }
            Spacer(Modifier.height(ForgeMetrics.space2))
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                days.forEach { d ->
                    val future = d.isAfter(today)
                    val e = l?.effort?.get(d.toString())
                    val p = planned(d).mapNotNull { it.effort }.maxOrNull()
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                        Canvas(Modifier.fillMaxWidth().height(96.dp)) {
                            val r = CornerRadius(10.dp.toPx(), 10.dp.toPx())
                            drawRoundRect(colors.inset, size = size, cornerRadius = r)
                            if (e != null && !future && e > 0) {
                                val h = (size.height * (e / 100).coerceAtMost(1.0)).toFloat()
                                drawRoundRect(colors.effort, Offset(0f, size.height - h), Size(size.width, h), r)
                            } else if (p != null) {
                                val h = (size.height * (p / 100).coerceAtMost(1.0)).toFloat()
                                drawRoundRect(colors.effort, Offset(1.dp.toPx(), size.height - h + 1.dp.toPx()),
                                              Size(size.width - 2.dp.toPx(), h - 2.dp.toPx()), r,
                                              style = Stroke(2.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 4.dp.toPx()))))
                            }
                        }
                        Text(d.dayOfWeek.getDisplayName(TextStyle.NARROW, locale), style = Forge.type.caption.copy(
                                 fontWeight = if (d == today) FontWeight.Bold else FontWeight.Normal),
                             color = if (d == today) colors.effort else colors.textSecondary, modifier = Modifier.padding(top = 6.dp))
                    }
                }
            }
        }
        SleepSectionTitle(stringResource(R.string.forge_wr_this_week))
        ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
            days.forEachIndexed { i, d ->
                if (i > 0) Box(Modifier.padding(start = 72.dp).fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider))
                val doneRows = done(d); val plan = planned(d)
                val past = d.isBefore(today)
                val title = if (doneRows.isNotEmpty()) doneRows.joinToString(", ") { com.noop.ui.WorkoutEditing.displaySport(it.sport) }
                            else plan.firstOrNull()?.label ?: stringResource(if (past) R.string.forge_wp_no_workout else R.string.forge_wp_nothing)
                val effort = l?.effort?.get(d.toString())
                val detail = when {
                    doneRows.isNotEmpty() && effort != null -> stringResource(R.string.forge_wp_done_effort, effortFormat(effort))
                    plan.size > 1 -> plan.drop(1).joinToString(" · ") { it.label }
                    !past -> plan.mapNotNull { it.effort }.maxOrNull()?.let { stringResource(R.string.forge_wp_target, effortFormat(it)) }
                    else -> null
                }
                val tag = when {
                    doneRows.isNotEmpty() -> stringResource(R.string.forge_wp_done) to colors.charge
                    d == today && plan.isNotEmpty() -> stringResource(R.string.forge_wp_today) to colors.effort
                    else -> null
                }
                val dim = past && doneRows.isEmpty()
                Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.width(44.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(d.dayOfMonth.toString(), style = Forge.type.title2.copy(fontWeight = FontWeight.SemiBold),
                             color = if (dim) colors.textSecondary else colors.text)
                        Text(d.dayOfWeek.getDisplayName(TextStyle.SHORT, locale), style = Forge.type.caption, color = colors.textSecondary)
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = if (dim) colors.textSecondary else colors.text)
                        detail?.let { Text(it, style = Forge.type.caption, color = colors.textSecondary) }
                    }
                    tag?.let { (t, c) ->
                        Text(t, style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = c,
                             modifier = Modifier.background(c.copy(alpha = 0.14f), CircleShape).padding(horizontal = 10.dp, vertical = 4.dp))
                    }
                }
            }
        }
        ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
            TrainingGroupRow(Icons.Rounded.CalendarMonth, colors.effort, stringResource(R.string.forge_wp_schedule),
                             stringResource(R.string.forge_wp_schedule_sub), false, onSchedule)
        }
        if (onAsk != null) {
            val prompt = stringResource(R.string.forge_wp_coach_prompt)
            Text(stringResource(R.string.forge_wp_coach), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.onAccent,
                 textAlign = TextAlign.Center,
                 modifier = Modifier.fillMaxWidth().background(colors.accent, CircleShape).clickable(role = Role.Button) { onAsk(prompt) }
                     .padding(vertical = 12.dp))
        }
        Spacer(Modifier.height(ForgeMetrics.space6))
    }
}
