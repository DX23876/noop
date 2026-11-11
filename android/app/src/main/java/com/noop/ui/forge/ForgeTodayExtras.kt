package com.noop.ui.forge

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.width
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.material.icons.Icons
import androidx.compose.foundation.background
import androidx.compose.material3.Icon
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.noop.R
import com.noop.analytics.HydrationGoal
import com.noop.analytics.HydrationStore
import com.noop.core.CoreRead
import com.noop.core.CoreTrainingLoad
import com.noop.data.DailyMetric
import com.noop.ui.AppViewModel
import com.noop.ui.BottomBarStyleStore
import com.noop.ui.DashboardCard
import com.noop.ui.DashboardCardPrefs
import com.noop.ui.HostedCardPrefs
import com.noop.ui.HostedPalette
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate

/**
 * Fork (DX23876), Android parity plan 2.3: the Today sections iOS can show that Forge Today did not draw (they went
 * with ryanbr's Today in E-3f): the latest workouts, the recovery vitals, Your Cards, the cycle card, the journal
 * card, the cards pulled in from Trends and Sleep, and Training Load. The cards are ryanbr's, taken from his current
 * Today, in the Forge colours; Training Load reads the shared core's lanes as `LiquidTrainingLoadSection` does.
 */
@Composable
private fun Classic(content: @Composable () -> Unit) {
    val colors = Forge.colors
    val tokens = remember(colors) { hostedTokens(colors) }
    HostedPalette(tokens, colors.dark) { content() }
}

/** The newest day carrying [pick], today first, as Today's per-field carry reads it. */
private fun latest(days: List<DailyMetric>, pick: (DailyMetric) -> Any?): DailyMetric? = days.lastOrNull { pick(it) != null }

@Composable
internal fun TodayWorkoutsForge(viewModel: AppViewModel) {
    val workouts by viewModel.workouts.collectAsState()
    if (ForgeDesign.preview) { LatestWorkoutCard(workouts); return }
    Classic {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            com.noop.ui.TodayWorkoutsSection(workouts) { }
        }
    }
}

@Composable
internal fun TodayRecoveryVitalsForge(viewModel: AppViewModel, onOpenMetric: (String) -> Unit) {
    val days by viewModel.recentDays.collectAsState()
    val today = com.noop.ui.logicalDayKeyNow()
    Classic {
        com.noop.ui.HeroMetricRows(day = days.lastOrNull { it.day == today }, carriedDay = latest(days) { it.recovery },
                                   vitalsDay = latest(days) { it.avgHrv }, onOpenMetric = onOpenMetric)
    }
}

@Composable
internal fun TodayYourCardsForge(viewModel: AppViewModel, onOpenMetric: (String) -> Unit, onOpenSleep: () -> Unit,
                                 onOpenStress: () -> Unit, onOpenHydration: () -> Unit, onOpenCoach: () -> Unit,
                                 onCustomise: () -> Unit) {
    val context = LocalContext.current
    val days by viewModel.recentDays.collectAsState()
    val spo2Candidates by viewModel.spo2CandidateByDay.collectAsState()
    val hydrationEnabled = remember { NoopPrefs.hydrationTracking(context) }
    val cards = remember { DashboardCardPrefs.enabled(context) }.filter {
        (it != DashboardCard.HYDRATION || hydrationEnabled) && (it != DashboardCard.COACH || BottomBarStyleStore.coachEnabled)
    }
    if (cards.isEmpty()) return
    var hydrationMl by remember { mutableStateOf(0.0) }
    val hydrationSeq by HydrationStore.mutationSeq.collectAsState()
    LaunchedEffect(days, hydrationSeq) {
        hydrationMl = if (hydrationEnabled) runCatching { HydrationStore.total(viewModel.repo) }.getOrDefault(0.0) else 0.0
    }
    val today = com.noop.ui.logicalDayKeyNow()
    val day = days.lastOrNull { it.day == today } ?: days.lastOrNull()
    val steps = days.takeLast(30).mapNotNull { it.steps }.filter { it > 0 }
    val profile = remember { ProfileStore.from(context) }
    Classic {
        com.noop.ui.YourCardsSection(
            cards = cards,
            stepsAverage30 = (steps.takeIf { it.isNotEmpty() }?.average()) to steps.size,
            day = day, carriedDay = latest(days) { it.recovery }, vitalsDay = latest(days) { it.avgHrv },
            spo2Day = latest(days) { it.spo2Pct }, skinTempDay = latest(days) { it.skinTempC ?: it.skinTempDevC },
            hrvDay = latest(days) { it.avgHrv }, rhrDay = latest(days) { it.restingHr }, respDay = latest(days) { it.respRateBpm },
            stress = viewModel.todayStressCache, fitnessAge = viewModel.todayFitnessAgeCache,
            vo2max = viewModel.todayVo2maxCache, vitality = viewModel.todayVitalityCache,
            importedStepsForDay = null, estimatedStepsForDay = null, caloriesForDay = null,
            hydrationTotalMl = hydrationMl,
            hydrationGoalMl = if (hydrationEnabled) HydrationGoal.dailyGoalMl(profile.sex, day?.strain) else 0,
            onOpenHydration = onOpenHydration, onOpenStress = onOpenStress, onOpenMetric = onOpenMetric,
            onOpenSleep = onOpenSleep, onOpenCoupled = { }, onOpenCoach = { onOpenCoach() }, onCustomise = onCustomise,
            spo2CandidateByDay = spo2Candidates,
        )
    }
}

@Composable
internal fun TodayCycleForge(viewModel: AppViewModel) {
    val enabled by viewModel.cycleTrackingEnabled.collectAsState()
    val starts by viewModel.periodStarts.collectAsState()
    val v5 by viewModel.v5Signals.collectAsState()
    var tracker by remember { mutableStateOf(false) }
    if (ForgeDesign.preview) {
        // The new design's cycle card and page (iOS `ForgeCycleSummaryCard`, `ForgeCycleView`).
        var page by remember { mutableStateOf(false) }
        var logFirst by remember { mutableStateOf(false) }
        if (enabled && starts.isNotEmpty()) ForgeCycleSummaryCard(viewModel, onOpen = { page = true }, onLog = { logFirst = true; page = true })
        else Classic {
            com.noop.ui.MenstrualCycleHomeCard(enabled = enabled, result = v5?.cycle, starts = starts,
                onSetUp = { viewModel.setCycleTrackingEnabled(true); page = true },
                onOpen = { page = true }, onLogToday = { viewModel.logPeriodStart() })
        }
        if (page) ForgeCycleOverlay(viewModel, logFirst, onDismiss = { page = false; logFirst = false })
        return
    }
    Classic {
        com.noop.ui.MenstrualCycleHomeCard(enabled = enabled, result = v5?.cycle, starts = starts,
            onSetUp = { viewModel.setCycleTrackingEnabled(true); tracker = true },
            onOpen = { tracker = true }, onLogToday = { viewModel.logPeriodStart() })
    }
    val cycle = v5?.cycle
    if (tracker && cycle != null) Classic {
        com.noop.ui.CycleTrackerDialog(result = cycle, starts = starts, onLog = viewModel::logPeriodStart,
            onDelete = viewModel::deletePeriodStart, onDeleteAll = viewModel::deleteAllPeriodStarts,
            onDismiss = { tracker = false })
    }
}

@Composable
internal fun TodayJournalForge(viewModel: AppViewModel, onOpenJournal: () -> Unit) {
    val days by viewModel.recentDays.collectAsState()
    Classic { com.noop.ui.JournalReminderCard(viewModel = viewModel, days = days, onOpenJournal = onOpenJournal) }
}

@Composable
internal fun TodayAddedCardsForge(viewModel: AppViewModel, onOpenMetric: (String) -> Unit, onOpenSleep: () -> Unit,
                                  onOpenStress: () -> Unit) {
    val context = LocalContext.current
    val days by viewModel.recentDays.collectAsState()
    val cards = remember { HostedCardPrefs.enabled(context) }
    if (cards.isEmpty()) return
    Classic {
        com.noop.ui.HostedCardsSection(cards = cards, days = days, viewModel = viewModel,
            effortScale = com.noop.ui.UnitPrefs.effortScale(context), onOpenStress = onOpenStress,
            onOpenSleep = onOpenSleep, onOpenMetric = onOpenMetric)
    }
}

/** `LiquidTrainingLoadSection`: TRAINING LOAD with "All", then the strength and cardio lanes from the core. */
@Composable
internal fun TodayTrainingLoadForge(onOpenAll: () -> Unit) {
    val context = LocalContext.current
    var output by remember { mutableStateOf<CoreTrainingLoad.Output?>(null) }
    // Read again after each analysis pass, so a workout synced while Today stays open shows in the lanes.
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    LaunchedEffect(coreRevision) {
        output = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val profile = ProfileStore.from(context)
            CoreTrainingLoad.read(profile.hrMax.toDouble(), profile.sex, dismissedTrainingWorkouts(context))
        }
    }
    val o = output ?: return
    val newDesign = ForgeDesign.preview
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            // The new design heads it as iOS's section: the title in sentence case, bold.
            if (newDesign) Text(stringResource(R.string.forge_tl_title), style = Forge.type.headline.copy(fontWeight = FontWeight.Bold),
                                color = Forge.sceneInk.text, modifier = Modifier.weight(1f))
            else Text(stringResource(R.string.forge_tl_title).uppercase(), style = Forge.type.overline,
                      color = Forge.sceneInk.secondary, modifier = Modifier.weight(1f))
            Text(stringResource(R.string.forge_momentum_all), style = Forge.type.caption, color = Forge.colors.accent,
                 modifier = Modifier.clickable(role = Role.Button, onClick = onOpenAll))
        }
        // As iOS's LiquidTrainingLoadSection: a lane with nothing logged in its window has nothing to compare and is
        // left out; with neither, one quiet sentence says what fills the card.
        if (newDesign && o.strength.possibleCount == 0 && o.cardio.possibleCount == 0) {
            ForgeCard(Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_tl_empty_today), style = Forge.type.footnote, color = Forge.colors.textSecondary)
            }
        } else HeroLanes(o)
    }
}

/**
 * The guided session (iOS `liveSessionCover`, opened from the quick actions): starts one when none runs, else shows
 * the running one again, never displacing a session or an unseen summary. ryanbr's session screen in Forge colours.
 */
@Composable
internal fun ForgeLiveSessionCover(viewModel: AppViewModel, onClose: () -> Unit) {
    val context = LocalContext.current
    LaunchedEffect(Unit) {
        if (com.noop.ui.LiveSessionRunner.active.value == null) com.noop.ui.startOrResumeLiveSession(viewModel, context)
    }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Classic { com.noop.ui.LiveSessionScreen(vm = viewModel, onClose = onClose) }
    }
}

/**
 * The new design's latest-workout card, as iOS's ForgeLastWorkoutWidget: the name, then the newest session of the
 * last 60 days with its sport's symbol, day, start and length, and its Effort on the right; before any, one quiet
 * line saying where workouts come from.
 */
@Composable
private fun LatestWorkoutCard(workouts: List<com.noop.data.WorkoutRow>) {
    val colors = Forge.colors
    val now = System.currentTimeMillis() / 1000
    val row = workouts.filter { it.endTs >= now - 60 * 86_400 }.maxByOrNull { it.endTs }
    val effortFormat = rememberEffortFormat()
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.forge_lw_title), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = colors.text, modifier = Modifier.weight(1f))
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = colors.textTertiary)
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        if (row == null) {
            Text(stringResource(R.string.forge_lw_none), style = Forge.type.caption, color = colors.textSecondary)
        } else {
            val zone = java.time.ZoneId.systemDefault()
            val start = java.time.Instant.ofEpochSecond(row.startTs).atZone(zone)
            val minutes = ((row.durationS ?: (row.endTs - row.startTs).coerceAtLeast(0).toDouble()) / 60).toInt()
            val locale = java.util.Locale.getDefault()
            val day = start.format(java.time.format.DateTimeFormatter.ofPattern(
                android.text.format.DateFormat.getBestDateTimePattern(locale, "dMMM"), locale))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(40.dp).background(colors.accent, RoundedCornerShape(10.dp)), contentAlignment = Alignment.Center) {
                    Icon(com.noop.ui.sportIcon(row.sport), contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
                }
                Spacer(Modifier.width(ForgeMetrics.space3))
                Column(Modifier.weight(1f)) {
                    Text(com.noop.ui.WorkoutEditing.displaySport(row.sport), style = Forge.type.headline, color = colors.text, maxLines = 1)
                    Text(stringResource(R.string.forge_lw_when, day, clockText(row.startTs), stringResource(R.string.forge_tw_min, minutes)),
                         style = Forge.type.caption, color = colors.textSecondary, maxLines = 1)
                }
                row.strain?.let { e ->
                    Column(horizontalAlignment = Alignment.End) {
                        Text(effortFormat(e), style = Forge.type.title2, color = colors.text)
                        Text(stringResource(R.string.forge_effort), style = Forge.type.caption, color = colors.textSecondary)
                    }
                }
            }
        }
    }
}

@Composable
private fun clockText(ts: Long): String =
    java.time.Instant.ofEpochSecond(ts).atZone(java.time.ZoneId.systemDefault()).format(rememberClockFormatter())
