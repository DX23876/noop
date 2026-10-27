package com.noop.ui.forge

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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Checklist
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.DirectionsWalk
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.MonitorWeight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreGoals
import com.noop.core.CoreLongTermGoals
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale
import kotlin.math.roundToInt

/** A catalog key in the wearer's language (`GOAL_CATALOG_TEXT`), or the key itself where no resource names it. */
@Composable
internal fun catalogText(key: String): String = GOAL_CATALOG_TEXT[key]?.let { stringResource(it) } ?: key

private enum class SetupStep { Area, Template, Value, Weekly, Preview }

/**
 * Fork (DX23876), Android parity plan 2.3: setting a long-term goal from the catalog, as the iOS setup does
 * (`LongTermGoalSetupView`): area, template, value and time, the weekly goal that drives it, a preview. Every
 * suggestion is the shared `LongTermGoalDraft`'s, read from the wearer's own data through the core, and the goal is
 * created there, asking first when another goal already measures the same thing.
 */
@Composable
internal fun LongTermSetupPage(onBack: () -> Unit, onCreated: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var catalog by remember { mutableStateOf<CoreLongTermGoals.Catalog?>(null) }
    var step by rememberSaveable { mutableStateOf(SetupStep.Area) }
    var area by rememberSaveable { mutableStateOf<String?>(null) }
    var draft by remember { mutableStateOf<CoreLongTermGoals.Draft?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var sameMeasure by remember { mutableStateOf<CoreLongTermGoals.Created?>(null) }
    var askReason by remember { mutableStateOf(false) }
    var reason by remember { mutableStateOf("") }
    LaunchedEffect(Unit) {
        catalog = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreLongTermGoals.catalog(context, dismissedTrainingWorkouts(context))
        }
    }
    fun run(state: CoreLongTermGoals.State, action: String, then: () -> Unit = {}) {
        busy = true
        scope.launch {
            val next = withContext(Dispatchers.IO) {
                CoreLongTermGoals.draft(context, dismissedTrainingWorkouts(context), state, action)
            }
            if (next != null) draft = next
            busy = false
            then()
        }
    }
    fun change(state: CoreLongTermGoals.State) {
        draft = draft?.copy(state = state)
        run(state, "none")
    }
    val limitText = stringResource(R.string.forge_lt_limit)
    val failedText = stringResource(R.string.forge_goals_failed)
    fun create(replacing: String?, keepBoth: Boolean, riskReason: String?) {
        val state = draft?.state ?: return
        busy = true
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                CoreLongTermGoals.create(context, dismissedTrainingWorkouts(context), state, replacing, keepBoth, riskReason)
            }
            busy = false
            when {
                result.ok -> onCreated()
                result.error == "sameMeasure" -> sameMeasure = result
                result.error == "riskReason" -> askReason = true
                result.error == "limitReached" -> error = limitText
                else -> error = failedText
            }
        }
    }
    fun back() {
        when (step) {
            SetupStep.Area -> onBack()
            else -> step = SetupStep.entries[step.ordinal - 1]
        }
    }

    SettingsColumn {
        PageTitle(stringResource(when (step) {
            SetupStep.Area -> R.string.forge_lt_step_area
            SetupStep.Template -> R.string.forge_lt_step_template
            SetupStep.Value -> R.string.forge_lt_step_value
            SetupStep.Weekly -> R.string.forge_lt_step_weekly
            SetupStep.Preview -> R.string.forge_lt_step_preview
        }), ::back)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            SetupStep.entries.forEach {
                Box(Modifier.weight(1f).height(4.dp).clip(CircleShape)
                        .background(if (it.ordinal <= step.ordinal) Forge.colors.accent else Forge.colors.inset))
            }
        }
        val c = catalog
        if (c == null) {
            Text(stringResource(R.string.forge_goals_loading), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        when (step) {
            SetupStep.Area -> {
                ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                    c.areas.forEachIndexed { i, a ->
                        Row(Modifier.fillMaxWidth().clickable(role = Role.Button) { area = a; step = SetupStep.Template }
                                .padding(vertical = ForgeMetrics.space3),
                            verticalAlignment = Alignment.CenterVertically) {
                            AreaTile(a)
                            Spacer(Modifier.width(ForgeMetrics.space3))
                            Text(catalogText(areaKey(a)), style = Forge.type.body, color = Forge.colors.text)
                        }
                        if (i < c.areas.lastIndex) RowDivider()
                    }
                }
            }
            SetupStep.Template -> {
                val items = c.templates.filter { it.area == area }
                ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                    items.forEachIndexed { i, t ->
                        Column(Modifier.fillMaxWidth().alpha(if (t.available) 1f else 0.45f)
                                .clickable(enabled = t.available && !busy, role = Role.Button) {
                                    run(CoreLongTermGoals.State(template = t.id), "suggest") { step = SetupStep.Value }
                                }.padding(vertical = ForgeMetrics.space3),
                               verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(catalogText(t.title), style = Forge.type.headline, color = Forge.colors.text)
                            Text(catalogText(t.reason ?: t.blurb), style = Forge.type.footnote, color = Forge.colors.textSecondary)
                        }
                        if (i < items.lastIndex) RowDivider()
                    }
                }
            }
            SetupStep.Value -> draft?.let { d -> ValueStep(d, c, ::change, ::run) }
            SetupStep.Weekly -> draft?.let { d -> WeeklyStep(d, ::change) }
            SetupStep.Preview -> draft?.let { d -> PreviewStep(d, c, ::change) }
        }
        error?.let { Text(it, style = Forge.type.caption, color = ForgeTokens.Color.systemRed.resolve()) }
        if (step >= SetupStep.Value && draft != null) {
            val last = step == SetupStep.Preview
            val ready = draft?.state?.let { it.template != JOURNAL_HABIT || it.habitKey != null } ?: false
            // A rhythm goal is its weekly goal, so it goes straight to the preview.
            val nextStep = if (step == SetupStep.Value && draft?.shape == "consistency") SetupStep.Preview
                           else SetupStep.entries.getOrElse(step.ordinal + 1) { SetupStep.Preview }
            Box(Modifier.fillMaxWidth().alpha(if (ready) 1f else 0.45f).clip(RoundedCornerShape(14.dp))
                    .background(Forge.colors.accent)
                    .clickable(enabled = !busy && ready, role = Role.Button) {
                        if (last) create(null, false, null) else step = nextStep
                    }.padding(vertical = 14.dp), contentAlignment = Alignment.Center) {
                Text(stringResource(if (last) R.string.forge_goals_create else R.string.forge_lt_next),
                     style = Forge.type.headline, color = Color.White)
            }
        }
    }
    sameMeasure?.let { same ->
        AlertDialog(
            onDismissRequest = { sameMeasure = null },
            title = { Text(stringResource(R.string.forge_lt_same_title)) },
            text = { Text(stringResource(R.string.forge_lt_same_text, same.existingTitle ?: "")) },
            confirmButton = {
                TextButton(onClick = { sameMeasure = null; create(same.existingId, false, null) }) {
                    Text(stringResource(R.string.forge_lt_replace))
                }
            },
            dismissButton = {
                TextButton(onClick = { sameMeasure = null; create(null, true, null) }) {
                    Text(stringResource(R.string.forge_lt_keep_both))
                }
            },
        )
    }
    if (askReason) {
        AlertDialog(
            onDismissRequest = { askReason = false },
            title = { Text(stringResource(R.string.forge_lt_risk_title)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.forge_lt_risk_text, draft?.rate ?: ""))
                    OutlinedTextField(value = reason, onValueChange = { reason = it },
                                      label = { Text(stringResource(R.string.forge_lt_risk_reason)) })
                }
            },
            confirmButton = {
                TextButton(enabled = reason.isNotBlank(), onClick = { askReason = false; create(null, false, reason) }) {
                    Text(stringResource(R.string.forge_lt_save_anyway))
                }
            },
            dismissButton = { TextButton(onClick = { askReason = false }) { Text(stringResource(R.string.forge_cancel)) } },
        )
    }
}

@Composable
private fun ValueStep(d: CoreLongTermGoals.Draft, catalog: CoreLongTermGoals.Catalog,
                      change: (CoreLongTermGoals.State) -> Unit, run: (CoreLongTermGoals.State, String, () -> Unit) -> Unit) {
    val s = d.state
    val template = catalog.templates.firstOrNull { it.id == s.template }
    if (s.template == JOURNAL_HABIT) {
        val context = LocalContext.current
        val habits = journalHabits()
        // "Keep a journal habit" says nothing on the list: the name follows the habit picked until the wearer types one.
        fun named(key: String?, yes: Boolean): String = key?.let { k ->
            val item = habits.firstOrNull { it.canonical == k }
            context.getString(if (yes) R.string.forge_goals_habit_do_title else R.string.forge_goals_habit_avoid_title,
                              item?.displayName ?: item?.canonical ?: k)
        } ?: ""
        val generic = template?.title?.let { catalogText(it) }
        fun pick(key: String?, yes: Boolean) {
            val follows = s.title.isEmpty() || s.title == template?.title || s.title == generic ||
                s.title == named(s.habitKey, s.habitWantsYes)
            change(s.copy(habitKey = key, habitWantsYes = yes, title = if (follows) named(key, yes) else s.title))
        }
        SettingsCard(title = stringResource(R.string.forge_goals_habit_which), blurb = null) {
            HabitPicker(habits, s.habitKey, s.habitWantsYes, onKey = { pick(it, s.habitWantsYes) },
                        onWantsYes = { pick(s.habitKey, it) })
        }
    }
    if (template != null && template.sportChoices.size > 1) {
        SettingsCard(title = stringResource(R.string.forge_lt_sport), blurb = null) {
            template.sportChoices.forEachIndexed { i, label ->
                Row(Modifier.fillMaxWidth().clickable(role = Role.RadioButton) { run(s.copy(sportIndex = i), "suggest") {} }
                        .padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(catalogText(label), style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
                    if (i == s.sportIndex) Text("✓", style = Forge.type.headline, color = Forge.colors.accent)
                }
                if (i < template.sportChoices.lastIndex) RowDivider()
            }
        }
    }
    SettingsCard(title = stringResource(R.string.forge_goals_target), blurb = null) {
        when (d.shape) {
            "sum" -> {
                SettingRow(stringResource(R.string.forge_goals_target)) {
                    Stepper(levelText(s.target, d.metric), onMinus = { change(s.copy(target = (s.target - d.sumStep).coerceAtLeast(d.sumStep))) },
                            onPlus = { change(s.copy(target = s.target + d.sumStep)) })
                }
                RowDivider()
                SettingRow(stringResource(R.string.forge_lt_by)) {
                    DateText(s.endDate) { picked -> run(s.copy(endDate = picked), "sum") {} }
                }
                RowDivider()
                ToggleRow(stringResource(R.string.forge_lt_count_year), stringResource(R.string.forge_lt_count_year_detail,
                          levelText(d.collectedSoFar, d.metric)), s.countFromYearStart) { on ->
                    run(s.copy(countFromYearStart = on), "sum") {}
                }
            }
            "consistency" -> {
                SettingRow(stringResource(R.string.forge_lt_per_week)) {
                    Stepper(whole(s.target), onMinus = { change(s.copy(target = (s.target - d.perWeekStep).coerceAtLeast(d.perWeekLow))) },
                            onPlus = { change(s.copy(target = (s.target + d.perWeekStep).coerceAtMost(d.perWeekHigh))) })
                }
                RowDivider()
                ToggleRow(stringResource(R.string.forge_lt_open_ended), null, s.openEnded) { change(s.copy(openEnded = it)) }
                if (!s.openEnded) {
                    SettingRow(stringResource(R.string.forge_lt_weeks)) {
                        Stepper(s.fixedWeeks.toString(), onMinus = { change(s.copy(fixedWeeks = (s.fixedWeeks - 1).coerceAtLeast(4))) },
                                onPlus = { change(s.copy(fixedWeeks = (s.fixedWeeks + 1).coerceAtMost(52))) })
                    }
                }
            }
            "maintain" -> {
                SettingRow(stringResource(R.string.forge_lt_keep_at)) { Text(levelText(s.baseline, d.metric), style = Forge.type.body) }
                RowDivider()
                SettingRow(stringResource(R.string.forge_lt_band)) {
                    Stepper("± " + levelText(s.band, d.metric), onMinus = { change(s.copy(band = (s.band - 0.5).coerceAtLeast(0.5))) },
                            onPlus = { change(s.copy(band = (s.band + 0.5).coerceAtMost(10.0))) })
                }
            }
            else -> {
                if (d.shape == "target" || d.shape == "average") {
                    d.currentLevel?.let {
                        SettingRow(stringResource(R.string.forge_lt_now)) {
                            Text(levelText(it, d.metric), style = Forge.type.body, color = Forge.colors.textSecondary)
                        }
                        RowDivider()
                    }
                }
                val step = if (d.shape == "best") 0.5 else d.levelStep
                SettingRow(stringResource(R.string.forge_goals_target)) {
                    Stepper(levelText(s.target, d.metric),
                            onMinus = { change(s.copy(target = (s.target - step).coerceAtLeast(if (d.shape == "best") step else d.levelLow))) },
                            onPlus = { change(s.copy(target = (s.target + step).coerceAtMost(if (d.shape == "best") 500.0 else d.levelHigh))) })
                }
                if (d.shape != "average") {
                    RowDivider()
                    ToggleRow(stringResource(R.string.forge_lt_with_date), null, s.hasDate) { on ->
                        val date = if (s.targetDate > 0) s.targetDate
                                   else LocalDate.now().plusWeeks(12).atStartOfDay(ZoneId.systemDefault()).toEpochSecond().toDouble()
                        change(s.copy(hasDate = on, targetDate = date))
                    }
                    if (s.hasDate) {
                        SettingRow(stringResource(R.string.forge_lt_by)) {
                            DateText(s.targetDate) { picked -> change(s.copy(targetDate = picked)) }
                        }
                    }
                }
            }
        }
        if (d.risky) {
            Text(stringResource(R.string.forge_lt_risk_text, d.rate ?: ""), style = Forge.type.caption,
                 color = ForgeTokens.Color.systemOrange.resolve())
        }
    }
}

@Composable
private fun WeeklyStep(d: CoreLongTermGoals.Draft, change: (CoreLongTermGoals.State) -> Unit) {
    val s = d.state
    val weekly = d.weeklyMetricOfGoal
    SettingsCard(title = null, blurb = stringResource(R.string.forge_lt_weekly_blurb)) {
        ToggleRow(stringResource(R.string.forge_lt_weekly_on), null, s.weeklyOn) { change(s.copy(weeklyOn = it)) }
        if (s.weeklyOn && weekly != null) {
            RowDivider()
            if (s.template == "body.weightLose" || s.template == "body.weightMaintain") {
                SettingRow(stringResource(R.string.forge_lt_weekly_kind)) {
                    Segmented(listOf("workouts", "stepDays"), s.weeklyChoice,
                              label = { stringResource(if (it == "workouts") R.string.forge_goals_m_workouts else R.string.forge_goals_m_step_days) },
                              onSelect = { change(s.copy(weeklyChoice = it)) })
                }
                RowDivider()
            }
            SettingRow(stringResource(R.string.forge_lt_per_week)) {
                Stepper(whole(s.weeklyTarget), onMinus = { change(s.copy(weeklyTarget = (s.weeklyTarget - 1).coerceAtLeast(1.0))) },
                        onPlus = { change(s.copy(weeklyTarget = s.weeklyTarget + 1)) })
            }
        }
    }
}

@Composable
private fun PreviewStep(d: CoreLongTermGoals.Draft, catalog: CoreLongTermGoals.Catalog, change: (CoreLongTermGoals.State) -> Unit) {
    val s = d.state
    val template = catalog.templates.firstOrNull { it.id == s.template }
    SettingsCard(title = null, blurb = null) {
        OutlinedTextField(value = s.title.ifEmpty { template?.title?.let { catalogText(it) } ?: "" },
                          onValueChange = { change(s.copy(title = it)) },
                          label = { Text(stringResource(R.string.forge_lt_name)) }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(value = s.motivation, onValueChange = { change(s.copy(motivation = it)) },
                          label = { Text(stringResource(R.string.forge_lt_why)) }, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(ForgeMetrics.space2))
        SettingRow(stringResource(R.string.forge_goals_target)) {
            Text(if (d.shape == "consistency") whole(s.target) + " · " + stringResource(R.string.forge_goals_a_week)
                 else levelText(s.target, d.metric), style = Forge.type.body, color = Forge.colors.text)
        }
        val date = when {
            d.shape == "sum" -> s.endDate
            s.hasDate -> s.targetDate
            else -> null
        }
        date?.let { SettingRow(stringResource(R.string.forge_lt_by)) { Text(epochDate(it), style = Forge.type.body) } }
        if (s.weeklyOn && d.weeklyMetricOfGoal != null && d.shape != "consistency") {
            SettingRow(stringResource(R.string.forge_lt_weekly_on)) { Text(whole(s.weeklyTarget), style = Forge.type.body) }
        }
    }
}

@Composable
private fun DateText(epoch: Double, onPicked: (Double) -> Unit) {
    val context = LocalContext.current
    Text(epochDate(epoch), style = Forge.type.body, color = Forge.colors.accent,
         modifier = Modifier.clickable(role = Role.Button) {
             val d = Instant.ofEpochSecond(epoch.toLong()).atZone(ZoneId.systemDefault()).toLocalDate()
             android.app.DatePickerDialog(context, { _, y, m, day ->
                 onPicked(LocalDate.of(y, m + 1, day).atStartOfDay(ZoneId.systemDefault()).toEpochSecond().toDouble())
             }, d.year, d.monthValue - 1, d.dayOfMonth).apply { datePicker.minDate = System.currentTimeMillis() }.show()
         }.padding(vertical = 8.dp))
}

private fun epochDate(epoch: Double): String = if (epoch <= 0) "" else
    java.time.format.DateTimeFormatter.ofLocalizedDate(java.time.format.FormatStyle.MEDIUM).withLocale(Locale.getDefault())
        .format(Instant.ofEpochSecond(epoch.toLong()).atZone(ZoneId.systemDefault()).toLocalDate())

private fun whole(v: Double): String = NumberFormat.getIntegerInstance(Locale.getDefault()).format(v.roundToInt())

/** A long-term value with its unit (`LongTermMetric`): kilometres, minutes, kilograms, beats, a pace per km… */
@Composable
private fun levelText(value: Double, metric: String?): String {
    val n = NumberFormat.getNumberInstance(Locale.getDefault()).apply { maximumFractionDigits = 1 }
    return when (metric) {
        "distanceTotal", "longestDistance" -> "${n.format(value)} km"
        "minutesTotal" -> "${whole(value)} ${stringResource(R.string.forge_goals_u_min)}"
        "workoutsTotal" -> "${whole(value)} ${stringResource(R.string.forge_goals_u_workouts)}"
        "stepsTotal", "stepsAverage" -> stringResource(R.string.forge_goals_steps_value, whole(value))
        "paceAverage" -> "%d:%02d /km".format(value.roundToInt() / 60, value.roundToInt() % 60)
        "hrvAverage" -> "${whole(value)} ms"
        "sleepAverage" -> "${n.format(value)} ${stringResource(R.string.forge_goals_u_h)}"
        "recoveryAverage", "sleepConsistency", "bodyFat" -> "${n.format(value)} %"
        "weight", "leanMass" -> "${n.format(value)} kg"
        "waist" -> "${whole(value)} cm"
        "vo2max" -> "${n.format(value)} ml/kg/min"
        "restingHr", "sleepHeartRate" -> "${whole(value)} bpm"
        else -> n.format(value)
    }
}

private fun areaKey(area: String): String = when (area) {
    "endurance" -> "Endurance"
    "training" -> "Strength and training"
    "fitness" -> "Heart and fitness"
    "daily" -> "Everyday activity"
    "body" -> "Body"
    "sleep" -> "Sleep and recovery"
    else -> "Habits"
}

private fun areaIcon(area: String): ImageVector = when (area) {
    "endurance" -> Icons.Rounded.DirectionsRun
    "training" -> Icons.Rounded.FitnessCenter
    "fitness" -> Icons.Rounded.Favorite
    "daily" -> Icons.Rounded.DirectionsWalk
    "body" -> Icons.Rounded.MonitorWeight
    "sleep" -> Icons.Rounded.Bedtime
    else -> Icons.Rounded.Checklist
}

@Composable
private fun AreaTile(area: String) {
    val tint = when (area) {
        "endurance", "training" -> ForgeTokens.Color.systemGreen
        "fitness" -> ForgeTokens.Color.systemRed
        "daily" -> ForgeTokens.Color.systemOrange
        "body" -> ForgeTokens.Color.systemBlue
        "sleep" -> ForgeTokens.Color.systemIndigo
        else -> ForgeTokens.Color.systemPurple
    }.resolve()
    Box(Modifier.size(30.dp).background(tint, RoundedCornerShape(8.4.dp)), contentAlignment = Alignment.Center) {
        Icon(areaIcon(area), contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
    }
}

// MARK: - The long-term goal's page (`LongTermGoalPage`)

/** A long-term goal: its state and progress, what to do next, the weekly goals that serve it and its lifecycle. */
@Composable
internal fun LongTermGoalPage(goal: CoreGoals.LongTerm?, periods: List<CoreGoals.Period>, onBack: () -> Unit,
                              onOpenPeriod: (String) -> Unit, onChanged: () -> Unit, onRemoved: () -> Unit) {
    val scope = rememberCoroutineScope()
    var confirmDelete by remember { mutableStateOf(false) }
    var choosingPause by remember { mutableStateOf(false) }
    fun change(action: String, reason: String? = null, after: () -> Unit = onChanged) {
        val id = goal?.id ?: return
        scope.launch {
            withContext(Dispatchers.IO) { CoreLongTermGoals.change(id, action, reason) }
            after()
        }
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_goals_long_term), onBack)
        if (goal == null) {
            Text(stringResource(R.string.forge_goals_gone), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        val colors = Forge.colors
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            LongTermRow(goal)
            if (goal.reason.isNotBlank()) {
                Text(goal.nextAction.ifBlank { goal.reason }, style = Forge.type.footnote, color = colors.textSecondary)
            }
        }
        val children = periods.filter { it.parentGoalId == goal.id }
        if (children.isNotEmpty()) {
            SectionHeader(stringResource(R.string.forge_lt_serving))
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                children.forEachIndexed { i, p ->
                    PeriodRow(p) { onOpenPeriod(p.id) }
                    if (i < children.lastIndex) RowDivider()
                }
            }
        }
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            if (goal.status == "paused") {
                GoalAction(stringResource(R.string.forge_goals_resume), colors.accent) { change("resume") }
            } else {
                GoalAction(stringResource(R.string.forge_goals_pause), colors.accent) { choosingPause = true }
            }
            RowDivider()
            GoalAction(stringResource(R.string.forge_lt_set_aside), colors.accent) { change("setAside", after = onRemoved) }
            RowDivider()
            GoalAction(stringResource(R.string.forge_goals_delete), ForgeTokens.Color.systemRed.resolve()) { confirmDelete = true }
        }
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(stringResource(R.string.forge_goals_delete_title)) },
            text = { Text(stringResource(R.string.forge_lt_delete_text)) },
            confirmButton = {
                TextButton(onClick = { confirmDelete = false; change("remove", after = onRemoved) }) {
                    Text(stringResource(R.string.forge_goals_delete), color = ForgeTokens.Color.systemRed.resolve())
                }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(stringResource(R.string.forge_cancel)) } },
        )
    }
    if (choosingPause) {
        PauseDialog(onDismiss = { choosingPause = false }) { raw -> choosingPause = false; change("pause", raw) }
    }
}

/** `GoalTemplateID.journalHabit`: the one template that needs a journal question before it can be set. */
private const val JOURNAL_HABIT = "habit.journal"
