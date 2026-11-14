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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CorePlans
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.launch
import java.time.DayOfWeek
import java.time.format.TextStyle
import java.util.Locale

private const val AVAILABLE_EQUIPMENT = "training.availableEquipment"
private const val WEIGHT_INCREMENT = "training.weightIncrementKg"

/**
 * Training plans on Android, feature for feature with the Apple app's plan list, plan page, builder and
 * ready-made plans.
 *
 * Every number and every verdict comes from `CorePlans`: which plan may be followed, what a week adds up
 * to, what stands out about it, how a plan is built. These screens ask and draw. The one thing written
 * here is the wording of a finding, from the figures the core carried, so it reads in the wearer's own
 * language.
 */

// MARK: - Library

@Composable
internal fun ForgePlanLibrary(onBack: () -> Unit, onOpen: (String) -> Unit, onBuild: () -> Unit,
                              onTemplates: () -> Unit, onNewPlan: () -> Unit) {
    val context = LocalContext.current
    var snapshot by remember { mutableStateOf<CorePlans.Snapshot?>(null) }
    LaunchedEffect(Unit) { snapshot = core(context) { CorePlans.snapshot() } }
    BackHandler { onBack() }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_plan_plans), onBack)
        val plans = snapshot?.plans.orEmpty()
            .sortedWith(compareByDescending<CorePlans.Plan> { it.isActive }.thenBy { it.title.lowercase() })
        if (plans.isEmpty()) {
            ForgeCard(Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_plan_none_title), style = Forge.type.headline,
                     color = Forge.colors.text)
                Text(stringResource(R.string.forge_plan_none_detail), style = Forge.type.subhead,
                     color = Forge.colors.textSecondary)
            }
        } else {
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
                plans.forEachIndexed { index, plan ->
                    PlanRow(plan) { onOpen(plan.id) }
                    if (index < plans.lastIndex) HubDivider()
                }
            }
        }
        PanelButton(stringResource(R.string.forge_plan_build), Icons.Rounded.AutoAwesome, onBuild)
        PanelButton(stringResource(R.string.forge_plan_ready_made), Icons.Rounded.GridView, onTemplates)
        PanelButton(stringResource(R.string.forge_plan_empty), Icons.Rounded.Add, onNewPlan)
    }
}

@Composable
private fun PlanRow(plan: CorePlans.Plan, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(onClick = onClick)
            .padding(horizontal = ForgeMetrics.cardPadding, vertical = ForgeMetrics.space3),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(plan.title.ifEmpty { stringResource(R.string.forge_plan_unnamed) },
                 style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
            val subtitle = planSubtitle(plan)
            if (subtitle.isNotEmpty()) {
                Text(subtitle, style = Forge.type.caption, color = Forge.colors.textSecondary)
            }
        }
        if (plan.isActive) {
            Text(stringResource(R.string.forge_plan_following), style = Forge.type.caption,
                 color = Forge.colors.charge, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun planSubtitle(plan: CorePlans.Plan): String {
    val parts = mutableListOf<String>()
    if (plan.dayCount > 0) parts += stringResource(R.string.forge_plan_days_a_week, plan.dayCount)
    val block = plan.block
    if (block != null) {
        parts += when {
            block.isFinished -> stringResource(R.string.forge_plan_block_finished)
            block.week != null -> stringResource(R.string.forge_plan_block_week, block.week, block.weeks)
            else -> stringResource(R.string.forge_plan_block_weeks, block.weeks)
        }
    }
    // A plan that IS being followed never reads "Resting": the badge beside it says the opposite,
    // and one of the two would be wrong.
    if (parts.isEmpty()) return if (plan.isActive) "" else stringResource(R.string.forge_plan_resting)
    return parts.joinToString(" · ")
}

// MARK: - One plan

@Composable
internal fun ForgePlanDetail(planId: String, onBack: () -> Unit, onEdit: (CorePlans.Plan) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var plan by remember { mutableStateOf<CorePlans.Plan?>(null) }
    var review by remember { mutableStateOf<CorePlans.Review?>(null) }
    var runs by remember { mutableStateOf<List<CorePlans.BlockRun>>(emptyList()) }
    var replaced by remember { mutableStateOf<String?>(null) }
    var confirmingDelete by remember { mutableStateOf(false) }
    var reload by remember { mutableStateOf(0) }

    LaunchedEffect(planId, reload) {
        val snapshot = core(context) { CorePlans.snapshot() }
        plan = snapshot?.plans?.firstOrNull { it.id == planId }
        replaced = snapshot?.plans?.firstOrNull {
            it.isActive && it.id != planId && it.kind == plan?.kind
        }?.title
        review = core(context) { CorePlans.review(planId) }
        runs = core(context) { CorePlans.blockRuns(planId) }
    }
    BackHandler { onBack() }

    val current = plan
    SettingsColumn {
        PageTitle(current?.title?.ifEmpty { stringResource(R.string.forge_plan_unnamed) }
                      ?: stringResource(R.string.forge_plan_plans), onBack)
        if (current == null) return@SettingsColumn

        // Being followed, or not, and the one button that changes it.
        ForgeCard(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(kindName(current.kind), style = Forge.type.caption, color = Forge.colors.textSecondary,
                     modifier = Modifier.weight(1f))
                if (current.isActive) {
                    Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = Forge.colors.charge,
                         modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.forge_plan_following), style = Forge.type.caption,
                         color = Forge.colors.charge, fontWeight = FontWeight.SemiBold)
                }
            }
            Spacer(Modifier.height(ForgeMetrics.space2))
            Text(if (current.isActive) stringResource(R.string.forge_plan_active_detail)
                 else stringResource(R.string.forge_plan_resting_detail),
                 style = Forge.type.subhead, color = Forge.colors.textSecondary)
            Spacer(Modifier.height(ForgeMetrics.space3))
            if (current.isActive) {
                PanelButton(stringResource(R.string.forge_plan_let_rest), Icons.Rounded.CalendarMonth) {
                    scope.launch { core(context) { CorePlans.deactivate(planId) }; reload++ }
                }
            } else {
                Row(Modifier.fillMaxWidth().background(Forge.colors.accent, RoundedCornerShape(12.dp))
                        .clickable { scope.launch { core(context) { CorePlans.activate(planId) }; reload++ } }
                        .padding(vertical = ForgeMetrics.space3),
                    horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.PlayArrow, contentDescription = null, tint = Forge.colors.onAccent)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.forge_plan_follow), style = Forge.type.headline,
                         color = Forge.colors.onAccent)
                }
                replaced?.let {
                    Spacer(Modifier.height(ForgeMetrics.space2))
                    Text(stringResource(R.string.forge_plan_replaces, it), style = Forge.type.caption,
                         color = Forge.colors.textTertiary)
                }
            }
        }

        current.block?.let { block -> BlockCard(block) }
        runs.firstOrNull { it.endedOn == null }?.let { RunCard(stringResource(R.string.forge_plan_this_block), it) }

        if (current.notes != null || current.sessionsPerWeek != null || current.cardioMinutesPerWeek != null) {
            ForgeCard(Modifier.fillMaxWidth()) {
                current.notes?.let {
                    Text(it, style = Forge.type.subhead, color = Forge.colors.textSecondary)
                }
                current.sessionsPerWeek?.let {
                    Text(stringResource(R.string.forge_plan_target_sessions, it), style = Forge.type.subhead,
                         color = Forge.colors.textSecondary)
                }
                current.cardioMinutesPerWeek?.let {
                    Text(stringResource(R.string.forge_plan_target_cardio, it), style = Forge.type.subhead,
                         color = Forge.colors.textSecondary)
                }
            }
        }

        review?.let { PlanReviewCard(it, current.routines.associate { r -> r.id to r.title }) }

        if (current.routines.isNotEmpty()) {
            Section(stringResource(R.string.forge_plan_routines), null) {
                ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
                    current.routines.forEachIndexed { index, routine ->
                        Row(Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.cardPadding,
                                                            vertical = ForgeMetrics.space3),
                            verticalAlignment = Alignment.CenterVertically) {
                            Text(routine.title, style = Forge.type.subhead, color = Forge.colors.text,
                                 modifier = Modifier.weight(1f))
                            Text(weekdayLabel(routine.weekdays), style = Forge.type.caption,
                                 color = Forge.colors.textSecondary)
                        }
                        if (index < current.routines.lastIndex) HubDivider()
                    }
                }
            }
        }

        val finished = runs.filter { it.endedOn != null }
        if (finished.isNotEmpty()) {
            Section(stringResource(R.string.forge_plan_earlier_blocks), null) {
                Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
                    finished.forEach { RunCard("${it.startedOn} – ${it.endedOn}", it) }
                }
            }
        }

        PanelButton(stringResource(R.string.forge_plan_edit), Icons.Rounded.Edit) { onEdit(current) }
        PanelButton(stringResource(R.string.forge_plan_duplicate), Icons.Rounded.ContentCopy) {
            val title = context.getString(R.string.forge_plan_copy_of, current.title)
            scope.launch { core(context) { CorePlans.duplicate(planId, title) }; onBack() }
        }
        TextButton(onClick = { confirmingDelete = true }, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.forge_plan_delete), color = ForgeTokens.Color.systemRed.resolve())
        }
        if (confirmingDelete) {
            ForgeCard(Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_plan_delete_detail), style = Forge.type.subhead,
                     color = Forge.colors.textSecondary)
                Spacer(Modifier.height(ForgeMetrics.space3))
                Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                    TextButton(onClick = { confirmingDelete = false }) {
                        Text(stringResource(R.string.forge_plan_cancel), color = Forge.colors.text)
                    }
                    TextButton(onClick = {
                        scope.launch { core(context) { CorePlans.delete(planId) }; onBack() }
                    }) {
                        Text(stringResource(R.string.forge_plan_delete),
                             color = ForgeTokens.Color.systemRed.resolve())
                    }
                }
            }
        }
    }
}

@Composable
private fun BlockCard(block: CorePlans.Block) {
    ForgeCard(Modifier.fillMaxWidth()) {
        Text(when {
                 block.isFinished -> stringResource(R.string.forge_plan_block_finished)
                 block.week != null -> stringResource(R.string.forge_plan_block_week, block.week, block.weeks)
                 else -> stringResource(R.string.forge_plan_block_weeks, block.weeks)
             },
             style = Forge.type.headline, color = Forge.colors.text)
        Spacer(Modifier.height(ForgeMetrics.space1))
        Text(when {
                 block.isFinished -> stringResource(R.string.forge_plan_block_finished_detail)
                 block.isDeload -> stringResource(R.string.forge_plan_block_deload_detail,
                                                  (block.deloadFactor * 100).toInt())
                 block.week == null -> stringResource(R.string.forge_plan_block_waiting)
                 else -> stringResource(R.string.forge_plan_block_running)
             },
             style = Forge.type.subhead, color = Forge.colors.textSecondary)
    }
}

/** A block's own figures, taken from the workout log rather than from anything stored about it. */
@Composable
private fun RunCard(title: String, run: CorePlans.BlockRun) {
    ForgeCard(Modifier.fillMaxWidth()) {
        Text(title, style = Forge.type.headline, color = Forge.colors.text)
        Spacer(Modifier.height(ForgeMetrics.space1))
        Text(run.plannedSessions?.let {
                 stringResource(R.string.forge_plan_sessions_of, run.doneSessions, it)
             } ?: stringResource(R.string.forge_plan_sessions, run.doneSessions),
             style = Forge.type.subhead, color = Forge.colors.textSecondary)
        Text(stringResource(R.string.forge_plan_work_sets, run.workSets), style = Forge.type.subhead,
             color = Forge.colors.textSecondary)
        if (run.loadKg > 0) {
            Text(stringResource(R.string.forge_plan_load_moved, run.loadKg.toInt()),
                 style = Forge.type.subhead, color = Forge.colors.textSecondary)
        }
        if (run.unpricedWorkSets > 0) {
            Text(stringResource(R.string.forge_plan_unpriced, run.unpricedWorkSets),
                 style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
        run.deltaWorkSets?.let { delta ->
            if (delta != 0) {
                Text(if (delta > 0) stringResource(R.string.forge_plan_more_sets_than_before, delta)
                     else stringResource(R.string.forge_plan_fewer_sets_than_before, -delta),
                     style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
        }
    }
}

// MARK: - What a week adds up to

/**
 * Sets a week per region, how long a session takes, and what stood out.
 *
 * Every sentence is written from the figures `PlanReview` carried, so the screen says what was compared
 * rather than a verdict nobody can check. It warns and never blocks.
 */
@Composable
internal fun PlanReviewCard(review: CorePlans.Review, routineTitles: Map<String, String>) {
    Section(stringResource(R.string.forge_plan_a_week), null) {
        ForgeCard(Modifier.fillMaxWidth()) {
            review.setsByRegion.entries.filter { it.value > 0 }.sortedByDescending { it.value }
                .forEach { (region, sets) ->
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(regionName(region), style = Forge.type.subhead, color = Forge.colors.text,
                             modifier = Modifier.weight(1f))
                        Text(stringResource(R.string.forge_plan_sets, formatSets(sets)),
                             style = Forge.type.subhead, color = Forge.colors.textSecondary)
                    }
                }
            val minutes = review.minutesByRoutine.values.sorted()
            if (minutes.isNotEmpty()) {
                Spacer(Modifier.height(ForgeMetrics.space2))
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.forge_plan_time_a_session), style = Forge.type.subhead,
                         color = Forge.colors.text, modifier = Modifier.weight(1f))
                    val low = minutes.first()
                    val high = minutes.last()
                    Text(if (low == high) stringResource(R.string.forge_plan_minutes, low)
                         else stringResource(R.string.forge_plan_minutes_range, low, high),
                         style = Forge.type.subhead, color = Forge.colors.textSecondary)
                }
            }
        }
        if (review.findings.isNotEmpty()) {
            ForgeCard(Modifier.fillMaxWidth()) {
                review.findings.forEach { finding ->
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                        Icon(Icons.Rounded.Info, contentDescription = null, tint = Forge.colors.textTertiary,
                             modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(ForgeMetrics.space2))
                        Text(findingSentence(finding, routineTitles), style = Forge.type.subhead,
                             color = Forge.colors.textSecondary)
                    }
                    Spacer(Modifier.height(ForgeMetrics.space2))
                }
            }
        }
    }
}

@Composable
private fun findingSentence(finding: CorePlans.Finding, routineTitles: Map<String, String>): String =
    when (finding.kind) {
        "regionUntrained" ->
            stringResource(R.string.forge_plan_finding_untrained, regionName(finding.region.orEmpty()))
        "regionAboveUsual" ->
            stringResource(R.string.forge_plan_finding_above_usual, regionName(finding.region.orEmpty()),
                           (finding.weeklySets ?: 0.0).toInt(), (finding.usualWeeklySets ?: 0.0).toInt())
        "heavyDaysBackToBack" ->
            stringResource(R.string.forge_plan_finding_back_to_back,
                           dayName(finding.firstWeekday ?: 1), dayName(finding.secondWeekday ?: 1))
        "sessionLongerThanAsked" ->
            stringResource(R.string.forge_plan_finding_over_time,
                           routineTitles[finding.routineId] ?: stringResource(R.string.forge_plan_one_session),
                           finding.minutes ?: 0, finding.askedMinutes ?: 0)
        else -> ""
    }

// MARK: - Wording

@Composable
private fun kindName(kind: String): String = when (kind) {
    "conditioning" -> stringResource(R.string.forge_plan_kind_conditioning)
    "mobility" -> stringResource(R.string.forge_plan_kind_mobility)
    else -> stringResource(R.string.forge_plan_kind_strength)
}

private fun dayName(weekday: Int): String =
    DayOfWeek.of(weekday.coerceIn(1, 7)).getDisplayName(TextStyle.FULL, Locale.getDefault())

private fun weekdayLabel(weekdays: List<Int>): String =
    if (weekdays.isEmpty()) ""
    else weekdays.sorted().joinToString(" ") {
        DayOfWeek.of(it.coerceIn(1, 7)).getDisplayName(TextStyle.SHORT, Locale.getDefault())
    }

private fun formatSets(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString() else String.format(Locale.getDefault(), "%.1f", value)

// MARK: - Building one

/**
 * Builds a plan from a handful of answers and shows what came out before anything is written.
 *
 * The questions and the preview are here; the plan itself is `PlanBuilder` in the core, so the same
 * answers give the same plan on both platforms.
 */
@Composable
internal fun ForgePlanBuilder(onBack: () -> Unit, onSaved: (String) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    // The same two settings the iPhone's wizard reads, so the same answers give the same plan: the
    // equipment the exercise library already knows about, and the wearer's own weight step under the
    // key Apple writes. Android has no screen for the step yet, so there it falls back to 2.5 kg; the
    // key is read rather than the number hard-coded, so the day it gains one, this follows.
    val prefs = remember(context) { NoopPrefs.of(context) }
    val equipment = remember(prefs) {
        prefs.getString(AVAILABLE_EQUIPMENT, "").orEmpty()
            .lineSequence().filter { it.isNotBlank() }.toList()
    }
    val weightStepKg = remember(prefs) {
        prefs.getString(WEIGHT_INCREMENT, null)?.toDoubleOrNull() ?: 2.5
    }
    var days by remember { mutableStateOf(3) }
    var minutes by remember { mutableStateOf(60) }
    var experience by remember { mutableStateOf("beginner") }
    var emphasis by remember { mutableStateOf("balanced") }
    var hasBlock by remember { mutableStateOf(false) }
    var blockWeeks by remember { mutableStateOf(8) }
    var preview by remember { mutableStateOf<CorePlans.Preview?>(null) }
    var failed by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    BackHandler { if (preview != null) preview = null else onBack() }

    fun build() {
        scope.launch {
            busy = true
            val result = core(context) {
                CorePlans.build(days, equipment = equipment, experience = experience,
                                emphasis = emphasis, minutes = minutes, weightStepKg = weightStepKg,
                                blockWeeks = if (hasBlock) blockWeeks else null)
            }
            busy = false
            failed = result == null
            preview = result
        }
    }

    fun save(follow: Boolean) {
        scope.launch {
            busy = true
            val result = core(context) {
                CorePlans.build(days, equipment = equipment, experience = experience,
                                emphasis = emphasis, minutes = minutes, weightStepKg = weightStepKg,
                                blockWeeks = if (hasBlock) blockWeeks else null,
                                save = true, activate = follow)
            }
            busy = false
            if (result != null) {
                // The plan the core has just written is the newest one of its title; open it by id.
                val id = core(context) { CorePlans.snapshot() }?.plans?.lastOrNull { it.title == result.title }?.id
                if (id != null) onSaved(id) else onBack()
            }
        }
    }

    SettingsColumn {
        PageTitle(stringResource(R.string.forge_plan_build), onBack, trailing = {
            if (preview == null) {
                TextButton(enabled = !busy, onClick = { build() }) {
                    Text(stringResource(R.string.forge_plan_build_action), color = Forge.colors.charge,
                         style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold))
                }
            }
        })
        val shown = preview
        if (shown == null) {
            ForgeCard(Modifier.fillMaxWidth()) {
                StepperRow(stringResource(R.string.forge_plan_days_a_week, days), days > 2, days < 6,
                           { days-- }, { days++ })
                HubDivider()
                StepperRow(stringResource(R.string.forge_plan_about_minutes, minutes),
                           minutes > 20, minutes < 150, { minutes -= 10 }, { minutes += 10 })
            }
            ChoiceCard(stringResource(R.string.forge_plan_experience),
                       listOf("beginner" to stringResource(R.string.forge_plan_experience_new),
                              "intermediate" to stringResource(R.string.forge_plan_experience_while),
                              "advanced" to stringResource(R.string.forge_plan_experience_years)),
                       experience) { experience = it }
            ChoiceCard(stringResource(R.string.forge_plan_lean),
                       listOf("balanced" to stringResource(R.string.forge_plan_lean_balanced),
                              "strength" to stringResource(R.string.forge_plan_lean_strength),
                              "hypertrophy" to stringResource(R.string.forge_plan_lean_size),
                              "upperBody" to stringResource(R.string.forge_plan_lean_upper),
                              "lowerBody" to stringResource(R.string.forge_plan_lean_lower)),
                       emphasis) { emphasis = it }
            ForgeCard(Modifier.fillMaxWidth()) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.forge_plan_run_for_weeks), style = Forge.type.subhead,
                         color = Forge.colors.text, modifier = Modifier.weight(1f))
                    Switch(checked = hasBlock, onCheckedChange = { hasBlock = it })
                }
                if (hasBlock) {
                    HubDivider()
                    StepperRow(stringResource(R.string.forge_plan_weeks_last_lighter, blockWeeks),
                               blockWeeks > 4, blockWeeks < 16, { blockWeeks-- }, { blockWeeks++ })
                }
            }
            if (failed) {
                Text(stringResource(R.string.forge_plan_build_failed), style = Forge.type.caption,
                     color = ForgeTokens.Color.systemRed.resolve())
            }
        } else {
            Text(shown.title, style = Forge.type.title2, color = Forge.colors.text)
            shown.routines.forEach { routine ->
                ForgeCard(Modifier.fillMaxWidth()) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(routine.title, style = Forge.type.headline, color = Forge.colors.text,
                             modifier = Modifier.weight(1f))
                        Text(stringResource(R.string.forge_plan_minutes, routine.minutes),
                             style = Forge.type.caption, color = Forge.colors.textSecondary)
                    }
                    Spacer(Modifier.height(ForgeMetrics.space2))
                    routine.lines.forEach {
                        Text(it, style = Forge.type.subhead, color = Forge.colors.textSecondary)
                    }
                }
            }
            PlanReviewCard(shown.review, emptyMap())
            Text(stringResource(R.string.forge_plan_saved_resting), style = Forge.type.caption,
                 color = Forge.colors.textTertiary)
            PanelButton(stringResource(R.string.forge_plan_save_and_follow), Icons.Rounded.PlayArrow) { save(true) }
            PanelButton(stringResource(R.string.forge_plan_save), Icons.Rounded.Add) { save(false) }
            TextButton(onClick = { preview = null }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_plan_start_over), color = Forge.colors.text)
            }
        }
    }
}

/** The ready-made plans. Picking one writes it resting, so the week does not change until it is followed. */
@Composable
internal fun ForgePlanTemplates(onBack: () -> Unit, onSaved: (String) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val weightStepKg = remember(context) {
        NoopPrefs.of(context).getString(WEIGHT_INCREMENT, null)?.toDoubleOrNull() ?: 2.5
    }
    var templates by remember { mutableStateOf<List<CorePlans.Template>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { templates = core(context) { CorePlans.snapshot() }?.templates.orEmpty() }
    BackHandler { onBack() }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_plan_ready_made), onBack)
        templates.forEach { template ->
            ForgeCard(Modifier.fillMaxWidth().clickable(enabled = !busy) {
                scope.launch {
                    busy = true
                    val id = core(context) { CorePlans.useTemplate(template.id, weightStepKg) }
                    busy = false
                    if (id != null) onSaved(id)
                }
            }) {
                Text(template.title, style = Forge.type.headline, color = Forge.colors.text)
                Text(template.summary, style = Forge.type.subhead, color = Forge.colors.textSecondary)
                val source = if (template.sourceName != null && template.sourceAttribution != null)
                    " · ${template.sourceName}, ${template.sourceAttribution}" else ""
                Text(stringResource(R.string.forge_plan_days_a_week, template.daysPerWeek) + source,
                     style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
        }
        Text(stringResource(R.string.forge_plan_template_footer), style = Forge.type.caption,
             color = Forge.colors.textTertiary)
    }
}

/** A plan's own settings. Nothing here starts a plan: that happens on its page, deliberately. */
@Composable
internal fun ForgePlanEditor(plan: CorePlans.Plan?, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var title by remember { mutableStateOf(plan?.title.orEmpty()) }
    var notes by remember { mutableStateOf(plan?.notes.orEmpty()) }
    var kind by remember { mutableStateOf(plan?.kind ?: "strength") }
    var sessions by remember { mutableStateOf(plan?.sessionsPerWeek ?: 0) }
    var cardio by remember { mutableStateOf(plan?.cardioMinutesPerWeek ?: 0) }
    var hasBlock by remember { mutableStateOf(plan?.block != null) }
    var weeks by remember { mutableStateOf(plan?.block?.weeks ?: 8) }
    var progression by remember { mutableStateOf(plan?.block?.progression ?: "none") }
    BackHandler { onClose() }
    SettingsColumn {
        PageTitle(if (plan == null) stringResource(R.string.forge_plan_new)
                  else stringResource(R.string.forge_plan_edit), onClose, trailing = {
            TextButton(enabled = title.isNotBlank(), onClick = {
                scope.launch {
                    core(context) {
                        CorePlans.save(id = plan?.id, title = title.trim(), kind = kind,
                                       notes = notes.trim(), targets = true,
                                       sessionsPerWeek = sessions.takeIf { it > 0 },
                                       cardioMinutesPerWeek = cardio.takeIf { it > 0 },
                                       blockWeeks = if (hasBlock) weeks else null,
                                       blockProgression = progression, clearBlock = !hasBlock)
                    }
                    onClose()
                }
            }) { Text(stringResource(R.string.forge_plan_save), color = Forge.colors.charge,
                      style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold)) }
        })
        OutlinedTextField(value = title, onValueChange = { title = it }, singleLine = true,
                          label = { Text(stringResource(R.string.forge_plan_name)) },
                          colors = OutlinedTextFieldDefaults.colors(
                              focusedContainerColor = Forge.colors.surface,
                              unfocusedContainerColor = Forge.colors.surface,
                              focusedTextColor = Forge.colors.text, unfocusedTextColor = Forge.colors.text),
                          modifier = Modifier.fillMaxWidth())
        OutlinedTextField(value = notes, onValueChange = { notes = it },
                          label = { Text(stringResource(R.string.forge_plan_notes)) },
                          colors = OutlinedTextFieldDefaults.colors(
                              focusedContainerColor = Forge.colors.surface,
                              unfocusedContainerColor = Forge.colors.surface,
                              focusedTextColor = Forge.colors.text, unfocusedTextColor = Forge.colors.text),
                          modifier = Modifier.fillMaxWidth())
        ChoiceCard(stringResource(R.string.forge_plan_kind),
                   listOf("strength" to stringResource(R.string.forge_plan_kind_strength),
                          "conditioning" to stringResource(R.string.forge_plan_kind_conditioning),
                          "mobility" to stringResource(R.string.forge_plan_kind_mobility)),
                   kind) { kind = it }
        ForgeCard(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.forge_plan_asks_of_a_week), style = Forge.type.headline,
                 color = Forge.colors.text)
            Spacer(Modifier.height(ForgeMetrics.space2))
            StepperRow(if (sessions > 0) stringResource(R.string.forge_plan_target_sessions, sessions)
                       else stringResource(R.string.forge_plan_no_session_target),
                       sessions > 0, sessions < 14, { sessions-- }, { sessions++ })
            HubDivider()
            StepperRow(if (cardio > 0) stringResource(R.string.forge_plan_target_cardio, cardio)
                       else stringResource(R.string.forge_plan_no_cardio_target),
                       cardio > 0, cardio < 1_200, { cardio -= 15 }, { cardio += 15 })
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.forge_plan_run_for_weeks), style = Forge.type.subhead,
                     color = Forge.colors.text, modifier = Modifier.weight(1f))
                Switch(checked = hasBlock, onCheckedChange = { hasBlock = it })
            }
            if (hasBlock) {
                HubDivider()
                StepperRow(stringResource(R.string.forge_plan_weeks_last_lighter, weeks),
                           weeks > 2, weeks < 52, { weeks-- }, { weeks++ })
                HubDivider()
                Text(stringResource(R.string.forge_plan_over_the_block), style = Forge.type.caption,
                     color = Forge.colors.textSecondary)
                listOf("none" to stringResource(R.string.forge_plan_block_earned),
                       "weeklyLoad" to stringResource(R.string.forge_plan_block_weight_step),
                       "weeklyVolume" to stringResource(R.string.forge_plan_block_one_more_set))
                    .forEach { (value, label) -> ChoiceRow(label, progression == value) { progression = value } }
            }
        }
    }
}

// MARK: - Small shared pieces

@Composable
private fun StepperRow(label: String, canDown: Boolean, canUp: Boolean, down: () -> Unit, up: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = Forge.type.subhead, color = Forge.colors.text, modifier = Modifier.weight(1f))
        StepperButton("−", canDown, down)
        Spacer(Modifier.width(ForgeMetrics.space2))
        StepperButton("+", canUp, up)
    }
}

@Composable
private fun StepperButton(label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(Modifier.size(36.dp)
            .background(Forge.colors.surfaceTop, CircleShape)
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center) {
        Text(label, style = Forge.type.headline,
             color = if (enabled) Forge.colors.text else Forge.colors.textTertiary)
    }
}

@Composable
private fun ChoiceCard(title: String, options: List<Pair<String, String>>, selected: String,
                       onPick: (String) -> Unit) {
    ForgeCard(Modifier.fillMaxWidth()) {
        Text(title, style = Forge.type.headline, color = Forge.colors.text)
        Spacer(Modifier.height(ForgeMetrics.space2))
        options.forEach { (value, label) -> ChoiceRow(label, value == selected) { onPick(value) } }
    }
}

@Composable
private fun ChoiceRow(label: String, selected: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable(onClick = onClick),
        verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = Forge.type.subhead,
             color = if (selected) Forge.colors.text else Forge.colors.textSecondary,
             fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
             modifier = Modifier.weight(1f))
        if (selected) {
            Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = Forge.colors.charge,
                 modifier = Modifier.size(18.dp))
        }
    }
}

/**
 * Keeps a session that has been done as a routine, so it can be done again without typing it in.
 *
 * What was performed becomes the prescription, which the core works out; this asks for a name and the
 * plan it should join. Nothing is written until the button is pressed.
 */
@Composable
internal fun KeepSessionAsRoutineCard(workoutId: String, suggestedTitle: String) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var plans by remember { mutableStateOf<List<CorePlans.Plan>>(emptyList()) }
    var planId by remember { mutableStateOf<String?>(null) }
    var title by remember { mutableStateOf(suggestedTitle) }
    var saved by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(workoutId) {
        val snapshot = core(context) { CorePlans.snapshot() }
        plans = snapshot?.plans.orEmpty()
        if (planId == null) planId = snapshot?.activeStrength?.id ?: plans.firstOrNull()?.id
    }
    if (plans.isEmpty()) return

    ForgeCard(Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.forge_keep_routine_title), style = Forge.type.headline,
             color = Forge.colors.text)
        Text(stringResource(R.string.forge_keep_routine_detail), style = Forge.type.subhead,
             color = Forge.colors.textSecondary)
        Spacer(Modifier.height(ForgeMetrics.space3))
        when {
            saved -> Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = Forge.colors.charge,
                     modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(ForgeMetrics.space2))
                Text(stringResource(R.string.forge_keep_routine_saved), style = Forge.type.subhead,
                     color = Forge.colors.charge)
            }
            else -> {
                OutlinedTextField(value = title, onValueChange = { title = it }, singleLine = true,
                                  label = { Text(stringResource(R.string.forge_training_routine_name)) },
                                  colors = OutlinedTextFieldDefaults.colors(
                                      focusedContainerColor = Forge.colors.surface,
                                      unfocusedContainerColor = Forge.colors.surface,
                                      focusedTextColor = Forge.colors.text,
                                      unfocusedTextColor = Forge.colors.text),
                                  modifier = Modifier.fillMaxWidth())
                if (plans.size > 1) {
                    Spacer(Modifier.height(ForgeMetrics.space2))
                    plans.forEach { plan ->
                        ChoiceRow(plan.title.ifEmpty { stringResource(R.string.forge_plan_unnamed) },
                                  plan.id == planId) { planId = plan.id }
                    }
                }
                Spacer(Modifier.height(ForgeMetrics.space2))
                PanelButton(stringResource(R.string.forge_keep_routine_save), Icons.Rounded.Add) {
                    if (!busy && title.isNotBlank()) {
                        busy = true
                        scope.launch {
                            val done = core(context) {
                                CorePlans.routineFromWorkout(workoutId, title.trim(), planId)
                            }
                            busy = false
                            saved = done
                            failed = !done
                        }
                    }
                }
                if (failed) {
                    Text(stringResource(R.string.forge_keep_routine_failed), style = Forge.type.caption,
                         color = ForgeTokens.Color.systemRed.resolve())
                }
            }
        }
    }
}
