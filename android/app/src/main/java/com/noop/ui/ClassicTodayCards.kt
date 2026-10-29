package com.noop.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.Accessibility
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.BluetoothSearching
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Functions
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.MonitorWeight
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material.icons.filled.TrackChanges
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.automirrored.filled.BatteryUnknown
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshContainer
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.zIndex
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import android.app.DatePickerDialog
import android.content.Context
import android.view.HapticFeedbackConstants
import android.widget.Toast
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.noop.R
import com.noop.ai.AiKeyStore
import com.noop.analytics.Baselines
import com.noop.analytics.ChargeBaselines
import com.noop.analytics.BatteryEstimator
import com.noop.analytics.ChargeDriver
import com.noop.analytics.ChargeDriverLabel
import com.noop.analytics.ChargeDriverUnit
import com.noop.analytics.RecoveryDrivers
import com.noop.analytics.ChargeDriverVerdict
import com.noop.analytics.DayCycleMode
import com.noop.analytics.DayCycleIntelligenceIntegration
import com.noop.analytics.HydrationGoal
import com.noop.analytics.HydrationStore
import com.noop.analytics.ReadinessEngine
import com.noop.analytics.ScoreConfidence
import com.noop.analytics.SleepMark
import com.noop.analytics.SleepMarkType
import com.noop.analytics.StepsEstimateEngine
import com.noop.analytics.StrainScorer
import com.noop.ble.WhoopModel
import com.noop.data.DailyMetric
import com.noop.protocol.Whoop5RR
import com.noop.widget.StressPoint
import com.noop.widget.StressWidgetProducer
import com.noop.widget.WidgetSnapshotStore
import com.noop.data.HrBucket
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ingest.HealthConnectImporter
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit
import java.util.Calendar
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The compact Live Sessions entry under the hero ("Start session · BETA"). Three honest states off the
 * process-wide [LiveSessionRunner.active]: no session → start affordance; session running → the way back
 * into the dismissed session dialog (with a live elapsed clock); session ended but its summary not yet
 * Done-dismissed → "See the summary". The runner's 1 Hz snapshot is collected INSIDE this card only, so
 * the per-second tick recomposes this card, never the Today body (the WorkoutInProgressCard idiom).
 * The whole card is one tap target; [onOpen] begins/re-presents the session dialog.
 */
@Composable
internal fun LiveSessionEntryCard(onOpen: () -> Unit) {
    val active by LiveSessionRunner.active.collectAsStateWithLifecycle()
    val runner = active
    var running = false
    var summaryWaiting = false
    var elapsed = ""
    if (runner != null) {
        val snap by runner.snapshot.collectAsStateWithLifecycle()
        running = !snap.ended
        summaryWaiting = snap.ended
        elapsed = elapsedClock(snap.elapsedSec.toLong())
    }
    val teal = Palette.metricCyan
    val title = when {
        running -> uiString(R.string.today_live_session_running)
        summaryWaiting -> uiString(R.string.today_live_session_ended)
        else -> uiString(R.string.today_live_session_start)
    }
    val detail = when {
        running -> uiString(R.string.today_live_session_guarding)
        summaryWaiting -> uiString(R.string.today_live_session_summary)
        else -> uiString(R.string.today_live_session_explanation)
    }

    // liquidPress on the whole tappable card (same interactionSource on clickable + press), matching the
    // workout-in-progress card above. Merged semantics so TalkBack reads one Button, not four stops.
    val interaction = remember { MutableInteractionSource() }
    NoopCard(
        tint = teal,
        modifier = Modifier
            .liquidPress(interaction)
            .clickable(interactionSource = interaction, indication = null, onClick = onOpen)
            .semantics(mergeDescendants = true) {
                contentDescription = uiString(R.string.l10n_today_screen_title_beta_detail_6b39ae21, title, detail)
            },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(
                Icons.Filled.TrackChanges,
                contentDescription = null,
                tint = teal,
                modifier = Modifier.size(20.dp),
            )
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                ) {
                    Text(title, style = NoopType.headline, color = Palette.textPrimary)
                    StatePill(uiString(R.string.today_beta), tone = StrandTone.Accent, showsDot = false)
                }
                Text(detail, style = NoopType.footnote, color = Palette.textTertiary)
            }
            if (running) {
                Text(elapsed, style = NoopType.number(15f), color = Palette.textPrimary)
            }
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = Palette.textTertiary,
                modifier = Modifier.size(Metrics.iconSmall),
            )
        }
    }
}

@Composable
internal fun TodayWorkoutsSection(workouts: List<WorkoutRow>, onSelect: (WorkoutRow) -> Unit) {
    // Single column, newest first: the 2x2 grid truncated durations on narrow phones and read as
    // unrelated stat tiles rather than a chronological feed. Full-width tiles have room for the
    // kcal chip, so the #332 compactDelta workaround is no longer needed here.
    val feed = lastWorkoutsFeed(workouts)
    if (feed.isEmpty()) return

    // "Latest Workouts", not "Last": "Last" read as "final". Mirrored on iOS (TodayView). Lives in
    // strings.xml (values + values-de) so the header is localizable like the nav labels.
    SectionHeader(stringResource(R.string.today_latest_workouts), overline = uiString(R.string.today_workouts_activity), trailing = uiString(R.string.today_workouts_14_days))
    // #1694: the feed was read-only, so the only way to a session's detail was More > Workouts. The
    // tap opens the SAME read-only WorkoutDetailSheet the Workouts list uses — nothing there can edit
    // or delete, so a tap from Today carries no risk that list does not already carry.
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        feed.forEach { workout ->
            val interaction = remember(workout.startTs, workout.source) { MutableInteractionSource() }
            StatTile(
                modifier = Modifier
                    .fillMaxWidth()
                    .liquidPress(interaction)
                    .clickable(
                        interactionSource = interaction,
                        indication = null,
                        onClickLabel = uiString(R.string.today_action_show_workout),
                        onClick = { onSelect(workout) },
                    ),
                label = WorkoutEditing.displaySport(workout.sport),
                value = localizedMetricValue(workoutDuration(workout)),
                caption = workoutCaption(workout),
                accent = workout.strain?.let { Palette.effortTint(it / StrainScorer.maxStrain) } ?: Palette.textPrimary,
                delta = workout.energyKcal?.let { "${it.roundToInt()} kcal" },
                deltaColor = Palette.metricAmber,
            )
        }
    }
}

/** The three hero vitals as README metric rows, HRV (teal) · Resting HR (rose) · Respiratory (blue).
 *  Reads PER-FIELD today-first with a recovery-INDEPENDENT vitals carry ([vitalsDay]) as the fallback
 *  (#543 follow-up), so a night whose recovery was nulled post-update still shows its OWN preserved HRV /
 *  RHR / respiratory rather than an older recovery-scored day's numbers (or "No Data"). This aligns the
 *  card to the Key-Metrics tiles, which already read per-field. Each row still falls through to "No Data"
 *  for a vital neither today nor the carry supplies. */
@Composable
@Suppress("UNUSED_PARAMETER")
internal fun HeroMetricRows(
    day: DailyMetric?,
    carriedDay: DailyMetric? = null,
    vitalsDay: DailyMetric? = null,
    // #706/#684: the same `vital_detail/<key>` trends the HRV / Resting HR / Respiratory dashboard cards
    // open. These three rows show the SAME metrics and had no way through, so the summary card was the one
    // place on Today where a metric was a dead end. Keys come from `dashboardCardMetricKey`, so the two
    // surfaces cannot drift onto different destinations for the same vital.
    onOpenMetric: (String) -> Unit = {},
) {
    // Per-field, today-first: today's own value wins; the vitals carry only fills a field today lacks.
    val hrv = day?.avgHrv ?: vitalsDay?.avgHrv
    val rhr = day?.restingHr ?: vitalsDay?.restingHr
    val resp = day?.respRateBpm ?: vitalsDay?.respRateBpm
    // The caption reflects the row the shown vitals actually came from: if today supplied ANY of them the
    // values are today's own, so don't stamp them as a prior "Last night · <date>"; only when EVERY shown
    // vital is carried do we stamp the carry's date (relabelled "Latest sleep · <date>" when weeks-old).
    val carriedFromVitals = day?.avgHrv == null && day?.restingHr == null && day?.respRateBpm == null &&
        (hrv != null || rhr != null || resp != null) && vitalsDay != null
    // #1801: why the two blanks below are blank. Read from the SAME row the shown vitals came from —
    // `carriedFromVitals` already decides that for the date caption, so reusing it keeps the note and the
    // values describing one night. `day?.sleepHrOnly ?: vitalsDay?.sleepHrOnly` would instead fall through
    // on a pre-v36 row whose flag is merely unknown, and explain a different night's numbers.
    // Gated on something actually being blank, so a night that recovered its vitals stays quiet.
    val hrOnlyNight = showsHrOnlyNote(day, vitalsDay, carriedFromVitals, hrv, rhr)
    // iOS `recoveryVitalsSection`: a frosted card with a "RECOVERY VITALS" header + a "last night · <date>"
    // on the right, then three `vitalRow`s (26dp mini LIQUID RING + label + value). NoopCard supplies the
    // same neutral surfaceRaised + hairline as iOS's frosted card. Inner spacing 12, matching iOS.
    NoopCard(padding = Metrics.space16) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(Metrics.space12),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Overline(uiString(R.string.today_section_recovery_vitals), modifier = Modifier.weight(1f))
                // iOS `lastNightLine` — today's own "Last night · <date>" unless the shown vitals are a carry.
                Text(
                    if (carriedFromVitals) carriedCaption(vitalsDay!!.day).localized() else heroVitalsLastNightLine(),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
            HeroVitalRow(
                label = uiString(R.string.l10n_today_screen_heart_rate_variability_a137586d),
                value = hrv?.let { "${it.roundToInt()} ms" } ?: NO_DATA,
                tint = Palette.metricCyan,
                fraction = hrv?.let { (it / 120.0).coerceIn(0.0, 1.0) },
                metricKey = dashboardCardMetricKey(DashboardCard.HRV),
                onOpenMetric = onOpenMetric,
            )
            HeroVitalRow(
                label = uiString(R.string.l10n_today_screen_resting_heart_rate_348928d6),
                value = rhr?.let { "$it bpm" } ?: NO_DATA,
                tint = Palette.metricRose,
                fraction = rhr?.let { (it / 100.0).coerceIn(0.0, 1.0) },
                metricKey = dashboardCardMetricKey(DashboardCard.RESTING_HR),
                onOpenMetric = onOpenMetric,
            )
            HeroVitalRow(
                label = uiString(R.string.l10n_today_screen_breaths_per_minute_2b197c54),
                value = resp?.let { String.format(Locale.getDefault(), "%.1f rpm", it) } ?: NO_DATA,
                tint = Palette.accent,
                fraction = resp?.let { (it / 24.0).coerceIn(0.0, 1.0) },
                metricKey = dashboardCardMetricKey(DashboardCard.RESPIRATORY),
                onOpenMetric = onOpenMetric,
            )
            if (hrOnlyNight) {
                Text(
                    uiString(R.string.l10n_today_screen_this_night_was_staged_from_heart_rate_4d0f1f9b),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

@Composable
internal fun YourCardsSection(
    cards: List<DashboardCard>,
    stepsAverage30: Pair<Double?, Int>,
    day: DailyMetric?,
    carriedDay: DailyMetric?,
    vitalsDay: DailyMetric?,
    spo2Day: DailyMetric?,
    skinTempDay: DailyMetric?,
    hrvDay: DailyMetric?,
    rhrDay: DailyMetric?,
    respDay: DailyMetric?,
    stress: Double?,
    fitnessAge: Double?,
    vo2max: Double?,
    vitality: Double?,
    importedStepsForDay: Int?,
    estimatedStepsForDay: Int?,
    caloriesForDay: Double?,
    hydrationTotalMl: Double,
    hydrationGoalMl: Int,
    onOpenHydration: () -> Unit,
    onOpenStress: () -> Unit,
    onOpenMetric: (String) -> Unit,
    onOpenSleep: () -> Unit,
    onOpenCoupled: () -> Unit,
    onOpenCoach: (String?) -> Unit,
    onCustomise: () -> Unit,
    spo2CandidateByDay: Map<String, Double> = emptyMap(),
) {
    // #1331 parity: honor the °C/°F preference on the Skin Temp card, the way Health / Compare (and the
    // Swift twin) do. The classic dashboard hardcoded Celsius here alone, so a °F user saw °C on this
    // screen only.
    val fahrenheit = UnitPrefs.temperature(LocalContext.current) == TemperatureUnit.FAHRENHEIT
    // #1862: the optional Coach card opens a launcher BOTTOM SHEET rather than a destination. Local
    // presentation state — showing it requests nothing from a provider.
    // Fork: the Coach card opens the Forge coach chat; Forge Today carries the launcher sheet itself.
    var showCoachLauncher by remember { mutableStateOf(false) }
    if (showCoachLauncher) { showCoachLauncher = false; onOpenCoach(null) }
    Box(modifier = Modifier.fillMaxWidth().staggeredAppear(2)) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            // Header: "YOUR CARDS" overline + a right-aligned blue EDIT action (the WHOOP ✎ affordance).
            Row(verticalAlignment = Alignment.CenterVertically) {
                Overline(uiString(R.string.today_section_your_cards), modifier = Modifier.weight(1f))
                TodayEditAction(
                    onClick = onCustomise,
                    contentDescription = uiString(R.string.l10n_today_screen_customise_your_cards_2428d761),
                )
            }
            cards.forEach { card ->
                DashboardCardRow(
                    card = card,
                    value = dashboardCardValue(
                        card = card,
                        stepsAverage30 = stepsAverage30.first,
                        day = day,
                        carriedDay = carriedDay,
                        vitalsDay = vitalsDay,
                        spo2Day = spo2Day,
                        skinTempDay = skinTempDay,
                        hrvDay = hrvDay,
                        rhrDay = rhrDay,
                        respDay = respDay,
                        fahrenheit = fahrenheit,
                        // #1846: the user's lead-with choice. Read at the call site, not defaulted inside —
                        // a defaulted parameter no caller passes is a setting that silently does nothing.
                        skinTempPreferred = com.noop.ui.UnitPrefs.skinTempPreferred(LocalContext.current),
                        stress = stress,
                        fitnessAge = fitnessAge,
                        vo2max = vo2max,
                        vitality = vitality,
                        importedStepsForDay = importedStepsForDay,
                        estimatedStepsForDay = estimatedStepsForDay,
                        caloriesForDay = caloriesForDay,
                        hydrationTotalMl = hydrationTotalMl,
                        hydrationGoalMl = hydrationGoalMl,
                        spo2CandidateByDay = spo2CandidateByDay,
                    ),
                    // The mini liquid ring's fill — the SAME per-card fraction iOS `liquidCard` uses.
                    fraction = dashboardCardFraction(
                        card = card,
                        stepsAverage30 = stepsAverage30.first,
                        day = day,
                        carriedDay = carriedDay,
                        vitalsDay = vitalsDay,
                        respDay = respDay,
                        stress = stress,
                        fitnessAge = fitnessAge,
                        vo2max = vo2max,
                        vitality = vitality,
                        importedStepsForDay = importedStepsForDay,
                        estimatedStepsForDay = estimatedStepsForDay,
                    ),
                    tint = dashboardCardTint(card),
                    // #110: label the sleep row with its source + night (this section renders at offset 0
                    // only, so it IS last night), so a WHOOP-imported figure is never silently shown as
                    // "last night" with no provenance. iOS TodayView.sleepSourceSubtitle twin.
                    subtitleOverride = if (card == DashboardCard.STEPS_AVERAGE_30)
                        uiString(R.string.steps_average_coverage, stepsAverage30.second)
                    else sleepSourceSubtitle(card, day),
                    // #706/#684: every card now opens its OWN detail, matching iOS. The Stress card -> Stress;
                    // the overnight vitals (HRV / Resting HR / Respiratory / SpO₂ / Skin Temp) + Fitness age /
                    // Vitality / Steps / Calories -> each metric's focused trend (vital_detail/<key>, the iOS
                    // metricDetail twin); Sleep -> Sleep; Hydration -> Hydration. Whole row is the button.
                    onClick = dashboardCardDestination(
                        card = card,
                        onOpenStress = onOpenStress,
                        onOpenMetric = onOpenMetric,
                        onOpenSleep = onOpenSleep,
                        onOpenHydration = onOpenHydration,
                        onOpenCoupled = onOpenCoupled,
                        onOpenCoach = { showCoachLauncher = true },
                    ),
                )
            }
        }
    }
}

/**
 * #today-hosted-cards render: the Trends/Sleep cards hosted in Today, in arranged order. Each case renders
 * the SAME card its home tab uses (a mirror, not a copy) so the two never diverge. P0 hosts only Sleep
 * marks; its logging callback mirrors the Sleep tab's exactly (external log + metric-series upsert +
 * confirmation toast). Renders nothing when [cards] is empty. Twin of the iOS `hostedCardsSection`.
 */
@Composable
internal fun HostedCardsSection(
    cards: List<HostedCard>,
    days: List<DailyMetric>,
    viewModel: AppViewModel,
    // Passed in rather than read here: Today already resolved it once for its own tiles, and reading
    // SharedPreferences per hosted card per recomposition would put a synchronous file read on the
    // composition path of a screen that recomposes often.
    effortScale: EffortScale,
    onOpenStress: () -> Unit,
    onOpenSleep: () -> Unit,
    onOpenMetric: (String) -> Unit,
) {
    if (cards.isEmpty()) return
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    // #today-hosted-cards: the SleepModel-backed hosted sleep cards (Stages vs typical today; more to
    // follow). Build the shared model ONCE, and only when at least one such card is actually hosted, so a
    // Today hosting none pays no cost. Same inputs + builder as the Sleep tab (buildHostedSleepModel), so
    // hosted numbers match the Sleep tab. Reused by every model-backed card. Twin of the iOS hostedSleepModel.
    val modelBackedHosted = setOf(HostedCard.STAGES_VS_TYPICAL, HostedCard.NIGHT_DETAIL, HostedCard.SLEEP_DEBT, HostedCard.STAGES, HostedCard.HOURS_VS_NEEDED, HostedCard.CONSISTENCY)
    val needsSleepModel = cards.any { it in modelBackedHosted }
    var hostedSleepModel by remember { mutableStateOf<SleepModel?>(null) }
    LaunchedEffect(needsSleepModel, days, viewModel.activeStrapId) {
        // OFF the main thread: a LaunchedEffect body runs on it, and this walks the night's stages.
        hostedSleepModel = if (needsSleepModel) {
            withContext(Dispatchers.Default) {
                buildHostedSleepModel(viewModel.repo, viewModel.activeStrapId, days)
            }
        } else {
            null
        }
    }
    // Today's stress curve, loaded only when the card is actually hosted — the same "hosting none pays
    // nothing" rule the sleep model above follows. Routed through the SAME gated producer the stress
    // widget publishes from, so an unchanged day costs one indexed COUNT. The foreground card passes
    // the user's selected lens; background widget callers deliberately keep the cheaper default lens.
    val needsStressCurve = cards.contains(HostedCard.STRESS_TODAY)
    var stressCurve by remember { mutableStateOf<List<StressPoint>>(emptyList()) }
    var stressActivityMaskedHours by remember { mutableStateOf(0) }
    // SEEDED from the curve already on disk, so an app update does not show "Calibrating" for a day it
    // has already scored. `stressCurve` starts empty on a cold process, and the card reads an empty
    // curve as an unscored day, which is honest for a genuinely unscored one and wrong the moment the
    // app is merely restarted. The first compute usually fills it, but not always in time: the strap id
    // it needs comes from the source coordinator and is blank for a moment after launch, and a blank id
    // makes the producer answer null, which by contract means "say nothing" and leaves the card empty
    // until the next pass.
    //
    // The widget snapshot is today's default-lens curve. It is a valid cold-start seed only while the
    // personal lens is OFF; using it while opted in recreates #2430 until the foreground pass finishes,
    // or indefinitely if no active strap id arrives. Read once, off the main thread, and only while
    // nothing better has arrived, so a compute that already landed is never overwritten by a stale copy.
    LaunchedEffect(Unit) {
        if (stressCurve.isNotEmpty()) return@LaunchedEffect
        if (NoopPrefs.stressPersonalBaseline(context)) return@LaunchedEffect
        val banked = withContext(Dispatchers.IO) {
            runCatching { WidgetSnapshotStore.load(context).stressSeries }.getOrDefault(emptyList())
        }
        if (banked.isNotEmpty() && stressCurve.isEmpty()) stressCurve = banked
    }
    // #2144: this used to score ONCE, when these keys last moved, and none of them tracks incoming
    // heart rate — `days` is the daily rows, not the intraday samples the curve is built from. So a
    // card left open held whatever it scored then, while the Stress screen scores when you open it,
    // and the two drifted apart by however long sat between the two triggers. A reporter saw 1pm here
    // against 2pm there at twenty past four. This asks again on the producer's shared cadence; the
    // foreground lens is passed below so Today's curve also matches Stress detail when personal mode is on.
    val stressLifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(needsStressCurve, days, viewModel.activeStrapId, stressLifecycleOwner) {
        if (!needsStressCurve) {
            stressCurve = emptyList()
            stressActivityMaskedHours = 0
            return@LaunchedEffect
        }
        // Gated on STARTED, the same reason HealthScreen's live-HR tick is: a LaunchedEffect is tied to
        // the composition and not to the lifecycle, so an ungated loop here would go on scoring a day of
        // heart-rate rows every fifteen minutes for as long as the composition survived in the
        // background. The service is already doing that work on this exact cadence while backgrounded,
        // which is the point of it, so the card doing it too would be a second pass that nothing is on
        // screen to read. Resuming re-enters the block and scores immediately, so coming back to the app
        // shows a current curve rather than waiting out an interval.
        stressLifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                // A null is "nothing to say about stress right now" (no device to read), which the
                // producer documents as keep-what-you-had rather than "today scored nothing". Holding
                // the last curve matters more here than for a single pass: blanking the card on one bad
                // tick would be a visible flicker on a screen that is sitting open.
                StressWidgetProducer.todayCurve(
                    viewModel.repo,
                    viewModel.activeStrapId,
                    personalBaseline = NoopPrefs.stressPersonalBaseline(context),
                )
                    ?.let {
                        stressCurve = it.points
                        stressActivityMaskedHours = it.activityMaskedHours
                    }
                delay(StressWidgetProducer.RESCORE_INTERVAL_MS)
            }
        }
    }
    // Turning the card's own destination into the callback that reaches it. The mapping itself lives
    // on `HostedCard` so a test can assert it; this is only the wiring, which cannot be tested and does
    // not need to be.
    fun opener(card: HostedCard): (() -> Unit)? = when (val d = card.destination) {
        HostedDestination.None -> null
        HostedDestination.Sleep -> onOpenSleep
        HostedDestination.Stress -> onOpenStress
        is HostedDestination.Metric -> ({ onOpenMetric(d.key) })
    }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap)) {
        cards.forEach { card ->
            val open = opener(card)
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    // Clipped BEFORE the click. `NoopCard` clips itself, but the ripple draws on this
                    // wrapper, so without matching the shape here it would wash square corners over a
                    // rounded card. `Metrics.cardRadius` is the right figure: the 26dp liquid-hero surface
                    // `ChartCard` can wear is hero-only, and none of these opt into it.
                    //
                    // This used to read "because every hosted card renders through NoopCard", and that was
                    // the bug (#2109). Six of them open with a bare section header instead, and the clip
                    // was cutting its first glyph. The shape is asked for per card now.
                    .clip(
                        // #2109: shaped from the card's own opening, not assumed. A card that FILLS this
                        // slot wants the full radius. A card that opens with a bare section header does
                        // not: its first pixel is heading text at the top-left, where an 18dp corner cuts
                        // hardest at y=0, and the radius clipped the overline's first glyph ("LAST NIGHT"
                        // read as "AST NIGHT"). Square the TOP corners for those and keep the bottom
                        // rounded, because the slot's bottom edge IS the inner card's bottom edge and a
                        // square ripple there would wash its corners, which is the defect the clip was
                        // added for in the first place.
                        if (card.leadsWithSectionHeader) {
                            RoundedCornerShape(
                                topStart = 0.dp, topEnd = 0.dp,
                                bottomStart = Metrics.cardRadius, bottomEnd = Metrics.cardRadius,
                            )
                        } else {
                            RoundedCornerShape(Metrics.cardRadius)
                        }
                    )
                    .then(if (open != null) Modifier.clickable(onClick = open) else Modifier),
            ) {
            when (card) {
                HostedCard.STRESS_TODAY -> StressTodayCard(stressCurve, stressActivityMaskedHours)
                // The Trends-origin trends. `resolveMetric` walks the `days` already in hand, so these
                // need no model build and no gate, unlike the sleep and stress cards above.
                HostedCard.TREND_HRV, HostedCard.TREND_RESTING_HR, HostedCard.TREND_EFFORT ->
                    TrendHostCard(card, days, effortScale)
                HostedCard.SLEEP_MARKS -> com.noop.ui.forge.ForgeSleepMarkCard(viewModel)
                // #today-hosted-cards P1: the hours-asleep trend, built pure from `days` (no nap/debt) so
                // it matches the Sleep tab's hours chart. The card composable lives in SleepScreen.kt
                // (internal) where its ChartCard/BarChart siblings are in-file.
                HostedCard.ASLEEP_DURATION -> {
                    val (hours, dates) = sleepDurationTrend(days)
                    AsleepDurationHostCard(hours = hours, dates = dates)
                }
                // #today-hosted-cards: last night's stages vs the wearer's personal per-stage means, rendered
                // from the SAME shared SleepModel the Sleep tab uses (mirror, not copy). Until the async build
                // lands — or on a device with no stage data — the model is null and the slot renders nothing
                // this frame, matching how the Sleep tab guards the section on a null model.
                HostedCard.STAGES_VS_TYPICAL -> hostedSleepModel?.let { StagesVsTypicalHostCard(it) }
                // #today-hosted-cards: the Night-detail metric grid, rendered from the SAME shared SleepModel
                // the Sleep tab uses (mirror, not copy). Null until the async build lands / no stage data —
                // the slot renders nothing this frame, matching the Sleep tab's null-model guard.
                HostedCard.NIGHT_DETAIL -> hostedSleepModel?.let { NightDetailHostCard(it) }
                // #today-hosted-cards: the Sleep-debt ledger, rendered from the SAME shared SleepModel the
                // Sleep tab uses (mirror, not copy). Null until the async build lands / no stage data — the
                // slot renders nothing this frame, matching the Sleep tab's null-model guard.
                HostedCard.SLEEP_DEBT -> hostedSleepModel?.let { SleepDebtLedgerHostCard(it) }
                // #today-hosted-cards: the READ-ONLY latest-night stage chart + breakdown, rendered from the
                // SAME shared SleepModel the Sleep tab uses (mirror, not copy) — none of the hero's nav/edit/
                // nap interaction. Null until the async build lands / no stage data — the slot renders nothing
                // this frame, matching the Sleep tab's null-model guard.
                // Fork: the stage chart lives in the Forge Sleep breakdown, which reads the core's night; the
                // classic hosted copy needed the hypnogram renderers E-3f removed, so it draws nothing here.
                HostedCard.STAGES -> Unit
                // #today-hosted-cards: the single hours-vs-need % metric, rendered from the SAME shared
                // SleepModel the Sleep tab uses (mirror, not copy) via the existing standalone
                // HoursVsNeededCard. Null until the async build lands / no stage data — the slot renders
                // nothing this frame, matching the Sleep tab's null-model guard.
                HostedCard.HOURS_VS_NEEDED -> hostedSleepModel?.let { HoursVsNeededCard(it) }
                // #today-hosted-cards: the single sleep-consistency % metric, rendered from the SAME shared
                // SleepModel the Sleep tab uses (mirror, not copy) via the simple standalone
                // ConsistencyHostCard. Null until the async build lands / no stage data — the slot renders
                // nothing this frame, matching the Sleep tab's null-model guard.
                HostedCard.CONSISTENCY -> hostedSleepModel?.let { ConsistencyHostCard(it) }
            }
            }
        }
    }
}

/**
 * One WHOOP "My Dashboard" metric row: a thin-line tinted icon tile, an UPPERCASE tracked label over a grey
 * baseline caption, the big white value + small unit, and a chevron, on the flat frosted card surface (no
 * glow), tokens only. Mirrors iOS pinnedCardRow. The whole row is the tap target: when [onClick] is set it
 * pushes that card's detail (the chevron is the hint), matching iOS (#706/#684).
 */
@Composable
private fun DashboardCardRow(
    card: DashboardCard,
    value: String,
    fraction: Double?,
    tint: Color,
    // #110: a per-card dynamic subtitle (currently the sleep row's source + night); null keeps the
    // card's static description.
    subtitleOverride: String? = null,
    onClick: (() -> Unit)? = null,
) {
    // A real number renders white; a placeholder (No Data, or the Stress calibrating state) renders dimmed.
    val hasValue = value != NO_DATA && value != STRESS_CALIBRATING
    val displayValue = localizedMetricValue(value)
    // iOS `cardLink` corner is 20 (a touch rounder than the app-wide 18dp card), with the SAME neutral
    // surfaceRaised fill + plain hairline the frosted neutral surface already draws.
    val rowShape = RoundedCornerShape(20.dp)
    // liquidPress: the tappable card settles inward on press (the iOS LiquidPressStyle feel). The SAME
    // interactionSource feeds the clickable and the press modifier, so it responds to the actual touch.
    // It is applied OUTSIDE the frosted surface so the whole card (surface + content) scales/dims as one.
    val interaction = remember { MutableInteractionSource() }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (onClick != null) it.liquidPress(interaction) else it }
            .clip(rowShape)
            .frostedCardSurface(cornerRadius = 20.dp)
            .let {
                if (onClick != null) {
                    it.clickable(interactionSource = interaction, indication = null, onClick = onClick)
                } else it
            }
            // iOS row padding: 14h / 11v (tighter than the old 13/11 icon-box row).
            .padding(horizontal = 14.dp, vertical = 11.dp)
            .semantics { contentDescription = uiString(R.string.l10n_today_screen_card_title_value_e4bb76b3, uiString(card.titleRes), displayValue) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // A 30dp mini GlowRing filled to this card's fraction, tinted its domain colour — the
        // "small ring per icon" iOS shows. Static (GlowRing starts empty, springs to target once).
        // Ring or vessel per the Today gauge preference. Static either way: the many small gauges
        // cost nothing per frame, which is what the vessel's animated=false bought here too.
        val cardGaugeCtx = LocalContext.current
        if (remember { NoopPrefs.todayRingGauges(cardGaugeCtx) }) {
            GlowRing(
                fraction = (fraction ?: 0.0).coerceIn(0.0, 1.0).toFloat(),
                value = 0.0,
                color = tint,
                diameter = 30.dp,
                lineWidth = 3.dp,
                showsLabel = false,
            )
        } else {
            LiquidVessel(
                value = fraction,
                tint = tint,
                animated = false,
                modifier = Modifier.size(30.dp),
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            // iOS: overline 11 / +1.0 tracking, textPrimary.
            Text(
                uiString(card.titleRes).uppercase(),
                style = NoopType.overline.copy(fontSize = 11.sp, letterSpacing = 1.0.sp),
                color = Palette.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                subtitleOverride ?: uiString(card.subtitleRes),
                style = NoopType.caption,
                color = Palette.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        // iOS value = number(17), textPrimary.
        Text(
            displayValue,
            style = NoopType.number(17f),
            color = if (hasValue) Palette.textPrimary else Palette.textTertiary,
            maxLines = 1,
        )
        // iOS chevron = 12.
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(12.dp),
        )
    }
}

/** One iOS `vitalRow`: a 26dp mini liquid RING filled to [fraction] in [tint], the label (subhead,
 *  secondary), a spacer, and the value (number 15, primary). Replaces the old flat-Material-icon row. */
@Composable
private fun HeroVitalRow(
    label: String,
    value: String,
    tint: Color,
    fraction: Double?,
    // The metric-detail key this row opens, from `dashboardCardMetricKey` so the row and its dashboard-card
    // twin cannot drift onto different trends for the same vital. NULL means the row simply does not
    // navigate: it loses the tap AND the chevron together, which is the honest degradation. An earlier
    // draft asserted the key was present, which would have turned a missing destination into a crash on
    // tap - a worse outcome than a row that quietly does not move.
    metricKey: String? = null,
    onOpenMetric: (String) -> Unit = {},
) {
    val onClick: (() -> Unit)? = metricKey?.let { key -> { onOpenMetric(key) } }
    val hasValue = value != NO_DATA
    val displayValue = localizedMetricValue(value)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable { onClick() } else Modifier)
            .semantics { contentDescription = uiString(R.string.l10n_today_screen_label_value_b781d590, label, displayValue) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
    ) {
        // Ring or vessel per the Today gauge preference; both are static here.
        val gaugeCtx = LocalContext.current
        if (remember { NoopPrefs.todayRingGauges(gaugeCtx) }) {
            GlowRing(
                fraction = (fraction ?: 0.0).coerceIn(0.0, 1.0).toFloat(),
                value = 0.0,
                color = tint,
                diameter = 26.dp,
                lineWidth = 2.6.dp,
                showsLabel = false,
            )
        } else {
            LiquidVessel(
                value = fraction,
                tint = tint,
                animated = false,
                modifier = Modifier.size(26.dp),
            )
        }
        Text(label, style = NoopType.subhead, color = Palette.textSecondary, modifier = Modifier.weight(1f))
        Text(
            displayValue,
            style = NoopType.number(15f),
            color = if (hasValue) Palette.textPrimary else Palette.textTertiary,
        )
        // Only when the row actually goes somewhere. `dashboardCardDestination` states the rule this
        // follows - every card resolves to a destination, so the chevron is always honest (#706/#684) -
        // and the inverse is what was wrong here: three rows that go somewhere and did not say so.
        if (onClick != null) {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = Palette.textTertiary,
                modifier = Modifier.size(Metrics.iconSmall),
            )
        }
    }
}

/** Shared Today section edit affordance. The 48dp box keeps the whole control easy to tap while its
 *  visible content stays pinned to the overline instead of centring against a two-line header. */
@Composable
private fun TodayEditAction(
    contentDescription: String,
    onClick: () -> Unit,
    contentAlignment: Alignment = Alignment.Center,
) {
    Box(
        modifier = Modifier
            .height(48.dp)
            .clickable(onClick = onClick)
            .semantics { this.contentDescription = contentDescription }
            .padding(horizontal = Metrics.space12),
    ) {
        Row(
            modifier = Modifier.align(contentAlignment),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Filled.Tune,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(Metrics.space4))
            Text(
                uiString(R.string.l10n_today_screen_edit_5301648d).uppercase(Locale.getDefault()),
                style = NoopType.overline.copy(letterSpacing = 0.4.sp),
                color = Palette.accent,
            )
        }
    }
}

/** The destination callback a dashboard card opens when tapped. Mirrors the iOS dashboardCardRow switch:
 *  Stress -> Stress; Sleep -> Sleep; Hydration -> Hydration; Coupled -> the WHOOP-style day screen; every
 *  metric/vital card -> its OWN focused trend (`vital_detail/<key>` via [onOpenMetric]), matching the iOS
 *  `metricDetail(key)`. Every card resolves to a destination, so the chevron is always honest (#706/#684). */
private fun dashboardCardDestination(
    card: DashboardCard,
    onOpenStress: () -> Unit,
    onOpenMetric: (String) -> Unit,
    onOpenSleep: () -> Unit,
    onOpenHydration: () -> Unit,
    onOpenCoupled: () -> Unit,
    // #1862: Coach is the one card that opens a SHEET rather than a destination, so its "destination" is
    // a callback that shows the launcher. Kept in this same resolver so every card still resolves to
    // exactly one tap action and the chevron stays honest.
    onOpenCoach: () -> Unit,
): () -> Unit = when (card) {
    DashboardCard.STRESS -> onOpenStress
    DashboardCard.SLEEP -> onOpenSleep
    DashboardCard.HYDRATION -> onOpenHydration
    // The Coupled view card (#43) taps through to the full WHOOP-style day screen.
    DashboardCard.COUPLED -> onOpenCoupled
    DashboardCard.COACH -> onOpenCoach
    // Every overnight vital + Fitness age / Vitality / Steps / Calories opens its own metric-detail trend.
    else -> {
        val key = dashboardCardMetricKey(card)
        if (key != null) ({ onOpenMetric(key) }) else ({})
    }
}

/**
 * A dashboard card's mini-ring fill fraction (0..1), or null for an empty (no-reading) ring. Mirrors the
 * iOS `liquidCard` `frac:` argument exactly, per card:
 *   Stress = stress/3 · Fitness age = 0.5 (fixed) · Vitality = vitality/100 · HRV = avgHrv/120 ·
 *   Resting HR = restingHr/100 · Respiratory = respRate/24 · Steps = steps/10000 · Sleep = totalSleepMin/480 ·
 *   Coupled = 0.6 (fixed) · Blood oxygen / Skin temp / Calories / Hydration = null (empty, not half-full).
 * The three overnight vitals (HRV / Resting HR / Respiratory) read PER-FIELD today-first with the
 * recovery-INDEPENDENT [vitalsDay] carry, matching the row VALUE, so the ring fill and the number agree
 * (and a recovery-nulled night keeps its OWN preserved vitals). Sleep keeps the recovery-gated
 * `carriedDay ?: day` carry.
 */
private fun dashboardCardFraction(
    card: DashboardCard,
    stepsAverage30: Double?,
    day: DailyMetric?,
    carriedDay: DailyMetric?,
    vitalsDay: DailyMetric?,
    respDay: DailyMetric?,
    stress: Double?,
    fitnessAge: Double?,
    vo2max: Double?,
    vitality: Double?,
    importedStepsForDay: Int?,
    estimatedStepsForDay: Int?,
): Double? {
    fun over(v: Double?, ceiling: Double): Double? = v?.let { (it / ceiling).coerceIn(0.0, 1.0) }
    val vd = carriedDay ?: day
    return when (card) {
        DashboardCard.STRESS -> over(stress, 3.0)
        DashboardCard.FITNESS_AGE -> if (fitnessAge != null) 0.5 else null
        DashboardCard.VO2MAX -> if (vo2max != null) 0.5 else null
        DashboardCard.VITALITY -> over(vitality, 100.0)
        DashboardCard.HRV -> over(day?.avgHrv ?: vitalsDay?.avgHrv, 120.0)
        DashboardCard.RESTING_HR -> over((day?.restingHr ?: vitalsDay?.restingHr)?.toDouble(), 100.0)
        // PER-FIELD carry: today → the STALENESS-BOUNDED prior night (`respDay` = lastRespRow). The
        // unbounded `vitalsDay?.respRateBpm` is dropped on purpose — it picks the newest row with ANY
        // vital regardless of age and printed one CSV import's 15.6 as today's rate for a fortnight
        // (#1331). Byte-twin of the Swift `lastRespDay` card.
        DashboardCard.RESPIRATORY -> over(day?.respRateBpm ?: respDay?.respRateBpm, 24.0)
        DashboardCard.STEPS -> {
            val steps = (day?.steps ?: importedStepsForDay ?: estimatedStepsForDay)?.toDouble()
            over(steps, 10000.0)
        }
        DashboardCard.SLEEP -> over(vd?.totalSleepMin, 480.0)
        DashboardCard.STEPS_AVERAGE_30 -> over(stepsAverage30, 10000.0)
        DashboardCard.COUPLED -> 0.6
        DashboardCard.COACH -> 0.5
        // Not wired to a real read yet — an EMPTY ring (not half-full) so it doesn't imply a reading.
        DashboardCard.BLOOD_OXYGEN, DashboardCard.SKIN_TEMP, DashboardCard.CALORIES,
        DashboardCard.HYDRATION -> null
    }
}

/** The `vital_detail/<key>` key a metric/vital card opens, or null when the card has its OWN dedicated
 *  screen (Stress / Sleep / Hydration / Coupled) rather than a metric-detail trend. Mirrors the iOS
 *  `liquidCard` switch, where every metric/vital card opens `metricDetail(key)` (its own focused trend),
 *  NOT the shared Health hub (2026-07-03). Keys are the Android VitalDetailScreen keys. */
internal fun dashboardCardMetricKey(card: DashboardCard): String? = when (card) {
    DashboardCard.HRV -> "hrv"
    DashboardCard.RESTING_HR -> "rhr"
    DashboardCard.RESPIRATORY -> "resp"
    DashboardCard.BLOOD_OXYGEN -> "spo2"
    DashboardCard.SKIN_TEMP -> "skin"
    DashboardCard.FITNESS_AGE -> "fitness_age"
    DashboardCard.VO2MAX -> "vo2max_est"
    DashboardCard.VITALITY -> "vitality"
    DashboardCard.STEPS, DashboardCard.STEPS_AVERAGE_30 -> "steps_est"
    DashboardCard.CALORIES -> "active_kcal"
    // These carry their own full screen, not a per-metric trend.
    DashboardCard.STRESS, DashboardCard.SLEEP, DashboardCard.HYDRATION, DashboardCard.COUPLED,
    // #1862: a launcher row, not a metric — no explorer key.
    DashboardCard.COACH -> null
}

/** A dashboard card's WHOOP-token tint (icon + accent). Score cards take their domain colour; vitals take
 *  their biometric hue; everything else the blue accent. No gold (WHOOP), tokens only. Mirrors iOS
 *  dashboardTint. This drives the mini liquid ring's tint on each row, so it follows the iOS `liquidCard`
 *  per-card tints exactly: Stress=accent, Fitness age=charge-green, Vitality=liquid-purple, HRV=cyan,
 *  Resting HR=rose, Respiratory=accent, Steps=cyan, Sleep=rest, Coupled=charge. */
private fun dashboardCardTint(card: DashboardCard): Color = when (card) {
    // iOS `liquidCard`: stress → StrandPalette.accent (blue), not the Effort orange.
    DashboardCard.STRESS -> Palette.accent
    DashboardCard.FITNESS_AGE -> Palette.chargeColor
    DashboardCard.VO2MAX -> Palette.chargeColor
    // iOS vitality → liquidPurple (#9b7bff).
    DashboardCard.VITALITY -> LIQUID_PURPLE
    // iOS hrv → metricCyan (this theme's metricPurple is a blue, cyan reads as the iOS HRV teal).
    DashboardCard.HRV -> Palette.metricCyan
    DashboardCard.RESTING_HR -> Palette.metricRose
    DashboardCard.RESPIRATORY -> Palette.accent
    DashboardCard.BLOOD_OXYGEN -> Palette.metricCyan
    DashboardCard.SKIN_TEMP -> Palette.metricAmber
    DashboardCard.SLEEP -> Palette.restColor
    DashboardCard.STEPS, DashboardCard.STEPS_AVERAGE_30 -> Palette.metricCyan
    DashboardCard.CALORIES -> Palette.metricAmber
    DashboardCard.HYDRATION -> Palette.metricCyan
    DashboardCard.COUPLED -> Palette.chargeColor
    DashboardCard.COACH -> Palette.accent
}

/**
 * Resolve a dashboard card's CURRENT display value from the values Today already loads, with its unit
 * suffix appended. Returns a dash when the value isn't available yet, never a fabricated number. Reuses
 * the SAME reads the rest of Today uses (displayMetric vitals, the pinned Stress / Fitness age / Vitality,
 * steps, calories, sleep duration). Mirrors iOS dashboardValue.
 *
 * The three overnight vitals (HRV / Resting HR / Respiratory) read PER-FIELD today-first with the
 * recovery-INDEPENDENT [vitalsDay] carry (#543 follow-up), so a night whose recovery was nulled post-update
 * still shows its OWN preserved value rather than an older recovery-scored day's (the tile-vs-card fix).
 * SpO₂ / Skin Temp / Sleep keep the recovery-gated `carriedDay ?: day` carry. Steps / Calories stay on
 * today's own row (they accrue through the day, never a carry). Stress / Fitness age / Vitality come from
 * their own resolved loads.
 */
private fun dashboardCardValue(
    card: DashboardCard,
    stepsAverage30: Double?,
    day: DailyMetric?,
    carriedDay: DailyMetric?,
    vitalsDay: DailyMetric?,
    spo2Day: DailyMetric?,
    skinTempDay: DailyMetric?,
    hrvDay: DailyMetric?,
    rhrDay: DailyMetric?,
    respDay: DailyMetric?,
    stress: Double?,
    fitnessAge: Double?,
    vo2max: Double?,
    vitality: Double?,
    importedStepsForDay: Int?,
    estimatedStepsForDay: Int?,
    caloriesForDay: Double?,
    hydrationTotalMl: Double,
    hydrationGoalMl: Int,
    spo2CandidateByDay: Map<String, Double> = emptyMap(),
    fahrenheit: Boolean = false,
    skinTempPreferred: com.noop.analytics.SkinTempDisplay.Kind =
        com.noop.analytics.SkinTempDisplay.Kind.ABSOLUTE,
): String {
    fun withUnit(s: String): String =
        if (s == NO_DATA) NO_DATA else if (card.unit.isEmpty()) s else "$s ${card.unit}"

    // SpO₂ / Skin Temp / Sleep carry over from the last scored night; today's accruing totals do not.
    val vd = carriedDay ?: day

    return when (card) {
        // #1842: PER-FIELD carry, the fourth of these. `lastVitalsRow`'s predicate is an OR across
        // HRV / resting-HR / respiratory, so it can select a row that has respRateBpm and a NULL avgHrv —
        // and the card then reads null and prints "No data" while the tile, carrying a different row,
        // shows a value. That is the same failure `lastSpo2Row` and `lastSkinTempRow` were split out to
        // fix ("can select a row whose spo2Pct is null … while an OLDER row has a real reading"); HRV and
        // resting HR were the two left on the shared predicate.
        //
        // Deliberately NOT the recovery-scored carry: the comment on `lastVitalsDay` is explicit that
        // vitals must not fall back to an older recovery-scored day.
        DashboardCard.HRV ->
            withUnit((day?.avgHrv ?: hrvDay?.avgHrv)?.let { it.roundToInt().toString() } ?: NO_DATA)
        DashboardCard.RESTING_HR ->
            withUnit((day?.restingHr ?: rhrDay?.restingHr)?.toString() ?: NO_DATA)
        DashboardCard.RESPIRATORY ->
            // PER-FIELD carry: today → the STALENESS-BOUNDED `respDay` (lastRespRow). The unbounded
            // `vitalsDay?.respRateBpm` is dropped on purpose (see the gauge site + Swift `lastRespDay`):
            // it had no age bound and showed a fortnight-old imported 15.6 as today's rate (#1331). A gap
            // past the window now reads NO_DATA — the truthful answer when nobody measured.
            withUnit((day?.respRateBpm ?: respDay?.respRateBpm)?.let { String.format(Locale.getDefault(), "%.1f", it) } ?: NO_DATA)
        DashboardCard.BLOOD_OXYGEN ->
            // PER-FIELD carry: the whole-row carries (vd) land on rows whose spo2Pct is null (the engine
            // writes spo2Pct = null on computed rows), so fall through to the last row that HAS one.
            // #103/queue-11a: when no calibrated spo2Pct exists, fall back to the spo2_candidate strap
            // estimate (WHOOP @82 or Oura ceiling@100, from metricSeries) when the experimental display
            // toggle is ON. Labelled "estimate" in the Health vitals screen; here it just fills the card
            // so it's not blank.
            (vd?.spo2Pct ?: spo2Day?.spo2Pct)?.let { String.format(Locale.getDefault(), "%.0f%%", it) }
                ?: (vd?.day ?: day?.day)?.let { spo2CandidateByDay[it] }?.let { String.format(Locale.getDefault(), "%.0f%%", it) }
                ?: NO_DATA
            DashboardCard.SKIN_TEMP -> {
                // #1844: LEAD WITH THE ABSOLUTE when the night measured one, the rule the Health tile has
                // used since #1665 — a deviation with no anchor cannot be read ("+0.9" is a fever or a warm
                // bedroom). Both numbers come off the SAME row so the scale shown is that night's own.
                // #622 still applies to the fallback: a deviation keeps its Δ unit so "−0.1 °C" is never
                // read as a wrist temperature.
                // Same resolver as the Key Metrics tile, so the two can never disagree — the claim the iOS
                // twin already made in a comment and that now actually holds on both platforms. It also puts
                // today's own reading FIRST: `vd` is `carriedDay ?: day`, so a live carry hid a temperature
                // measured today, which `todaysOwnReadingWinsOverEitherCarry` has asserted all along.
                resolveSkinTempReading(day, carriedDay, skinTempDay, skinTempPreferred)
                    ?.let { com.noop.analytics.SkinTempDisplay.formatReading(it, fahrenheit = fahrenheit) }
                    ?: NO_DATA
            }
        DashboardCard.SLEEP -> todaySleepValue(vd)
        DashboardCard.STEPS -> {
            val real = day?.steps?.let { intStringGrouped(it.toDouble()) }
                ?: importedStepsForDay?.let { intStringGrouped(it.toDouble()) }
            val est = estimatedStepsForDay?.let { intStringGrouped(it.toDouble()) }
            real ?: est ?: NO_DATA
        }
        DashboardCard.STEPS_AVERAGE_30 -> stepsAverage30?.let { intStringGrouped(it) } ?: NO_DATA
        DashboardCard.CALORIES ->
            withUnit(caloriesForDay?.let { intStringGrouped(it) } ?: NO_DATA)
        DashboardCard.STRESS ->
            // #706/#684: Stress is baseline-relative, so until the strap has banked enough worn nights to
            // seed the 30-day RHR/HRV baseline StressScreen reads, the front card has no number to show. The
            // old `?: NO_DATA` rendered a bare dash that read like a broken card; show the honest calibrating
            // state instead, matching the owner's reply on #706 and the StressScreen empty/calibrating copy.
            stress?.let { it.roundToInt().toString() } ?: STRESS_CALIBRATING
        DashboardCard.FITNESS_AGE ->
            // Carries the bound symbol the Health hero uses (#2173), so a floored reading does not read
            // as an exact one here and as a bounded one there.
            withUnit(fitnessAge?.let { "${fitnessAgeBoundSymbol(it)}${it.roundToInt()}" } ?: NO_DATA)
        DashboardCard.VO2MAX ->
            vo2max?.let { it.roundToInt().toString() } ?: NO_DATA
        DashboardCard.VITALITY ->
            vitality?.let { it.roundToInt().toString() } ?: NO_DATA
        DashboardCard.HYDRATION ->
            // "<total> / <goal> L" in litres to 1 dp, e.g. "1.2 / 3.2 L". Always shows a value (a fresh
            // day reads "0.0 / 3.2 L"), since the goal is always derivable from the profile.
            String.format(
                Locale.getDefault(), "%.1f / %.1f L",
                hydrationTotalMl / 1000.0, hydrationGoalMl / 1000.0,
            )
        DashboardCard.COUPLED ->
            // A tap-through row with no metric value of its own, the row shows just the chevron. An empty
            // string (not NO_DATA) renders no number and leaves it un-dimmed. Mirrors iOS dashboardValue.
            ""
        DashboardCard.COACH ->
            // #1862: likewise a launcher row. Empty rather than NO_DATA for the same reason — there is no
            // missing measurement here, there is no measurement at all.
            ""
    }
}

/** iOS `lastNightLine` — "Last night · <date>" where <date> is yesterday in "d MMM" form. */
@Composable
private fun heroVitalsLastNightLine(): String {
    val d = LocalDate.now().minusDays(1)
    return uiString(R.string.today_last_night_date, d.format(DateTimeFormatter.ofPattern("d MMM", Locale.getDefault())))
}

@Composable
private fun DisplayText.localized(): String = when (this) {
    is DisplayText.Resource -> uiString(id, *args.toTypedArray())
    is DisplayText.Dynamic -> value
}

@Composable
private fun localizedMetricValue(value: String): String = when (value) {
    NO_DATA -> uiString(R.string.today_no_data)
    STRESS_CALIBRATING -> uiString(R.string.today_calibrating)
    else -> value
}

/**
 * Whether the Recovery Vitals card should explain its blanks with the HR-only note (#1801).
 *
 * Reads the flag from the SAME row the shown vitals came from. [carriedFromVitals] already decides that
 * for the date caption, so reusing it keeps the note and the numbers describing ONE night;
 * `day?.sleepHrOnly ?: vitalsDay?.sleepHrOnly` would instead fall through whenever today's flag is merely
 * unknown — every row scored before v36 — and caption today's blanks with a different night's staging.
 *
 * Gated on something actually being blank so a night that kept its vitals stays quiet, and on `== true`
 * so the tri-state reads correctly: null means "not known", which earns no claim either way.
 */
internal fun showsHrOnlyNote(
    day: DailyMetric?,
    vitalsDay: DailyMetric?,
    carriedFromVitals: Boolean,
    hrv: Double?,
    rhr: Int?,
): Boolean {
    val source = if (carriedFromVitals) vitalsDay else day
    return source?.sleepHrOnly == true && (hrv == null || rhr == null)
}

/** #110: the sleep row's value is `totalSleepMin` — WHOOP's imported TST, which can legitimately differ
 *  from the Sleep tab's on-device re-staged night (WHOOP CSV + Apple Health both imported). Label the row
 *  with its source (the SAME `daySourceBadge` winner the Sleep tab's `MainSleepFooter` uses) + "last
 *  night" — `YourCardsSection` renders at offset 0 only, so the row IS last night — so a WHOOP figure is
 *  never silently shown as "last night" with no provenance. null → the card keeps its static subtitle
 *  (not the sleep card, or no banked sleep). Twin of iOS `TodayView.sleepSourceSubtitle`; the source
 *  mechanism differs per platform (Android keys on the day's session source, iOS on `importedSleep`),
 *  exactly as the two Sleep-tab badges already do, so the label — not the wiring — is what stays in parity. */
@Composable
private fun sleepSourceSubtitle(card: DashboardCard, day: DailyMetric?): String? {
    if (card != DashboardCard.SLEEP) return null
    val d = day ?: return null
    if (d.totalSleepMin == null) return null
    val source = daySourceBadge(d.deviceId).first
    return uiString(R.string.today_sleep_source_last_night, source)
}

/** "d MMM · HH:mm–HH:mm" (#157); start-only when the end isn't after the start (zero/unknown span). */
private fun workoutCaption(row: WorkoutRow): String {
    val date = workoutDateFmt.format(Instant.ofEpochSecond(row.startTs))
    val start = workoutTimeFmt.format(Instant.ofEpochSecond(row.startTs))
    return if (row.endTs > row.startTs) {
        "$date · $start - ${workoutTimeFmt.format(Instant.ofEpochSecond(row.endTs))}"
    } else {
        "$date · $start"
    }
}

private fun workoutDuration(row: WorkoutRow): String {
    val seconds = row.durationS ?: (row.endTs - row.startTs).coerceAtLeast(0L).toDouble()
    if (seconds <= 0.0) return NO_DATA
    val totalMinutes = (seconds / 60.0).roundToInt()
    return if (totalMinutes >= 60) {
        "${totalMinutes / 60}h ${totalMinutes % 60}m"
    } else {
        "${totalMinutes}m"
    }
}

// The Vitality ring purple (#9b7bff) — no exact Palette token in this theme, so a fixed brand literal
// matching the iOS liquid Today's `liquidPurple` (Color(.sRGB, red:0x9b, green:0x7b, blue:0xff)). Used by
// the mini "Your cards" ring so Vitality reads the same purple as iOS.
private val LIQUID_PURPLE: Color = Color(red = 0x9b / 255f, green = 0x7b / 255f, blue = 0xff / 255f, alpha = 1f)

/** Group-separated integer display from a Double (e.g. 12 345 steps), matching the Apple Health tiles. A
 *  file-internal twin of the private [intString] so the dashboard rows format steps/calories identically. */
private fun intStringGrouped(v: Double): String {
    val n = v.roundToInt()
    return if (kotlin.math.abs(n) >= 1000) String.format(Locale.getDefault(), "%,d", n) else "$n"
}

/**
 * The skin-temp reading a Today surface should LEAD with (#1844): the first of today / the recovery carry
 * / the per-field carry that holds EITHER number, resolved to absolute-or-deviation by
 * [com.noop.analytics.SkinTempDisplay.leadReading].
 *
 * Both numbers are read off the SAME row, so an absolute is never paired with another night's deviation.
 * Replaces `resolveSkinTempDevC`, which had no caller left once both Today surfaces moved onto
 * this one; its carry-order tests were repinned here rather than dropped.
 */
internal fun resolveSkinTempReading(
    d: DailyMetric?,
    carriedDay: DailyMetric?,
    skinTempCarryDay: DailyMetric?,
    prefer: com.noop.analytics.SkinTempDisplay.Kind = com.noop.analytics.SkinTempDisplay.Kind.ABSOLUTE,
): com.noop.analytics.SkinTempDisplay.Reading? =
    listOfNotNull(d, carriedDay, skinTempCarryDay)
        .firstOrNull { it.skinTempC != null || it.skinTempDevC != null }
        ?.let { com.noop.analytics.SkinTempDisplay.leadReading(it.skinTempC, it.skinTempDevC, prefer) }


private val workoutDateFmt: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM", Locale.getDefault()).withZone(ZoneId.systemDefault())

private val workoutTimeFmt: DateTimeFormatter =
    // Respect the device's 12-/24-hour locale (#337): "7:10 AM" where 12-hour is preferred, "19:10"
    // where 24-hour is, instead of forcing 24-hour on everyone.
    DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
        .withLocale(Locale.getDefault()).withZone(ZoneId.systemDefault())

private const val NO_DATA = "noop:no-data"
private const val STRESS_CALIBRATING = "noop:calibrating"

private fun todaySleepValue(d: DailyMetric?): String {
    val m = d?.totalSleepMin ?: return NO_DATA
    val total = m.roundToInt()
    return "${total / 60}h ${total % 60}m"
}

/** Fork: the Trends-origin hosted cards, drawn by Forge Trends' card from the shared core. */
@Composable
internal fun TrendHostCard(card: HostedCard, days: List<DailyMetric>, effortScale: EffortScale) {
    when (card) {
        HostedCard.TREND_HRV -> com.noop.ui.forge.ForgeHostedTrend(com.noop.core.CoreRead.Metric.Hrv)
        HostedCard.TREND_RESTING_HR -> com.noop.ui.forge.ForgeHostedTrend(com.noop.core.CoreRead.Metric.RestingHr)
        HostedCard.TREND_EFFORT -> com.noop.ui.forge.ForgeHostedTrend(com.noop.core.CoreRead.Metric.Effort)
        else -> Unit
    }
}
