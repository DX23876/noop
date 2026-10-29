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
    Classic {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            com.noop.ui.TodayWorkoutsSection(workouts) { }
        }
    }
}

@Composable
internal fun TodayRecoveryVitalsForge(viewModel: AppViewModel, onOpenMetric: (String) -> Unit) {
    val days by viewModel.recentDays.collectAsState()
    val today = LocalDate.now().toString()
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
    val today = LocalDate.now().toString()
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
    LaunchedEffect(Unit) {
        output = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val profile = ProfileStore.from(context)
            CoreTrainingLoad.read(profile.hrMax.toDouble(), profile.sex, dismissedTrainingWorkouts(context))
        }
    }
    val o = output ?: return
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.forge_tl_title).uppercase(), style = Forge.type.overline,
                 color = Forge.sceneInk.secondary, modifier = Modifier.weight(1f))
            Text(stringResource(R.string.forge_momentum_all), style = Forge.type.caption, color = Forge.colors.accent,
                 modifier = Modifier.clickable(role = Role.Button, onClick = onOpenAll))
        }
        HeroLanes(o)
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
