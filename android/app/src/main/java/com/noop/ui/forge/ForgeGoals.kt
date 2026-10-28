package com.noop.ui.forge

import com.noop.ui.journalDisplayName
import androidx.compose.ui.draw.alpha
import com.noop.ui.resolveJournalItems
import com.noop.ui.loadJournalCatalogItems
import com.noop.ui.JournalCatalogItem
import com.noop.NoopApplication
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.TrackChanges
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.DirectionsWalk
import androidx.compose.material.icons.rounded.Eco
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Hotel
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material.icons.rounded.Checklist
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.Route
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material.icons.rounded.WaterDrop
import androidx.compose.material.icons.rounded.SportsGymnastics
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreGoals
import com.noop.core.CoreRead
import com.noop.ui.UnitPrefs
import com.noop.ui.UnitSystem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.roundToInt

/** What the goals page has open over its overview: one weekly or monthly goal, or the setup. */
private sealed interface GoalsPage {
    data class Detail(val id: String) : GoalsPage
    data class Daily(val slot: String) : GoalsPage
    data class LongTerm(val id: String) : GoalsPage
    data object LongTermSetup : GoalsPage
    data object Setup : GoalsPage
    data object Badges : GoalsPage
}

/**
 * Fork (DX23876), Android parity plan 2.3: "My goals" as the iOS overview draws it (`GoalsOverviewView`): today's
 * daily goals, the long-term goals, the weekly and the monthly goals with their pace, and the paused ones; a weekly or
 * monthly goal opens its page (`PeriodGoalDetailView`) and the plus starts the setup (`PeriodGoalSetupView`). Every
 * number comes from the shared core (`CoreGoals`), which evaluates and stores the goals as the Apple app does.
 */
@Composable
fun ForgeGoalsPage(onBack: () -> Unit, initialPage: String = "") {
    val context = LocalContext.current
    var output by remember { mutableStateOf<CoreGoals.Output?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var revision by remember { mutableIntStateOf(0) }
    var pageRaw by rememberSaveable { mutableStateOf(initialPage) }
    val page: GoalsPage? = when {
        pageRaw == "setup" -> GoalsPage.Setup
        pageRaw.startsWith("detail:") -> GoalsPage.Detail(pageRaw.removePrefix("detail:"))
        pageRaw.startsWith("daily:") -> GoalsPage.Daily(pageRaw.removePrefix("daily:"))
        pageRaw.startsWith("lt:") -> GoalsPage.LongTerm(pageRaw.removePrefix("lt:"))
        pageRaw == "ltsetup" -> GoalsPage.LongTermSetup
        pageRaw == "badges" -> GoalsPage.Badges
        else -> null
    }
    LaunchedEffect(revision) {
        output = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreGoals.snapshot(context, dismissedTrainingWorkouts(context))
        }
        loaded = true
    }
    // A page opened straight from a context card returns to that screen, not to the overview.
    fun back() { if (initialPage.isNotEmpty()) onBack() else pageRaw = "" }
    fun refresh() { revision++ }
    // System Back reloads like the page's own arrow, so what a page changed (badges seen, a goal edited) shows.
    BackHandler(enabled = page != null) { back(); refresh() }
    PublishGoalsWidget(output)
    when (page) {
        GoalsPage.Setup -> GoalSetupPage(onBack = ::back, onCreated = { back(); refresh() })
        is GoalsPage.Detail -> {
            val goal = output?.period?.firstOrNull { it.id == page.id }
            PeriodGoalPage(goal, onBack = ::back, onChanged = ::refresh,
                           onRemoved = { back(); refresh() })
        }
        is GoalsPage.Daily -> DailyGoalPage(output?.daily?.firstOrNull { it.slot == page.slot },
                                            onBack = ::back, onSaved = { back(); refresh() })
        is GoalsPage.LongTerm -> LongTermGoalPage(output?.longTerm?.firstOrNull { it.id == page.id },
                                                  output?.period.orEmpty(), onBack = ::back,
                                                  onOpenPeriod = { pageRaw = "detail:$it" }, onChanged = ::refresh,
                                                  onRemoved = { back(); refresh() })
        GoalsPage.LongTermSetup -> LongTermSetupPage(onBack = ::back, onCreated = { back(); refresh() })
        GoalsPage.Badges -> GoalBadgesPage(output?.motivation, onBack = { back(); refresh() })
        null -> GoalsOverview(output, loaded, onBack, onOpen = { pageRaw = "detail:$it" },
                              onDaily = { pageRaw = "daily:$it" }, onLongTerm = { pageRaw = "lt:$it" },
                              onAddLongTerm = { pageRaw = "ltsetup" }, onBadges = { pageRaw = "badges" },
                              onAdd = { pageRaw = "setup" }, onChanged = ::refresh)
    }
}

@Composable
private fun GoalsOverview(output: CoreGoals.Output?, loaded: Boolean, onBack: () -> Unit, onOpen: (String) -> Unit,
                          onDaily: (String) -> Unit, onLongTerm: (String) -> Unit, onAddLongTerm: () -> Unit,
                          onBadges: () -> Unit, onAdd: () -> Unit, onChanged: () -> Unit) {
    val scope = rememberCoroutineScope()
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_goals_title), onBack) {
            IconButton(onClick = onAdd) {
                Icon(Icons.Rounded.AddCircle, stringResource(R.string.forge_goals_new), tint = Forge.colors.accent)
            }
        }
        if (output == null) {
            Text(stringResource(if (loaded) R.string.forge_goals_unavailable else R.string.forge_goals_loading),
                 style = Forge.type.subhead, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        val active = output.period.filter { it.status == "active" }
        val paused = output.period.filter { it.status == "paused" }
        val longTerm = output.longTerm.filter { it.status == "active" || it.status == "paused" }
        val motivation = output.motivation
        var bannerHidden by remember { mutableStateOf(false) }
        if (motivation != null && motivation.unseen.isNotEmpty() && !bannerHidden) {
            NewBadgeBanner(motivation.unseen, onOpen = onBadges, onSeen = {
                bannerHidden = true
                scope.launch {
                    withContext(Dispatchers.IO) { CoreGoals.changeMotivation(seen = motivation.unseenIds) }
                    onChanged()
                }
            })
        }

        if (output.today.isNotEmpty()) {
            GoalSectionHeader(stringResource(R.string.forge_goals_today))
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                output.today.forEachIndexed { i, action ->
                    DailyRow(action, streak = motivation?.streaks?.get(action.actionId)) {
                        scope.launch {
                            withContext(Dispatchers.IO) { CoreGoals.toggleAction(action.actionId, action.day) }
                            onChanged()
                        }
                    }
                    if (i < output.today.lastIndex) RowDivider()
                }
            }
        }

        // The measured daily goals, one slot each, as the iOS "Daily" list offers them (`DailyGoalSheet`).
        GoalSectionHeader(stringResource(R.string.forge_goals_daily))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            output.daily.forEachIndexed { i, slot ->
                Row(Modifier.fillMaxWidth().clickable(role = Role.Button) { onDaily(slot.slot) }
                        .padding(vertical = ForgeMetrics.space2),
                    verticalAlignment = Alignment.CenterVertically) {
                    MetricTile(slotMetric(slot.slot))
                    Spacer(Modifier.width(ForgeMetrics.space3))
                    Text(slotTitle(slot.slot), style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
                    Text(slot.value?.let { slotValue(slot.slot, it) } ?: stringResource(R.string.forge_goals_daily_off),
                         style = Forge.type.subhead,
                         color = if (slot.value != null) Forge.colors.textSecondary else Forge.colors.textTertiary)
                    Spacer(Modifier.width(ForgeMetrics.space2))
                    Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = Forge.colors.textTertiary,
                         modifier = Modifier.size(18.dp))
                }
                if (i < output.daily.lastIndex) RowDivider()
            }
        }

        GoalSectionHeader(stringResource(R.string.forge_goals_long_term))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            longTerm.forEachIndexed { i, goal ->
                Box(Modifier.clickable(role = Role.Button) { onLongTerm(goal.id) }) { LongTermRow(goal) }
                RowDivider()
            }
            AddRow(stringResource(R.string.forge_lt_add), onAddLongTerm)
        }

        for (period in listOf("week", "month")) {
            val goals = active.filter { it.period == period }
            val left = goals.firstOrNull()?.daysLeft
            GoalSectionHeader(stringResource(if (period == "week") R.string.forge_goals_weekly else R.string.forge_goals_monthly) +
                (left?.let { " · " + if (it <= 1) stringResource(R.string.forge_goals_ends_today)
                                     else stringResource(R.string.forge_goals_days_left, it) } ?: ""))
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                goals.forEachIndexed { i, goal ->
                    PeriodRow(goal) { onOpen(goal.id) }
                    if (i < goals.lastIndex) RowDivider()
                }
                if (goals.isNotEmpty()) RowDivider()
                AddRow(stringResource(if (period == "week") R.string.forge_goals_add_weekly else R.string.forge_goals_add_monthly),
                       onAdd)
            }
        }

        if (paused.isNotEmpty()) {
            GoalSectionHeader(stringResource(R.string.forge_goals_paused))
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                paused.forEachIndexed { i, goal ->
                    PeriodRow(goal) { onOpen(goal.id) }
                    if (i < paused.lastIndex) RowDivider()
                }
            }
        }
        AchievementsCard(motivation, output.motivationEnabled, onOpen = onBadges, onSwitch = { on ->
            scope.launch {
                withContext(Dispatchers.IO) { CoreGoals.changeMotivation(enabled = on) }
                onChanged()
            }
        })
        GoalNotificationsCard()
    }
}

/**
 * The goal notifications iOS offers in its goal settings (`GoalsSettingsView`): four kinds, each off until switched
 * on. Switching one on asks for Android's notification permission where the system needs it.
 */
@Composable
private fun GoalNotificationsCard() {
    val context = LocalContext.current
    val kinds = com.noop.notif.GoalNoticeNotifier.Kind.values()
    var on by remember { mutableStateOf(kinds.associateWith { com.noop.notif.GoalNoticeNotifier.isOn(context, it) }) }
    val permission = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) {}
    GoalSectionHeader(stringResource(R.string.forge_gn_title))
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        kinds.forEachIndexed { i, kind ->
            ToggleRow(stringResource(when (kind) {
                com.noop.notif.GoalNoticeNotifier.Kind.Reached -> R.string.forge_gn_reached
                com.noop.notif.GoalNoticeNotifier.Kind.Streak -> R.string.forge_gn_streak
                com.noop.notif.GoalNoticeNotifier.Kind.Badge -> R.string.forge_gn_badge
                com.noop.notif.GoalNoticeNotifier.Kind.Milestone -> R.string.forge_gn_milestone
            }), detail = null, checked = on[kind] == true) { value ->
                com.noop.notif.GoalNoticeNotifier.setOn(context, kind, value)
                on = on + (kind to value)
                if (value && android.os.Build.VERSION.SDK_INT >= 33 &&
                    androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS) !=
                    android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    permission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
                }
            }
            if (i < kinds.lastIndex) RowDivider()
        }
        Text(stringResource(R.string.forge_gn_footer), style = Forge.type.caption, color = Forge.colors.textTertiary)
    }
}

// MARK: - Rows

@Composable
private fun DailyRow(action: CoreGoals.Action, streak: Int? = null, onToggle: () -> Unit) {
    val colors = Forge.colors
    val manual = action.kind == "manual" || action.kind == "journal"
    Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
            .then(if (manual) Modifier.clickable(role = Role.Checkbox, onClick = onToggle) else Modifier)
            .padding(vertical = ForgeMetrics.space1),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(if (action.isCompleted) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked,
             contentDescription = null, tint = if (action.isCompleted) colors.charge else colors.textTertiary,
             modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(action.title, style = Forge.type.body, color = colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
            val measured = action.measured
            val target = action.measuredTarget
            if (measured != null && target != null && target > 0) {
                ProgressBar((measured / target).coerceIn(0.0, 1.0), if (action.isCompleted) colors.charge else colors.accent,
                            pace = null)
                Text(stringResource(R.string.forge_goals_fraction, whole(measured), whole(target)), style = Forge.type.caption, color = colors.textSecondary)
            }
            // "5 days in a row", as the iOS daily list adds it from two days on.
            if (streak != null && streak >= 2) {
                Text(stringResource(R.string.forge_gm_in_a_row, streak), style = Forge.type.caption, color = colors.textSecondary)
            }
        }
    }
}

@Composable
internal fun LongTermRow(goal: CoreGoals.LongTerm) {
    val colors = Forge.colors
    Column(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(goal.title, style = Forge.type.body, color = colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis,
                 modifier = Modifier.weight(1f))
            Spacer(Modifier.width(ForgeMetrics.space2))
            // A catalog goal reads its state as its page does (Apple's overview row); others keep their health.
            val color = if (goal.statusText != null) toneColor(goal.statusTone) else healthColor(goal.health)
            Text(goal.statusText ?: healthWord(goal.health), style = Forge.type.footnote, color = color)
        }
        goal.progress?.let {
            ProgressBar(it.coerceIn(0.0, 1.0), if (goal.statusText != null) toneColor(goal.statusTone) else healthColor(goal.health),
                        pace = null)
        }
        goal.targetDate?.let { day ->
            Text(stringResource(R.string.forge_goals_by_date, longDate(day)), style = Forge.type.caption,
                 color = colors.textTertiary)
        }
    }
}

@Composable
internal fun PeriodRow(goal: CoreGoals.Period, onClick: () -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onClick).padding(vertical = ForgeMetrics.space2),
        verticalAlignment = Alignment.CenterVertically) {
        MetricTile(goal.metric)
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(shortName(goal), style = Forge.type.body, color = colors.text, maxLines = 1,
                     overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                Text(progressText(goal), style = Forge.type.bodyNumber, color = colors.text)
            }
            ProgressBar(goal.fraction.coerceIn(0.0, 1.0), stateColor(goal.state), goal.paceFraction)
            Row {
                Text(stateWord(goal.state), style = Forge.type.caption, color = stateColor(goal.state))
                Text(" · " + remainingLine(goal), style = Forge.type.caption, color = colors.textSecondary,
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Spacer(Modifier.width(ForgeMetrics.space2))
        Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun AddRow(title: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget).clickable(role = Role.Button, onClick = onClick),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Rounded.AddCircle, contentDescription = null, tint = Forge.colors.accent, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(ForgeMetrics.space2))
        Text(title, style = Forge.type.subhead, color = Forge.colors.accent)
    }
}

/** A rounded track with the done share filled and, where the pace says where the wearer should stand, a tick. */
@Composable
private fun ProgressBar(fraction: Double, color: Color, pace: Double?) {
    Box(Modifier.fillMaxWidth().height(6.dp).clip(CircleShape).background(Forge.colors.inset)) {
        Box(Modifier.fillMaxWidth(fraction.toFloat()).height(6.dp).clip(CircleShape).background(color))
        if (pace != null && pace in 0.0..1.0) {
            Box(Modifier.fillMaxWidth(pace.toFloat()).height(6.dp), contentAlignment = Alignment.CenterEnd) {
                Box(Modifier.width(2.dp).height(6.dp).background(Forge.colors.text.copy(alpha = 0.55f)))
            }
        }
    }
}

@Composable
private fun MetricTile(metric: String) {
    Box(Modifier.size(30.dp).background(metricColor(metric), RoundedCornerShape(8.4.dp)), contentAlignment = Alignment.Center) {
        Icon(metricIcon(metric), contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
    }
}

// MARK: - Detail

@Composable
private fun PeriodGoalPage(goal: CoreGoals.Period?, onBack: () -> Unit, onChanged: () -> Unit, onRemoved: () -> Unit) {
    val scope = rememberCoroutineScope()
    var confirmDelete by remember { mutableStateOf(false) }
    var choosingPause by remember { mutableStateOf(false) }
    fun change(action: String, target: Double? = null, reason: String? = null, after: () -> Unit = onChanged) {
        val id = goal?.id ?: return
        scope.launch {
            withContext(Dispatchers.IO) { CoreGoals.changePeriodGoal(id, action, target, reason) }
            after()
        }
    }
    SettingsColumn {
        PageTitle(stringResource(if (goal?.period == "month") R.string.forge_goals_monthly_goal else R.string.forge_goals_weekly_goal),
                  onBack)
        if (goal == null) {
            Text(stringResource(R.string.forge_goals_gone), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        val colors = Forge.colors
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                MetricTile(goal.metric)
                Spacer(Modifier.width(ForgeMetrics.space3))
                Text(title(goal), style = Forge.type.headline, color = colors.text, modifier = Modifier.weight(1f))
            }
            Spacer(Modifier.height(ForgeMetrics.space3))
            Text(range(goal.periodDays) + " · " + remainingLine(goal), style = Forge.type.footnote, color = colors.textSecondary)
            Spacer(Modifier.height(ForgeMetrics.space3))
            Row(verticalAlignment = Alignment.Bottom) {
                Text(if (goal.aggregation == "average") amount(goal.current, goal.metric) else number(goal.current, goal.metric),
                     style = Forge.type.title1, color = colors.text)
                if (goal.aggregation != "average") {
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.forge_goals_of, amount(goal.periodTarget, goal.metric)),
                         style = Forge.type.subhead, color = colors.textSecondary,
                         modifier = Modifier.padding(bottom = 4.dp))
                }
                Spacer(Modifier.weight(1f))
                Text(stateWord(goal.state), style = Forge.type.subhead, color = stateColor(goal.state))
            }
            Spacer(Modifier.height(ForgeMetrics.space2))
            ProgressBar(goal.fraction.coerceIn(0.0, 1.0), stateColor(goal.state), goal.paceFraction)
            if (goal.period == "week" && goal.aggregation != "average") {
                Spacer(Modifier.height(ForgeMetrics.space3))
                DayStrip(goal)
            }
        }

        SettingsCard(title = stringResource(R.string.forge_goals_target), blurb = null) {
            SettingRow(stringResource(R.string.forge_goals_per_period,
                                      stringResource(if (goal.period == "week") R.string.forge_goals_a_week else R.string.forge_goals_a_month))) {
                Stepper(amount(goal.target, goal.metric), enabled = goal.status == "active",
                        onMinus = { change("setTarget", (goal.target - goal.step).coerceAtLeast(goal.rangeLow)) },
                        onPlus = { change("setTarget", (goal.target + goal.step).coerceAtMost(goal.rangeHigh)) })
            }
            Text(stringResource(R.string.forge_goals_target_note), style = Forge.type.caption, color = colors.textTertiary)
        }

        if (goal.history.isNotEmpty() || goal.bestStreak > 0) {
            SettingsCard(title = stringResource(R.string.forge_goals_history), blurb = streakLine(goal)) {
                val reached = goal.history.count { it.outcome == "achieved" }
                goal.history.asReversed().forEachIndexed { i, entry ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(longDate(entry.periodStart), style = Forge.type.subhead, color = colors.text,
                             modifier = Modifier.weight(1f))
                        Text(stringResource(R.string.forge_goals_fraction, number(entry.value, goal.metric), number(entry.target, goal.metric)),
                             style = Forge.type.subhead, color = colors.textSecondary)
                        Spacer(Modifier.width(ForgeMetrics.space2))
                        Text(outcomeWord(entry.outcome), style = Forge.type.caption, color = outcomeColor(entry.outcome))
                    }
                    if (i < goal.history.lastIndex) RowDivider()
                }
                if (goal.history.isNotEmpty()) {
                    Text(stringResource(if (goal.period == "week") R.string.forge_goals_reached_weeks else R.string.forge_goals_reached_months,
                                        reached, goal.history.size),
                         style = Forge.type.caption, color = colors.textTertiary)
                }
            }
        }

        SettingsCard(title = stringResource(R.string.forge_goals_counted), blurb = null) {
            if (goal.counted.isEmpty()) {
                Text(stringResource(if (goal.period == "week") R.string.forge_goals_nothing_week else R.string.forge_goals_nothing_month),
                     style = Forge.type.subhead, color = colors.textSecondary)
            }
            goal.counted.forEachIndexed { i, item ->
                Row(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    Text(goalDay(item.day) + " · " + item.title, style = Forge.type.subhead, color = colors.text,
                         modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(number(item.value, goal.metric), style = Forge.type.subhead, color = colors.textSecondary)
                }
                if (i < goal.counted.lastIndex) RowDivider()
            }
            if (goal.notCounted.isNotEmpty()) {
                Text(stringResource(R.string.forge_goals_not_counted, goal.notCounted.size), style = Forge.type.caption,
                     color = colors.textTertiary)
            }
        }

        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            if (goal.status == "paused") {
                GoalAction(stringResource(R.string.forge_goals_resume), colors.accent) { change("resume") }
            } else {
                GoalAction(stringResource(R.string.forge_goals_pause), colors.accent) { choosingPause = true }
            }
            RowDivider()
            GoalAction(stringResource(R.string.forge_goals_end), colors.accent) { change("end", after = onRemoved) }
            RowDivider()
            GoalAction(stringResource(R.string.forge_goals_delete), ForgeTokens.Color.systemRed.resolve()) { confirmDelete = true }
        }
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(stringResource(R.string.forge_goals_delete_title)) },
            text = { Text(stringResource(R.string.forge_goals_delete_text)) },
            confirmButton = {
                TextButton(onClick = { confirmDelete = false; change("remove", after = onRemoved) }) {
                    Text(stringResource(R.string.forge_goals_delete), color = ForgeTokens.Color.systemRed.resolve())
                }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(stringResource(R.string.forge_cancel)) } },
        )
    }
    if (choosingPause) {
        PauseDialog(onDismiss = { choosingPause = false }) { raw -> choosingPause = false; change("pause", reason = raw) }
    }
}

/** The pause question with its reasons (`CoachGoal.PauseReason`): paused weeks are protected. */
@Composable
internal fun PauseDialog(onDismiss: () -> Unit, onPick: (String) -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.forge_goals_pause_title)) },
        text = {
            Column {
                Text(stringResource(R.string.forge_goals_pause_text), style = Forge.type.footnote)
                PAUSE_REASONS.forEach { (raw, label) ->
                    Text(stringResource(label), style = Forge.type.body, color = Forge.colors.accent,
                         modifier = Modifier.fillMaxWidth().clickable(role = Role.Button) { onPick(raw) }
                             .padding(vertical = 12.dp))
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.forge_cancel)) } },
    )
}

private val PAUSE_REASONS = listOf(
    "illness" to R.string.forge_goals_pause_illness, "pain" to R.string.forge_goals_pause_pain,
    "travel" to R.string.forge_goals_pause_travel, "life" to R.string.forge_goals_pause_life,
    "other" to R.string.forge_goals_pause_other,
)

@Composable
internal fun GoalAction(label: String, color: Color, onClick: () -> Unit) {
    Text(label, style = Forge.type.body, color = color,
         modifier = Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onClick).padding(vertical = 12.dp))
}

/** The week as dots, as iOS draws a count goal's days (`dayDots`): met, missed, rest, today and still to come. */
@Composable
private fun DayStrip(goal: CoreGoals.Period) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        goal.periodDays.forEachIndexed { i, day ->
            val value = goal.dayValues.getOrNull(i)
            val met = (value ?: 0.0) > 0
            val future = i > goal.todayIndex
            val rest = goal.restDays.contains(day)
            val fill = when {
                met -> stateColor(goal.state)
                i == goal.todayIndex -> colors.accent.copy(alpha = 0.25f)
                future || rest || value == null -> Color.Transparent
                else -> colors.inset
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Box(Modifier.size(16.dp).clip(CircleShape).background(fill)
                        .then(if (fill == Color.Transparent) Modifier.border(1.dp, colors.divider, CircleShape) else Modifier))
                Text(weekdayInitial(day), style = Forge.type.caption,
                     color = if (i == goal.todayIndex) colors.text else colors.textTertiary)
            }
        }
    }
}

// MARK: - Setup

@Composable
private fun GoalSetupPage(onBack: () -> Unit, onCreated: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var setup by remember { mutableStateOf<CoreGoals.Setup?>(null) }
    var period by rememberSaveable { mutableStateOf("week") }
    var metric by rememberSaveable { mutableStateOf<String?>(null) }
    var target by rememberSaveable { mutableStateOf<Double?>(null) }
    var habitKey by rememberSaveable { mutableStateOf<String?>(null) }
    var habitWantsYes by rememberSaveable { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    val habits = journalHabits()
    LaunchedEffect(Unit) {
        setup = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreGoals.setup(context, dismissedTrainingWorkouts(context))
        }
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_goals_new), onBack)
        val s = setup
        if (s == null) {
            Text(stringResource(R.string.forge_goals_loading), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        SettingsCard(title = null, blurb = stringResource(R.string.forge_goals_setup_blurb)) {
            SettingRow(stringResource(R.string.forge_goals_period)) {
                Segmented(listOf("week", "month"), period,
                          label = { stringResource(if (it == "week") R.string.forge_goals_weekly else R.string.forge_goals_monthly) },
                          onSelect = { period = it; target = null })
            }
        }
        SettingsCard(title = stringResource(R.string.forge_goals_what), blurb = null) {
            val shown = s.metrics
            shown.forEachIndexed { i, choice ->
                val chosen = choice.metric == metric
                Row(Modifier.fillMaxWidth()
                        .clickable(enabled = choice.available, role = Role.RadioButton) { metric = choice.metric; target = null }
                        .padding(vertical = ForgeMetrics.space2),
                    verticalAlignment = Alignment.CenterVertically) {
                    MetricTile(choice.metric)
                    Spacer(Modifier.width(ForgeMetrics.space3))
                    Column(Modifier.weight(1f)) {
                        Text(metricLabel(choice.metric), style = Forge.type.body,
                             color = if (choice.available) Forge.colors.text else Forge.colors.textTertiary)
                        Text(if (choice.available) metricBlurb(choice.metric)
                             else choice.reason?.let { GOAL_CATALOG_TEXT[it] }?.let { stringResource(it) }
                                 ?: stringResource(R.string.forge_goals_no_data_yet),
                             style = Forge.type.caption, color = Forge.colors.textTertiary)
                    }
                    if (chosen) Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = Forge.colors.accent)
                }
                if (i < shown.lastIndex) RowDivider()
            }
        }
        val choice = s.metrics.firstOrNull { it.metric == metric }
        if (choice?.metric == "habitDays") {
            SettingsCard(title = stringResource(R.string.forge_goals_habit_which), blurb = null) {
                HabitPicker(habits, habitKey, habitWantsYes, onKey = { habitKey = it }, onWantsYes = { habitWantsYes = it })
                Text(stringResource(if (habitWantsYes) R.string.forge_goals_habit_counts_yes else R.string.forge_goals_habit_counts_no),
                     style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
        }
        if (choice != null) {
            val week = period == "week"
            val ready = choice.metric != "habitDays" || habitKey != null
            val step = if (week) choice.weekStep else choice.monthStep
            val low = if (week) choice.weekLow else choice.monthLow
            val high = if (week) choice.weekHigh else choice.monthHigh
            val value = target ?: (if (week) choice.weekDefault else choice.monthDefault)
            SettingsCard(title = stringResource(R.string.forge_goals_target), blurb = null) {
                SettingRow(stringResource(R.string.forge_goals_per_period,
                                          stringResource(if (week) R.string.forge_goals_a_week else R.string.forge_goals_a_month))) {
                    Stepper(amount(value, choice.metric),
                            onMinus = { target = (value - step).coerceAtLeast(low) },
                            onPlus = { target = (value + step).coerceAtMost(high) })
                }
                error?.let { Text(it, style = Forge.type.caption, color = ForgeTokens.Color.systemRed.resolve()) }
                Spacer(Modifier.height(ForgeMetrics.space2))
                val limitText = stringResource(R.string.forge_goals_limit, s.periodLimit)
                val duplicateText = stringResource(R.string.forge_goals_duplicate)
                val failedText = stringResource(R.string.forge_goals_failed)
                Box(Modifier.fillMaxWidth().alpha(if (ready) 1f else 0.45f).clip(RoundedCornerShape(14.dp))
                         .background(Forge.colors.accent)
                         .clickable(enabled = ready, role = Role.Button) {
                             scope.launch {
                                 val result = withContext(Dispatchers.IO) {
                                     CoreGoals.addPeriodGoal(choice.metric, period, value, choice.threshold,
                                                             habitKey.takeIf { choice.metric == "habitDays" }, habitWantsYes)
                                 }
                                 when {
                                     result.ok -> onCreated()
                                     result.error == "limitReached" -> error = limitText
                                     result.error == "duplicate" -> error = duplicateText
                                     else -> error = failedText
                                 }
                             }
                         }.padding(vertical = 14.dp), contentAlignment = Alignment.Center) {
                    Text(stringResource(R.string.forge_goals_create), style = Forge.type.headline, color = Color.White)
                }
            }
        }
    }
}


// MARK: - Daily goal editor (`DailyGoalSheet`)

@Composable
private fun DailyGoalPage(slot: CoreGoals.DailySlot?, onBack: () -> Unit, onSaved: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    SettingsColumn {
        PageTitle(slot?.let { slotTitle(it.slot) } ?: stringResource(R.string.forge_goals_daily), onBack)
        if (slot == null) {
            Text(stringResource(R.string.forge_goals_loading), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        var value by rememberSaveable { mutableStateOf(slot.value ?: slot.defaultValue) }
        var runs by rememberSaveable { mutableStateOf(slot.runs ?: "ongoing") }
        var endsOn by rememberSaveable {
            mutableStateOf(slot.endsOn?.takeIf { slot.runs == "untilDate" } ?: LocalDate.now().plusMonths(1).toString())
        }
        var weekdays by rememberSaveable { mutableStateOf(slot.weekdays.toSet().toList()) }
        var ring by rememberSaveable { mutableStateOf(slot.showsAsRing) }
        val values = slot.values
        SettingsCard(title = null, blurb = null) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                MetricTile(slotMetric(slot.slot))
                Spacer(Modifier.width(ForgeMetrics.space3))
                Column(Modifier.weight(1f)) {
                    Text(slotValue(slot.slot, value), style = Forge.type.title2, color = Forge.colors.text)
                    Text(stringResource(if (slot.slot == "sleep") R.string.forge_goals_a_night else R.string.forge_goals_a_day),
                         style = Forge.type.caption, color = Forge.colors.textTertiary)
                }
                val index = values.indexOfFirst { it >= value }.let { if (it < 0) values.lastIndex else it }
                Stepper("", onMinus = { value = values.getOrElse(index - 1) { values.first() } },
                        onPlus = { value = values.getOrElse(index + 1) { values.last() } })
            }
        }
        SettingsCard(title = stringResource(R.string.forge_goals_how_long), blurb = null) {
            Segmented(listOf("ongoing", "untilDate", "todayOnly"), runs,
                      label = {
                          stringResource(when (it) {
                              "untilDate" -> R.string.forge_goals_until_date
                              "todayOnly" -> R.string.forge_goals_today_only
                              else -> R.string.forge_goals_ongoing
                          })
                      },
                      onSelect = { runs = it })
            if (runs == "untilDate") {
                RowDivider()
                SettingRow(stringResource(R.string.forge_goals_last_day)) {
                    Text(longDate(endsOn), style = Forge.type.body, color = Forge.colors.accent,
                         modifier = Modifier.clickable(role = Role.Button) {
                             val d = parse(endsOn) ?: LocalDate.now()
                             android.app.DatePickerDialog(context, { _, y, m, day ->
                                 endsOn = LocalDate.of(y, m + 1, day).toString()
                             }, d.year, d.monthValue - 1, d.dayOfMonth).apply {
                                 datePicker.minDate = System.currentTimeMillis()
                             }.show()
                         }.padding(vertical = 8.dp))
                }
            }
        }
        if (runs != "todayOnly") {
            SettingsCard(title = stringResource(R.string.forge_goals_on_days), blurb = null) {
                // Calendar weekdays as iOS stores them (1 Sunday ... 7 Saturday), shown from Monday.
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    listOf(2, 3, 4, 5, 6, 7, 1).forEach { weekday ->
                        val on = weekday in weekdays
                        val name = java.time.DayOfWeek.of(if (weekday == 1) 7 else weekday - 1)
                            .getDisplayName(TextStyle.NARROW, Locale.getDefault())
                        Box(Modifier.size(36.dp).clip(CircleShape)
                                .background(if (on) Forge.colors.accent else Forge.colors.inset)
                                .clickable(role = Role.Checkbox) {
                                    weekdays = if (on) weekdays - weekday else weekdays + weekday
                                },
                            contentAlignment = Alignment.Center) {
                            Text(name, style = Forge.type.subhead, color = if (on) Color.White else Forge.colors.textSecondary)
                        }
                    }
                }
            }
        }
        SettingsCard(title = null, blurb = null) {
            ToggleRow(stringResource(R.string.forge_goals_show_ring), stringResource(R.string.forge_goals_show_ring_detail),
                      ring) { ring = it }
        }
        val canSave = runs == "todayOnly" || weekdays.isNotEmpty()
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp))
                .background(if (canSave) Forge.colors.accent else Forge.colors.inset)
                .clickable(enabled = canSave, role = Role.Button) {
                    scope.launch {
                        withContext(Dispatchers.IO) {
                            CoreGoals.saveDaily(slot.slot, value, runs, endsOn, weekdays.sorted(), ring)
                        }
                        onSaved()
                    }
                }.padding(vertical = 14.dp), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.forge_goals_save), style = Forge.type.headline, color = Color.White)
        }
        if (slot.value != null) {
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                GoalAction(stringResource(R.string.forge_goals_turn_off), ForgeTokens.Color.systemRed.resolve()) {
                    scope.launch {
                        withContext(Dispatchers.IO) { CoreGoals.turnOffDaily(slot.slot) }
                        onSaved()
                    }
                }
            }
        }
    }
}

private fun slotMetric(slot: String): String = when (slot) {
    "activeCalories" -> "activeEnergy"
    "sleep" -> "sleepNights"
    else -> "stepDays"
}

@Composable
private fun slotTitle(slot: String): String = stringResource(when (slot) {
    "activeCalories" -> R.string.forge_goals_slot_active
    "sleep" -> R.string.forge_goals_slot_sleep
    else -> R.string.forge_goals_slot_steps
})

@Composable
private fun slotValue(slot: String, value: Double): String = when (slot) {
    "activeCalories" -> stringResource(R.string.forge_goals_kcal_value, whole(value))
    "sleep" -> stringResource(R.string.forge_goals_hours_value,
                              NumberFormat.getNumberInstance(Locale.getDefault()).apply { maximumFractionDigits = 2 }.format(value))
    else -> stringResource(R.string.forge_goals_steps_value, whole(value))
}

// MARK: - Today card (`GoalsTodaySection`)

/**
 * Today's goals card as iOS shows it on the home screen (`GoalsTodaySection`, decided by the shared `GoalSpotlight`):
 * the weekly, monthly or long-term goals that need a look, today's daily goals with their progress, and how many
 * weekly and monthly goals are on course. Nothing is drawn while there are no goals.
 */
@Composable
fun ForgeTodayGoalsCard(output: CoreGoals.Output?, onOpen: () -> Unit, onToggle: (CoreGoals.Action) -> Unit) {
    output ?: return
    val spot = output.spotlight
    if (spot.rows.isEmpty() && output.today.isEmpty() && spot.weekTotal + spot.monthTotal == 0) return
    val colors = Forge.colors
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        SectionHeader(stringResource(R.string.forge_goals_more_title))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            spot.rows.forEachIndexed { i, row ->
                if (i > 0) RowDivider()
                if (row.kind == "period") {
                    output.period.firstOrNull { it.id == row.id }?.let { PeriodRow(it, onOpen) }
                } else {
                    output.longTerm.firstOrNull { it.id == row.id }?.let {
                        Box(Modifier.clickable(role = Role.Button, onClick = onOpen)) { LongTermRow(it) }
                    }
                }
            }
            if (output.today.isNotEmpty()) {
                if (spot.rows.isNotEmpty()) RowDivider()
                Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget).clickable(role = Role.Button, onClick = onOpen),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.forge_goals_today).uppercase(), style = Forge.type.overline,
                         color = colors.textSecondary)
                    Spacer(Modifier.width(ForgeMetrics.space2))
                    Text(stringResource(R.string.forge_goals_done_count, spot.dailyDone, spot.dailyTotal),
                         style = Forge.type.caption, color = colors.textSecondary, modifier = Modifier.weight(1f))
                    Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary,
                         modifier = Modifier.size(16.dp))
                }
                val order = spot.rings + spot.checks
                output.today.sortedBy { order.indexOf(it.id).let { i -> if (i < 0) Int.MAX_VALUE else i } }.forEach { action ->
                    DailyRow(action) { onToggle(action) }
                }
            }
            val parts = buildList {
                if (spot.weekTotal > 0) add(stringResource(R.string.forge_goals_week_on_course, spot.weekOnCourse, spot.weekTotal))
                if (spot.monthTotal > 0) {
                    val month = LocalDate.now().month.getDisplayName(TextStyle.FULL_STANDALONE, Locale.getDefault())
                    add(stringResource(R.string.forge_goals_month_on_course, month, spot.monthOnCourse, spot.monthTotal))
                }
            }
            if (parts.isNotEmpty()) {
                RowDivider()
                Row(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen).padding(vertical = ForgeMetrics.space2),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(parts.joinToString(" · "), style = Forge.type.footnote, color = colors.textSecondary,
                         modifier = Modifier.weight(1f))
                    Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary,
                         modifier = Modifier.size(16.dp))
                }
            }
        }
    }
}

/**
 * A section heading on the goal pages, which sit on the sky scene: the scene's ink keeps it readable over a dark sky
 * as iOS's overline is over its backdrop. The Today card keeps the canvas heading.
 */
@Composable
internal fun GoalSectionHeader(text: String, modifier: Modifier = Modifier) {
    Text(text.uppercase(), style = Forge.type.overline, color = Forge.sceneInk.secondary,
         modifier = modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space1))
}

// MARK: - Context card (`GoalsContextCard`)

/**
 * The goals that belong to a screen, at its top, as iOS places them (`GoalsContextCard`): the week's training goals on
 * the Training tab, the week's sleep goal on Sleep. Which goal belongs where is the shared `GoalContext`'s call. A goal
 * opens its own page; without a training goal the Training tab offers to set one. Sleep draws nothing without one.
 */
@Composable
fun ForgeGoalsContextCard(contextName: String) {
    val context = LocalContext.current
    var output by remember { mutableStateOf<CoreGoals.Output?>(null) }
    var revision by remember { mutableIntStateOf(0) }
    var open by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(revision) {
        output = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreGoals.snapshot(context, dismissedTrainingWorkouts(context))
        }
    }
    val loaded = output ?: return
    val items = loaded.period.filter { contextName in it.contexts }.take(2)
    val training = contextName == "training"
    if (items.isNotEmpty()) {
        ForgeCard(Modifier.fillMaxWidth()) {
            Text(stringResource(if (training) R.string.forge_goals_ctx_training else R.string.forge_goals_ctx_sleep).uppercase(),
                 style = Forge.type.overline, color = Forge.colors.textSecondary)
            Spacer(Modifier.height(ForgeMetrics.space2))
            items.forEach { goal -> PeriodRow(goal) { open = "detail:${goal.id}" } }
        }
    } else if (training) {
        Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
                .clickable(role = Role.Button) { open = "setup" },
            verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.AddCircle, contentDescription = null, tint = Forge.colors.accent, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(stringResource(R.string.forge_goals_ctx_set_training), style = Forge.type.footnote, color = Forge.colors.accent)
        }
    }
    open?.let { start ->
        ForgeOverlayPage(onDismiss = { open = null; revision++ }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) { ForgeGoalsPage(onBack = { open = null; revision++ }, initialPage = start) }
        }
    }
}

/**
 * The goal notes beside a workout or a night (iOS `GoalContributionNote`, `SleepGoalNightLine`): one line per goal with
 * the target mark, as the core words them. Nothing is drawn without a line.
 */
@Composable
fun ForgeGoalLines(lines: List<String>) {
    if (lines.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        lines.forEach { line ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.TrackChanges, contentDescription = null, tint = Forge.colors.accent,
                     modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(6.dp))
                Text(line, style = Forge.type.footnote, color = Forge.colors.textSecondary)
            }
        }
    }
}

/**
 * Hands the goals widget what Today's card shows (`GoalSpotlight`'s rows with their progress, the daily count and the
 * week on course), in the screens' own words. Called wherever the app shows the goals; quiet without a widget placed.
 */
@Composable
internal fun PublishGoalsWidget(output: CoreGoals.Output?) {
    output ?: return
    val context = LocalContext.current
    val spot = output.spotlight
    val chosen = spot.rows.mapNotNull { row ->
        if (row.kind == "period") output.period.firstOrNull { it.id == row.id }?.let { periodWidgetGoal(it) }
        else output.longTerm.firstOrNull { it.id == row.id }?.let {
            com.noop.widget.GoalsGlanceWidget.Goal(it.title, it.progress?.let { p -> "${(p * 100).roundToInt()} %" } ?: "",
                it.progress ?: 0.0, it.statusText ?: healthWord(it.health))
        }
    }
    // Nothing needs a look: the open weekly goals, then the monthly ones, as the iOS widget falls back to every
    // goal (`spot.isEmpty ? goals : spot`), so a goal on course never reads as "set a weekly goal".
    val open = output.period.filter { it.status == "active" }
    val goals = chosen.ifEmpty {
        (open.filter { it.period == "week" } + open.filter { it.period == "month" }).take(3).map { periodWidgetGoal(it) }
    }
    val summary = buildList {
        if (spot.dailyTotal > 0) add(stringResource(R.string.forge_goals_done_count, spot.dailyDone, spot.dailyTotal))
        if (spot.weekTotal > 0) add(stringResource(R.string.forge_goals_week_on_course, spot.weekOnCourse, spot.weekTotal))
    }.joinToString(" · ")
    LaunchedEffect(goals, summary) {
        withContext(Dispatchers.IO) { com.noop.widget.GoalsGlanceWidget.publish(context, goals, summary) }
    }
}

@Composable
private fun periodWidgetGoal(goal: CoreGoals.Period) = com.noop.widget.GoalsGlanceWidget.Goal(
    shortName(goal), progressText(goal), goal.fraction.coerceIn(0.0, 1.0), stateWord(goal.state))

// MARK: - Words and numbers (`GoalFormat`, `GoalStatusStyle`)

@Composable
private fun metricLabel(metric: String): String = stringResource(when (metric) {
    "workouts" -> R.string.forge_goals_m_workouts
    "trainingMinutes" -> R.string.forge_goals_m_training_minutes
    "distance" -> R.string.forge_goals_m_distance
    "stepDays" -> R.string.forge_goals_m_step_days
    "sleepNights" -> R.string.forge_goals_m_sleep_nights
    "sleepAverage" -> R.string.forge_goals_m_sleep_average
    "zoneMinutes" -> R.string.forge_goals_m_zone_minutes
    "workingSets" -> R.string.forge_goals_m_working_sets
    "activeEnergy" -> R.string.forge_goals_m_active_energy
    "restDays" -> R.string.forge_goals_m_rest_days
    "hydrationDays" -> R.string.forge_goals_m_hydration_days
    "habitDays" -> R.string.forge_goals_m_habit_days
    "strengthMinutes" -> R.string.forge_goals_m_strength_minutes
    "moderateMinutes" -> R.string.forge_goals_m_moderate_minutes
    else -> R.string.forge_goals_m_vigorous_minutes
})

@Composable
private fun metricBlurb(metric: String): String = stringResource(when (metric) {
    "workouts" -> R.string.forge_goals_b_workouts
    "trainingMinutes" -> R.string.forge_goals_b_training_minutes
    "distance" -> R.string.forge_goals_b_distance
    "stepDays" -> R.string.forge_goals_b_step_days
    "sleepNights" -> R.string.forge_goals_b_sleep_nights
    "sleepAverage" -> R.string.forge_goals_b_sleep_average
    "zoneMinutes" -> R.string.forge_goals_b_zone_minutes
    "workingSets" -> R.string.forge_goals_b_working_sets
    "activeEnergy" -> R.string.forge_goals_b_active_energy
    "restDays" -> R.string.forge_goals_b_rest_days
    "hydrationDays" -> R.string.forge_goals_b_hydration_days
    "habitDays" -> R.string.forge_goals_b_habit_days
    "strengthMinutes" -> R.string.forge_goals_b_strength_minutes
    "moderateMinutes" -> R.string.forge_goals_b_moderate_minutes
    else -> R.string.forge_goals_b_vigorous_minutes
})

private fun metricIcon(metric: String): ImageVector = when (metric) {
    "workouts", "vigorousMinutes" -> Icons.Rounded.DirectionsRun
    "trainingMinutes" -> Icons.Rounded.Timer
    "distance" -> Icons.Rounded.Route
    "stepDays", "moderateMinutes" -> Icons.Rounded.DirectionsWalk
    "sleepNights" -> Icons.Rounded.Bedtime
    "sleepAverage" -> Icons.Rounded.Hotel
    "zoneMinutes" -> Icons.Rounded.Favorite
    "workingSets" -> Icons.Rounded.FitnessCenter
    "activeEnergy" -> Icons.Rounded.LocalFireDepartment
    "restDays" -> Icons.Rounded.Eco
    "hydrationDays" -> Icons.Rounded.WaterDrop
    "habitDays" -> Icons.Rounded.Checklist
    else -> Icons.Rounded.SportsGymnastics
}

/** The metric's identity colour, the system colour its iOS colour key resolves to. */
@Composable
private fun metricColor(metric: String): Color = when (metric) {
    "workouts", "trainingMinutes" -> ForgeTokens.Color.systemGreen
    "distance" -> ForgeTokens.Color.systemGreen
    "zoneMinutes", "moderateMinutes", "vigorousMinutes" -> ForgeTokens.Color.systemRed
    "stepDays" -> ForgeTokens.Color.systemOrange
    "activeEnergy" -> ForgeTokens.Color.systemOrange
    "hydrationDays" -> ForgeTokens.Color.systemCyan
    "sleepNights", "sleepAverage" -> ForgeTokens.Color.systemIndigo
    "workingSets", "strengthMinutes" -> ForgeTokens.Color.systemBlue
    "restDays" -> ForgeTokens.Color.systemMint
    else -> ForgeTokens.Color.systemPurple
}.resolve()

@Composable
private fun unit(metric: String): String = when (metric) {
    "workouts" -> stringResource(R.string.forge_goals_u_workouts)
    "trainingMinutes", "zoneMinutes", "strengthMinutes", "moderateMinutes", "vigorousMinutes" ->
        stringResource(R.string.forge_goals_u_min)
    "distance" -> if (imperialDistance()) "mi" else "km"
    "sleepAverage" -> stringResource(R.string.forge_goals_u_h)
    "workingSets" -> stringResource(R.string.forge_goals_u_sets)
    "activeEnergy" -> "kcal"
    else -> stringResource(R.string.forge_goals_u_days)
}

@Composable
private fun imperialDistance(): Boolean = UnitPrefs.distanceSystem(LocalContext.current) == UnitSystem.IMPERIAL

/** The number alone: whole for counts and days, one decimal for distance and hours (`GoalFormat.number`). */
@Composable
private fun number(value: Double, metric: String): String {
    val shown = if (metric == "distance" && imperialDistance()) value / 1.609344 else value
    val format = NumberFormat.getNumberInstance(Locale.getDefault())
    return when (metric) {
        "distance" -> format.apply { maximumFractionDigits = 1; minimumFractionDigits = 0 }.format(shown)
        "sleepAverage" -> format.apply { maximumFractionDigits = 1; minimumFractionDigits = 1 }.format(shown)
        else -> format.format(shown.roundToInt())
    }
}

@Composable
private fun amount(value: Double, metric: String): String = "${number(value, metric)} ${unit(metric)}"

private fun whole(value: Double): String = NumberFormat.getIntegerInstance(Locale.getDefault()).format(value.roundToInt())

@Composable
private fun progressText(goal: CoreGoals.Period): String =
    if (goal.aggregation == "average") amount(goal.current, goal.metric)
    else "${number(goal.current, goal.metric)}/${number(goal.periodTarget, goal.metric)}"

/** Short name for rows: the metric with its threshold (`GoalFormat.shortName`). */
@Composable
private fun shortName(goal: CoreGoals.Period): String = when (goal.metric) {
    "stepDays" -> stringResource(R.string.forge_goals_steps_name, whole(goal.threshold ?: 8_000.0))
    "sleepNights" -> stringResource(R.string.forge_goals_nights_name, hours(goal.threshold ?: 7.0))
    "habitDays" -> goal.habitKey?.let { journalDisplayName(loadJournalCatalogItems(LocalContext.current), it) }
        ?: metricLabel(goal.metric)
    else -> metricLabel(goal.metric)
}

/** The goal's name as the wearer reads it (`GoalFormat.title`). */
@Composable
private fun title(goal: CoreGoals.Period): String {
    val per = stringResource(if (goal.period == "week") R.string.forge_goals_a_week else R.string.forge_goals_a_month)
    val target = number(goal.target, goal.metric)
    return when (goal.metric) {
        "stepDays" -> stringResource(R.string.forge_goals_title_steps, target, whole(goal.threshold ?: 8_000.0), per)
        "sleepNights" -> stringResource(R.string.forge_goals_title_nights, target, hours(goal.threshold ?: 7.0), per)
        "sleepAverage" -> stringResource(R.string.forge_goals_title_sleep_average, target, per)
        "restDays" -> stringResource(R.string.forge_goals_title_rest, target, per)
        "habitDays" -> {
            val habit = shortName(goal)
            if (goal.habitWantsYes) stringResource(R.string.forge_goals_title_habit_yes, habit, target, per)
            else stringResource(R.string.forge_goals_title_habit_no, target, habit, per)
        }
        else -> "$target ${unit(goal.metric)} $per"
    }
}

private fun hours(value: Double): String =
    NumberFormat.getNumberInstance(Locale.getDefault()).apply { maximumFractionDigits = 1 }.format(value)

/** The line under a goal: what is left, numbers before words (`GoalFormat.remainingLine`). */
@Composable
private fun remainingLine(goal: CoreGoals.Period): String {
    val week = goal.period == "week"
    return when (goal.state) {
        "achieved" -> {
            val over = goal.current - goal.periodTarget
            if (goal.aggregation != "average" && over >= goal.step - 1e-9)
                stringResource(R.string.forge_goals_over, number(over, goal.metric))
            else stringResource(if (week) R.string.forge_goals_done_week else R.string.forge_goals_done_month)
        }
        "protected" -> stringResource(if (week) R.string.forge_goals_protected_week else R.string.forge_goals_protected_month)
        "noData" -> stringResource(R.string.forge_goals_too_few_days)
        "outOfReach" ->
            if (goal.daysLeft <= 1) stringResource(if (week) R.string.forge_goals_short_new_week else R.string.forge_goals_short_new_month,
                                                   amount(goal.remaining, goal.metric))
            else stringResource(R.string.forge_goals_short, amount(goal.remaining, goal.metric))
        else -> when {
            goal.aggregation == "average" -> {
                val needed = goal.requiredPerDay
                if (needed != null && goal.daysLeft > 0 && goal.state != "onTrack" && goal.state != "ahead")
                    stringResource(R.string.forge_goals_needs_nightly, number(needed, goal.metric))
                else stringResource(R.string.forge_goals_average_so_far, amount(goal.periodTarget, goal.metric))
            }
            goal.isProrated && goal.history.isEmpty() ->
                stringResource(if (week) R.string.forge_goals_first_week_prorated else R.string.forge_goals_first_month_prorated,
                               amount(goal.remaining, goal.metric))
            goal.daysLeft == 1 -> stringResource(R.string.forge_goals_to_go_last_day, amount(goal.remaining, goal.metric))
            else -> stringResource(R.string.forge_goals_to_go, amount(goal.remaining, goal.metric), goal.daysLeft)
        }
    }
}

@Composable
private fun streakLine(goal: CoreGoals.Period): String? {
    val week = goal.period == "week"
    return when {
        goal.currentStreak > 0 && goal.bestStreak > goal.currentStreak ->
            stringResource(if (week) R.string.forge_goals_streak_weeks_best else R.string.forge_goals_streak_months_best,
                           goal.currentStreak, goal.bestStreak)
        goal.currentStreak > 0 ->
            stringResource(if (week) R.string.forge_goals_streak_weeks else R.string.forge_goals_streak_months, goal.currentStreak)
        goal.bestStreak > 0 ->
            stringResource(if (week) R.string.forge_goals_best_weeks else R.string.forge_goals_best_months, goal.bestStreak)
        else -> null
    }
}

@Composable
private fun stateWord(state: String): String = stringResource(when (state) {
    "achieved" -> R.string.forge_goals_s_achieved
    "ahead" -> R.string.forge_goals_s_ahead
    "onTrack" -> R.string.forge_goals_s_on_track
    "close" -> R.string.forge_goals_s_close
    "behind" -> R.string.forge_goals_s_behind
    "outOfReach" -> R.string.forge_goals_s_out_of_reach
    "protected" -> R.string.forge_goals_s_protected
    "starting" -> R.string.forge_goals_s_starting
    else -> R.string.forge_goals_s_no_data
})

/** The state's tone (`GoalStatusStyle`): positive, warning, critical, accent or neutral. */
@Composable
private fun stateColor(state: String): Color = when (state) {
    "achieved", "ahead", "onTrack" -> ForgeTokens.Color.systemGreen.resolve()
    "close" -> ForgeTokens.Color.systemOrange.resolve()
    "behind" -> ForgeTokens.Color.systemRed.resolve()
    "protected" -> Forge.colors.accent
    else -> Forge.colors.textTertiary
}

@Composable
private fun outcomeWord(outcome: String): String = when (outcome) {
    "almost" -> stringResource(R.string.forge_goals_o_almost)
    "missed" -> stringResource(R.string.forge_goals_o_missed)
    else -> stateWord(outcome)
}

@Composable
private fun outcomeColor(outcome: String): Color = when (outcome) {
    "almost" -> ForgeTokens.Color.systemOrange.resolve()
    "missed" -> ForgeTokens.Color.systemRed.resolve()
    else -> stateColor(outcome)
}

@Composable
private fun healthWord(health: String): String = stringResource(when (health) {
    "decisionNeeded" -> R.string.forge_goals_h_decision
    "atRisk" -> R.string.forge_goals_h_at_risk
    "attention" -> R.string.forge_goals_h_attention
    "onTrack" -> R.string.forge_goals_s_on_track
    "paused" -> R.string.forge_goals_paused_one
    else -> R.string.forge_goals_h_building
})

@Composable
private fun healthColor(health: String): Color = when (health) {
    "onTrack" -> ForgeTokens.Color.systemGreen.resolve()
    "attention" -> ForgeTokens.Color.systemOrange.resolve()
    "atRisk", "decisionNeeded" -> ForgeTokens.Color.systemRed.resolve()
    else -> Forge.colors.textTertiary
}

private fun parse(day: String): LocalDate? = runCatching { LocalDate.parse(day) }.getOrNull()

private fun longDate(day: String): String = parse(day)?.let {
    java.time.format.DateTimeFormatter.ofLocalizedDate(java.time.format.FormatStyle.MEDIUM).withLocale(Locale.getDefault()).format(it)
} ?: day

private fun goalDay(day: String): String = parse(day)?.let {
    java.time.format.DateTimeFormatter.ofPattern("d MMM", Locale.getDefault()).format(it)
} ?: day

@Composable
private fun range(days: List<String>): String {
    val first = days.firstOrNull()?.let(::parse) ?: return ""
    val last = days.lastOrNull()?.let(::parse) ?: return ""
    fun f(d: LocalDate) = java.time.format.DateTimeFormatter.ofPattern("d MMMM", Locale.getDefault()).format(d)
    return stringResource(R.string.forge_goals_range, f(first), f(last))
}

private fun weekdayInitial(day: String): String =
    parse(day)?.dayOfWeek?.getDisplayName(TextStyle.NARROW, Locale.getDefault()) ?: ""

// MARK: - Journal habits

/** The journal's own list, starter, imported and custom questions, as the Apple habit picker offers it. */
@Composable
internal fun journalHabits(): List<JournalCatalogItem> {
    val context = LocalContext.current
    var items by remember { mutableStateOf<List<JournalCatalogItem>>(emptyList()) }
    LaunchedEffect(Unit) {
        items = withContext(Dispatchers.IO) {
            val repo = (context.applicationContext as NoopApplication).repository
            val imported = runCatching { repo.journal("my-whoop", "0000-01-01", "9999-12-31") }.getOrDefault(emptyList())
            resolveJournalItems(imported.map { it.question }.distinct(), loadJournalCatalogItems(context))
        }
    }
    return items
}

/** Which journal question a habit goal counts, and whether a yes or a no keeps it. */
@Composable
internal fun HabitPicker(items: List<JournalCatalogItem>, key: String?, wantsYes: Boolean,
                         onKey: (String) -> Unit, onWantsYes: (Boolean) -> Unit) {
    if (items.isEmpty()) {
        Text(stringResource(R.string.forge_goals_habit_none), style = Forge.type.footnote, color = Forge.colors.textSecondary)
    }
    items.forEachIndexed { i, item ->
        Row(Modifier.fillMaxWidth().clickable(role = Role.RadioButton) { onKey(item.canonical) }
                .padding(vertical = ForgeMetrics.space2),
            verticalAlignment = Alignment.CenterVertically) {
            Text(item.displayName ?: item.canonical, style = Forge.type.body, color = Forge.colors.text,
                 modifier = Modifier.weight(1f))
            if (item.canonical == key) Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = Forge.colors.accent)
        }
        if (i < items.lastIndex) RowDivider()
    }
    Spacer(Modifier.height(ForgeMetrics.space2))
    Segmented(listOf(true, false), wantsYes,
              label = { stringResource(if (it) R.string.forge_goals_habit_do else R.string.forge_goals_habit_avoid) },
              onSelect = onWantsYes)
}
