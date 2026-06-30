package com.noop.ui

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Functions
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import android.app.DatePickerDialog
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.BaselineState
import com.noop.analytics.Baselines
import com.noop.analytics.BatteryEstimator
import com.noop.analytics.ChargeDriver
import com.noop.analytics.HydrationGoal
import com.noop.analytics.HydrationStore
import com.noop.analytics.ReadinessEngine
import com.noop.analytics.RecoveryDrivers
import com.noop.analytics.RecoveryScorer
import com.noop.analytics.RestScorer
import com.noop.analytics.ScoreConfidence
import com.noop.analytics.StepsEstimateEngine
import com.noop.analytics.StrainScorer
import com.noop.data.AppleDaily
import com.noop.data.DailyMetric
import com.noop.data.HrBucket
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ingest.HealthConnectImporter
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.chrono.IsoChronology
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeFormatterBuilder
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit
import java.util.Calendar
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Control Center — the home dashboard. A recovery ring + plain-English synthesis
 * hero, an illness banner when the watch fires, and a tile grid of the day's key
 * metrics — each tile carrying a 14-day sparkline. Ports the macOS TodayView
 * composition (Strand/Screens/TodayView.swift) with the same locked components.
 *
 * Sparkline series are built off the view model's `recentDays` (oldest → newest,
 * all from the my-whoop source). Missing current-day values render as explicit
 * "No Data" states instead of raw dashes, so old imports do not look like today.
 */

/** Stable Today info-card ids (the dismissed-flag suffix + the inbox `restorePayload`). Match the
 *  iOS card ids so an export/import round-trips. */
private const val CARD_SCORES_BUILDING = "scoresBuilding"
private const val CARD_NEW_HERE = "newHere"
private const val CARD_CALIBRATING = "calibratingBaseline"

/** Process-lifetime guard for the #605 dashboard auto-land. A top-level var = one value per LAUNCH, which
 *  survives BOTH a recomposition AND an Activity recreation / tab-away+restore. rememberSaveable only
 *  survived the save/restore, but a full screen rebuild still re-armed the one-shot and re-snapped the
 *  dashboard back onto the strap's start day (#739). Reset only happens on a genuine fresh process. */
private var todayDidAutoLandThisLaunch = false

/** #739: only auto-land (#605) when the newest banked day is within this many days of today. Past this, the
 *  data is stale enough that jumping the dashboard there on launch is more surprising than an empty today. */
private const val AUTO_LAND_MAX_DAYS_BACK = 14L

/**
 * The minimal, stable slice of the BLE [com.noop.ble.LiveState] the Today top-level body reads. Pulled out
 * so a per-second heart-rate tick — which the body does not display numerically — produces an EQUAL value
 * and skips recomposing the whole dashboard (the redesign's scroll-jank fix). `hrStreaming` collapses the
 * ticking bpm to "is a live stream present" (the only thing the recording light needs); all other fields
 * change at most every few seconds. A plain data class so [androidx.compose.runtime.derivedStateOf] can
 * structurally-compare successive snapshots and emit only on a real change.
 */
private data class TodayLiveSnapshot(
    val connected: Boolean,
    val hrStreaming: Boolean,
    val lastSyncAt: Long?,
    val backfilling: Boolean,
    val syncChunksThisSession: Int,
    val historySyncExperimental: Boolean,
    val batteryPct: Double?,
    /** True once a WHOOP 5/MG strap has been seen this session — picks the 5/MG rated-life fallback for the
     *  battery runtime estimate (#713). Changes at most once per connection, so it doesn't reintroduce the
     *  per-tick churn the snapshot exists to avoid. */
    val whoop5: Boolean,
    /** Charging hides the runtime estimate (no "X left" while topping up). Rare flips, snapshot-safe. */
    val charging: Boolean?,
)

@Composable
fun TodayScreen(
    viewModel: AppViewModel,
    onSupport: () -> Unit = {},
    onQuickActions: () -> Unit = {},
    updateStore: UpdateStore? = null,
    onOpenUpdates: () -> Unit = {},
    onOpenSettings: () -> Unit = {},
    onOpenHydration: () -> Unit = {},
    // #706/#684: the "Your cards" dashboard rows are tappable on iOS but only Hydration navigated on Android.
    // These push each card's detail (Stress card -> Stress; the overnight vitals + Fitness age / Vitality ->
    // Health; Sleep -> Sleep), matching the iOS pinnedCardRow destinations. Defaulted to no-ops so the call
    // site stays compiling; AppRoot binds them to nav.navigate(...) like onOpenHydration.
    onOpenStress: () -> Unit = {},
    onOpenHealth: () -> Unit = {},
    onOpenSleep: () -> Unit = {},
) {
    val today by viewModel.today.collectAsStateWithLifecycle()
    val alert by viewModel.healthAlert.collectAsStateWithLifecycle()
    val days by viewModel.recentDays.collectAsStateWithLifecycle()
    val live by viewModel.live.collectAsStateWithLifecycle()
    // PERF (#scroll-jank): the BLE live state ticks the heart rate roughly once a second. Reading the raw
    // `live` object directly in this top-level body would recompose the ENTIRE Today tree (rings, cards,
    // scene-positioning) on every bpm change — visible as scroll stutter on real devices. The body only
    // needs a handful of stable, slow-changing fields, and the live HR matters here only as "is a stream
    // present" (null↔non-null), never the bpm number. Funnel those through a `derivedStateOf` snapshot so a
    // 72→73 bpm tick produces an EQUAL snapshot and the body is NOT recomposed; it only recomposes when
    // connection / sync / battery / streaming-presence actually change. The live bpm number is rendered
    // elsewhere (HeartRateTrendCard), which scopes its own collection. Appearance-preserving.
    val liveSnap by remember {
        derivedStateOf {
            val s = live
            TodayLiveSnapshot(
                connected = s.connected,
                hrStreaming = s.heartRate != null,
                lastSyncAt = s.lastSyncAt,
                backfilling = s.backfilling,
                syncChunksThisSession = s.syncChunksThisSession,
                historySyncExperimental = s.historySyncExperimental,
                batteryPct = s.batteryPct,
                whoop5 = s.whoop5Detected,
                charging = s.charging,
            )
        }
    }
    var footer by remember { mutableStateOf(TodayFooterState()) }
    // rememberSaveable (not plain remember): the bottom-tab NavHost (AppRoot) navigates with
    // saveState/restoreState, which only restores rememberSaveable-backed state. With plain remember a
    // tab-away wiped the chosen day back to 0, so on return the dashboard "shifted" off the day the user was
    // looking at (#614 follow-up). Persisting it across the save/restore keeps the chosen day put. The
    // #605/#739 auto-land guard is a separate process-lifetime flag (todayDidAutoLandThisLaunch below).
    var selectedDayOffset by rememberSaveable { mutableIntStateOf(0) }
    // Anchor offset-0 to the LOGICAL day (rolls at 04:00 local), so between midnight and 4am "Today"
    // still resolves to the prior calendar day's banked row instead of an empty new-calendar-day row
    // that blanks the dashboard (#144). Past offsets count back from this anchor. Presentation-only.
    val todayDate = logicalDayNow()
    // #605/#739: the first time the app opens to a today with NOTHING banked, land the dashboard on the most
    // recent day that DOES have data instead of an empty graph (fresh install, or a strap mid-backfill whose
    // newest banked day is older than today). Two #739 fixes over the old version:
    //   - The trigger is "today has NO row at all" (today == null off resolveTodayRow), NOT "no HR samples".
    //     A metadata-only strap banks a recovery/sleep row for today with no streamed HR; the old hrBuckets
    //     test treated that as empty and snapped the dashboard back onto the start day even though today had
    //     data. Only a genuinely empty today should auto-land.
    //   - The newest banked day must be RECENT (within AUTO_LAND_MAX_DAYS_BACK). Open the app after a long
    //     gap and jumping weeks back on launch is more confusing than an empty today, so we stay put.
    // The guard is process-lifetime (todayDidAutoLandThisLaunch), not view/saveable state, so a tab-away that
    // recreates the screen can't re-arm the one-shot and re-snap the day the user navigated to (#739). It
    // fires at most once per launch; after that the user chevrons freely. iOS parity in TodayView.
    LaunchedEffect(days, today) {
        if (todayDidAutoLandThisLaunch || selectedDayOffset != 0) return@LaunchedEffect
        // Today already has a banked row -> nothing to land on; arm the guard so we don't keep re-checking.
        if (today != null) { todayDidAutoLandThisLaunch = true; return@LaunchedEffect }
        // No newest reading yet means data is still loading (empty initial emission) -> wait, DON'T arm the
        // guard, otherwise a premature fire on the empty load would burn the one-shot before the strap's
        // history arrives and we'd never land.
        val zone = ZoneId.systemDefault()
        val latestTs = runCatching { viewModel.repo.latestHrSampleTs("my-whoop") }.getOrNull()
            ?: return@LaunchedEffect
        todayDidAutoLandThisLaunch = true
        val latestDay = logicalDay(java.time.Instant.ofEpochSecond(latestTs).atZone(zone))
        val back = java.time.temporal.ChronoUnit.DAYS.between(latestDay, todayDate)
        if (back in 1..AUTO_LAND_MAX_DAYS_BACK) selectedDayOffset = back.toInt()
    }
    val selectedDay = remember(selectedDayOffset, todayDate) { todayDate.minusDays(selectedDayOffset.toLong()) }
    // The key the day-scoped read-outs (Rest score, HR window, sleep band) key on. At offset 0 it
    // follows the resolver's `today?.day` so it tracks the row actually surfaced — including the non-UTC
    // pre-04:00 case (#304) where Today is the LOCAL-calendar-day row, not the logical-day one. Falls
    // back to the logical key when no row is banked yet. Past offsets use the logical key directly.
    val selectedDayKey = remember(selectedDay, today, selectedDayOffset) {
        if (selectedDayOffset == 0) today?.day ?: selectedDay.toString() else selectedDay.toString()
    }
    val historicalMetric = remember(days, selectedDayKey) { days.lastOrNull { it.day == selectedDayKey } }
    val displayMetric = remember(today, historicalMetric, selectedDayOffset) {
        if (selectedDayOffset == 0) today ?: historicalMetric else historicalMetric
    }
    // Keep the explicit calendar date visible alongside Today/Yesterday so the logical-day remap stays
    // honest — between midnight and 04:00 "Today" still points at the prior calendar date, and showing
    // that date makes it obvious which day's row is on screen (#144).
    val dayLabel = remember(selectedDayOffset, selectedDay, selectedDayKey) {
        // Date the label by the row ACTUALLY on screen, not the raw logical date. `selectedDayKey` already
        // follows the resolver's `today?.day` at offset 0, so when the resolver surfaces yesterday's
        // complete row (today not scored yet) the date now reads that row's day — instead of stamping
        // "Today · <today>" over yesterday's values, which disagreed with the Intelligence History row for
        // the same data (#434). iOS/Mac already label by the shown row's day; this brings Android to parity.
        val keyDate = runCatching { LocalDate.parse(selectedDayKey) }.getOrNull() ?: selectedDay
        val date = keyDate.format(DateTimeFormatter.ofPattern("EEE, d MMM", Locale.US))
        when (selectedDayOffset) {
            0 -> "Today · $date"
            1 -> "Yesterday · $date"
            else -> date
        }
    }
    // Display-only unit system + the SI profile weight, read once like every other Settings-backed
    // preference (SharedPreferences isn't reactive — a Settings write triggers recomposition).
    val context = LocalContext.current
    val unitSystem = UnitPrefs.system(context)
    // Effort display scale (#268) — drives the Effort tile's value + caption. Display-only.
    val effortScale = UnitPrefs.effortScale(context)
    val profileWeightKg = remember { ProfileStore.from(context).weightKg }
    // Body profile for the live Effort computation below — age/sex/HR-max-override drive the same
    // StrainScorer call the daily pass uses. Read once like every other Settings-backed value. (#402)
    val profileStore = remember { ProfileStore.from(context) }

    // Editable Key-Metrics layout (#251) — an ordered list of the enabled tiles, persisted display-only.
    // SharedPreferences isn't reactive, so it's mirrored into local state and re-read when the editor saves.
    var showMetricsEditor by remember { mutableStateOf(false) }
    var enabledKeyMetrics by remember { mutableStateOf(KeyMetricPrefs.enabled(context)) }

    // "Your cards" customisable dashboard (WHOOP "My Dashboard") — a persisted, reorderable selection of
    // metric cards. Empty/unset shows the sensible default set (Stress / Fitness age / Vitality + HRV +
    // Resting HR). The "CUSTOMISE" link on the section header opens a local sheet (no new nav destination).
    // Persistence is display-only — these cards read the SAME values the rest of Today already loads.
    // SharedPreferences isn't reactive, so it's mirrored into local state and re-read when the editor saves.
    var showDashboardEditor by remember { mutableStateOf(false) }
    var enabledDashboardCards by remember { mutableStateOf(DashboardCardPrefs.enabled(context)) }

    // The pinned "Your cards" values (Stress / Fitness age / Vitality), surfaced on Today so the buried
    // Explore features sit on the home screen (#582). The same merged resolvedSeries reads their detail
    // screens use; null simply renders a dash on that card. Mirror the iOS Today lane's stressToday /
    // fitnessAgeToday / vitalityToday loads (last resolved value over all history). Loaded off the main
    // thread; re-read as the data grows.
    var stressToday by remember { mutableStateOf<Double?>(null) }
    var fitnessAgeToday by remember { mutableStateOf<Double?>(null) }
    var vitalityToday by remember { mutableStateOf<Double?>(null) }
    LaunchedEffect(days) {
        // Read each pinned card from the SAME source its own detail screen reads — the proven path that
        // already shows real numbers there (and the resolution iOS's exploreSeries uses). Stress is derived
        // from the imported strap data (StressScreen reads "my-whoop"); Fitness age + Vitality are
        // NOOP-COMPUTED weekly scores the IntelligenceEngine writes under the "-noop" source (HealthScreen
        // reads COMPUTED_SOURCE = "my-whoop-noop"). The earlier resolvedSeries("…","my-whoop") read resolved
        // empty in the demo because those two scores never live under the imported "my-whoop" source. Take
        // the latest value (series are day-ascending), null → the card shows a dash, never a fabricated number.
        // #753: build the SAME StressModel the detail screen (StressScreen) shows and take `model.score`,
        // rather than the stress series' last banked row. StressModel.build prefers today's stored stress row
        // but otherwise DERIVES today's score from the live `days` RHR/HRV baseline; the old `.lastOrNull()`
        // read returned the latest *banked* day, so on a day with no stored stress row the pinned card sat on
        // yesterday's number (e.g. "2") while the detail page moved on. Reading the stored series the same way
        // StressScreen does (day → value, clamped 0–3) and feeding the same `days` ties the two together; both
        // recompute off `days`, so the pinned card stays in sync. null (no usable signal) keeps the honest
        // "Calibrating" placeholder, matching StressScreen's empty state.
        stressToday = runCatching {
            val stored = viewModel.repo.metricSeries("my-whoop", "stress", "0000-01-01", "9999-12-31")
                .associate { it.day to it.value.coerceIn(0.0, 3.0) }
            StressModel.build(days, stored)?.score
        }.getOrNull()
        fitnessAgeToday = runCatching {
            viewModel.repo.metricSeries("my-whoop-noop", "fitness_age", "0000-01-01", "9999-12-31").lastOrNull()?.value
        }.getOrNull()
        vitalityToday = runCatching {
            viewModel.repo.metricSeries("my-whoop-noop", "vitality", "0000-01-01", "9999-12-31").lastOrNull()?.value
        }.getOrNull()
    }

    // #713 — strap battery runtime estimate ("~X left") for the Data-sources battery row. The battery lane
    // banks a SoC time series; here we read it and run the SHARED BatteryEstimator (the iOS twin computes the
    // same value off LiveState.batteryEstimate). Rated-life fallback is chosen by strap generation: WHOOP 5/MG
    // gets the ~12-day figure, WHOOP 4.0 the ~4.5-day one. Recomputed when the banked series grows (a new
    // reading lands ~every 8 min), when the link comes/goes, or when the strap generation resolves. Charging
    // hides it (no "X left" while topping up); a too-short discharge run returns null and the badge shows just
    // the %. Display rule: hours < 48 -> "~Nh left", else "~N days left"; null hides the estimate.
    var batteryEstimateText by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(liveSnap.connected, liveSnap.batteryPct, liveSnap.whoop5, liveSnap.charging) {
        batteryEstimateText = if (!liveSnap.connected || liveSnap.charging == true) {
            null
        } else {
            runCatching {
                val now = System.currentTimeMillis() / 1000
                // A wide window: SoC readings are sparse (~8 min apart), so a few days back is plenty for the
                // estimator to find the trailing discharge run and still cheap to load.
                val from = now - 14L * 86_400
                val samples = viewModel.repo.batterySamples("my-whoop", from, now, limit = 2_000)
                    .mapNotNull { s -> s.soc?.let { s.ts to it } }
                val rated = if (liveSnap.whoop5) BatteryEstimator.ratedLifeHoursWhoop5
                            else BatteryEstimator.ratedLifeHoursWhoop4
                // Battery test mode (Test Centre #713): emit the discharge-run / fitted-slope / gate ANALYSIS
                // trace, not only the per-reading "bank soc=" line. This LaunchedEffect re-runs on a natural
                // throttle (battery% / connection / charging changes), never a tight loop, and reuses the
                // samples + rated just loaded, so there is no extra Room read. estimateTrace returns the SAME
                // Estimate the badge shows, so no displayed number changes. Gated zero-cost when the mode is off
                // (one SharedPreferences bool read) and routed to the .battery-tagged strap log via externalLog.
                if (com.noop.testcentre.TestCentre.from(context)
                        .active(com.noop.testcentre.TestDomain.BATTERY)) {
                    for (line in BatteryEstimator.estimateTrace(samples, rated).second) {
                        viewModel.ble.externalLog(line, com.noop.testcentre.TestDomain.BATTERY)
                    }
                }
                BatteryEstimator.estimate(samples, rated)?.let { est ->
                    val hours = est.hoursRemaining
                    if (!hours.isFinite() || hours <= 0.0) null
                    else if (hours < 48) "~${hours.roundToInt()}h left"
                    else {
                        val daysLeft = (hours / 24).roundToInt()
                        "~$daysLeft day${if (daysLeft == 1) "" else "s"} left"
                    }
                }
            }.getOrNull()
        }
    }

    // The latest active-energy figure (kcal) for the Calories card — the newest non-null activeKcal across
    // the Apple-side daily aggregates, mirroring the Today Calories tile. Null hides the card's value.
    var latestActiveKcal by remember { mutableStateOf<Double?>(null) }
    LaunchedEffect(days) {
        latestActiveKcal = runCatching {
            (viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31") +
                viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31"))
                .filter { it.activeKcal != null }
                .maxByOrNull { it.day }
                ?.activeKcal
        }.getOrNull()
    }

    // HYDRATION (opt-in, default OFF) — the Today "Hydration" card + its detail are hidden unless the user
    // turns Hydration tracking on in Settings. When on, the card reads today's logged total (ml, from the
    // local-only HydrationStore series) against the pure HydrationGoal (sex baseline + today's Effort bump).
    // Both are loaded off the main thread and re-read as the day's data grows; SharedPreferences isn't
    // reactive, so the toggle is read once into local state.
    val hydrationEnabled = remember { NoopPrefs.hydrationTracking(context) }
    // Day-cycle scene backdrop (#698). Default ON. When off, Today drops the SceneScreenBackground and
    // the scaffold paints the plain dark surface canvas instead. SharedPreferences isn't reactive, so
    // this is read once into local state (mirrors iOS @AppStorage in TodayView).
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    var hydrationTotalMl by remember { mutableStateOf(0.0) }
    LaunchedEffect(days, hydrationEnabled) {
        hydrationTotalMl = if (hydrationEnabled) {
            runCatching { HydrationStore.total(viewModel.repo) }.getOrDefault(0.0)
        } else 0.0
    }
    // The day's Effort/strain (0..100) drives the goal's effort bump. Prefer the live in-progress Effort
    // for today (floored at the stored value, mirroring the Effort gauge) so the goal reflects a hard day
    // as it accrues; null leaves the bump at 0. Computed below where liveTodayStrain is in scope.
    val hydrationGoalMl = remember(displayMetric, profileStore) {
        if (!hydrationEnabled) 0 else HydrationGoal.dailyGoalMl(profileStore.sex, displayMetric?.strain)
    }

    // "How your scores work" guide, opened from the per-score ⓘ affordances and the one-time
    // first-run card. `guideSection` carries which score to deep-link to (null = open at the top);
    // `showGuide` gates the presenting Dialog. The first-run card's seen-state lives in
    // ScoringGuidePrefs and is read once (SharedPreferences isn't reactive), then driven locally.
    var showGuide by remember { mutableStateOf(false) }
    var guideSection by remember { mutableStateOf<ScoreSection?>(null) }
    val openGuide: (ScoreSection?) -> Unit = { section ->
        guideSection = section
        showGuide = true
    }
    // A1 (#514/#706): the Charge breakdown sheet, opened by tapping the hero Charge ring. Hosts the
    // existing RecoveryDriversSection (gated to the calibration countdown when the night can't score) plus
    // the folded Readiness card (S4). Not persisted, so it reopens closed. Mirrors iOS showChargeBreakdown.
    var showChargeBreakdown by remember { mutableStateOf(false) }
    // S4: the Synthesis card collapses to a one-liner that expands on tap (default collapsed). Mirrors iOS.
    var synthesisExpanded by remember { mutableStateOf(false) }
    // S5: the Key Metrics grid caps at the first METRICS_COLLAPSED_CAP tiles behind a "Show all metrics"
    // expander, and the Data Sources footer collapses to a single "Synced from: ..." line. Both default
    // collapsed and are NOT persisted, so the home screen reopens compact. Mirrors iOS.
    var metricsExpanded by remember { mutableStateOf(false) }
    var sourcesExpanded by remember { mutableStateOf(false) }
    var scoringCardSeen by remember { mutableStateOf(ScoringGuidePrefs.cardSeen(context)) }
    val dismissScoringCard: () -> Unit = {
        ScoringGuidePrefs.setCardSeen(context)
        scoringCardSeen = true
    }

    // Per-card "dismissed into the inbox" flags for the two Today info-cards. A small × on each card
    // sets these (and posts a `.dismissedCard` update); "Restore to Today" in the inbox flips them back
    // via the shared TodayCardDismissal key. Read once (SharedPreferences isn't reactive), driven locally.
    var scoresBuildingDismissed by remember {
        mutableStateOf(TodayCardDismissal.isDismissed(context, CARD_SCORES_BUILDING))
    }
    var newHereDismissed by remember {
        mutableStateOf(TodayCardDismissal.isDismissed(context, CARD_NEW_HERE))
    }
    var calibratingDismissed by remember {
        mutableStateOf(TodayCardDismissal.isDismissed(context, CARD_CALIBRATING))
    }
    // Dismiss a Today info-card INTO the inbox: persist its flag, hide it, and post a restorable
    // `.dismissedCard` update carrying the card id. Mirrors the iOS `dismissTodayCard`.
    val dismissTodayCard: (String, String, String) -> Unit = { id, title, message ->
        TodayCardDismissal.setDismissed(context, id, true)
        when (id) {
            CARD_SCORES_BUILDING -> scoresBuildingDismissed = true
            CARD_NEW_HERE -> newHereDismissed = true
            CARD_CALIBRATING -> calibratingDismissed = true
        }
        updateStore?.post(
            UpdateItem(
                kind = UpdateKind.DISMISSED_CARD,
                title = title,
                message = message,
                restorePayload = id,
            ),
        )
    }
    // Honour a "Restore to Today" tap from the inbox: flip the matching dismissed flag back so the card
    // reappears (the inbox also cleared the shared pref directly, but this re-reads it into local state
    // for an already-mounted Today). Cleared once handled. Mirrors the iOS restoreRequest observer.
    val restoreSignal = updateStore?.restoreRequest
    LaunchedEffect(restoreSignal) {
        if (updateStore != null && restoreSignal != null) {
            when (restoreSignal) {
                CARD_SCORES_BUILDING -> scoresBuildingDismissed = false
                CARD_NEW_HERE -> newHereDismissed = false
                CARD_CALIBRATING -> calibratingDismissed = false
            }
            updateStore.restoreRequest = null
        }
    }

    // Announce NEW history to the inbox only when the NEWEST day-key (max yyyy-MM-dd) moves strictly
    // forward — not on a count change (#521). A background recompute rebuilds the window via
    // delete-then-reinsert, so the count momentarily dips and recovers while the newest key is unchanged
    // — keying off the count mistook that churn for new history and re-posted "New data added" on a
    // loop. The baseline is PERSISTED in SharedPreferences (not `remember`), so a relaunch over the same
    // history never re-announces. Empty baseline = first sight → record silently, never announce
    // historical data. The "added" count is the distinct days strictly above the old watermark — real,
    // never fabricated. Deep-links to Trends. Mirrors the Swift `announceNewDaysIfNeeded`.
    LaunchedEffect(days, updateStore) {
        val store = updateStore ?: return@LaunchedEffect
        val newestKey = days.maxOfOrNull { it.day } ?: return@LaunchedEffect   // no history yet
        val previousKey = NewDataWatermark.lastAnnouncedKey(context)
        NewDataWatermark.setLastAnnouncedKey(context, newestKey)
        if (previousKey.isEmpty()) return@LaunchedEffect            // first sight → silent baseline
        if (newestKey <= previousKey) return@LaunchedEffect         // recompute churn, not new history
        val added = days.map { it.day }.toSet().count { it > previousKey }
        if (added <= 0) return@LaunchedEffect
        val daysWord = if (added == 1) "day" else "days"
        store.post(
            UpdateItem(
                kind = UpdateKind.READING,
                title = "New data added",
                message = "$added new $daysWord of history is ready in Trends.",
                deepLink = "trends",
            ),
        )
    }

    // The newest Apple Health / Health Connect body weight, loaded off the main thread. Null until the
    // load runs or when neither source carries a weight — the Weight tile then falls back to the profile.
    var weightKg by remember { mutableStateOf<Double?>(null) }
    LaunchedEffect(days) {
        weightKg = latestWeightKg(
            viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31"),
            viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31"),
        )
    }

    // Steps for the selected day from imported Apple Health / Health Connect data — the Today Steps
    // tile's fallback when the strap itself didn't bank an on-device count. A WHOOP 4.0 DOES count
    // steps (in the official WHOOP app), but NOOP can't yet read them off the strap over Bluetooth, so
    // on a 4.0 the tile shows your imported steps instead of "No Data". Reloads as the day selector
    // moves. On-device WHOOP 5/MG steps still take precedence. (#150)
    var importedStepsForDay by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(days, selectedDayKey) {
        // Today's steps keep moving after the manual one-shot HC import, so the stored row goes
        // stale within minutes — top it up with ONE live StepsRecord read before the stored-row
        // read below. Best-effort: any HC hiccup just falls through to whatever is stored. (#150)
        if (selectedDayOffset == 0) {
            try {
                HealthConnectImporter.refreshTodaySteps(context, viewModel.repo)
            } catch (_: Exception) { /* best-effort */ }
        }
        importedStepsForDay = stepsForDay(
            viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31"),
            viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31"),
            selectedDayKey,
        )
    }

    // On-device steps ESTIMATE for the selected day (key "steps_est", computed "-noop" source). The
    // Steps tile prefers a REAL step count (strap @57 counter / imported Health Connect); only when a
    // day has NEITHER does it fall back to this estimate, shown with an "est." caption so it's never read
    // as a measured count. resolvedSeries reads the computed source for the my-whoop key, exactly like
    // the Explore "steps_est" metric. Null until loaded / no estimate for the day. (#150)
    var stepsEstForDay by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(days, selectedDayKey) {
        val byDay = runCatching {
            viewModel.repo.resolvedSeries("steps_est", "my-whoop", "0000-00-00", "9999-99-99")
                .values.associate { it.first to it.second }
        }.getOrDefault(emptyMap())
        stepsEstForDay = byDay[selectedDayKey]?.let { Math.round(it).toInt() }
    }

    // The Rest SCORE (0–100) for the selected day — IntelligenceEngine's Rest composite, written to the
    // `sleep_performance` metric series. The Key-Metrics "Rest" tile shows THIS, with hours-in-bed kept
    // as the caption; the tile previously showed hours where the score belonged (#248). resolvedSeries
    // merges imported + computed sleep_performance (imported-wins), so an importer sees the export's
    // figure and a Bluetooth-only user sees the on-device composite. Null until loaded / no night yet.
    var restScoreForDay by remember { mutableStateOf<Double?>(null) }
    LaunchedEffect(days, selectedDayKey) {
        val byDay = runCatching {
            viewModel.repo.resolvedSeries("sleep_performance", "my-whoop", "0000-00-00", "9999-99-99")
                .values.associate { it.first to it.second }
        }.getOrDefault(emptyMap())
        restScoreForDay = byDay[selectedDayKey] ?: byDay.entries.maxByOrNull { it.key }?.value
    }

    // The Rest tile's SPARKLINE series (#614 follow-up). The Rest tile's NUMBER is the Rest composite
    // (0–100) from `sleep_performance` above, but its mini-graph used to plot raw sleep MINUTES
    // (`w.sleepMin`), so the trend line didn't track the score it sat under. Build the SAME 0–100
    // `sleep_performance` series here, windowed to the trailing 14 calendar days ending on the selected
    // day (oldest → newest, nulls dropped — mirrors remember14's windowing of the DailyMetric series), and
    // feed it to the Rest tile instead. Now the sparkline tracks the Rest score. Empty until loaded.
    var restCompositeSpark by remember { mutableStateOf<List<Double>>(emptyList()) }
    LaunchedEffect(days, selectedDay) {
        val byDay = runCatching {
            viewModel.repo.resolvedSeries("sleep_performance", "my-whoop", "0000-00-00", "9999-99-99")
                .values.associate { it.first to it.second }
        }.getOrDefault(emptyMap())
        val cutoff = selectedDay.minusDays(13).toString()
        val end = selectedDay.toString()
        restCompositeSpark = byDay.entries
            .filter { it.key in cutoff..end }
            .sortedBy { it.key }
            .map { it.value }
    }

    // Provenance (COMPONENT 4): the REAL per-metric merge winner for the selected day's derived scores,
    // keyed by metric key ("recovery" / "sleep_performance"); each value is the RAW source id the resolver
    // returned (e.g. "my-whoop", "my-whoop-noop", "apple-health"). resolvedSeries applies the SAME
    // imported-WHOOP > NOOP-computed > Apple-Health precedence the dashboard merge uses field-by-field
    // (WhoopRepository.mergeDaily), so the badge under each ring names the source that ACTUALLY supplied
    // that day's number rather than a blanket day-level deviceId. Mirrors the Swift Today lane's
    // `provenanceByMetric` resolution exactly (the winner is the last resolved point on selectedDayKey).
    var provenanceByMetric by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    LaunchedEffect(days, selectedDayKey) {
        val resolved = mutableMapOf<String, String>()
        for (key in listOf("recovery", "sleep_performance")) {
            val win = runCatching {
                viewModel.repo.resolvedSeries(key, "my-whoop", "0000-00-00", "9999-99-99")
                    .points.lastOrNull { it.day == selectedDayKey }?.source
            }.getOrNull()
            if (win != null) resolved[key] = win
        }
        provenanceByMetric = resolved
    }

    // LIVE in-progress Effort for TODAY (#402) — mirrors the iOS TodayView live-Effort fix. The stored
    // `day?.strain` lags: early in the day it shows yesterday's completed Effort (or a stale 0.0) until the
    // heavy daily pass re-scores. So for offset 0 only, integrate today's raw HR over the SAME window the
    // HR trend uses (the logical day's local-midnight → now) through StrainScorer with the SAME params the
    // daily pass persists (Tanaka HR-max from age — or the manual override — the day's resting HR else the
    // default, profile sex), and prefer it on the Effort gauge. StrainScorer returns null below
    // `minReadings`, so before there's enough HR the gauge falls back to the stored value and never shows a
    // fabricated number. Any past day → null (the gauge uses the stored strain). Keyed on the same inputs
    // as the day-scoped loads so it reloads as the selector moves and as a sync/import grows the HR window.
    var liveTodayStrain by remember { mutableStateOf<Double?>(null) }
    LaunchedEffect(days, selectedDayKey, selectedDayOffset) {
        liveTodayStrain = if (selectedDayOffset == 0) {
            val zone = ZoneId.systemDefault()
            val start = selectedDay.atStartOfDay(zone).toEpochSecond()
            val now = System.currentTimeMillis() / 1000
            val todayHr = runCatching { viewModel.repo.hrSamples("my-whoop", start, now) }.getOrDefault(emptyList())
            // effMaxHR resolution matches AnalyticsEngine: manual HR-max override first, else Tanaka from age.
            val effMaxHR = profileStore.hrMaxOverride.takeIf { it > 0 }?.toDouble()
                ?: if (profileStore.age > 0) StrainScorer.tanakaHRmax(profileStore.age.toDouble()) else null
            StrainScorer.strain(
                hr = todayHr,
                maxHR = effMaxHR,
                restingHR = displayMetric?.restingHr?.toDouble() ?: StrainScorer.defaultRestingHR,
                sex = profileStore.sex,
            )
        } else {
            null
        }
    }

    // Recovery cold-start: recovery is null until the HRV baseline crosses the seed gate
    // (Baselines.minNightsSeed valid nights). Show honest "calibrating — N of 4 nights" progress
    // instead of a bare "No Data" so a new BLE-only user knows scores are coming, not broken. (PR #85)
    val recoveryCalibration: Int? = if (selectedDayOffset == 0) {
        recoveryCalibrationNights(days, displayMetric?.recovery != null)
    } else {
        null
    }

    // The most recent fully-SCORED recovery day to carry over on TODAY while tonight's recovery hasn't
    // been scored yet (#543). Right after the logical-day rollover the new day has no recovery (the new
    // night isn't scored until you wear it tonight), so a baseline-established user — past calibration, so
    // recoveryCalibration is null — saw the WHOLE recovery side blank ("No Data" Charge AND blank HRV /
    // resting-HR / respiratory / SpO₂ tiles + Synthesis + Contributors) while live HR kept ticking, which
    // reads as broken. This is the ONE prior row every recovery-derived read-out carries over from, the
    // way WHOOP keeps showing last recovery until the new one lands — it NEVER fabricates a number for the
    // new day, each carried read shows the REAL prior value labelled as prior, and any metric the prior
    // row genuinely lacks still falls through to "No Data". Non-null only when: it's today, today has no
    // recovery, and we're not mid-calibration (calibration owns its own copy). days is oldest→newest;
    // exclude the (still-null) today key so we never echo "today". Mirrors iOS lastScoredRecoveryDay.
    // #547 carry-over upper bound: the LATER of the logical "today" (rolls at 04:00) and the local
    // calendar day. Using the later key means a legitimate just-after-midnight carry-over of yesterday's
    // logical day is NOT dropped, while any FUTURE-dated row (a bad strap clock) still sorts past it and
    // is excluded. ISO date strings compare chronologically.
    val carryOverTodayKey = remember(todayDate) {
        maxOf(todayDate.toString(), java.time.LocalDate.now().toString())
    }
    val lastScoredRecoveryDay: DailyMetric? = remember(days, selectedDayKey, recoveryCalibration, selectedDayOffset, displayMetric, carryOverTodayKey) {
        lastScoredRecoveryDay(
            days = days,
            selectedDayKey = selectedDayKey,
            isToday = selectedDayOffset == 0,
            todayScored = displayMetric?.recovery != null,
            isCalibrating = recoveryCalibration != null,
            today = carryOverTodayKey,
        )
    }
    // Carry-over Charge for TODAY — the prior scored row's recovery + its "Last night · <date>" caption.
    // Derived from lastScoredRecoveryDay so Charge and every other recovery tile carry the SAME prior day.
    val lastScoredCharge: LastCharge? = remember(lastScoredRecoveryDay) {
        lastScoredRecoveryDay?.let { prior ->
            prior.recovery?.let { LastCharge(it, carriedCaption(prior.day, carryOverTodayKey)) }
        }
    }

    // Explainability (COMPONENT 2): the honest state of the score side for TODAY — scored / calibrating /
    // carried-last-night / needs-strap. One state, never a bare blank, and never a fabricated number. Only
    // computed for today (offset 0); a past day shows its own row, not a "needs the strap" prompt.
    val scoreState: ScoreState = remember(displayMetric, recoveryCalibration, lastScoredRecoveryDay, selectedDayOffset, carryOverTodayKey) {
        if (selectedDayOffset == 0) {
            scoreStateForToday(
                todayRecovery = displayMetric?.recovery,
                calibratingNights = recoveryCalibration,
                carriedDay = lastScoredRecoveryDay,
                today = carryOverTodayKey,
            )
        } else {
            ScoreState.Scored(displayMetric?.recovery ?: 0.0)
        }
    }

    // Explainability (COMPONENT 4): the displayed day's REAL PER-METRIC merge winners, mapped to their
    // provenance labels ("On-device" / "Whoop" / "Apple Health" / …). Each ring badges the source that
    // actually supplied THAT metric's number (recovery → Charge, sleep_performance → Rest), not a blanket
    // day-level deviceId, so an imported metric on an otherwise-computed day reads honestly. Gated on the
    // ring having a value (a calibrating / empty ring shows no badge). Null → no badge. Mirrors the Swift
    // Today lane (per-ring SourceBadge from provenanceByMetric, gated by ringHasValue).
    val chargeProvenance = remember(provenanceByMetric, displayMetric) {
        if (displayMetric?.recovery != null) provenanceByMetric["recovery"]?.let { provenanceDisplayLabel(it) } else null
    }
    val restProvenance = remember(provenanceByMetric, restScoreForDay) {
        if (restScoreForDay != null) provenanceByMetric["sleep_performance"]?.let { provenanceDisplayLabel(it) } else null
    }

    // 14-day trailing calendar window ending on the phone's actual local day.
    // Old imports stay in history, but they do not fill the Today trend tiles.
    val window = remember14(days, selectedDay)

    LaunchedEffect(days) {
        val now = System.currentTimeMillis() / 1000
        val recentCutoff = LocalDate.now()
            .minusDays(13)
            .atStartOfDay(ZoneId.systemDefault())
            .toEpochSecond()
        val whoopWorkouts = viewModel.repo.workouts("my-whoop", 0L, now)
        // Apple Health and Health Connect are separate sources (since #34) — keep them separate in the
        // provenance footer too, so Health Connect data isn't mislabelled under the "Apple Health" pill
        // (issue #53). The recent-workouts list below still unions all sources for a combined feed.
        val appleWorkouts = viewModel.repo.workouts("apple-health", 0L, now)
        val hcWorkouts = viewModel.repo.workouts("health-connect", 0L, now)
        val appleDaysCount = viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31").size
        val hcDaysCount = viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31").size
        footer = TodayFooterState(
            // fillWorkoutHrFromStrap: imported sessions carry no HR — derive it from strap samples (#77).
            recentWorkouts = viewModel.repo.fillWorkoutHrFromStrap(
                viewModel.repo.workoutsAllSources(recentCutoff, now)
                    .sortedByDescending { it.startTs }
            ),
            whoopDays = days.size,
            whoopWorkouts = whoopWorkouts.size,
            appleDays = appleDaysCount,
            appleWorkouts = appleWorkouts.size,
            hcDays = hcDaysCount,
            hcWorkouts = hcWorkouts.size,
        )
    }

    // #817 - horizontal swipe to change day, alongside the header chevrons. `detectHorizontalDragGestures`
    // only claims HORIZONTAL drags, so the LazyColumn keeps its vertical scroll; we accumulate the drag and
    // resolve the day ONCE on lift via the pure `dayNavSwipeTarget` (rightward = older, leftward = newer,
    // clamped at today). The threshold is density-scaled from DAY_NAV_SWIPE_THRESHOLD_DP so a small wobble
    // during a scroll doesn't flip the day. Mirrors the iOS day-nav swipe lane.
    val swipeThresholdPx = with(LocalDensity.current) { DAY_NAV_SWIPE_THRESHOLD_DP.dp.toPx() }
    val daySwipeModifier = Modifier.pointerInput(Unit) {
        var accumulatedX = 0f
        detectHorizontalDragGestures(
            onDragStart = { accumulatedX = 0f },
            onDragEnd = {
                selectedDayOffset = dayNavSwipeTarget(selectedDayOffset, accumulatedX, swipeThresholdPx)
            },
            onHorizontalDrag = { _, dragAmount -> accumulatedX += dragAmount },
        )
    }

    LazyScreenScaffold(
        modifier = daySwipeModifier,
        // title = null suppresses the big scaffold header (the nullable-title path); the compact
        // WHOOP-style top bar below replaces it, mirroring the iOS Today screen (todayTopBar).
        title = null,
        // Tighten the top inset now the big title is gone (Compose forbids negative padding, so this
        // expresses iOS's `.padding(top: -16)` as a smaller scaffold top padding).
        topPadding = 12.dp,
        // SCREEN-level day-cycle scene backdrop (iOS parity): the current hour's illustration sits behind
        // the WHOLE top region — the TodayTopBar AND the rings hero — full-bleed (full-width, up behind the
        // status bar), top-aligned, fading into the flat canvas over its lower portion, with a faint top
        // dark scrim so the white header text stays legible. The cards float OVER it on the flat canvas
        // below. Replaces the in-card hero scene (removed from the hero Box below). Mirrors iOS TodayView
        // passing `topBackground: AnyView(SceneScreenBackground())`. No glow.
        // #698 — gated on the "Day-cycle background" setting (default ON). Off passes null, so the scaffold
        // paints the plain dark surface canvas instead, mirroring iOS's `showDayCycleBackground ? ... : nil`.
        topBackground = if (showDayCycleBackground) { { SceneScreenBackground() } } else null,
    ) {
        // The header recording-status (COMPONENT 3) the top-bar light reflects: Recording while the strap
        // is connected and a live HR is streaming, else "Last synced Xm ago" from the last offload, else
        // "Not recording". Today only — a past day isn't "recording", so the light is omitted then.
        // #580 — a connected WHOOP 5/MG streaming live HR but offloading no history reads "Connected"
        // (history sync experimental on 5.0), overriding the honest resolver. Mirrors Swift `recordingState`.
        item {
        val headerRecordingState: RecordingState? = if (selectedDayOffset == 0) {
            if (liveSnap.connected && liveSnap.historySyncExperimental) {
                RecordingState.HistoryExperimental
            } else {
                recordingStateFor(
                    connected = liveSnap.connected,
                    // `recordingStateFor` only checks liveHeartRate for nullness (is a stream present), so
                    // the streaming boolean is sufficient and keeps the per-second bpm tick out of this body.
                    liveHeartRate = if (liveSnap.hrStreaming) 1 else null,
                    lastSyncAtSec = liveSnap.lastSyncAt,
                    nowSec = System.currentTimeMillis() / 1000,
                )
            }
        } else {
            null
        }

        // Apple-style large-title top bar (iOS TodayView.todayTopBar parity): a tappable "Today ⌄" big
        // title + full date on the LEFT (taps to change day), then a row of UNIFORM 36dp circular icons on
        // the RIGHT — a recording-status light, the updates bell, the gold quick-add (+), and the
        // menu/settings avatar. Plain header (no atmosphere card): the day-cycle scene now backs the rings
        // hero below, mirroring iOS. Staggered in as the first section (index 0).
        Box(modifier = Modifier.fillMaxWidth().staggeredAppear(0)) {
            TodayTopBar(
                dateText = dayNavNumericDate(selectedDay),
                selectedDay = selectedDay,
                recordingState = headerRecordingState,
                onPickDay = { offset -> selectedDayOffset = offset },
                updateStore = updateStore,
                onOpenUpdates = onOpenUpdates,
                onQuickActions = onQuickActions,
                onOpenSettings = onOpenSettings,
                onRecordingTap = onOpenSettings,
            )
        }
        }

        // Design Reset (iOS parity): the "New here?" first-run card is off the Today dashboard for the
        // clean look — the scoring guide stays reachable from the i on each score and in Settings.

        // When there is no daily score yet (today's recovery is null / no history),
        // lead with the "live now, history one import away" note so the empty tiles
        // below are explained rather than just dashed out. A small × dismisses it INTO
        // the Updates inbox (restorable from there). Only anchored to today (offset 0).
        if (displayMetric?.recovery == null) {
            item {
            // While the strap is mid-offload, say so — empty tiles read as final otherwise (#77).
            if (liveSnap.backfilling) SyncingHistoryNote(chunks = liveSnap.syncChunksThisSession)
            // Explained score state (COMPONENT 2): when there's no own number to show, say WHY and WHAT to
            // do. "Calibrating" (N more nights, no fake number), "Last night · <date>" (#802 carry-over)
            // or "Needs the strap" (no data overnight). The carried Charge now draws a dimmed filled ring on
            // the hero with NO in-ring caption, so its "Last night ..." note renders BELOW the rings here,
            // matching iOS explainedScoreNote. CarriedLastNight + NeedsStrap always show (one-off / today-
            // blocking, not recurring nags); the Calibrating note is dismissible-and-remembered just below.
            // Today only; never a fabricated value.
            if (selectedDayOffset == 0 &&
                (scoreState is ScoreState.CarriedLastNight || scoreState is ScoreState.NeedsStrap)
            ) {
                ScoreStateNote(scoreState)
            }
            // The calibrating "Building your baseline … N more nights …" note is dismissible-and-remembered
            // (into the Updates inbox, restorable) like the neighbouring "scores are building" card, so a
            // returning user who's read it once isn't shown it every day through the calibration window.
            if (selectedDayOffset == 0 && scoreState is ScoreState.Calibrating && !calibratingDismissed) {
                Box(modifier = Modifier.fillMaxWidth()) {
                    ScoreStateNote(scoreState)
                    if (updateStore != null) {
                        TodayCardDismissButton(
                            modifier = Modifier.align(Alignment.TopEnd),
                            onClick = {
                                dismissTodayCard(
                                    CARD_CALIBRATING,
                                    "Building your baseline",
                                    "Charge, Effort and Rest become personal after a few nights of wear.",
                                )
                            },
                        )
                    }
                }
            }
            if (selectedDayOffset != 0 || !scoresBuildingDismissed) {
                Box(modifier = Modifier.fillMaxWidth()) {
                    DataPendingNote(
                        title = "Live now. Your scores are building.",
                        body = "Your live heart rate is working from the strap, and recovery, strain " +
                            "and sleep build from it over your next few nights of wear, sharpening as it " +
                            "learns your baseline. Want your full history instantly? Import your WHOOP " +
                            "export in Data Sources and it backfills in about a minute.",
                    )
                    // The × is only meaningful for today's card (a past day's note isn't dismissed).
                    if (selectedDayOffset == 0 && updateStore != null) {
                        TodayCardDismissButton(
                            modifier = Modifier.align(Alignment.TopEnd),
                            onClick = {
                                dismissTodayCard(
                                    CARD_SCORES_BUILDING,
                                    "Live now. Your scores are building.",
                                    "Charge, Effort and Rest build over your next few nights of wear.",
                                )
                            },
                        )
                    }
                }
            }
            }
        }

        if (alert != null) item { IllnessBanner(alert!!) }

        // HERO — the three Charge / Effort / Rest score rings, Charge centred + enlarged, floating on a
        // scenic Charge-tinted backdrop (the WHOOP-style hero, #23). The old big gold RecoveryRing hero and
        // the "At a glance" header are gone: recovery now reads as the enlarged Charge ring, the Support
        // heart moved to the scaffold's compact top bar, and the Synthesis card + HRV/RHR/Respiratory rows
        // re-home below. iOS/macOS parity (TodayView.heroSection). The Effort gauge prefers the live
        // in-progress strain for today, falling back to the stored value (#402).
        // Staggered in as the rings hero (index 1, after the header). The ring numbers themselves tick up
        // via GlowRing's built-in count-up (the Android equivalent of iOS GlowRing's animated `value`).
        // The day-cycle SCENE now sits at SCREEN level (the scaffold's `topBackground`, behind the header +
        // these rings + bled full-width up behind the status bar), so the rings float DIRECTLY on the scene
        // rather than in a card-clipped scene of their own — mirroring iOS, where TodayView moved the scene
        // to a screen-level `SceneScreenBackground` and the hero dropped `.sceneHeroBackground()`. No
        // in-card scene here, and no rounded clip (a flat hero on the screen-level backdrop). The Charge
        // ring value reads WHITE (GlowRing's centre label) with a charge-green arc, matching the iOS source.
        item {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                // The dark hero CARD floats over the vivid day-scene so the rings + white numbers stay crisp —
                // the card does the contrast work, not a muted scene (Aaron 2026-06-23). Mirrors iOS heroSection.
                .background(
                    Palette.surfaceBase.copy(alpha = 0.72f),
                    RoundedCornerShape(Metrics.cardRadius),
                )
                .staggeredAppear(1),
        ) {
            ScoreHeroRow(
                day = displayMetric,
                restScore = restScoreForDay,
                recoveryCalibration = recoveryCalibration,
                lastScoredCharge = lastScoredCharge,
                effortScale = effortScale,
                liveTodayStrain = if (selectedDayOffset == 0) liveTodayStrain else null,
                chargeProvenance = chargeProvenance,
                restProvenance = restProvenance,
                onScoreInfo = openGuide,
                onChargeTap = { showChargeBreakdown = true },
            )
        }
        }

        // YOUR CARDS — the user-customisable dashboard (WHOOP "My Dashboard"). Surfaces a persisted,
        // reorderable selection of metric cards as flat WHOOP metric rows (leading icon + UPPERCASE label +
        // sublabel on the left, big value + unit + chevron on the right). Default = Stress / Fitness age /
        // Vitality + HRV + Resting HR. TODAY only; a card with no value yet renders a dash rather than
        // vanishing. The "CUSTOMISE" link opens a local toggle/reorder dialog. Mirrors iOS yourCardsSection.
        // When Hydration tracking is OFF the card is hidden even if it sits in the saved selection (the
        // editor still offers it, so the choice persists), keeping the opt-in feature fully invisible until
        // enabled. Mirrors the iOS yourCardsSection hydration gate.
        item {
        val visibleDashboardCards = enabledDashboardCards.filter {
            it != DashboardCard.HYDRATION || hydrationEnabled
        }
        if (selectedDayOffset == 0 && visibleDashboardCards.isNotEmpty()) {
            YourCardsSection(
                cards = visibleDashboardCards,
                day = displayMetric,
                // The SAME carried-over last-scored row the OLD hero vital rows + Key-Metrics tiles read
                // (#543): right after the logical-day rollover today's row carries no vitals yet, so without
                // this the HRV / Resting HR / Respiratory / SpO₂ / Sleep cards all blank to "No Data" while
                // the rest of Today shows last night's carried values. Routing the cards through the same
                // `carriedDay ?: day` source the HeroMetricRows + MetricGrid already use brings them to parity.
                carriedDay = lastScoredRecoveryDay,
                stress = stressToday,
                fitnessAge = fitnessAgeToday,
                vitality = vitalityToday,
                importedStepsForDay = importedStepsForDay,
                estimatedStepsForDay = stepsEstForDay,
                latestActiveKcal = latestActiveKcal,
                hydrationTotalMl = hydrationTotalMl,
                hydrationGoalMl = hydrationGoalMl,
                onOpenHydration = onOpenHydration,
                onOpenStress = onOpenStress,
                onOpenHealth = onOpenHealth,
                onOpenSleep = onOpenSleep,
                onCustomise = { showDashboardEditor = true },
            )
        }
        }

        // The plain-English read-out — the Charge-tinted Synthesis card with a WHITE headline — carries the
        // greeting + the SOLID/CALIBRATING data-confidence pill in its top-right. Mirrors the iOS Synthesis
        // InsightCard. Carries the last scored day's read at the rollover (#543) so it doesn't blank to
        // "No Data". Staggered in as index 2.
        item {
        Box(modifier = Modifier.fillMaxWidth().staggeredAppear(2)) {
            SynthesisHeroCard(
                day = displayMetric,
                recoveryCalibration = recoveryCalibration,
                carriedDay = lastScoredRecoveryDay,
                days = days,
                synthesisExpanded = synthesisExpanded,
                onToggleSynthesis = { synthesisExpanded = !synthesisExpanded },
                onOpenReadiness = { showChargeBreakdown = true },
            )
        }
        }

        // Provenance (COMPONENT 4) now rides UNDER each hero ring as a per-metric badge (Charge names the
        // recovery winner, Rest names the sleep_performance winner), resolved field-by-field per
        // WhoopRepository.mergeDaily, so an imported metric on an otherwise-computed day is labelled
        // honestly rather than under one blanket day-level deviceId. See ScoreHeroRow + HeroRingColumn.
        // Mirrors the iOS Today lane, which badges each ring's real winner and has no separate day badge.

        // Honest "why is Effort 0?" caption (#482/#480) — only when today's Effort is a real
        // near-zero (HR present but never crossed the cardio zone), so a calm day reads as explained
        // rather than broken. Mirrors the iOS effortZeroNote. A low-HR day honestly earns ~0.
        // Effort accrues over a day and must never visibly drop: floor the in-progress value at the day's
        // already-earned strain (#489/#506). displayMetric for today is today's row or null, never a prior
        // day, so this can't resurrect a stale day — it only stops the gauge dropping below what's earned.
        item {
        val todayEffort = if (selectedDayOffset == 0) {
            val live = liveTodayStrain; val stored = displayMetric?.strain
            if (live != null && stored != null) maxOf(live, stored) else (live ?: stored)
        } else null
        if (todayEffort != null && todayEffort < 1.0) {
            Row(
                modifier = Modifier.padding(horizontal = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(
                    Icons.Filled.Info,
                    contentDescription = null,
                    tint = Palette.effortColor,
                    modifier = Modifier.size(Metrics.iconSmall),
                )
                Text(
                    "No cardio load yet — Effort builds once your heart rate climbs into your effort " +
                        "zone (around 50% of your heart-rate reserve). A calm day honestly reads near zero.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
        }

        // The three hero vitals — HRV / Resting HR / Respiratory — re-homed below the ring hero now that
        // the big RecoveryRing card (which used to carry them) is gone. Mirrors the iOS metric rows.
        // Carries the last scored day's vitals (with a "Last night · <date>" footnote) at the rollover so
        // they don't blank to "No Data" while live HR ticks (#543). Staggered in as index 3.
        item {
        Box(modifier = Modifier.fillMaxWidth().staggeredAppear(3)) {
            HeroMetricRows(day = displayMetric, carriedDay = lastScoredRecoveryDay)
        }
        }

        // A1/S4: the WHAT SHAPED IT breakdown, the Contributors bars and the READINESS card all folded into
        // the Charge-ring TAP (the showChargeBreakdown dialog below), collapsing the home screen. They are
        // NOT deleted, only moved behind a tap; a one-word readiness read (Push / Maintain / Rest, #205)
        // stays on the hero via SynthesisHeroCard. Mirrors the iOS chargeBreakdownSheet + readiness fold.

        // METRICS — uniform tile grid (two columns), each tile with a 14-day sparkline.
        // #765: no ad-hoc Spacer row before this header. The lone `selectorTopUp` spacer here (a device the
        // Health/Sleep screens use to tug a SEGMENTED SELECTOR up toward the section above) had no selector
        // to tug on Today; it just injected an extra gap that, on top of the scaffold's per-row spacing on
        // both sides of the spacer item, made the gap before Key Metrics visibly larger than every other
        // inter-card gap. Removing it lets Key Metrics sit on the SAME shared screenRowSpacing as the rest.
        // Section header + an Edit affordance to open the local layout editor (#251). No new nav
        // destination — a dialog over Today. The Box lets the SectionHeader keep its trailing label while
        // the Edit control sits to its right.
        item {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(modifier = Modifier.weight(1f)) {
                SectionHeader("Key Metrics", overline = dayLabel, trailing = "14-day trend")
            }
            TextButton(
                onClick = { showMetricsEditor = true },
                colors = ButtonDefaults.textButtonColors(contentColor = Palette.accent),
            ) {
                Icon(
                    Icons.Filled.Tune,
                    contentDescription = "Edit Key Metrics",
                    modifier = Modifier.size(Metrics.iconSmall),
                )
                Spacer(Modifier.width(4.dp))
                Text("Edit", style = NoopType.footnote)
            }
        }
        }
        // Key Metrics grid, HR trend and Workouts each stagger in as the lower main sections (indices 4–6),
        // mirroring iOS's `.staggeredAppear` on metricsSection / heartRateTrendSection / workoutsSection.
        item {
        Box(modifier = Modifier.fillMaxWidth().staggeredAppear(4)) {
            MetricGrid(
                d = displayMetric,
                w = window,
                recoveryCalibration = recoveryCalibration,
                lastScoredCharge = lastScoredCharge,
                carriedDay = lastScoredRecoveryDay,
                unitSystem = unitSystem,
                effortScale = effortScale,
                latestWeightKg = weightKg,
                profileWeightKg = profileWeightKg,
                importedStepsForDay = importedStepsForDay,
                estimatedStepsForDay = stepsEstForDay,
                stepsEstimateCaption = stepsEstimateCaption(profileStore),
                restScore = restScoreForDay,
                restSpark = restCompositeSpark,
                enabledMetrics = enabledKeyMetrics,
                isToday = selectedDayOffset == 0,
                onScoreInfo = openGuide,
                metricsExpanded = metricsExpanded,
                onToggleMetrics = { metricsExpanded = !metricsExpanded },
            )
        }
        }
        item {
        Box(modifier = Modifier.fillMaxWidth().staggeredAppear(5)) {
            HeartRateTrendCard(viewModel, days, selectedDay, todayDate, displayMetric, effortScale)
        }
        }
        item {
        Box(modifier = Modifier.fillMaxWidth().staggeredAppear(6)) {
            TodayWorkoutsSection(footer.recentWorkouts)
        }
        }
        // Auto-detect workouts (MVP, opt-in, default OFF) — a NON-DESTRUCTIVE "looks like a workout?"
        // card that suggests logging a detected sustained-elevated-HR bout. Renders nothing when the
        // toggle is off or there's nothing to suggest. Save → a manual "Workout" row; × → dismissed forever.
        if (selectedDayOffset == 0) {
            item { AutoWorkoutNudgeCard(viewModel = viewModel, days = days) }
        }
        // Honest, dismissible 12-hourly donation ask — a card in the flow, never a dialog.
        item { DonationNudgeCard() }
        // Support — an in-content card (heart.fill in metricRose, "Donate or get in touch — totally
        // optional.", chevron). The Support heart left the header cluster for parity with iOS, where
        // Support is an in-flow supportRow near the donation nudge (still reachable via More → Support).
        item { SupportRow(onSupport = onSupport) }
        // Strap battery only while the link is up AND a real reading exists — a stale % from a
        // dropped connection must not present as live (#159).
        item {
            TodaySourcesSection(
                footer,
                strapBatteryPct = if (liveSnap.connected) liveSnap.batteryPct?.roundToInt() else null,
                strapBatteryEstimate = if (liveSnap.connected) batteryEstimateText else null,
                expanded = sourcesExpanded,
                onToggle = { sourcesExpanded = !sourcesExpanded },
            )
        }
    }

    // Scoring guide sheet — full-screen Dialog, mirroring Settings' What's-new presentation. Opened
    // by the per-score ⓘ (deep-linked via guideSection) and the first-run card (guideSection = null).
    if (showGuide) {
        Dialog(
            onDismissRequest = { showGuide = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                ScoringGuideScreen(
                    onClose = { showGuide = false },
                    initialSection = guideSection,
                )
            }
        }
    }

    // A1/S4: the Charge breakdown sheet, opened by tapping the hero Charge ring. A full-screen Dialog
    // (mirroring the scoring guide's presentation) hosting the existing What-shaped-it breakdown, the
    // Contributors bars and the Readiness card, built only when shown (#819 lazy). A calibrating night
    // (empty drivers) falls through to the existing countdown inside RecoveryDriversSection's own gate.
    if (showChargeBreakdown) {
        Dialog(
            onDismissRequest = { showChargeBreakdown = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            ChargeBreakdownSheet(
                days = days,
                displayDay = displayMetric,
                carriedDay = lastScoredRecoveryDay,
                showReadiness = selectedDayOffset == 0,
                onClose = { showChargeBreakdown = false },
                // "How Charge is calculated" → close the breakdown and open the scoring guide at the Charge
                // section, the same target the per-ring ⓘ buttons use. Mirrors the iOS NavigationLink to
                // ScoringGuideView(initialSection: .charge) whose onClose dismisses the breakdown.
                onHowCalculated = {
                    showChargeBreakdown = false
                    openGuide(ScoreSection.CHARGE)
                },
            )
        }
    }

    // Key-Metrics layout editor (#251) — a Today-local dialog (no new nav destination). Saves the layout
    // and re-reads it into local state so the grid updates immediately and survives relaunch.
    if (showMetricsEditor) {
        KeyMetricsEditorDialog(
            initial = enabledKeyMetrics,
            onDismiss = { showMetricsEditor = false },
            onSave = { metrics ->
                KeyMetricPrefs.setEnabled(context, metrics)
                enabledKeyMetrics = metrics
                showMetricsEditor = false
            },
        )
    }

    // "Your cards" dashboard editor (WHOOP "My Dashboard" ✎) — a Today-local dialog (no new nav
    // destination): toggle which cards show + reorder them with up/down arrows. Saves the selection and
    // re-reads it into local state so the dashboard updates immediately and survives relaunch. Mirrors the
    // iOS DashboardCardsEditorSheet. (No reorder lib is added — simple arrow buttons, like KeyMetricsEditor.)
    if (showDashboardEditor) {
        DashboardCardsEditorDialog(
            initial = enabledDashboardCards,
            onDismiss = { showDashboardEditor = false },
            onSave = { cards ->
                DashboardCardPrefs.setEnabled(context, cards)
                enabledDashboardCards = cards
                showDashboardEditor = false
            },
        )
    }
}

/**
 * The accent quick-action "+" in the Today header's top-right. Moved off the bottom bar (now four clean
 * tabs) to balance the header and open the existing quick-action sheet. A small CONTAINED accent disc —
 * the accented primary among an otherwise-neutral icon set, ~36dp, no float and no glow: a flat reset-blue
 * accent fill with a hairline rim, the "+" glyph in crisp white. Mirrors the iOS quick-action + (a glyph on
 * Circle().fill(StrandPalette.accent)).
 */
/**
 * The Updates "ringer": a bell glyph on a 36dp inset disc (textSecondary tint) with a small unread-count
 * badge overlaid top-trailing when [unreadCount] > 0. Sized to the uniform 36dp top-bar icon
 * ([Metrics.iconButton]) so it matches the recording light, the + and the avatar. Tapping opens the inbox
 * sheet. Mirrors the iOS `updateBell` (bell.badge + a statusCritical capsule on a 36pt circle). No glow.
 */
@Composable
private fun UpdateBell(unreadCount: Int, onClick: () -> Unit) {
    val label = if (unreadCount > 0) "Updates, $unreadCount unread" else "Updates"
    Box(
        // The outer Box is NOT clipped so the gold count pill can overflow the disc's top-trailing corner;
        // the inset disc inside carries the CircleShape clip + fill. There's no ripple (indication = null).
        modifier = Modifier
            .size(Metrics.iconButton)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            )
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(Metrics.iconButton)
                .clip(CircleShape)
                .background(Palette.surfaceInset),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (unreadCount > 0) Icons.Filled.NotificationsActive else Icons.Outlined.Notifications,
                contentDescription = null,
                tint = Palette.textSecondary,
                modifier = Modifier.size(Metrics.iconSmall),
            )
        }
        if (unreadCount > 0) {
            // Unread count pill (statusCritical, crisp-white count), nudged into the top-trailing corner
            // over the bell — the Design-Reset semantic for an unread/attention dot. Mirrors the iOS
            // updateBell, which fills the capsule with StrandPalette.statusCritical and reads the count white.
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .offset(x = 3.dp, y = (-2).dp)
                    .clip(RoundedCornerShape(Metrics.cornerPill))
                    .background(Palette.statusCritical)
                    .padding(horizontal = 4.dp, vertical = 1.dp),
            ) {
                Text(
                    if (unreadCount > 99) "99" else unreadCount.toString(),
                    style = NoopType.footnote.copy(fontSize = 9.sp),
                    // Crisp white on the critical fill (iOS goldDeepText = #FFFFFF post-reset); a fixed white
                    // here, not the theme-dependent goldDeepText (brown in light mode), keeps the count legible.
                    color = Color(0xFFFFFFFF),
                )
            }
        }
    }
}

/**
 * A small top-trailing × for a Today info-card that has no built-in dismiss control (the shared
 * [DataPendingNote]). Matches the "New here?" card's × styling. Dismisses the card into the inbox.
 */
@Composable
private fun TodayCardDismissButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    IconButton(
        onClick = onClick,
        modifier = modifier
            .size(Metrics.iconButton)
            .semantics { contentDescription = "Dismiss to Updates" },
    ) {
        Icon(
            Icons.Filled.Close,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(14.dp),
        )
    }
}

@Composable
private fun QuickActionDisc(onClick: () -> Unit) {
    Box(
        modifier = Modifier
            // Uniform 36dp top-bar icon ([Metrics.iconButton]) so the + matches the recording light, bell
            // and avatar — the accented (reset-blue) primary among an otherwise neutral set (iOS parity).
            .size(Metrics.iconButton)
            .clip(CircleShape)
            // Flat accent fill + a faint accent hairline (Design Reset: a + action reads on the blue accent,
            // never gold). Mirrors the iOS quick-action +, a glyph on Circle().fill(StrandPalette.accent).
            .background(Palette.accent)
            .border(0.5.dp, Palette.accent.copy(alpha = 0.5f), CircleShape)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            )
            .semantics { contentDescription = "Quick actions" },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Filled.Add,
            contentDescription = null,
            // Crisp white glyph on the accent fill (iOS goldDeepText = #FFFFFF post-reset).
            tint = Color(0xFFFFFFFF),
            modifier = Modifier.size(18.dp),
        )
    }
}

// MARK: - Scoring-guide affordances (ⓘ + first-run card)

/**
 * The small ⓘ that opens the scoring guide. Used on the Charge ring and the Effort / Rest tiles.
 * [section] only tunes the accessibility label; the deep-link target is carried by [onClick]'s
 * call site. Icon-only, so it always carries a content description. [compact] shrinks the hit-target
 * for the tile headers (where a full 36dp button would crowd the fixed-height tile).
 */
@Composable
private fun ScoreInfoButton(
    section: ScoreSection?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    val label = section?.let { "How ${it.label} is calculated" } ?: "How this score is calculated"
    val button = if (compact) 24.dp else Metrics.iconButton
    val glyph = if (compact) 16.dp else Metrics.iconSmall
    IconButton(onClick = onClick, modifier = modifier.size(button)) {
        Icon(
            Icons.Outlined.Info,
            contentDescription = label,
            tint = Palette.textTertiary,
            modifier = Modifier.size(glyph),
        )
    }
}

/**
 * One-time "New here?" card pointing first-run users at the scoring guide. A NoopCard in the Today
 * flow — never a dialog — with a primary "See how it works" action and a ✕ dismiss; both set the
 * seen-flag at the call site so the card never returns. Copy verbatim from the approved source.
 */
@Composable
private fun ScoringGuideIntroCard(onOpen: () -> Unit, onDismiss: () -> Unit) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Outlined.Info,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text("New here?", style = NoopType.headline, color = Palette.textPrimary)
                Spacer(Modifier.weight(1f))
                IconButton(
                    onClick = onDismiss,
                    modifier = Modifier
                        .size(Metrics.iconButton)
                        .semantics { contentDescription = "Dismiss" },
                ) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = null,
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(Metrics.iconSmall),
                    )
                }
            }
            Text(
                "See how Charge, Effort and Rest are calculated — and how they differ from WHOOP.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onOpen) {
                    Text("See how it works", style = NoopType.captionNumber, color = Palette.accent)
                }
            }
        }
    }
}

// MARK: - Today top bar (iOS TodayView.todayTopBar parity)
//
// A compact header: JUST the selected day as a small locale-numeric date on the LEFT (taps to open the date
// picker), then a trailing row of UNIFORM 36dp circular icons (a recording-status light, the updates bell,
// the gold quick-add (+), and the menu/settings avatar). No "Today" / "Yesterday" word, no prev/next
// chevrons and no full-date subtitle now: day-change is by horizontal swipe across the dashboard or by
// tapping the date, and a one-word "Swipe" / "Tap" hint flashes periodically in the accent colour to teach
// the now-invisible gestures. Mirrors iOS todayTopBar.

/** The top-bar date: JUST the selected day as a SMALL locale-numeric string ("28/06/2026" or "6/28/2026"
 *  per region), driven by the screen's own day (NOT LocalDate.now()) so the header and the data day never
 *  drift. No "Today" / "Yesterday" word and no prev/next arrows now: day-change is by horizontal swipe or
 *  by tapping to open the picker, and a rotating one-word hint teaches both. Mirrors iOS dayNavDateText. */
private fun dayNavNumericDate(selectedDay: LocalDate): String {
    // iOS `.numeric` yields a 4-digit year (e.g. 28/06/2026). The plain localized SHORT style yields a
    // 2-digit year (M/d/yy) in many locales, so we take the locale's SHORT pattern, widen any 2-y year
    // field ("yy") to a 4-digit one ("yyyy"), and keep every other locale ordering/separator as-is. Locale
    // -aware: the field order is never hardcoded to a single region.
    val locale = Locale.getDefault()
    val shortPattern = DateTimeFormatterBuilder.getLocalizedDateTimePattern(
        FormatStyle.SHORT, null, IsoChronology.INSTANCE, locale,
    )
    // Replace a run of EXACTLY two y (a 2-digit year) with yyyy; leave single-y or already-4-y untouched.
    val fourDigitYearPattern = shortPattern.replace(Regex("(?<!y)yy(?!y)"), "yyyy")
    return selectedDay.format(DateTimeFormatter.ofPattern(fourDigitYearPattern, locale))
}

/** The two one-word day-nav hints flashed in place of the date, alternating, in the accent colour. With the
 *  arrows gone the swipe / tap affordances are otherwise invisible, so this teaches them. Mirrors iOS. */
private val DAY_NAV_HINTS = listOf("Swipe", "Tap")

// MARK: - Day navigation (#817) - chevron arrows + horizontal swipe, iOS parity
//
// `selectedDayOffset` is days-back-from-today (0 = today, 1 = yesterday, …). The header chevrons and a
// horizontal swipe across the dashboard both move it: older increments the offset (no upper bound - you
// can browse arbitrarily far back), newer decrements it but is CLAMPED at 0 so a future day can never be
// selected. These pure helpers hold that clamp so it's covered by a JVM test and shared by both the
// arrow taps and the swipe handler, matching the iOS DayNavBar's `canGoNewer` / `selectedOffset ± 1`.

/** The offset for one step toward an OLDER day (previous). Unbounded above - history runs as far back as
 *  the data does. */
internal fun dayNavOlder(selectedOffset: Int): Int = selectedOffset + 1

/** The offset for one step toward a NEWER day (next), CLAMPED at 0 so a future day is never selectable. */
internal fun dayNavNewer(selectedOffset: Int): Int = (selectedOffset - 1).coerceAtLeast(0)

/** True when there IS a newer day to step to (i.e. we're not already on today). Gates the ▶ chevron's
 *  enabled state, mirroring the iOS `canGoNewer`. */
internal fun dayNavCanGoNewer(selectedOffset: Int): Boolean = selectedOffset > 0

/** The minimum horizontal drag (px) that counts as a day-change swipe, so a small wobble during a
 *  vertical scroll doesn't flip the day. ~64dp at mdpi; the handler passes density-scaled px. */
internal const val DAY_NAV_SWIPE_THRESHOLD_DP: Float = 64f

/**
 * Resolve a completed horizontal swipe to the next [selectedDayOffset]. A drag whose total horizontal
 * travel doesn't clear [thresholdPx] returns the offset UNCHANGED (treated as a non-swipe). A rightward
 * swipe (positive [dragX], the natural "go back" / reveal-the-past gesture) steps to the OLDER day; a
 * leftward swipe steps to the NEWER day, clamped at today. Pure so the gesture mapping is unit-tested.
 */
internal fun dayNavSwipeTarget(selectedOffset: Int, dragX: Float, thresholdPx: Float): Int = when {
    kotlin.math.abs(dragX) < thresholdPx -> selectedOffset
    dragX > 0f -> dayNavOlder(selectedOffset)
    else -> dayNavNewer(selectedOffset)
}

@Composable
private fun TodayTopBar(
    dateText: String,
    selectedDay: LocalDate,
    recordingState: RecordingState?,
    onPickDay: (Int) -> Unit,
    updateStore: UpdateStore?,
    onOpenUpdates: () -> Unit,
    onQuickActions: () -> Unit,
    onOpenSettings: () -> Unit,
    onRecordingTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var showPicker by remember { mutableStateOf(false) }
    if (showPicker) {
        val context = LocalContext.current
        DisposableEffect(selectedDay) {
            val cal = Calendar.getInstance().apply {
                set(selectedDay.year, selectedDay.monthValue - 1, selectedDay.dayOfMonth)
            }
            // Anchor the offset to the LOGICAL day (matches selectedDayOffset's anchor) so a picked date
            // resolves to the same row the header is labelling — never drifting against LocalDate.now().
            val anchor = logicalDayNow()
            val dialog = DatePickerDialog(
                context,
                { _, year, month, day ->
                    val picked = LocalDate.of(year, month + 1, day)
                    val offset = ChronoUnit.DAYS.between(picked, anchor).toInt().coerceAtLeast(0)
                    onPickDay(offset)
                    showPicker = false
                },
                cal.get(Calendar.YEAR),
                cal.get(Calendar.MONTH),
                cal.get(Calendar.DAY_OF_MONTH),
            ).apply {
                datePicker.maxDate = System.currentTimeMillis()
                setOnDismissListener { showPicker = false }
            }
            dialog.show()
            onDispose { runCatching { dialog.dismiss() } }
        }
    }

    // The rotating one-word hint shown in place of the date (null = show the date). Roughly every 10s it
    // flashes a hint for ~1.5s, alternating "Swipe" / "Tap", in the accent colour, then returns to the date.
    // With the arrows gone these are the only cues for the swipe / tap day-nav, so this teaches them. One
    // coroutine, auto-cancelled when the top bar leaves composition (no leaked timer). Mirrors iOS .task.
    var dayNavHint by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        var i = 0
        while (true) {
            kotlinx.coroutines.delay(10_000)
            dayNavHint = DAY_NAV_HINTS[i % DAY_NAV_HINTS.size]
            i++
            kotlinx.coroutines.delay(1_500)
            dayNavHint = null
        }
    }
    // Fade the colour between the normal date (primary) and the accent-coloured hint, mirroring the iOS
    // easeInOut colour swap. The text itself crossfades between the date string and the hint word.
    val dateColor by animateColorAsState(
        targetValue = if (dayNavHint != null) Palette.accent else Palette.textPrimary,
        label = "day-nav-hint-color",
    )

    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // LEFT side: JUST the date, small (locale numeric), no relative word and no prev/next arrows. Taps open
        // the date picker; a horizontal swipe across the dashboard still changes the day. Every ~10s it
        // swaps for ~1.5s to a one-word "Swipe" / "Tap" hint in the accent colour so users learn the now-
        // invisible day-nav gestures. weight(1f) so the date claims the leading room and never pushes the
        // trailing icon cluster, which sits after this. Mirrors iOS dayNavDateText + the .task hint loop.
        Box(
            modifier = Modifier
                .weight(1f)
                .clip(RoundedCornerShape(Metrics.cornerSm))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClickLabel = "Change day",
                    onClick = { showPicker = true },
                )
                .semantics { contentDescription = "$dateText. Swipe or tap to change day" },
        ) {
            Crossfade(targetState = dayNavHint ?: dateText, label = "day-nav-date") { label ->
                Text(
                    label,
                    // ~13sp SemiBold, matching the iOS .system(size: 13, weight: .semibold). subhead is the
                    // 13sp house style; override its weight to semibold for the bolder date stamp.
                    style = NoopType.subhead.copy(fontWeight = FontWeight.SemiBold),
                    color = dateColor,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }

        // RIGHT — the UNIFORM 36dp circular icon set: recording-status light · bell · + · avatar. All
        // share Metrics.iconButton (36dp), matching iOS's uniform-size top-bar icons.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // Recording-status light — a colour-coded dot inside a 36dp inset disc (green recording /
            // amber synced / red not-recording / accent experimental). The chip ALWAYS renders so the icon
            // row never jumps when you scrub to a past day; a past day (null state) shows a muted,
            // non-interactive dot, recording status only means something for today. Mirrors iOS.
            RecordingStatusLight(state = recordingState, onClick = onRecordingTap)
            // Updates bell (36dp inset disc + gold unread pill).
            if (updateStore != null) {
                UpdateBell(unreadCount = updateStore.unreadCount, onClick = onOpenUpdates)
            }
            // Quick-add (+) — the accented gold primary, same 36dp as the rest.
            QuickActionDisc(onClick = onQuickActions)
            // Menu / settings avatar — the loop mark when no photo, same 36dp.
            Box(
                modifier = Modifier
                    .size(Metrics.iconButton)
                    .clip(CircleShape)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onOpenSettings,
                    )
                    .semantics { contentDescription = "Menu and settings" },
                contentAlignment = Alignment.Center,
            ) {
                ProfileAvatar(size = Metrics.iconButton)
            }
        }
    }
}

/** The top-bar recording-status light: a 36dp inset disc with a centred colour-coded dot — green while
 *  recording, amber after a recent sync, red when not recording, accent for the 5.0 experimental-history
 *  state. The chip ALWAYS renders so the top-bar icon row never jumps when you scrub to a past day; a past
 *  day ([state] == null, no live state) shows a MUTED dot (textTertiary at 0.4 alpha) and is NON-clickable,
 *  recording status only means something for today. Tap (today only) routes to connect. Mirrors the iOS
 *  top-bar RecordingStatusLight + recordingHue (a plain dot). */
@Composable
private fun RecordingStatusLight(state: RecordingState?, onClick: () -> Unit) {
    // A live state colours the dot; a past day (null) reads as a muted, non-actionable tertiary dot.
    val hue = when (state) {
        RecordingState.Recording -> Palette.statusPositive
        is RecordingState.LastSynced -> Palette.statusWarning
        RecordingState.NotRecording -> Palette.statusCritical
        RecordingState.HistoryExperimental -> Palette.accent
        null -> Palette.textTertiary.copy(alpha = 0.4f)
    }
    val label = if (state != null) {
        "${state.title}. ${state.detail}"
    } else {
        "Recording status, not shown for a past day"
    }
    // Only today's chip is tappable; a past day's muted dot is inert (no clickable, matching iOS .disabled).
    val base = Modifier
        .size(Metrics.iconButton)
        .clip(CircleShape)
        .background(Palette.surfaceInset)
    val tappable = if (state != null) {
        base.clickable(
            interactionSource = remember { MutableInteractionSource() },
            indication = null,
            onClick = onClick,
        )
    } else {
        base
    }
    Box(
        modifier = tappable.semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(10.dp)
                .clip(CircleShape)
                .background(hue),
        )
    }
}

/** In-content Support card (iOS supportRow): heart.fill in metricRose, the donation copy, a chevron.
 *  The whole card is the tap target. Lives near the donation nudge in the Today flow. */
@Composable
private fun SupportRow(onSupport: () -> Unit) {
    NoopCard(
        modifier = Modifier
            .clip(RoundedCornerShape(Metrics.cardRadius))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onSupport,
            )
            .semantics { contentDescription = "Support NOOP — donate or get in touch" },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.space14),
        ) {
            Icon(
                Icons.Filled.Favorite,
                contentDescription = null,
                tint = Palette.metricRose,
                modifier = Modifier.size(Metrics.iconSmall),
            )
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(Metrics.space4),
            ) {
                Text("Support NOOP", style = NoopType.headline, color = Palette.textPrimary)
                Text(
                    "Donate or get in touch — totally optional.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
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

// MARK: - Score hero row — three Charge / Effort / Rest score rings, Charge centred + enlarged
//
// The WHOOP-style Today hero (#23): the three daily scores as animated [GlowRing]s floating on a
// Charge-tinted [ScenicHeroBackground], the Charge (recovery) ring centred and ENLARGED as the hero
// and smaller Rest / Effort rings flanking it, bottom-aligned so all three share a baseline. A tappable
// UPPERCASE label + chevron sits beneath each ring and opens that score's scoring-guide section. Honest
// empty / calibrating overlays when a score is null. Mirrors iOS TodayView.scoreHeroRow (order Rest ·
// Charge · Effort; centre = min(150, max(110, (w-12)/2.3)); side = centre × 0.66; lineWidth = diameter
// × 0.085). Data wiring is unchanged — presentation only.

@Composable
private fun ScoreHeroRow(
    day: DailyMetric?,
    restScore: Double?,
    recoveryCalibration: Int?,
    lastScoredCharge: LastCharge? = null,
    effortScale: EffortScale,
    liveTodayStrain: Double? = null,
    // Per-metric provenance labels (COMPONENT 4) — the REAL merge winner under each ring, or null to hide
    // the badge (no value / no resolved winner). Charge ← "recovery", Rest ← "sleep_performance". Effort
    // has no cross-source merge, so it carries no provenance badge (matches iOS).
    chargeProvenance: String? = null,
    restProvenance: String? = null,
    onScoreInfo: (ScoreSection) -> Unit,
    // A1 (#514/#706): tapping the Charge ring opens the breakdown sheet. A small chevron cue overlays the
    // ring's bottom edge INSIDE the ring frame, so it adds no stacked height (the #762 self-sizing parity).
    onChargeTap: (() -> Unit)? = null,
) {
    val recovery = day?.recovery
    // Prefer the live in-progress Effort for today, but never BELOW the day's already-earned strain
    // (#489/#506: a live under-read replaced today's real Effort with 0). The effective value drives the
    // gauge number AND the has-data / "No Data" branch, so the ring only reads "No Data" when neither
    // exists. Mirrors the iOS live-Effort gauge. (#402)
    val strain = run {
        val live = liveTodayStrain; val stored = day?.strain
        if (live != null && stored != null) maxOf(live, stored) else (live ?: stored)
    }
    // Effort honours the 0–100 / WHOOP-0–21 toggle (#313). The stored strain is on NOOP's 0–100 Effort
    // axis; render it on the user's selected scale so the arc and centre number match the app's Effort.
    val effortOutOf = if (effortScale == EffortScale.WHOOP) 21.0 else 100.0
    val effortVal = strain?.let { UnitFormatter.effortValue(it, effortScale) } ?: 0.0

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cardRadius)),
    ) {
        // iOS parity: the hero rings float DIRECTLY on the SCREEN-level day-cycle scene (the scaffold's
        // topBackground), not on any per-hero atmosphere or the old scenic indigo gradient — matching
        // TodayView, which moved the scene to a screen-level SceneScreenBackground and dropped the
        // per-hero scene/ScenicHeroBackground.
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Metrics.gap, vertical = Metrics.space18),
        ) {
            // iOS parity (TodayView.scoreHeroRow): three EQUAL rings in CHARGE · EFFORT · REST order — no
            // enlarged centre — filling the width as one balanced row. Ring stroke 0.10 (WHOOP weight).
            val ringGap = 14.dp
            val ring = ((maxWidth - ringGap * 2) / 3.1f).coerceIn(90.dp, 112.dp)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(ringGap, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.Top,
            ) {
                // CHARGE — recovery 0–100. Honest empty / calibrating overlay; badges its recovery winner.
                HeroRingColumn(
                    domain = DomainTheme.Charge,
                    onInfo = { onScoreInfo(ScoreSection.CHARGE) },
                    provenance = chargeProvenance,
                    onRingTap = onChargeTap,
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        // #802: when today has no Charge yet but a prior night's value is carried, draw a
                        // DIMMED (0.8 opacity) REAL ring filled to the carried value, matching the Rest ring,
                        // rather than a bare number on an empty track (which read as broken). Same diameter so
                        // the self-sizing hero row is untouched; the dim + the carried "Last night · <date>"
                        // caption mark it as carried, not today's fresh score. Mirrors iOS chargeRing (#802).
                        val carried = if (recovery == null && recoveryCalibration == null) lastScoredCharge else null
                        if (carried != null) {
                            // #802: the carried branch draws ONLY the dimmed filled ring with the value
                            // number inside, matching iOS chargeRing. The "Last night · <date>" note is NOT
                            // drawn in-ring (an unbounded in-ring caption inflated the Charge column and broke
                            // the three-equal-rings layout); it renders BELOW the hero via ScoreStateNote.
                            GlowRing(
                                modifier = Modifier.alpha(0.8f),
                                fraction = (carried.value / 100.0).toFloat(),
                                value = carried.value,
                                color = Palette.recoveryColor(carried.value),
                                diameter = ring,
                                lineWidth = ring * 0.10f,
                                showsLabel = true,
                                format = { "${it.roundToInt()}" },
                            )
                        } else {
                            GlowRing(
                                fraction = ((recovery ?: 0.0) / 100.0).toFloat(),
                                value = recovery ?: 0.0,
                                color = Palette.recoveryColor(recovery ?: 0.0),
                                diameter = ring,
                                lineWidth = ring * 0.10f,
                                showsLabel = recovery != null,
                            )
                            // Empty track + calibrating / no-data overlay (the carried case is handled above).
                            if (recovery == null) RingEmptyOverlay(recoveryCalibration, diameter = ring)
                        }
                        // No in-ring tap cue: the single tap affordance is the CHARGE-label chevron below the
                        // ring (HeroRingColumn), matching iOS where the in-ring cue was removed.
                    }
                }
                // EFFORT — strain on the gauge, on the user's selected scale.
                HeroRingColumn(domain = DomainTheme.Effort, onInfo = { onScoreInfo(ScoreSection.EFFORT) }) {
                    Box(contentAlignment = Alignment.Center) {
                        GlowRing(
                            fraction = (if (effortOutOf > 0) effortVal / effortOutOf else 0.0).toFloat(),
                            value = effortVal,
                            color = Palette.effortTint((strain ?: 0.0) / 100.0),
                            diameter = ring,
                            lineWidth = ring * 0.10f,
                            showsLabel = strain != null,
                            format = { if (effortScale == EffortScale.WHOOP) String.format("%.1f", it) else it.toInt().toString() },
                        )
                        if (strain == null) RingNoData()
                    }
                }
                // REST — sleep composite 0–100, reusing the recovery ring's colour scale. Badges its real
                // sleep_performance merge winner under the ring (gated upstream on restScore != null).
                HeroRingColumn(
                    domain = DomainTheme.Rest,
                    onInfo = { onScoreInfo(ScoreSection.REST) },
                    provenance = restProvenance,
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        GlowRing(
                            fraction = ((restScore ?: 0.0) / 100.0).toFloat(),
                            value = restScore ?: 0.0,
                            color = Palette.recoveryColor(restScore ?: 0.0),
                            diameter = ring,
                            lineWidth = ring * 0.10f,
                            showsLabel = restScore != null,
                        )
                        if (restScore == null) RingNoData()
                    }
                }
            }
        }
    }
}

/**
 * One hero ring column: the ring, with a tappable UPPERCASE domain label + chevron beneath it (the
 * WHOOP affordance) that opens the matching scoring-guide section, and an OPTIONAL per-metric provenance
 * badge (COMPONENT 4) under that — the real merge winner for this ring's score ("On-device" / "Whoop" /
 * "Apple Health"). The badge is shown only when [provenance] is non-null (the caller gates it on the
 * ring having a value AND a resolved winner). Mirrors the iOS heroRingColumn — the ring floats on the
 * scenic field with no per-ring card, the SourceBadge sits beneath the label.
 */
@Composable
private fun HeroRingColumn(
    domain: DomainTheme,
    onInfo: () -> Unit,
    provenance: String? = null,
    // A1: when non-null (Charge), the ring is tappable and opens the breakdown sheet. The chevron cue is
    // overlaid by the caller INSIDE the ring box so it adds no stacked height (#762 self-sizing parity).
    onRingTap: (() -> Unit)? = null,
    ring: @Composable () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (onRingTap != null) {
            Box(
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(
                        onClickLabel = "See what shaped your ${domain.label}",
                        onClick = onRingTap,
                    ),
            ) { ring() }
        } else {
            ring()
        }
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .clickable { onInfo() }
                .padding(horizontal = 6.dp, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(domain.label.uppercase(), style = NoopType.overline, color = Palette.textSecondary)
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = "How ${domain.label} is calculated",
                tint = Palette.textSecondary.copy(alpha = 0.6f),
                modifier = Modifier.size(14.dp),
            )
        }
        // COMPONENT 4 — the real per-metric merge winner under this ring (only when resolved + the ring
        // has a value). Tinted to the source's badge hue, matching the Data Sources footer + iOS.
        if (provenance != null) {
            SourceBadge(
                provenance,
                tint = provenanceLabelTint(provenance),
                modifier = Modifier.semantics { contentDescription = "Source: $provenance" },
            )
        }
    }
}

/**
 * The plain-English Synthesis card — the Charge-tinted [InsightCard] read-out under the ring hero, with a
 * WHITE headline (the key iOS Design-Reset change — `statusColor: textPrimary`, not the recovery/charge
 * colour), carrying the greeting + the SOLID / CALIBRATING data-confidence pill in its top-right. Mirrors
 * the iOS Synthesis InsightCard (which moved here when the big RecoveryRing hero that owned the pill went).
 */
@Composable
private fun SynthesisHeroCard(
    day: DailyMetric?,
    recoveryCalibration: Int?,
    carriedDay: DailyMetric? = null,
    // S4: the day history (for the one-word readiness read), whether the Synthesis card is expanded, and the
    // taps to toggle it / open the Charge breakdown (where the full Readiness card lives). Defaults keep old
    // call sites compiling; the Today call site supplies them.
    days: List<DailyMetric> = emptyList(),
    synthesisExpanded: Boolean = true,
    onToggleSynthesis: () -> Unit = {},
    onOpenReadiness: () -> Unit = {},
) {
    // The row the synthesis reads from: today's own when it carries recovery, else the carried-over last
    // scored day (#543) so the card mirrors the carried Charge ring instead of blanking to "No Data". When
    // carrying, the detail line gets a "Last night · <date>" provenance so the prior read isn't passed off
    // as today's. today's own read wins the instant tonight is scored.
    val readDay = carriedDay ?: day
    val recovery = readDay?.recovery
    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        // The greeting + SOLID/CALIBRATING data-confidence pill ride in their OWN header row ABOVE the
        // card, not as a top-end overlay over it (#527). The old overlay sat over the card's "SYNTHESIS"
        // overline + big status word and, on a narrow phone, collided with them — and squeezing the
        // status into the leftover width force-broke a single word ("Calibrating" → "Calibrati/ng").
        // A separate row CAN'T overlap, and the card keeps its FULL width so the status stays one line.
        // Mirrors the iOS Synthesis header-row layout (TodayView heroSection).
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // The greeting yields/ellipsises first; the pill keeps its full width (#527).
            Text(
                greetingWord(),
                style = NoopType.subhead,
                color = Palette.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Spacer(Modifier.weight(1f))
            // S4 (#205): the one-word readiness read kept on the hero now the full Readiness card folded
            // into the Charge-ring tap. Push / Maintain / Rest; hidden when there isn't enough history.
            // Tapping it opens the Charge breakdown, where the full Readiness card now lives.
            val readinessLevel = remember(days) {
                if (days.isEmpty()) ReadinessEngine.Level.INSUFFICIENT
                else ReadinessEngine.evaluate(days, today = logicalDayKeyNow()).level
            }
            readinessWord(readinessLevel)?.let { word ->
                ReadinessHeroPill(word = word, level = readinessLevel, onTap = onOpenReadiness)
            }
            // SOLID only when TODAY's own row carries a settled recovery, a carried prior-day read is
            // honestly still CALIBRATING for today, matching the iOS pill (keyed on displayDay.recovery).
            val todayRecovery = day?.recovery
            StatePill(
                title = if (todayRecovery != null) "SOLID" else "CALIBRATING",
                tone = if (todayRecovery != null) StrandTone.Accent else StrandTone.Neutral,
            )
        }
        // S4: the Synthesis card collapses to a one-liner that expands on tap. The headline (the status) is
        // the SAME in both states, only the detail body and chrome fold, never the read (#506).
        val status = if (recoveryCalibration != null) "Calibrating" else synthesisWord(recovery)
        val detail = if (recoveryCalibration != null) {
            // Comma (not the old em-dash) to match the Swift canonical synthesis copy VERBATIM
            // (TodayView "Learning your baseline, N of M nights.") and the no-em-dash standing rule.
            "Learning your baseline, $recoveryCalibration of ${Baselines.minNightsSeed} nights."
        } else if (carriedDay != null) {
            // Carried prior-day read, summarise that day + stamp it so it isn't passed off as today's.
            synthesisDetail(carriedDay) + " ${carriedCaption(carriedDay.day)}."
        } else {
            synthesisDetail(day)
        }
        if (synthesisExpanded) {
            Box(modifier = Modifier.clickable(onClickLabel = "Collapse", onClick = onToggleSynthesis)) {
                InsightCard(
                    modifier = Modifier.fillMaxWidth(),
                    category = "Synthesis",
                    status = status,
                    detail = detail,
                    // The SYNTHESIS headline reads WHITE (textPrimary), not the recovery/charge colour, the
                    // key iOS Design-Reset change (TodayView.synthesisSection passes statusColor textPrimary).
                    statusColor = Palette.textPrimary,
                    // FLAT card to match iOS (no navy-bevel gradient / border): identity comes from the white
                    // headline alone. tint = null routes to the neutral FLAT surfaceRaised + hairline path.
                    tint = null,
                )
            }
        } else {
            // Collapsed: a one-liner with the SYNTHESIS overline, the status headline and a down-chevron.
            NoopCard(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClickLabel = "Expand for the full read", onClick = onToggleSynthesis),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("SYNTHESIS", style = NoopType.overline, color = Palette.textTertiary)
                        Text(
                            status,
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Icon(
                        Icons.Filled.KeyboardArrowDown,
                        contentDescription = null,
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}

/**
 * S4 (#205): the one-word readiness pill on the hero (Push / Maintain / Rest). A small tinted capsule
 * matching the score-pill chrome, coloured by the readiness level; tapping opens the Charge breakdown sheet
 * where the full Readiness card lives. Mirrors the iOS readinessHeroPill.
 */
@Composable
private fun ReadinessHeroPill(word: String, level: ReadinessEngine.Level, onTap: () -> Unit) {
    val tone = readinessColor(level)
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(tone.copy(alpha = 0.12f))
            .border(1.dp, tone.copy(alpha = 0.32f), RoundedCornerShape(50))
            .clickable(onClickLabel = "See your full readiness", onClick = onTap)
            .padding(horizontal = 10.dp, vertical = 5.dp)
            .semantics { contentDescription = "Readiness: $word" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(word.uppercase(), style = NoopType.overline, color = tone)
    }
}

/** Honest overlay shown over the Charge ring when today's recovery is null: either the calibrating count
 *  or No data. The carried last-scored Charge case is NOT handled here anymore: it's intercepted earlier
 *  and drawn as a dimmed FILLED ring in the carried branch (matching iOS chargeRing), so this overlay only
 *  covers the calibrating and no-data cases. Mirrors iOS TodayView.ringEmptyOverlay. */
@Composable
private fun RingEmptyOverlay(
    calibratingNights: Int?,
    diameter: Dp,
) {
    if (calibratingNights != null) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Calibrating", style = NoopType.headline, color = Palette.textTertiary, maxLines = 1)
            Text(
                "$calibratingNights of ${Baselines.minNightsSeed}",
                style = NoopType.footnote,
                color = Palette.textSecondary,
                maxLines = 1,
            )
        }
    } else {
        RingNoData()
    }
}

@Composable
private fun RingNoData() {
    Text(NO_DATA, style = NoopType.headline, color = Palette.textTertiary, maxLines = 1)
}

// MARK: - Hero vitals metric rows — HRV / Resting HR / Respiratory, re-homed below the ring hero
//
// The WHOOP-style redesign (#23) dropped the big gold RecoveryRing hero that used to carry these; the
// three vitals now read directly below the three-ring hero + Synthesis card. [HeroMetricRows] is the
// README "Metric row" card; the SOLID/CALIBRATING pill + Synthesis insight moved into [SynthesisHeroCard].

/** The three hero vitals as README metric rows — HRV (teal) · Resting HR (rose) · Respiratory (blue).
 *  When today isn't scored yet (#543), reads the carried last-scored day instead of blanking to "No Data",
 *  with ONE card-level "Last night · <date>" footnote so the whole recovery side reads consistently as a
 *  prior read. Each row still falls through to "No Data" for a metric the carried row genuinely lacks. */
@Composable
private fun HeroMetricRows(day: DailyMetric?, carriedDay: DailyMetric? = null) {
    // The row the vitals read from: today's own when it carries recovery, else the carried prior day.
    val vd = carriedDay ?: day
    // The neutral white card surface (matching iOS's frosted vitals card + every other card) — NOT a
    // faint surfaceInset wash, which blended into the page. NoopCard(tint = null) fills the white
    // surfaceRaised + a hairline + a rounded clip so the inter-row dividers trim cleanly.
    NoopCard(padding = 0.dp) {
        Column(modifier = Modifier.fillMaxWidth()) {
            HeroMetricRow(
                icon = Icons.Filled.Favorite,
                label = "HRV",
                value = vd?.avgHrv?.let { it.roundToInt().toString() } ?: NO_DATA,
                unit = "ms",
                hue = Palette.metricCyan,
            )
            HeroMetricDivider()
            HeroMetricRow(
                icon = Icons.Filled.MonitorHeart,
                label = "Resting HR",
                value = vd?.restingHr?.toString() ?: NO_DATA,
                unit = "bpm",
                hue = Palette.metricRose,
            )
            HeroMetricDivider()
            HeroMetricRow(
                icon = Icons.Filled.Air,
                label = "Respiratory",
                value = vd?.respRateBpm?.let { String.format(Locale.US, "%.1f", it) } ?: NO_DATA,
                unit = "rpm",
                hue = Palette.sleepLight,
            )
            // ONE provenance footnote when these are carried prior-day vitals — matching the carried Charge
            // ring's "Last night · <date>" stamp so the whole recovery side is labelled as a prior read.
            if (carriedDay != null) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = Metrics.space14, vertical = Metrics.space12)
                        .semantics { contentDescription = "These vitals are from last night ${lastChargeDateLabel(carriedDay.day)}" },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Icon(
                        Icons.Filled.History,
                        contentDescription = null,
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(13.dp),
                    )
                    Text(
                        carriedCaption(carriedDay.day),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
            }
        }
    }
}

@Composable
private fun HeroMetricRow(icon: ImageVector, label: String, value: String, unit: String, hue: Color) {
    val hasValue = value != NO_DATA
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.space14, vertical = Metrics.space12)
            .semantics { contentDescription = "$label $value $unit" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = hue, modifier = Modifier.size(17.dp))
        Spacer(Modifier.width(Metrics.space12))
        Text(label, style = NoopType.subhead, color = Palette.textSecondary, modifier = Modifier.weight(1f))
        Text(
            value,
            style = NoopType.bodyNumber,
            color = if (hasValue) Palette.textPrimary else Palette.textTertiary,
        )
        if (hasValue) {
            Spacer(Modifier.width(Metrics.space4))
            Text(unit, style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}

@Composable
private fun HeroMetricDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(Metrics.divider)
            .background(Palette.hairline.copy(alpha = 0.5f)),
    )
}

// MARK: - "Your cards" dashboard (WHOOP "My Dashboard") — iOS yourCardsSection parity
//
// A persisted, reorderable selection of metric cards surfaced on Today as flat WHOOP metric ROWS. The
// section header carries the "Your cards" overline + a right-aligned BLUE "CUSTOMISE" text action; each row
// is a leading tinted icon tile + UPPERCASE tracked label over a grey baseline caption on the left, and the
// big white value + small unit + chevron on the right. A card with no value yet renders a dash rather than
// vanishing. Mirrors iOS TodayView.yourCardsSection / pinnedCardRow / dashboardValue / dashboardTint.

@Composable
private fun YourCardsSection(
    cards: List<DashboardCard>,
    day: DailyMetric?,
    carriedDay: DailyMetric?,
    stress: Double?,
    fitnessAge: Double?,
    vitality: Double?,
    importedStepsForDay: Int?,
    estimatedStepsForDay: Int?,
    latestActiveKcal: Double?,
    hydrationTotalMl: Double,
    hydrationGoalMl: Int,
    onOpenHydration: () -> Unit,
    onOpenStress: () -> Unit,
    onOpenHealth: () -> Unit,
    onOpenSleep: () -> Unit,
    onCustomise: () -> Unit,
) {
    Box(modifier = Modifier.fillMaxWidth().staggeredAppear(2)) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            // Header: "YOUR CARDS" overline + a right-aligned blue CUSTOMISE action (the WHOOP ✎ affordance).
            Row(verticalAlignment = Alignment.CenterVertically) {
                Overline("Your cards", modifier = Modifier.weight(1f))
                TextButton(
                    onClick = onCustomise,
                    colors = ButtonDefaults.textButtonColors(contentColor = Palette.accent),
                    modifier = Modifier.semantics { contentDescription = "Customise your cards" },
                ) {
                    Icon(
                        Icons.Filled.Tune,
                        contentDescription = null,
                        modifier = Modifier.size(14.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        "CUSTOMISE",
                        style = NoopType.overline.copy(letterSpacing = 0.4.sp),
                        color = Palette.accent,
                    )
                }
            }
            cards.forEach { card ->
                DashboardCardRow(
                    card = card,
                    value = dashboardCardValue(
                        card = card,
                        day = day,
                        carriedDay = carriedDay,
                        stress = stress,
                        fitnessAge = fitnessAge,
                        vitality = vitality,
                        importedStepsForDay = importedStepsForDay,
                        estimatedStepsForDay = estimatedStepsForDay,
                        latestActiveKcal = latestActiveKcal,
                        hydrationTotalMl = hydrationTotalMl,
                        hydrationGoalMl = hydrationGoalMl,
                    ),
                    tint = dashboardCardTint(card),
                    // #706/#684: every card now opens its detail, matching iOS. The Stress card -> Stress; the
                    // overnight vitals (HRV / Resting HR / Respiratory / SpO₂ / Skin Temp) + Fitness age /
                    // Vitality / Steps / Calories -> Health (the vital-signs surface, the iOS HealthView twin);
                    // Sleep -> Sleep; Hydration -> Hydration. The whole row is the button, the chevron the hint.
                    onClick = dashboardCardDestination(
                        card = card,
                        onOpenStress = onOpenStress,
                        onOpenHealth = onOpenHealth,
                        onOpenSleep = onOpenSleep,
                        onOpenHydration = onOpenHydration,
                    ),
                )
            }
        }
    }
}

/** The detail-screen callback a dashboard card opens when tapped, or null if it has no destination. Mirrors
 *  the iOS dashboardCardRow switch: Stress -> Stress; the overnight vitals + Fitness age / Vitality / Steps /
 *  Calories -> Health (the vital-signs hub); Sleep -> Sleep; Hydration -> Hydration. Every card resolves to a
 *  destination, so the chevron is always honest (#706/#684). */
private fun dashboardCardDestination(
    card: DashboardCard,
    onOpenStress: () -> Unit,
    onOpenHealth: () -> Unit,
    onOpenSleep: () -> Unit,
    onOpenHydration: () -> Unit,
): () -> Unit = when (card) {
    DashboardCard.STRESS -> onOpenStress
    DashboardCard.SLEEP -> onOpenSleep
    DashboardCard.HYDRATION -> onOpenHydration
    // Fitness age / Vitality + every overnight vital + steps/calories share the Health detail surface.
    DashboardCard.FITNESS_AGE, DashboardCard.VITALITY, DashboardCard.HRV, DashboardCard.RESTING_HR,
    DashboardCard.RESPIRATORY, DashboardCard.BLOOD_OXYGEN, DashboardCard.SKIN_TEMP,
    DashboardCard.STEPS, DashboardCard.CALORIES -> onOpenHealth
}

/** A dashboard card's WHOOP-token tint (icon + accent). Score cards take their domain colour; vitals take
 *  their biometric hue; everything else the blue accent. No gold (WHOOP), tokens only. Mirrors iOS
 *  dashboardTint. */
private fun dashboardCardTint(card: DashboardCard): Color = when (card) {
    DashboardCard.STRESS -> Palette.effortColor
    DashboardCard.FITNESS_AGE -> Palette.chargeColor
    DashboardCard.VITALITY -> Palette.restColor
    DashboardCard.HRV -> Palette.metricPurple
    DashboardCard.RESTING_HR -> Palette.metricRose
    DashboardCard.RESPIRATORY -> Palette.accent
    DashboardCard.BLOOD_OXYGEN -> Palette.metricCyan
    DashboardCard.SKIN_TEMP -> Palette.metricAmber
    DashboardCard.SLEEP -> Palette.restColor
    DashboardCard.STEPS -> Palette.metricCyan
    DashboardCard.CALORIES -> Palette.metricAmber
    DashboardCard.HYDRATION -> Palette.metricCyan
}

/**
 * Resolve a dashboard card's CURRENT display value from the values Today already loads, with its unit
 * suffix appended. Returns a dash when the value isn't available yet — never a fabricated number. Reuses
 * the SAME reads the rest of Today uses (displayMetric vitals, the pinned Stress / Fitness age / Vitality,
 * steps, calories, sleep duration). Mirrors iOS dashboardValue.
 *
 * The overnight-vital cards (HRV / Resting HR / Respiratory / SpO₂ / Skin Temp / Sleep) read
 * `carriedDay ?: day` — the SAME carry-over the HeroMetricRows + Key-Metrics tiles use (#543) — so right
 * after the logical-day rollover, before tonight is scored, they show last night's carried values instead
 * of blanking to "No Data". Steps / Calories stay on today's own row (they accrue through the day, never
 * a recovery-night carry). Stress / Fitness age / Vitality come from their own resolved loads.
 */
private fun dashboardCardValue(
    card: DashboardCard,
    day: DailyMetric?,
    carriedDay: DailyMetric?,
    stress: Double?,
    fitnessAge: Double?,
    vitality: Double?,
    importedStepsForDay: Int?,
    estimatedStepsForDay: Int?,
    latestActiveKcal: Double?,
    hydrationTotalMl: Double,
    hydrationGoalMl: Int,
): String {
    fun withUnit(s: String): String =
        if (s == NO_DATA) NO_DATA else if (card.unit.isEmpty()) s else "$s ${card.unit}"

    // The overnight vitals carry over from the last scored night; today's accruing totals do not.
    val vd = carriedDay ?: day

    return when (card) {
        DashboardCard.HRV ->
            withUnit(vd?.avgHrv?.let { it.roundToInt().toString() } ?: NO_DATA)
        DashboardCard.RESTING_HR ->
            withUnit(vd?.restingHr?.toString() ?: NO_DATA)
        DashboardCard.RESPIRATORY ->
            withUnit(vd?.respRateBpm?.let { String.format(Locale.US, "%.1f", it) } ?: NO_DATA)
        DashboardCard.BLOOD_OXYGEN ->
            vd?.spo2Pct?.let { String.format(Locale.US, "%.0f%%", it) } ?: NO_DATA
        DashboardCard.SKIN_TEMP ->
            // Stored as a deviation from baseline (°C); show it signed so +/- reads honestly.
            vd?.skinTempDevC?.let { String.format(Locale.US, "%+.1f°", it) } ?: NO_DATA
        DashboardCard.SLEEP -> sleepValue(vd)
        DashboardCard.STEPS -> {
            val real = day?.steps?.let { intStringGrouped(it.toDouble()) }
                ?: importedStepsForDay?.let { intStringGrouped(it.toDouble()) }
            val est = estimatedStepsForDay?.let { intStringGrouped(it.toDouble()) }
            real ?: est ?: NO_DATA
        }
        DashboardCard.CALORIES ->
            withUnit(latestActiveKcal?.let { intStringGrouped(it) } ?: NO_DATA)
        DashboardCard.STRESS ->
            // #706/#684: Stress is baseline-relative, so until the strap has banked enough worn nights to
            // seed the 30-day RHR/HRV baseline StressScreen reads, the front card has no number to show. The
            // old `?: NO_DATA` rendered a bare dash that read like a broken card; show the honest calibrating
            // state instead, matching the owner's reply on #706 and the StressScreen empty/calibrating copy.
            stress?.let { it.roundToInt().toString() } ?: STRESS_CALIBRATING
        DashboardCard.FITNESS_AGE ->
            withUnit(fitnessAge?.let { it.roundToInt().toString() } ?: NO_DATA)
        DashboardCard.VITALITY ->
            vitality?.let { it.roundToInt().toString() } ?: NO_DATA
        DashboardCard.HYDRATION ->
            // "<total> / <goal> L" in litres to 1 dp, e.g. "1.2 / 3.2 L". Always shows a value (a fresh
            // day reads "0.0 / 3.2 L"), since the goal is always derivable from the profile.
            String.format(
                Locale.US, "%.1f / %.1f L",
                hydrationTotalMl / 1000.0, hydrationGoalMl / 1000.0,
            )
    }
}

/**
 * One WHOOP "My Dashboard" metric row: a thin-line tinted icon tile, an UPPERCASE tracked label over a grey
 * baseline caption, the big white value + small unit, and a chevron — on the flat frosted card surface (no
 * glow), tokens only. Mirrors iOS pinnedCardRow. The whole row is the tap target: when [onClick] is set it
 * pushes that card's detail (the chevron is the hint), matching iOS (#706/#684).
 */
@Composable
private fun DashboardCardRow(
    card: DashboardCard,
    value: String,
    tint: Color,
    onClick: (() -> Unit)? = null,
) {
    // A real number renders white; a placeholder (No Data, or the Stress calibrating state) renders dimmed.
    val hasValue = value != NO_DATA && value != STRESS_CALIBRATING
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cardRadius))
            .frostedCardSurface(cornerRadius = Metrics.cardRadius)
            .let { if (onClick != null) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 13.dp, vertical = 11.dp)
            .semantics { contentDescription = "${card.title}: $value" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(tint.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(card.icon, contentDescription = null, tint = tint, modifier = Modifier.size(17.dp))
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                card.title.uppercase(),
                style = NoopType.overline.copy(letterSpacing = 0.4.sp),
                color = Palette.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                card.subtitle,
                style = NoopType.footnote,
                color = Palette.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            value,
            style = NoopType.title2.copy(fontWeight = FontWeight.SemiBold),
            color = if (hasValue) Palette.textPrimary else Palette.textTertiary,
            maxLines = 1,
        )
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(Metrics.iconSmall),
        )
    }
}

/** #760/#792: the caption under an ESTIMATED Steps tile: "est. · <status detail>", where the detail is the
 *  engine's own STATUS line (manual k, or k=… from N days + confidence tier) built from the SAME persisted
 *  calibration the estimate used. So a WHOOP 4.0 user can see WHY the number reads as it does (and why it may
 *  look frozen at low confidence) right where they notice the "est." flag. Falls back to a bare "est." when no
 *  coefficient is recorded yet. Mirrors iOS `stepsEstimateCaption`. */
private fun stepsEstimateCaption(profileStore: ProfileStore): String {
    if (profileStore.stepsCalibrationCoefficient <= 0.0) return "est."
    val status: StepsEstimateEngine.CalibrationStatus = if (profileStore.stepsCalibrationManual) {
        StepsEstimateEngine.CalibrationStatus.Manual(
            coefficient = profileStore.stepsCalibrationCoefficient,
            sampleDays = profileStore.stepsCalibrationSampleDays,
        )
    } else {
        StepsEstimateEngine.CalibrationStatus.Calibrated(
            coefficient = profileStore.stepsCalibrationCoefficient,
            sampleDays = profileStore.stepsCalibrationSampleDays,
            confidence = profileStore.stepsCalibrationConfidence,
        )
    }
    return "est. · ${status.detail}"
}

/** Group-separated integer display from a Double (e.g. 12 345 steps), matching the Apple Health tiles. A
 *  file-internal twin of the private [intString] so the dashboard rows format steps/calories identically. */
private fun intStringGrouped(v: Double): String {
    val n = v.roundToInt()
    return if (kotlin.math.abs(n) >= 1000) String.format(Locale.US, "%,d", n) else "$n"
}

// MARK: - "Your cards" dashboard editor (WHOOP "My Dashboard" ✎)
//
// A Today-local dialog for choosing WHICH dashboard cards show and in what order. Display-only: it edits the
// persisted selection, never any stored metric. Enabled cards first (saved order), then the disabled
// remainder in canonical order, so toggling one on drops it at the end of the visible set and every known
// card is listed once. Toggle hides/shows a card; up/down arrows reorder it (no reorder lib — simple arrow
// buttons, matching KeyMetricsEditorDialog). Mirrors iOS DashboardCardsEditorSheet. At least one card must
// stay enabled (an empty dashboard reads as a bug).

@Composable
private fun DashboardCardsEditorDialog(
    initial: List<DashboardCard>,
    onDismiss: () -> Unit,
    onSave: (List<DashboardCard>) -> Unit,
) {
    val items = remember {
        val enabledSet = initial.toHashSet()
        mutableStateListOf<EditableDashboardCard>().apply {
            initial.forEach { add(EditableDashboardCard(it, true)) }
            DashboardCard.canonicalOrder.filter { it !in enabledSet }.forEach { add(EditableDashboardCard(it, false)) }
        }
    }

    fun move(from: Int, to: Int) {
        if (from in items.indices && to in items.indices) {
            val item = items.removeAt(from)
            items.add(to, item)
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            color = Palette.surfaceOverlay,
            shape = RoundedCornerShape(16.dp),
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text("My Dashboard", style = NoopType.title2, color = Palette.textPrimary)
                    Text(
                        "Choose which cards show on Today and reorder them with the arrows. " +
                            "Cards with no value yet show a dash.",
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }

                Column(
                    modifier = Modifier
                        .heightIn(max = 360.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    items.forEachIndexed { index, item ->
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Switch(
                                checked = item.enabled,
                                onCheckedChange = { items[index] = item.copy(enabled = it) },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = Palette.surfaceBase,
                                    checkedTrackColor = Palette.accent,
                                    uncheckedThumbColor = Palette.textSecondary,
                                    uncheckedTrackColor = Palette.surfaceInset,
                                    uncheckedBorderColor = Palette.hairline,
                                ),
                                modifier = Modifier.semantics { contentDescription = "Show ${item.card.title}" },
                            )
                            Spacer(Modifier.width(12.dp))
                            Text(
                                item.card.title,
                                style = NoopType.body,
                                color = if (item.enabled) Palette.textPrimary else Palette.textTertiary,
                                modifier = Modifier.weight(1f),
                            )
                            IconButton(
                                onClick = { move(index, index - 1) },
                                enabled = index > 0,
                                modifier = Modifier.size(Metrics.iconButton),
                            ) {
                                Icon(
                                    Icons.Filled.KeyboardArrowUp,
                                    contentDescription = "Move ${item.card.title} up",
                                    tint = if (index > 0) Palette.textSecondary else Palette.textTertiary,
                                    modifier = Modifier.size(Metrics.iconSmall),
                                )
                            }
                            IconButton(
                                onClick = { move(index, index + 1) },
                                enabled = index < items.lastIndex,
                                modifier = Modifier.size(Metrics.iconButton),
                            ) {
                                Icon(
                                    Icons.Filled.KeyboardArrowDown,
                                    contentDescription = "Move ${item.card.title} down",
                                    tint = if (index < items.lastIndex) Palette.textSecondary else Palette.textTertiary,
                                    modifier = Modifier.size(Metrics.iconSmall),
                                )
                            }
                        }
                        if (index < items.lastIndex) {
                            HorizontalDivider(color = Palette.hairline, thickness = 1.dp)
                        }
                    }
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        onClick = {
                            // Reset to the canonical default: the default selection enabled, rest disabled.
                            items.clear()
                            val enabledSet = DashboardCard.defaultSelection.toHashSet()
                            DashboardCard.defaultSelection.forEach { items.add(EditableDashboardCard(it, true)) }
                            DashboardCard.canonicalOrder.filter { it !in enabledSet }
                                .forEach { items.add(EditableDashboardCard(it, false)) }
                        },
                        colors = ButtonDefaults.textButtonColors(contentColor = Palette.textSecondary),
                    ) { Text("Reset", style = NoopType.body) }
                    Spacer(Modifier.weight(1f))
                    Button(
                        onClick = { onSave(items.filter { it.enabled }.map { it.card }) },
                        // At least one card must stay visible — an empty dashboard reads as a bug, not a choice.
                        enabled = items.any { it.enabled },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) { Text("Done", style = NoopType.captionNumber) }
                }
            }
        }
    }
}

/** One row's working state in the dashboard editor: the card + whether it's currently enabled. */
private data class EditableDashboardCard(val card: DashboardCard, val enabled: Boolean)

/**
 * A1/S4: the Charge breakdown sheet opened by tapping the hero Charge ring. A full-screen surface with a
 * titled top bar (Close) and a scrollable body hosting the existing What-shaped-it breakdown, the
 * Contributors bars and (S4) the folded Readiness card. Built only when shown (the caller gates on
 * showChargeBreakdown), so the heavy rows materialise on tap (#819). Nothing is recomputed here, it reuses
 * the existing sections, which read the SAME carried/today row the ring shows. Mirrors iOS chargeBreakdownSheet.
 */
@Composable
private fun ChargeBreakdownSheet(
    days: List<DailyMetric>,
    displayDay: DailyMetric?,
    carriedDay: DailyMetric?,
    showReadiness: Boolean,
    onClose: () -> Unit,
    onHowCalculated: () -> Unit,
) {
    Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Metrics.screenPadding, vertical = Metrics.gap),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "What shaped your Charge",
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onClose) {
                    Icon(Icons.Filled.Close, contentDescription = "Close", tint = Palette.textSecondary)
                }
            }
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = Metrics.screenPadding)
                    .padding(bottom = Metrics.sectionGap),
                verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap),
            ) {
                // The breakdown self-gates: a calibrating night (empty drivers) renders nothing here, the
                // Contributors + Readiness below still give an honest read, never a blank sheet.
                RecoveryDriversSection(days = days, displayDay = displayDay, carriedDay = carriedDay)
                RecoveryContributorsSection(day = displayDay, carriedDay = carriedDay)
                // S4: the SEPARATE Readiness block now lives here behind the Charge-ring tap (today-only,
                // matching the old inline gate). A one-word read (Push / Maintain / Rest) stays on the hero.
                if (showReadiness) ReadinessSection(days, carriedDay = carriedDay)
                // Everything above is what shaped YOUR Charge today; this opens the general METHOD behind the
                // score, so the two are clearly separated, not conflated. Opens the scoring guide at the
                // Charge section, the same target the per-ring ⓘ buttons use. Mirrors the iOS chargeBreakdown
                // "How Charge is calculated" NavigationLink to ScoringGuideView(initialSection: .charge).
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .clickable(
                            onClickLabel = "How Charge is calculated",
                            onClick = onHowCalculated,
                        )
                        .background(Palette.surfaceInset)
                        .padding(14.dp)
                        .semantics {
                            contentDescription = "How Charge is calculated. The method behind the score."
                        },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(
                        Icons.Filled.Functions,
                        contentDescription = null,
                        tint = DomainTheme.Charge.color,
                        modifier = Modifier.size(14.dp),
                    )
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(1.dp),
                    ) {
                        Text(
                            "How Charge is calculated",
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                        )
                        Text(
                            "The method behind the score, not today's values.",
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(12.dp),
                    )
                }
            }
        }
    }
}

// MARK: - "What shaped it" the engine-computed Charge driver breakdown
//
// The SHARED-CONTRACT driver rows under the Charge ring: one row per REAL term the recovery scorer used,
// each carrying its signed point contribution (deltaPoints), the night's value, the personal baseline it
// was scored against, and a short plain-English verdict. Computed by RecoveryDrivers.chargeDrivers from
// the SAME inputs the Charge ring reads, so a row can never describe a term the score did not use; a
// missing input yields NO row (never a faked zero). The confidence dot + tier tag SURFACE the existing
// ScoreConfidence.forCharge: they are read, not recomputed. Hidden entirely when the day can't score
// (cold-start / no drivers). Byte-aligned with the iOS "What shaped it" section. No em-dashes.

@Composable
private fun RecoveryDriversSection(
    days: List<DailyMetric>,
    displayDay: DailyMetric?,
    carriedDay: DailyMetric? = null,
) {
    // Read the row the Charge ring itself reads: today's own when scored, else the carried last-scored
    // day (#543) so the breakdown matches the carried ring instead of vanishing at the rollover.
    val readDay = carriedDay ?: displayDay
    val drivers = remember(days, readDay) { recoveryChargeDrivers(days, readDay) }
    if (drivers.isEmpty()) return

    val tier = remember(days, readDay) { chargeConfidenceTier(days, readDay) }
    val overline = carriedDay?.let { "Charge · ${carriedCaption(it.day)}" } ?: "Charge"

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        // Header row: section title + the SURFACED confidence pill (dot + tier tag) on the right.
        Row(verticalAlignment = Alignment.Top) {
            Box(modifier = Modifier.weight(1f)) {
                SectionHeader("What shaped it", overline = overline, trailing = "vs your baseline")
            }
            ChargeConfidencePill(tier)
        }
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
                drivers.forEach { DriverRow(it) }
                Text(
                    "Each line is how many points that signal moved Charge versus sitting at your " +
                        "on-device baseline. Approximate, not medical advice.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

/** The SURFACED Charge confidence pill (dot + tier tag). Reads the existing ScoreConfidence, never
 *  recomputes it. SOLID = gold/accent, BUILDING = the blue warning tone, CALIBRATING = neutral slate. */
@Composable
private fun ChargeConfidencePill(tier: ScoreConfidence) {
    val (label, tone) = when (tier) {
        ScoreConfidence.SOLID -> "SOLID" to StrandTone.Accent
        ScoreConfidence.BUILDING -> "BUILDING" to StrandTone.Warning
        ScoreConfidence.CALIBRATING -> "CALIBRATING" to StrandTone.Neutral
    }
    StatePill(title = label, tone = tone)
}

/** One "What shaped it" driver row: an up/down delta chip (signed points, green up / red down),
 *  the label + verdict, and the value over its baseline. Mirrors the iOS driver row layout. */
@Composable
private fun DriverRow(driver: ChargeDriver) {
    val positive = driver.deltaPoints >= 0
    // A zero delta reads neutral (no green/red), not a misleading "good".
    val tone = when {
        driver.deltaPoints > 0 -> Palette.statusPositive
        driver.deltaPoints < 0 -> Palette.statusCritical
        else -> Palette.textTertiary
    }
    val signed = if (driver.deltaPoints > 0) "+${driver.deltaPoints}" else "${driver.deltaPoints}"
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.semantics {
            contentDescription =
                "${driver.label}, ${driver.valueText}, ${driver.baselineText}, " +
                    "$signed points, ${driver.verdict}"
        },
    ) {
        // Signed-point delta chip with a direction glyph.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            modifier = Modifier
                .clip(RoundedCornerShape(Metrics.cornerPill))
                .background(tone.copy(alpha = 0.12f))
                .padding(horizontal = 8.dp, vertical = 4.dp),
        ) {
            if (driver.deltaPoints != 0) {
                Icon(
                    if (positive) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                    contentDescription = null,
                    tint = tone,
                    modifier = Modifier.size(14.dp),
                )
            }
            Text("$signed pts", style = NoopType.captionNumber, color = tone)
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(driver.label, style = NoopType.headline, color = Palette.textPrimary)
            Text(driver.verdict, style = NoopType.footnote, color = Palette.textSecondary)
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(driver.valueText, style = NoopType.captionNumber, color = Palette.textPrimary)
            Text(driver.baselineText, style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}

// MARK: - Recovery contributors (README screen #5) — labelled progress bars
//
// "CONTRIBUTORS" — what drove today's Charge, each as a labelled progress bar in the shared stage/zone
// bar style (inset track, round-capped metric-hue fill, right-aligned read-out). Design-Reset tokens
// (iOS RecoveryContributorsSection parity): HRV reads teal (metricCyan), Resting HR the recovery/Charge
// world (chargeColor), Sleep and Respiratory the blue sleep world. Each bar's fraction is a
// presentation-only normalisation of the day's value to a typical adult span — no scoring/logic change.
// Suppressed entirely until at least one contributor has a value.

@Composable
private fun RecoveryContributorsSection(day: DailyMetric?, carriedDay: DailyMetric? = null) {
    // The row the contributors read from: today's own when it carries recovery, else the carried last
    // scored day (#543) so the bars don't all read "No Data" at the rollover while live HR ticks. The
    // overline stamps "Last night · <date>" when carrying so the prior read isn't passed off as today's.
    val cd = carriedDay ?: day
    val hrv = cd?.avgHrv
    val rhr = cd?.restingHr?.toDouble()
    val sleepMin = cd?.totalSleepMin
    val resp = cd?.respRateBpm
    if (hrv == null && rhr == null && sleepMin == null && resp == null) return

    val overline = carriedDay?.let { "Recovery · ${carriedCaption(it.day)}" } ?: "Recovery"
    SectionHeader("Contributors", overline = overline, trailing = "What drove Charge")
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
            // HRV — higher is better; map a typical 20–120 ms span. Teal (its biometric hue; iOS metricCyan).
            ContributorBar(
                label = "HRV",
                readout = hrv?.let { "${it.roundToInt()} ms" } ?: NO_DATA,
                fraction = hrv?.let { ((it - 20.0) / 100.0) },
                color = Palette.metricCyan,
            )
            // Resting HR — lower is better, so invert a typical 40–80 bpm span. Charge/recovery world (iOS
            // chargeColor — the recovery contributor reads on the WHOOP-green Charge world, not gold).
            ContributorBar(
                label = "Resting HR",
                readout = rhr?.let { "${it.roundToInt()} bpm" } ?: NO_DATA,
                fraction = rhr?.let { 1.0 - ((it - 40.0) / 40.0) },
                color = Palette.chargeColor,
            )
            // Sleep — hours in bed against an 8h target. Blue (sleep world).
            ContributorBar(
                label = "Sleep",
                readout = sleepMin?.let { sleepValue(cd) } ?: NO_DATA,
                fraction = sleepMin?.let { (it / 60.0) / 8.0 },
                color = Palette.sleepLight,
            )
            // Respiratory — stability around a typical 12–20 rpm span. Deep blue (sleep world).
            ContributorBar(
                label = "Respiratory",
                readout = resp?.let { String.format(Locale.US, "%.1f rpm", it) } ?: NO_DATA,
                fraction = resp?.let { 1.0 - ((it - 12.0) / 8.0) },
                color = Palette.sleepDeep,
            )
            Text(
                "Baselines learned on-device over 14 days. Bars are an approximate read of each " +
                    "signal against a typical adult range — not medical advice.",
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

/** One labelled contributor bar in the shared stage/zone-bar style: a label + right-aligned read-out
 *  over an inset track with a round-capped metric-hue fill. A null fraction renders an empty track. */
@Composable
private fun ContributorBar(label: String, readout: String, fraction: Double?, color: Color) {
    val fillFrac = fraction?.coerceIn(0.0, 1.0)?.toFloat() ?: 0f
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space6)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Overline(label, modifier = Modifier.weight(1f))
            Text(readout, style = NoopType.captionNumber, color = Palette.textPrimary)
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(Metrics.progressHeight)
                .clip(RoundedCornerShape(Metrics.cornerPill))
                .background(Palette.surfaceInset)
                .semantics { contentDescription = "$label $readout" }
                .drawBehind { if (fillFrac > 0f) drawContributorFill(color, fillFrac) },
        )
    }
}

private fun DrawScope.drawContributorFill(color: Color, frac: Float) {
    val w = (size.width * frac).coerceAtLeast(size.height)
    val r = size.height / 2f
    drawRoundRect(color = color, size = Size(w, size.height), cornerRadius = CornerRadius(r, r))
}

/**
 * Recent nights carrying a usable nightly HRV — the signal that seeds the recovery baseline. While
 * recovery is still null and this count is in [1, seed), it is the honest "calibrating N of <seed>"
 * progress shown in place of "No Data"; null once recovery exists or no night has data yet. Pure +
 * unit-tested (RecoveryCalibrationTest). Mirrors Baselines.minNightsSeed as the seed gate. (PR #85)
 */
internal fun recoveryCalibrationNights(
    days: List<DailyMetric>,
    hasRecovery: Boolean,
    seed: Int = Baselines.minNightsSeed,
): Int? {
    if (hasRecovery) return null
    // Match the baseline's validity predicate, not just non-null: Baselines.update only advances the
    // recovery seed (nValid) for nights whose avgHrv is within the HRV config bounds, so an implausible
    // out-of-range night must NOT be counted here either — else the displayed N could over-state nValid.
    val cfg = Baselines.hrvCfg
    // Include 0: a brand-new user (no banked nights) reads "Calibrating — 0 of N" on Charge, not a
    // bare "No data" that looks broken (#335). Caller gates past days to null; >= seed → null.
    return days.count { val v = it.avgHrv; v != null && v in cfg.minVal..cfg.maxVal }
        .takeIf { it in 0 until seed }
}

/**
 * The ordered "What shaped it" Charge driver rows for [displayDay], rebuilt PURELY from the visible
 * [days] history (the same in-memory rows the dashboard already shows, imports win field-by-field in
 * the merge), so no engine round-trip is needed and the bars match the Charge ring's own inputs. Folds
 * the whole history (oldest first) into the four-plus-one personal baselines with [Baselines.foldHistory]
 * (byte-identical to the engine's whole-history fold when no manual Recalibrate epoch is set, the common
 * case), then defers to [RecoveryDrivers.chargeDrivers], which scores each row against the SAME inputs
 * [RecoveryScorer.recovery] reads. Empty when the displayed day can't score (cold-start / missing input),
 * so the section hides rather than faking rows. Mirrors the iOS chargeDrivers wiring.
 */
internal fun recoveryChargeDrivers(
    days: List<DailyMetric>,
    displayDay: DailyMetric?,
): List<ChargeDriver> {
    val day = displayDay ?: return emptyList()
    val hrv = day.avgHrv ?: return emptyList()
    val rhr = day.restingHr?.toDouble() ?: return emptyList()

    // Whole-history fold (oldest first), exactly as the engine seeds baselines2.
    val ordered = days.sortedBy { it.day }
    val hrvBase = Baselines.foldHistory(ordered.map { it.avgHrv }, Baselines.hrvCfg)
    if (!hrvBase.usable) return emptyList()
    val rhrBase = Baselines.foldHistory(ordered.map { it.restingHr?.toDouble() }, Baselines.restingHRCfg)
    val respBase = Baselines.foldHistory(ordered.map { it.respRateBpm }, Baselines.respCfg).takeIf { it.usable }

    // sleepPerf: the Rest COMPOSITE (÷100) when stages exist, else raw efficiency, the SAME derivation
    // recomputeRecovery uses, so the Sleep driver scores against the headline's own input.
    val sleepPerf = RestScorer.restFromDaily(day)?.let { it / 100.0 } ?: day.efficiency

    return RecoveryDrivers.chargeDrivers(
        hrv = hrv,
        rhr = rhr,
        resp = day.respRateBpm,
        hrvBaseline = hrvBase,
        rhrBaseline = rhrBase,
        respBaseline = respBase,
        sleepPerf = sleepPerf,
        skinTempDev = day.skinTempDevC,
    )
}

/**
 * The Charge (recovery) [ScoreConfidence] tier for [displayDay] against the HRV baseline folded from
 * [days], surfaced as the confidence dot + tier tag under the "What shaped it" rows. SURFACED, never
 * recomputed differently: it calls [ScoreConfidence.forCharge] with the SAME folded HRV baseline the
 * drivers scored against. Mirrors the iOS surfacing of the existing ScoreConfidence on the recovery screen.
 */
internal fun chargeConfidenceTier(
    days: List<DailyMetric>,
    displayDay: DailyMetric?,
): ScoreConfidence {
    val hrvBase: BaselineState =
        Baselines.foldHistory(days.sortedBy { it.day }.map { it.avgHrv }, Baselines.hrvCfg)
    return ScoreConfidence.forCharge(displayDay?.recovery, hrvBase)
}

/**
 * The most recent fully-SCORED recovery day to carry over on TODAY while tonight's recovery hasn't been
 * scored yet (#543) — the ONE prior row every recovery-derived read-out (Charge ring, HRV / resting-HR /
 * respiratory / SpO₂ tiles, Synthesis, Contributors, Readiness) carries over from at the rollover. Pure +
 * unit-tested (TodayMetricTilesTest). [days] is oldest→newest; the chosen row is the last with a non-null
 * recovery that isn't today's (still-null) [selectedDayKey]. Returns null unless it's today, today itself
 * isn't scored, and we're not mid-calibration (calibration owns its own copy) — so past days / a scored
 * today / a calibrating today carry nothing and live behaviour is unchanged. Mirrors iOS.
 */
internal fun lastScoredRecoveryDay(
    days: List<DailyMetric>,
    selectedDayKey: String,
    isToday: Boolean,
    todayScored: Boolean,
    isCalibrating: Boolean,
    // #547 carry-over guard: the local "today" key ("yyyy-MM-dd"). A stray FUTURE-dated row (a bad strap
    // clock wrote a day past today) must NEVER be picked as "last night" — that's how #547's Today header
    // read "12 Jul". Cheap belt-and-suspenders alongside the ingest gate + heal: filter candidates to
    // day <= today so even a future row that slipped through can't surface here. ISO date keys sort
    // chronologically, so a plain string compare is correct. Defaulted to MAX so an un-updated call site
    // keeps the prior behaviour; the Today call site passes the real local today.
    today: String = "9999-12-31",
): DailyMetric? {
    if (!isToday || todayScored || isCalibrating) return null
    return days.lastOrNull { it.recovery != null && it.day != selectedDayKey && it.day <= today }
}

/** A prior day's Charge carried over on TODAY (value + "Last night · <date>" caption) while tonight's
 *  recovery hasn't been scored yet (#543). Mirrors the iOS lastScoredCharge tuple. */
internal data class LastCharge(val value: Double, val caption: String)

/** "d MMM" for a stored `yyyy-MM-dd` day key, used by the carried-over Charge caption (#543). Parses
 *  the key and falls back to the raw key so the caption is never empty. Mirrors iOS lastChargeDateFmt. */
internal fun lastChargeDateLabel(dayKey: String): String =
    runCatching {
        LocalDate.parse(dayKey).format(DateTimeFormatter.ofPattern("d MMM", Locale.US))
    }.getOrDefault(dayKey)

/** Carry-over recency cap (#779): the "Last night" framing only holds when the carried scored day is
 *  within this many days of today. Mirrors iOS TodayView.carryFreshnessDays. */
internal const val CARRY_FRESHNESS_DAYS = 2L

/** True when the carried scored day is OLDER than the freshness cap (#779), which drives the "Latest
 *  sleep" relabel. Pure + unit-testable. Both keys are "yyyy-MM-dd"; an unparseable key (or non-positive gap)
 *  reads as fresh so we never over-claim staleness. [today] is today's key (carry-over is today-only),
 *  defaulted to the device's current date for the composable call sites. Mirrors iOS isCarryStale. */
internal fun isCarryStale(priorDayKey: String, today: String = LocalDate.now().toString()): Boolean =
    runCatching {
        ChronoUnit.DAYS.between(LocalDate.parse(priorDayKey), LocalDate.parse(today)) > CARRY_FRESHNESS_DAYS
    }.getOrDefault(false)

/** The carried recovery caption stamp, keyed on that scored day's own date and its recency. Within the
 *  freshness cap it reads "Last night · <date>"; once the carried day is older than the cap (#779) it reads
 *  "Latest sleep · <date>" so a weeks-old import is never surfaced as "Last night". Shared by every carried
 *  recovery read-out so the prior-day provenance reads identically. Mirrors iOS carriedCaption. */
internal fun carriedCaption(priorDayKey: String, today: String = LocalDate.now().toString()): String {
    val prefix = if (isCarryStale(priorDayKey, today)) "Latest sleep" else "Last night"
    return "$prefix · ${lastChargeDateLabel(priorDayKey)}"
}

// ════════════════════════════════════════════════════════════════════════════════════════════════════
// Explainability layer — COMPONENTS 2, 3, 4 (spec: 2026-06-20-sleep-guidance-explainability.md)
//
// "No bare number without a STATE, a REASON, and a NEXT STEP." Every uncertain or derived read-out on
// Today gets a clear state, a plain-English reason and a next step — and we NEVER fabricate a number:
// calibrating / needs-strap show NO value, carried values are always stamped with their date, and the
// provenance badge reflects the REAL per-day merge winner. The copy here is VERBATIM and must match the
// Swift today lane word-for-word (ScoreState / RecordingState). No em-dashes anywhere.
// ════════════════════════════════════════════════════════════════════════════════════════════════════

// ── COMPONENT 2 — explained score states ─────────────────────────────────────────────────────────────

/**
 * The honest state of one score/tile on Today — one state per score, never a bare blank. Derived from
 * baseline readiness + data presence + the #543 carry-over, so a tile that has no own value for the day
 * still says WHY and WHAT to do, and shows no fabricated number. Mirrors Swift `ScoreState` 1:1 (same
 * three cases, same [title] / [detail] copy). [Scored] carries the real value the tile renders normally;
 * the other three are the no-own-number states this layer explains.
 */
sealed class ScoreState {
    /** Today's own value exists — the tile renders the number as usual; this layer adds nothing. */
    data class Scored(val value: Double) : ScoreState()

    /** Baselines still cold-start: [nightsRemaining] more nights of wear until scores get personal.
     *  Shows NO number (calibrating never fakes a value). */
    data class Calibrating(val nightsRemaining: Int) : ScoreState()

    /** A prior scored day shown before tonight is scored (#543 carry-over), stamped with [dateLabel]
     *  ("d MMM") so the prior read is never passed off as today's. [stale] is true when that day is older
     *  than the freshness cap (#779): the carry is still shown so the recovery side isn't a bare blank, but
     *  it's relabelled "Latest sleep" so a weeks-old import is never passed off as "Last night". */
    data class CarriedLastNight(val dateLabel: String, val stale: Boolean = false) : ScoreState()

    /** No data for today at all — strap not worn / not connected / not synced. Shows NO number. */
    object NeedsStrap : ScoreState()

    /** The status title shown in the tile's state slot. VERBATIM — mirror Swift exactly. */
    val title: String
        get() = when (this) {
            is Scored -> ""
            is Calibrating -> "Calibrating"
            is CarriedLastNight -> if (stale) "Latest sleep · $dateLabel" else "Last night · $dateLabel"
            NeedsStrap -> "Needs the strap"
        }

    /** The one-line plain-English what-to-do. VERBATIM — mirror Swift exactly. The night(s) plural in
     *  the calibrating copy follows [nightsRemaining]. */
    val detail: String
        get() = when (this) {
            is Scored -> ""
            is Calibrating -> {
                val nights = if (nightsRemaining == 1) "night" else "nights"
                "Building your baseline. About $nightsRemaining more $nights until your scores are personal."
            }
            is CarriedLastNight ->
                // A fresh post-rollover carry tells you tonight's score is on its way; a stale carry (an
                // older import, #779) instead explains the number is from that earlier session, not today.
                if (stale) "This is your last scored session. Wear the strap overnight for a fresh score."
                else "Tonight's lands after you sleep with the strap on."
            NeedsStrap -> "No data for today. Was your strap worn and connected overnight?"
        }
}

/**
 * Resolve the honest [ScoreState] for the Today score side from the same signals the tiles already use,
 * so the explainer is the EXACT truth on screen (never a separate guess). Pure + unit-tested. Order of
 * precedence mirrors the tile waterfall:
 *   1. [todayRecovery] present                → [ScoreState.Scored] (the tile shows its real number);
 *   2. mid-calibration ([calibratingNights])  → [ScoreState.Calibrating] (N more nights, no number);
 *   3. a prior scored day to carry (#543)     → [ScoreState.CarriedLastNight] (stamped with its date);
 *   4. otherwise                              → [ScoreState.NeedsStrap] (no data, no number).
 * Mirrors Swift `scoreStateForToday`.
 */
internal fun scoreStateForToday(
    todayRecovery: Double?,
    calibratingNights: Int?,
    carriedDay: DailyMetric?,
    seed: Int = Baselines.minNightsSeed,
    today: String = LocalDate.now().toString(),
): ScoreState = when {
    todayRecovery != null -> ScoreState.Scored(todayRecovery)
    // "About N more nights" = the seed gate minus the nights banked so far, floored at 1 (zero would read
    // as "ready" when it isn't). Calibrating never fakes a value.
    calibratingNights != null -> ScoreState.Calibrating((seed - calibratingNights).coerceAtLeast(1))
    // #779: a carry older than the freshness cap is still shown (not a bare blank) but relabelled to
    // "Latest sleep" so a weeks-old import is never passed off as "Last night".
    carriedDay != null -> ScoreState.CarriedLastNight(lastChargeDateLabel(carriedDay.day), isCarryStale(carriedDay.day, today))
    else -> ScoreState.NeedsStrap
}

/** The honest score-state note shown in the Today flow when there is no own number to render — the
 *  state title + one what-to-do line, no fabricated value. [ScoreState.Scored] renders nothing (the
 *  tiles carry the real number). The whole card is the spec's "never a bare blank". Mirrors the iOS
 *  ScoreStateNote. */
@Composable
private fun ScoreStateNote(state: ScoreState) {
    if (state is ScoreState.Scored) return
    val icon = when (state) {
        is ScoreState.Calibrating -> Icons.Filled.Tune
        is ScoreState.CarriedLastNight -> Icons.Filled.History
        ScoreState.NeedsStrap -> Icons.Filled.Warning
        is ScoreState.Scored -> Icons.Filled.Info
    }
    val tint = when (state) {
        ScoreState.NeedsStrap -> Palette.statusWarning
        else -> Palette.textTertiary
    }
    NoopCard {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = "${state.title}. ${state.detail}" },
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier
                    .padding(top = 1.dp)
                    .size(Metrics.iconSmall),
            )
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(state.title, style = NoopType.headline, color = Palette.textPrimary)
                Text(state.detail, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

// ── COMPONENT 3 — recording status ───────────────────────────────────────────────────────────────────

/**
 * The honest live-recording state of the strap, for the Today/Live chip. Derived from the BLE connection
 * + last-sync timestamp so people always know it's working, or know it isn't and why. Mirrors Swift
 * `RecordingState` 1:1 (same three cases, same [title] / [detail] copy, same [tone]).
 */
sealed class RecordingState {
    /** The strap is connected and saving data live. */
    object Recording : RecordingState()

    /** Not live now, but synced [minutesAgo] minutes ago — an honest "how fresh is it". */
    data class LastSynced(val minutesAgo: Long) : RecordingState()

    /** No connection and nothing recent to fall back on. */
    object NotRecording : RecordingState()

    /** #580 — a connected WHOOP 5/MG streaming live HR fine, but its firmware hands over no history
     *  offload yet. NOT the WHOOP-4 "not recording" failure: the link is live, history sync is just
     *  experimental on 5.0. Surfaced from `LiveState.historySyncExperimental`, overriding the resolver. */
    object HistoryExperimental : RecordingState()

    /** The chip's status word. VERBATIM — mirror Swift exactly. */
    val title: String
        get() = when (this) {
            Recording -> "Recording"
            is LastSynced -> "Last synced ${minutesAgo}m ago"
            NotRecording -> "Not recording"
            HistoryExperimental -> "Connected"
        }

    /** The chip's one-line detail. VERBATIM — mirror Swift exactly. */
    val detail: String
        get() = when (this) {
            Recording -> "Your strap is connected and saving data."
            is LastSynced -> "Reconnect to pull the latest."
            NotRecording -> "Strap not connected. Tap to connect."
            HistoryExperimental -> "History sync is experimental on 5.0."
        }

    /** Chip hue: live recording reads positive (gold/green dot), a stale-but-recent sync reads neutral,
     *  not-recording reads critical so a dropped link is obvious; the 5.0 experimental-history state is
     *  connected so it reads accent, not critical. */
    val tone: StrandTone
        get() = when (this) {
            Recording -> StrandTone.Positive
            is LastSynced -> StrandTone.Neutral
            NotRecording -> StrandTone.Critical
            HistoryExperimental -> StrandTone.Accent
        }
}

/**
 * Resolve the honest [RecordingState] from the live BLE state + last-sync timestamp. Pure + unit-tested.
 *   - connected AND a live HR is streaming  → [RecordingState.Recording] (it really is saving data);
 *   - else a [lastSyncAtSec] this session    → [RecordingState.LastSynced] (minutes since, clamped >= 0,
 *                                              ROUNDED UP so a 30s-old sync reads "1m ago" not "0m ago");
 *   - else                                   → [RecordingState.NotRecording].
 * "Recording" requires BOTH a connection AND a live heart-rate sample so a bonded-but-silent link can't
 * claim it's saving data. [nowSec] is unix seconds (injected so the math is testable). Mirrors Swift
 * `recordingStateFor`.
 */
internal fun recordingStateFor(
    connected: Boolean,
    liveHeartRate: Int?,
    lastSyncAtSec: Long?,
    nowSec: Long,
): RecordingState = when {
    connected && liveHeartRate != null -> RecordingState.Recording
    lastSyncAtSec != null -> {
        // Clamp at 0 (a sync stamped slightly in the future from strap-clock skew can't read negative)
        // then ROUND UP so a 30-second-old sync reads "1m ago", never "0m ago" — matches the Swift
        // `RecordingState.resolve` ceil. ceil(secs / 60) == (secs + 59) / 60 for non-negative longs.
        val secs = (nowSec - lastSyncAtSec).coerceAtLeast(0L)
        RecordingState.LastSynced((secs + 59L) / 60L)
    }
    else -> RecordingState.NotRecording
}

/** The Today/Live recording chip: a tinted StatePill with the status word (a pulsing dot while live),
 *  plus the one-line what-it-means below. Honest, never claims "Recording" without a live stream.
 *  Tapping a not-recording chip routes to connect (Settings). Mirrors the iOS RecordingStatusChip. */
@Composable
private fun RecordingStatusChip(state: RecordingState, onConnect: () -> Unit) {
    val clickable = state is RecordingState.NotRecording || state is RecordingState.LastSynced
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(
                if (clickable) {
                    Modifier.clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onConnect,
                    )
                } else {
                    Modifier
                },
            )
            .semantics { contentDescription = "${state.title}. ${state.detail}" },
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        StatePill(
            title = state.title,
            tone = state.tone,
            showsDot = true,
            pulsing = state is RecordingState.Recording,
        )
        Text(
            state.detail,
            style = NoopType.footnote,
            color = Palette.textTertiary,
            modifier = Modifier.weight(1f),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// ── COMPONENT 4 — provenance badge ───────────────────────────────────────────────────────────────────

/**
 * The Today provenance label for the day's REAL merge winner — extends the existing By-Day badge
 * vocabulary consistently. NOOP-computed reads "On-device" (the spec's wording for the By-Day badge,
 * versus the FusedRecord screen's terser "NOOP"), an imported strap day reads "Whoop", and a phone
 * aggregate reads "Apple Health" / "Health Connect". Null when no source owns the day (nothing to
 * stamp). Mirrors the Swift `provenanceBadgeLabel`. */
internal fun dayOwnerSource(deviceId: String?): com.noop.analytics.FusionSource? = when {
    deviceId == null -> null
    deviceId.endsWith("-noop") -> com.noop.analytics.FusionSource.NOOP_COMPUTED
    deviceId == WhoopRepository.APPLE_HEALTH_SOURCE -> com.noop.analytics.FusionSource.APPLE_HEALTH
    deviceId == WhoopRepository.HEALTH_CONNECT_SOURCE -> com.noop.analytics.FusionSource.HEALTH_CONNECT
    // The merged Today rows carry the imported strap deviceId ("my-whoop") on days a real WHOOP import
    // covers, and the "-noop" sibling otherwise; any other strap deviceId is still an imported strap day.
    else -> com.noop.analytics.FusionSource.WHOOP_IMPORT
}

internal fun provenanceBadgeLabel(owner: com.noop.analytics.FusionSource?): String? = when (owner) {
    com.noop.analytics.FusionSource.NOOP_COMPUTED -> "On-device"
    com.noop.analytics.FusionSource.WHOOP_IMPORT -> "Whoop"
    com.noop.analytics.FusionSource.APPLE_HEALTH -> "Apple Health"
    com.noop.analytics.FusionSource.HEALTH_CONNECT -> "Health Connect"
    com.noop.analytics.FusionSource.XIAOMI_BAND -> "Mi Band"
    com.noop.analytics.FusionSource.NUTRITION_CSV -> "Nutrition"
    com.noop.analytics.FusionSource.LOCAL_CACHE -> "Cached"
    null -> null
}

/**
 * PURE mapper (unit-tested) — a RAW resolver source id (as returned by [WhoopRepository.resolvedSeries]'s
 * winning point, e.g. "my-whoop", "my-whoop-noop", "apple-health") onto the spec's provenance labels,
 * given the strap's real [deviceId]. The NOOP-computed strap sibling ("$deviceId-noop") reads "On-device"
 * (scored on THIS device from the raw strap stream); the imported strap source ([deviceId], normally
 * "my-whoop") reads "Whoop"; the Apple-Health source reads "Apple Health". Any other real source (Health
 * Connect, Mi Band, nutrition) keeps its [com.noop.analytics.FusionSource.displayName] — still the genuine
 * merge winner, never a blanket claim. Mirrors the Swift `provenanceDisplayLabel` EXACTLY. This is the
 * PER-METRIC mapper the Today rings use; the day-level [dayOwnerSource]/[provenanceBadgeLabel] pair stays
 * for the legacy By-Day vocabulary.
 */
internal fun provenanceDisplayLabel(
    rawSource: String,
    deviceId: String = WhoopRepository.WHOOP_SOURCE,
): String {
    if (rawSource == "$deviceId-noop") return "On-device"
    if (rawSource == deviceId || rawSource == WhoopRepository.WHOOP_SOURCE) return "Whoop"
    if (rawSource == WhoopRepository.APPLE_HEALTH_SOURCE) return "Apple Health"
    // Fall back to the FusionSource display name for any other known source; else the raw id verbatim.
    return com.noop.analytics.FusionSource.entries.firstOrNull { it.id == rawSource }?.displayName ?: rawSource
}

/** The tint for a per-metric provenance badge, keyed on the resolved LABEL — gold for Whoop, cyan for
 *  Apple Health, the positive status hue for on-device (and anything else). Matches the Data Sources
 *  footer + the Swift `provenanceTint` so the same source reads the same colour on Today. */
internal fun provenanceLabelTint(label: String): Color = when (label) {
    "Whoop" -> Palette.accent
    "Apple Health" -> Palette.metricCyan
    "Health Connect" -> Palette.metricPurple
    else -> Palette.statusPositive
}

// NOTE: the blanket day-level `TodayProvenanceBadge` was removed — Today provenance is now PER-METRIC,
// rendered as a SourceBadge under each hero ring (see HeroRingColumn + ScoreHeroRow), resolving the real
// field-by-field merge winner per WhoopRepository.mergeDaily. The pure `dayOwnerSource` /
// `provenanceBadgeLabel` By-Day mappers are kept (Intelligence/Trends + tests still use that vocabulary).

/**
 * The full 14-day metric grid, mirroring the macOS LazyVGrid order:
 * Charge, Effort, Rest, HRV, Resting HR, Blood Oxygen, Respiratory,
 * Steps, Weight, Calories. Each tile is a fixed-height [SparkStatTile] so the
 * grid tiles perfectly with no empty cells.
 */
@Composable
private fun MetricGrid(
    d: DailyMetric?,
    w: Window,
    recoveryCalibration: Int? = null,
    lastScoredCharge: LastCharge? = null,
    carriedDay: DailyMetric? = null,
    unitSystem: UnitSystem = UnitSystem.METRIC,
    effortScale: EffortScale = EffortScale.HUNDRED,
    latestWeightKg: Double? = null,
    profileWeightKg: Double = 75.0,
    importedStepsForDay: Int? = null,
    estimatedStepsForDay: Int? = null,
    // #760/#792: the caption under an ESTIMATED Steps tile: the engine's STATUS line (manual k, or
    // k=… from N days + confidence tier) so a frozen-looking estimate self-explains. Built from the SAME
    // persisted calibration the estimate used; defaults to a bare "est." for callers that don't supply it.
    stepsEstimateCaption: String = "est.",
    restScore: Double? = null,
    // The Rest tile's sparkline: the trailing-window Rest composite (0–100, `sleep_performance`), so the
    // mini-graph tracks the Rest SCORE rather than raw sleep minutes (#614 follow-up). Other tiles still
    // read their series off `w` (the DailyMetric windows).
    restSpark: List<Double> = emptyList(),
    enabledMetrics: List<KeyMetric> = KeyMetric.defaultOrder,
    isToday: Boolean = false,
    onScoreInfo: (ScoreSection) -> Unit = {},
    // S5: cap the grid to the first METRICS_COLLAPSED_CAP tiles behind a "Show all metrics" expander,
    // collapsing OVERFLOW only (never dropping or reordering a user-selected tile, #251). Defaults keep the
    // grid fully expanded for any caller that doesn't opt into the cap.
    metricsExpanded: Boolean = true,
    onToggleMetrics: () -> Unit = {},
) {
    // The "Last night · <date>" caption carried recovery-vital tiles show in place of their unit when
    // they're showing the prior scored day's value (#543); null when not carrying. Mirrors iOS.
    val carriedVitalCaption = carriedDay?.let { carriedCaption(it.day) }
    // One builder per tile, keyed by KeyMetric so the grid can be filtered + reordered per the saved
    // layout (#251). Each builder is byte-for-byte the tile that used to be hard-coded in the list — the
    // refactor only changes WHICH tiles render and in WHAT order, never how an individual tile looks.
    val builders: Map<KeyMetric, @Composable (Modifier) -> Unit> = mapOf(
        KeyMetric.CHARGE to { m ->
            // Order of precedence: today's own scored recovery → mid-calibration "N of 4" → the last
            // scored day carried over ("Last night · <date>", #543) so a post-rollover today that isn't
            // scored yet keeps a real Charge instead of a bare "No Data" while live HR ticks → NO_DATA
            // only when there is genuinely nothing banked anywhere. The carry-over shows the PRIOR value
            // labelled as prior — it never fabricates a number for the new day. Mirrors iOS.
            SparkStatTile(
                modifier = m,
                label = "Charge",
                value = d?.recovery?.let { "${it.roundToInt()}%" }
                    ?: recoveryCalibration?.let { "$it/${Baselines.minNightsSeed}" }
                    ?: lastScoredCharge?.let { "${it.value.roundToInt()}%" } ?: NO_DATA,
                // H10: cold-start Charge — when there's no score, no "N of 4" calibration count and nothing
                // carried, fall back to the honest "Building, wear it tonight" hint (today only) instead of
                // a captionless "No Data". Past days stay bare (buildingHint returns null off-today).
                caption = d?.recovery?.let {
                    Palette.recoveryState(it).lowercase().replaceFirstChar { c -> c.uppercase() }
                } ?: recoveryCalibration?.let { "Calibrating" } ?: lastScoredCharge?.caption
                    ?: buildingHint(KeyMetric.CHARGE, isToday),
                accent = d?.recovery?.let { Palette.recoveryColor(it) }
                    ?: lastScoredCharge?.let { Palette.recoveryColor(it.value) } ?: Palette.textTertiary,
                spark = w.recovery,
                sparkColor = Palette.accent,
            )
        },
        KeyMetric.EFFORT to { m ->
            // Unscored TODAY → a short "building" hint instead of the "of N" axis caption, so a fresh
            // user reads "coming" not "broken" (#527); a scored day keeps "of N", a past day stays bare.
            SparkStatTile(
                modifier = m,
                label = "Effort",
                value = d?.strain?.let { UnitFormatter.effortDisplay(it, effortScale) } ?: NO_DATA,
                caption = d?.strain?.let { "of ${UnitFormatter.effortScaleMax(effortScale)}" }
                    ?: buildingHint(KeyMetric.EFFORT, isToday),
                accent = d?.strain?.let { Palette.effortTint(it / StrainScorer.maxStrain) } ?: Palette.textTertiary,
                spark = w.strain,
                sparkColor = Palette.strain066,
                onInfo = { onScoreInfo(ScoreSection.EFFORT) },
            )
        },
        KeyMetric.REST to { m ->
            // Unscored TODAY → "building, wear it tonight" instead of a lone dash, so a fresh user reads
            // "coming" not "broken" (#527); a scored day keeps its sleep caption, a past day stays bare.
            // H9 — when the night IS scored but its staging is low-confidence (a high-efficiency night with
            // implausibly low deep+REM, per the core's ScoreConfidence rule), badge it "Estimated" so the
            // stage figures read honestly. Only shown alongside a real score; never on a "building" tile.
            SparkStatTile(
                modifier = m,
                label = "Rest",
                value = restScore?.let { "${it.roundToInt()}%" } ?: NO_DATA,
                // Scored → the sleep-duration caption. Unscored TODAY → the "building" hint. Unscored
                // PAST day → keep the sleep caption (honest: missing score, not mid-calibration).
                caption = if (restScore != null) restCaption(d)
                          else buildingHint(KeyMetric.REST, isToday) ?: restCaption(d),
                accent = restScore?.let { Palette.recoveryColor(it) } ?: Palette.textTertiary,
                // The Rest composite (0–100) trend, not raw sleep minutes — tracks the score above (#614).
                spark = restSpark,
                sparkColor = Palette.metricPurple,
                onInfo = { onScoreInfo(ScoreSection.REST) },
                badge = if (restScore != null && restStageLowConfidence(d)) "Estimated" else null,
            )
        },
        KeyMetric.HRV to { m ->
            // Carry the last scored night's HRV at the rollover (#543) — today's wins (unit caption), the
            // carried value is stamped "Last night · <date>", a never-scored metric still shows "No Data".
            val today = d?.avgHrv
            val carried = today ?: carriedDay?.avgHrv
            SparkStatTile(
                modifier = m,
                label = "HRV",
                value = carried?.let { "${it.roundToInt()}" } ?: NO_DATA,
                caption = if (today != null) "ms" else carried?.let { carriedVitalCaption },
                accent = carried?.let { Palette.metricPurple } ?: Palette.textTertiary,
                spark = w.hrv,
                sparkColor = Palette.metricPurple,
            )
        },
        KeyMetric.RESTING_HR to { m ->
            val today = d?.restingHr
            val carried = today ?: carriedDay?.restingHr
            SparkStatTile(
                modifier = m,
                label = "Resting HR",
                value = carried?.toString() ?: NO_DATA,
                caption = if (today != null) "bpm" else carried?.let { carriedVitalCaption },
                accent = carried?.let { Palette.metricRose } ?: Palette.textTertiary,
                spark = w.rhr,
                sparkColor = Palette.metricRose,
            )
        },
        KeyMetric.BLOOD_OXYGEN to { m ->
            val today = d?.spo2Pct
            val carried = today ?: carriedDay?.spo2Pct
            SparkStatTile(
                modifier = m,
                label = "Blood Oxygen",
                value = carried?.let { String.format(Locale.US, "%.0f%%", it) } ?: NO_DATA,
                // H10: with no reading today and nothing carried, say the overnight SpO₂ is still building
                // (today only) rather than a captionless "No Data". A carried night keeps its date stamp.
                caption = if (today != null) "SpO₂" else (carried?.let { carriedVitalCaption }
                    ?: buildingHint(KeyMetric.BLOOD_OXYGEN, isToday)),
                accent = carried?.let { Palette.metricCyan } ?: Palette.textTertiary,
                spark = w.spo2,
                sparkColor = Palette.metricCyan,
            )
        },
        KeyMetric.RESPIRATORY to { m ->
            val today = d?.respRateBpm
            val carried = today ?: carriedDay?.respRateBpm
            SparkStatTile(
                modifier = m,
                label = "Respiratory",
                value = carried?.let { String.format(Locale.US, "%.1f", it) } ?: NO_DATA,
                caption = if (today != null) "rpm" else carried?.let { carriedVitalCaption },
                accent = carried?.let { Palette.accent } ?: Palette.textTertiary,
                spark = w.resp,
                sparkColor = Palette.accent,
            )
        },
        KeyMetric.STEPS to { m ->
            // Steps: prefer a REAL count — the on-device WHOOP 5/MG @57 counter (DailyMetric.steps), then
            // the steps imported from Apple Health / Health Connect for the day. Only when a day has
            // NEITHER do we fall back to the on-device ESTIMATE (steps_est) a WHOOP 4.0 user gets, flagged
            // "est." so it's never mistaken for a measured count — a 4.0 counts steps in the official
            // WHOOP app but doesn't expose them to NOOP over Bluetooth. A day with none shows "No Data".
            // (#107, #150)
            val realSteps = d?.steps ?: importedStepsForDay
            val steps = realSteps ?: estimatedStepsForDay
            SparkStatTile(
                modifier = m,
                label = "Steps",
                value = steps?.let { intString(it.toDouble()) } ?: NO_DATA,
                // An estimated day reads "est." plus the calibration STATUS (k / days / confidence) so a
                // frozen-looking estimate self-explains (#760/#792); the number is never taken as a measured
                // count. H10: with no count at all, say steps are still building today rather than a
                // captionless "No Data" (today only; a past day with no steps stays a bare dash).
                caption = when {
                    realSteps != null -> "steps"
                    estimatedStepsForDay != null -> stepsEstimateCaption
                    else -> buildingHint(KeyMetric.STEPS, isToday)
                },
                accent = steps?.let { Palette.metricCyan } ?: Palette.textTertiary,
                spark = emptyList(),
                sparkColor = Palette.metricCyan,
            )
        },
        KeyMetric.WEIGHT to { m ->
            // Latest Apple Health / Health Connect body weight, else the SI profile weight (#107). The
            // caption stays honest — "from profile" only when we fell back. Always shown in the user's
            // chosen units via the shared UnitFormatter (matches AppleHealthScreen's weight tile).
            val weight = weightTile(latestWeightKg, profileWeightKg, unitSystem)
            SparkStatTile(
                modifier = m,
                label = "Weight",
                value = weight.value,
                caption = weight.caption,
                accent = Palette.accent,
                spark = emptyList(),
                sparkColor = Palette.accent,
            )
        },
        KeyMetric.CALORIES to { m ->
            // On-device APPROXIMATE whole-day active+resting energy from HR alone (DailyMetric
            // .activeKcalEst). A heart-rate estimate, not cloud/clinical parity — shown rounded. (#107)
            SparkStatTile(
                modifier = m,
                label = "Calories",
                value = d?.activeKcalEst?.let { "${intString(it)} kcal" } ?: NO_DATA,
                caption = d?.activeKcalEst?.let { "active · est." },
                accent = d?.activeKcalEst?.let { Palette.metricAmber } ?: Palette.textTertiary,
                spark = emptyList(),
                sparkColor = Palette.metricAmber,
            )
        },
    )

    // Resolve the enabled tiles to their builders, dropping any unknown key defensively.
    val allTiles = enabledMetrics.mapNotNull { builders[it] }
    // S5: slice from the FRONT of the saved order so a pinned/selected tile is never dropped or reordered
    // (#251); only the tail folds behind the expander. Mirrors the iOS visibleKeyMetrics prefix(cap).
    val hasOverflow = allTiles.size > METRICS_COLLAPSED_CAP
    val tiles = if (metricsExpanded || !hasOverflow) allTiles else allTiles.take(METRICS_COLLAPSED_CAP)

    // Two-column grid built from rows so tile heights stay uniform (mirrors the
    // macOS adaptive grid; a fixed 2-up layout reads well on phone widths).
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        tiles.chunked(2).forEach { rowTiles ->
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                rowTiles.forEach { tile -> tile(Modifier.weight(1f)) }
                if (rowTiles.size == 1) Spacer(Modifier.weight(1f))
            }
        }
        // S5: the "Show all metrics" / "Show fewer" expander. Toggles visibility only, never WHICH tiles
        // are enabled or their order (that stays the #251 editor's job). Mirrors iOS metricsExpander.
        if (hasOverflow) {
            val hidden = allTiles.size - METRICS_COLLAPSED_CAP
            TextButton(
                onClick = onToggleMetrics,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.textButtonColors(contentColor = Palette.accent),
            ) {
                Text(
                    if (metricsExpanded) "Show fewer" else "Show all metrics ($hidden)",
                    style = NoopType.footnote,
                )
                Spacer(Modifier.width(4.dp))
                Icon(
                    if (metricsExpanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

// Workouts across every recorded + imported source over [from, to]. Recorded sessions live under
// "my-whoop"; Apple Health and Health Connect imports are stored under their own device ids (since
// #34/#53). Both the "Last Workouts" feed and the HR-graph sport glyphs need the SAME union, or
// Health-Connect-imported sessions get no glyph on the Today trend — so they share this one seam.
private suspend fun WhoopRepository.workoutsAllSources(from: Long, to: Long): List<WorkoutRow> =
    workouts("my-whoop", from, to) +
        workouts("apple-health", from, to) +
        workouts("health-connect", from, to)

// MARK: - Heart-rate trend (today's continuous HR off the strap's own ~1Hz history)
//
// A full-width 24h HR trend, plotted from 5-minute bucket means of the strap's hrSample history
// (offloaded even while the app was closed, so the day reads continuously). Hidden until there are at
// least two buckets, so a strap-only user with no wear today sees nothing rather than an empty chart.
// Mirrors the macOS TodayView.heartRateTrendSection. LineChart spaces points by index (no time axis),
// so the buckets — being uniform 5-min means in time order — read as an even left-to-right day curve.

@Composable
private fun HeartRateTrendCard(
    viewModel: AppViewModel,
    days: List<DailyMetric>,
    selectedDay: LocalDate,
    today: LocalDate,
    displayMetric: DailyMetric? = null,
    effortScale: EffortScale = EffortScale.HUNDRED,
) {
    // "Today" here is the LOGICAL day (rolls at 04:00 local), so in the small hours after midnight the
    // trend keeps the evening's curve — window start at the logical day's own midnight, "since midnight"
    // subtitle, "Today" label — rather than blanking to an empty new-calendar-day axis (#144).
    var buckets by remember { mutableStateOf<List<HrBucket>>(emptyList()) }
    // The night's sleep session overlapping the HR window + the day's workouts — the Overview-HR
    // marker layers (sleep band, Charge at wake, sport glyphs at HR peaks). Loaded off the main
    // thread alongside the buckets; each marker self-hides when its data is absent. (PR #285)
    var sleepToday by remember { mutableStateOf<SleepSession?>(null) }
    var workoutsToday by remember { mutableStateOf<List<WorkoutRow>>(emptyList()) }
    // #605: a WHOOP-4.0 offload banks raw HR samples straight into the hr-sample store WITHOUT touching
    // any DailyMetric row — so a sync that only adds today's HR curve never changes `days`, and keying the
    // reload on `days` alone left this chart frozen on the pre-sync window until something unrelated
    // recomposed it. Re-key on the live sync tokens too: `lastSyncAt` ticks the moment an offload reaches
    // HISTORY_COMPLETE (the banked samples are now final → reload the buckets), and `syncChunksThisSession`
    // advances through a long backfill so the curve fills in progressively rather than only at the end.
    // (No "show a past day curve" fallback — rejected behaviour change; this only re-queries the SAME
    // selected-day window when fresh samples land.) Mirrors the iOS Today HR lane keying off the sync state.
    val live by viewModel.live.collectAsStateWithLifecycle()
    // Re-load when the day list changes (an import updates it), when the day selector moves, and — via the
    // sync tokens — when a strap offload banks fresh HR samples for the current window. Also on first compose.
    LaunchedEffect(days, selectedDay, today, live.lastSyncAt, live.syncChunksThisSession) {
        val zone = ZoneId.systemDefault()
        val start = selectedDay.atStartOfDay(zone).toEpochSecond()
        val nextStart = selectedDay.plusDays(1).atStartOfDay(zone).toEpochSecond()
        val now = System.currentTimeMillis() / 1000
        val end = if (selectedDay == today) now else (nextStart - 1)
        buckets = viewModel.repo.hrBuckets("my-whoop", start, end, 300L)
        // The sleep that ended within the chart window (the night before / this morning) — anchors
        // the band + the Charge-at-wake marker. A wide lower bound catches an onset before midnight.
        sleepToday = runCatching {
            viewModel.repo.sleepSessions("my-whoop", start - 18 * 3600L, end)
                .filter { it.startTs <= end && it.endTs >= start }   // overlaps the window
                .maxByOrNull { it.endTs }
        }.getOrNull()
        // Workouts overlapping the window — each gets a sport glyph at its in-window HR peak.
        // Union every source (not just "my-whoop"): Health-Connect-imported sessions are stored
        // under their own device id, so a strap-only query left them glyph-less here while the
        // "Last Workouts" feed below showed them (#34/#53). The glyph self-hides when no strap HR
        // overlaps, so an import with no matching strap curve simply draws nothing.
        workoutsToday = runCatching {
            viewModel.repo.workoutsAllSources(start - 6 * 3600L, end)
                .filter { it.startTs <= end && it.endTs >= start }
        }.getOrDefault(emptyList())
    }
    if (buckets.size < 2) return

    val bpm = remember(buckets) { buckets.map { it.avgBpm } }
    val latest = bpm.last().roundToInt()
    val min = bpm.min().roundToInt()
    val max = bpm.max().roundToInt()
    val avg = bpm.average().roundToInt()

    val selectedLabel = when (selectedDay) {
        today -> "Today"
        today.minusDays(1) -> "Yesterday"
        else -> selectedDay.format(DateTimeFormatter.ofPattern("d MMM", Locale.US))
    }

    SectionHeader("Heart Rate", overline = selectedLabel)
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Header — mirrors the macOS ChartCard (title + subtitle, trailing read-out).
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Beats per minute")
                    val subtitle = if (selectedDay == today) {
                        "5-minute average | since midnight"
                    } else {
                        "5-minute average | selected day"
                    }
                    Text(
                        subtitle,
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Text("$latest bpm", style = NoopType.chartValueLarge, color = Palette.metricRose)
            }
            // Chart with a max/avg/min Y-axis label column on the left and an HH:mm X-axis row below.
            // The line spaces points by index, but the X labels read each bucket's REAL timestamp in
            // local time (see below) so the axis reads true wall-clock even when the day has gaps (#544).
            Row(
                modifier = Modifier.height(IntrinsicSize.Min),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Column(
                    modifier = Modifier.height(Metrics.chartHeight),
                    verticalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text("$max", style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                    Text("$avg", style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                    Text("$min", style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                }
                // The HR line, with the Overview marker layers (sleep band · Charge · Effort · sport
                // glyphs) overlaid on top — markers are positioned by mapping each event's wall-clock
                // time onto the line's index spacing, so they sit on the same curve. (PR #285)
                OverviewHRChart(
                    buckets = buckets,
                    bpm = bpm,
                    sleep = sleepToday,
                    workouts = workoutsToday,
                    recovery = displayMetric?.recovery,
                    strain = displayMetric?.strain,
                    effortScale = effortScale,
                    modifier = Modifier.weight(1f).height(Metrics.chartHeight),
                )
            }
            // X-axis: start / midpoint / end of the loaded window. Each label is read from the
            // ACTUAL bucket timestamp at that index, converted to the device-local wall clock —
            // NOT idx*5 from midnight. hrBuckets only emits filled 5-min slots (gaps when the strap
            // wasn't worn) and its bucket key is epoch-aligned, so idx*5 mislabelled every tick once
            // the day had a gap and the labels drifted out of step with the time-positioned markers
            // (an evening workout read as if it sat earlier in the day) (#544). The line/markers are
            // already placed by real timestamp, so labelling by real timestamp makes the axis agree.
            Row(modifier = Modifier.fillMaxWidth()) {
                val zone = ZoneId.systemDefault()
                val hhmm = DateTimeFormatter.ofPattern("HH:mm", Locale.US)
                val bucketToTime = { idx: Int ->
                    val b = buckets.getOrNull(idx) ?: buckets.last()
                    Instant.ofEpochSecond(b.bucket).atZone(zone).format(hhmm)
                }
                val xLabels = if (buckets.size >= 3) {
                    listOf(
                        bucketToTime(0),
                        bucketToTime(buckets.size / 2),
                        if (selectedDay == today) "Now" else bucketToTime(buckets.size - 1),
                    )
                } else listOf("Start", "", "Now")
                xLabels.forEach { lbl ->
                    Text(lbl, style = NoopType.footnote, color = Palette.textTertiary, modifier = Modifier.weight(1f))
                }
            }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(Metrics.divider)
                    .background(Palette.hairline),
            )
            Row(modifier = Modifier.fillMaxWidth()) {
                listOf("Min" to min, "Avg" to avg, "Max" to max).forEach { (label, value) ->
                    Column(modifier = Modifier.weight(1f)) {
                        Overline(label, color = Palette.textTertiary)
                        Text("$value bpm", style = NoopType.bodyNumber, color = Palette.textPrimary)
                    }
                }
            }
        }
    }
}

// MARK: - Overview HR chart (WHOOP-style day-in-review annotations)
//
// The 24h HR line — the shared index-spaced [LineChart] — with marker layers drawn ON TOP:
//   (a) a sleep band shading the night's sleep span (indigo, behind the line conceptually but
//       drawn under the marker chrome so labels stay legible),
//   (b) a dashed Charge rule + label at wake time (sleep end), hidden while recovery calibrates,
//   (c) a dashed Effort rule + label at "now" (the latest sample), routed through the SAME
//       UnitFormatter.effortDisplay the Effort tile uses so it honours the 0–100 / 0–21 toggle (#268),
//   (d) a small sport glyph at each workout's in-window HR peak.
//
// LineChart plots points by LIST INDEX (evenly spaced, no time axis), so each marker's wall-clock
// time is mapped to a fractional list index by interpolating against the buckets' own timestamps —
// markers then sit exactly on the rendered curve even when the strap history has gaps. Every layer
// self-hides when its data is absent (no sleep, calibrating Charge, no workouts). Mirrors the macOS
// OverviewHRChart (Packages/StrandDesign) in NOOP's own colour language. (PR #285)

@Composable
private fun OverviewHRChart(
    buckets: List<HrBucket>,
    bpm: List<Double>,
    sleep: SleepSession?,
    workouts: List<WorkoutRow>,
    recovery: Double?,
    strain: Double?,
    effortScale: EffortScale,
    modifier: Modifier,
) {
    // The line itself stays the existing shared component, unchanged — markers are a sibling overlay.
    val minV = bpm.min()
    val maxV = bpm.max()
    val span = (maxV - minV).takeIf { it > 0.0 } ?: 1.0
    val n = bpm.size

    // Geometry constants copied verbatim from LineChart/pointsFor so overlay positions land on the curve.
    val strokePx = 2.5f
    val topPad = strokePx + 4f
    val bottomPad = strokePx + 4f

    // Plot pixel size, captured from the Box that wraps both the line and the overlay.
    var plotW by remember { mutableStateOf(0f) }
    var plotH by remember { mutableStateOf(0f) }
    val density = LocalDensity.current

    // ── time → x helpers ──
    // Fractional list index for a wall-clock unix-seconds time, interpolating between bucket
    // timestamps; null when the time falls outside the loaded buckets.
    fun fracIndexFor(ts: Long): Float? {
        if (n < 2) return null
        val first = buckets.first().bucket
        val last = buckets.last().bucket
        if (ts <= first) return 0f
        if (ts >= last) return (n - 1).toFloat()
        val hi = buckets.indexOfFirst { it.bucket >= ts }
        if (hi <= 0) return 0f
        val lo = hi - 1
        val t0 = buckets[lo].bucket
        val t1 = buckets[hi].bucket
        val f = if (t1 > t0) (ts - t0).toFloat() / (t1 - t0).toFloat() else 0f
        return lo + f
    }
    fun xFor(ts: Long): Float? {
        val fi = fracIndexFor(ts) ?: return null
        return if (n > 1) plotW * fi / (n - 1) else null
    }
    fun yForBpm(v: Double): Float {
        val usableH = (plotH - topPad - bottomPad).coerceAtLeast(1f)
        val norm = ((v - minV) / span).toFloat().coerceIn(0f, 1f)
        return topPad + (1f - norm) * usableH
    }

    // ── derived marker model (self-hiding) ──
    // Sleep band span clamped to the window; only drawn when it overlaps a visible stretch. Uses the
    // EFFECTIVE onset so a hand-edited bedtime moves the band. (PR #395)
    val sleepStartX = sleep?.let { xFor(it.effectiveStartTs) }
    val sleepEndX = sleep?.let { xFor(it.endTs) }
    // Charge marker sits at wake (sleep end), else the window start; hidden while recovery is null.
    val chargeX = recovery?.let { sleep?.let { s -> xFor(s.endTs) } ?: 0f }
    // Effort marker pinned to the latest sample (right edge) when a strain exists.
    val effortX = strain?.let { if (n > 1) plotW else null }

    // One combined TalkBack description for the overlay layers, so the markers (which are otherwise
    // small decorative pills) are announced. Only mentions the layers actually present.
    val markerDescription = remember(sleep, recovery, strain, workouts, effortScale) {
        buildList {
            add("24-hour heart rate")
            if (sleep != null) add("sleep band ${hrHoursMinutes((sleep.endTs - sleep.effectiveStartTs).toInt())}")
            if (recovery != null) add("${recovery.roundToInt()} percent Charge at wake")
            if (strain != null) add("${UnitFormatter.effortDisplay(strain, effortScale)} Effort now")
            if (workouts.isNotEmpty()) add("${workouts.size} workout${if (workouts.size == 1) "" else "s"} marked")
        }.joinToString(", ")
    }

    Box(
        modifier = modifier
            .clipToBounds()
            .onSizeChanged { plotW = it.width.toFloat(); plotH = it.height.toFloat() }
            .semantics { contentDescription = markerDescription },
    ) {
        // #765 (z-order / background layering): the sleep band must sit BEHIND the HR curve, matching the
        // iOS OverviewHRChart whose RectangleMark is "drawn first so the HR line/area sit on top". Android
        // previously drew the band in the SAME Canvas as the dashed rules, AFTER the LineChart, so the
        // translucent indigo region washed OVER the HR line + its value markers (the reported "text behind
        // the chart" / muddied curve). Splitting the band into its OWN Canvas placed BEFORE the LineChart
        // puts it under the curve, exactly like iOS; the wake divider, Charge/Effort rules and glow end-cap
        // stay in the Canvas AFTER the line (iOS draws those marks after the LineMark too, so they read on
        // top). Only the fill moved; same geometry, same colours.
        if (plotW > 0f && plotH > 0f &&
            sleepStartX != null && sleepEndX != null && sleepEndX > sleepStartX) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                drawRect(
                    color = Palette.sleepDeep.copy(alpha = 0.30f),
                    topLeft = Offset(sleepStartX, 0f),
                    size = Size(sleepEndX - sleepStartX, size.height),
                )
            }
        }

        // 1) The HR line (unchanged shared component, tap-to-inspect intact). Sits OVER the sleep band
        // (above) and UNDER the dashed rules + glow end-cap + marker pills (below), mirroring iOS.
        LineChart(
            values = bpm,
            modifier = Modifier.fillMaxSize(),
            color = Palette.metricRose,
            fill = true,
            selectionEnabled = true,
        )

        // 2) Wake divider + dashed rules + glow end-cap, drawn in one Canvas ON TOP of the line.
        if (plotW > 0f && plotH > 0f) {
            val dash = remember { PathEffect.dashPathEffect(floatArrayOf(8f, 8f), 0f) }
            val wakeDash = remember { PathEffect.dashPathEffect(floatArrayOf(3f, 3f), 0f) }
            Canvas(modifier = Modifier.fillMaxSize()) {
                // Wake divider: the sleep-to-day boundary, so the band reads even before Charge calibrates.
                // On top of the line (matching iOS's wake RuleMark after the LineMark).
                if (sleepStartX != null && sleepEndX != null && sleepEndX > sleepStartX &&
                    sleepEndX > 0f && sleepEndX < size.width) {
                    drawLine(
                        color = Palette.sleepLight.copy(alpha = 0.5f),
                        start = Offset(sleepEndX, 0f),
                        end = Offset(sleepEndX, size.height),
                        strokeWidth = 1f,
                        pathEffect = wakeDash,
                    )
                }
                // Charge rule at wake.
                if (chargeX != null && recovery != null) {
                    drawLine(
                        color = Palette.recoveryColor(recovery).copy(alpha = 0.85f),
                        start = Offset(chargeX.coerceIn(0f, size.width), 0f),
                        end = Offset(chargeX.coerceIn(0f, size.width), size.height),
                        strokeWidth = 1.5f,
                        cap = StrokeCap.Round,
                        pathEffect = dash,
                    )
                }
                // Effort rule at now.
                if (effortX != null && strain != null) {
                    val x = (size.width - 1f).coerceIn(0f, size.width)
                    drawLine(
                        color = Palette.effortTint(strain / StrainScorer.maxStrain).copy(alpha = 0.85f),
                        start = Offset(x, 0f),
                        end = Offset(x, size.height),
                        strokeWidth = 1.5f,
                        cap = StrokeCap.Round,
                        pathEffect = dash,
                    )
                }

                // Glowing endpoint at the latest HR sample (right edge) — a Bevel chart end-cap:
                // a soft rose halo + white core sitting on the line's final point.
                if (n >= 2) {
                    val lastX = size.width
                    val lastY = yForBpm(bpm.last())
                    val end = Offset(lastX.coerceIn(0f, size.width), lastY)
                    drawCircle(color = Palette.metricRose.copy(alpha = 0.30f), radius = 9f, center = end)
                    drawCircle(color = Palette.metricRose.copy(alpha = 0.65f), radius = 5.5f, center = end)
                    drawCircle(color = Palette.tipCore, radius = 2.4f, center = end)
                }
            }

            // 3) Marker labels + sport glyphs — positioned composables (crisp text/icons vs Canvas).
            val topPadDp = 10.dp
            // Sleep duration pill at the band's leading edge.
            if (sleepStartX != null && sleep != null && (sleepEndX ?: 0f) > (sleepStartX)) {
                val durLabel = hrHoursMinutes((sleep.endTs - sleep.effectiveStartTs).toInt())
                ChartMarkerPill(
                    text = durLabel,
                    color = Palette.sleepLight,
                    leadingIcon = Icons.Filled.Bedtime,
                    modifier = Modifier.markerOffset(sleepStartX, density, topPadDp),
                )
            }
            if (chargeX != null && recovery != null) {
                ChartMarkerPill(
                    text = "${recovery.roundToInt()}% Charge",
                    color = Palette.recoveryColor(recovery),
                    modifier = Modifier.markerOffset(chargeX, density, topPadDp),
                )
            }
            if (effortX != null && strain != null) {
                ChartMarkerPill(
                    text = "${UnitFormatter.effortDisplay(strain, effortScale)} Effort",
                    color = Palette.effortTint(strain / StrainScorer.maxStrain),
                    modifier = Modifier.markerOffset(plotW, density, topPadDp, alignEnd = true),
                )
            }
            // Sport glyph at each workout's in-window HR peak.
            workouts.forEach { w ->
                val peak = hrPeakIn(buckets, w.startTs, w.endTs)
                if (peak != null) {
                    val px = xFor(peak.bucket)
                    if (px != null) {
                        val py = yForBpm(peak.avgBpm)
                        WorkoutGlyph(
                            icon = sportIcon(w.sport),
                            modifier = Modifier.glyphOffset(px, py, plotW, plotH, density),
                        )
                    }
                }
            }
        }
    }
}

/** "H:MM" for a duration in seconds (e.g. a 6h06m night → "6:06"). Mirrors TodayView.hoursMinutes. */
private fun hrHoursMinutes(seconds: Int): String {
    val h = (if (seconds < 0) 0 else seconds) / 3600
    val m = ((if (seconds < 0) 0 else seconds) % 3600) / 60
    return "$h:${m.toString().padStart(2, '0')}"
}

/** The peak HR bucket whose timestamp falls inside [start, end]; null when none overlap. */
private fun hrPeakIn(buckets: List<HrBucket>, start: Long, end: Long): HrBucket? =
    buckets.filter { it.bucket in start..end }.maxByOrNull { it.avgBpm }

/** Offset a marker pill near plot-x [x] (px). End-aligned markers (Effort) tuck under the right
 *  edge; the rest centre roughly on their anchor. Coerced to ≥ 0 so a pill never starts off-screen. */
private fun Modifier.markerOffset(
    x: Float,
    density: androidx.compose.ui.unit.Density,
    topPad: androidx.compose.ui.unit.Dp,
    alignEnd: Boolean = false,
): Modifier = this.offset(
    x = with(density) {
        // Approx pill half-width for edge clamping (footnote ≈ 7px/char + chrome).
        val xDp = x.toDp()
        if (alignEnd) (xDp - 70.dp).coerceAtLeast(0.dp) else (xDp - 36.dp).coerceAtLeast(0.dp)
    },
    y = topPad,
)

/** Position a 22dp sport glyph centred on a plot point (px), clamped inside the plot. */
private fun Modifier.glyphOffset(
    x: Float,
    y: Float,
    plotW: Float,
    plotH: Float,
    density: androidx.compose.ui.unit.Density,
): Modifier = this.offset(
    x = with(density) { (x.toDp() - 11.dp).coerceIn(0.dp, (plotW.toDp() - 22.dp).coerceAtLeast(0.dp)) },
    y = with(density) { (y.toDp() - 26.dp).coerceIn(0.dp, (plotH.toDp() - 22.dp).coerceAtLeast(0.dp)) },
)

/** Small caps read-out pill for the Charge / Effort / sleep-duration markers. */
@Composable
private fun ChartMarkerPill(
    text: String,
    color: Color,
    modifier: Modifier = Modifier,
    leadingIcon: ImageVector? = null,
) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(6.dp))
            .background(Palette.surfaceOverlay.copy(alpha = 0.92f))
            .padding(horizontal = 6.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (leadingIcon != null) {
            Icon(leadingIcon, contentDescription = null, tint = color, modifier = Modifier.size(10.dp))
        }
        Text(text, style = NoopType.footnote, color = color, maxLines = 1)
    }
}

/** Sport glyph in a tinted badge, anchored above a workout's HR peak. */
@Composable
private fun WorkoutGlyph(icon: ImageVector, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(22.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(Palette.strain033),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = Palette.textPrimary,
            modifier = Modifier.size(13.dp),
        )
    }
}

// MARK: - Today footer sections

private data class TodayFooterState(
    val recentWorkouts: List<WorkoutRow> = emptyList(),
    val whoopDays: Int? = null,
    val whoopWorkouts: Int? = null,
    val appleDays: Int? = null,
    val appleWorkouts: Int? = null,
    val hcDays: Int? = null,
    val hcWorkouts: Int? = null,
)

@Composable
private fun TodayWorkoutsSection(workouts: List<WorkoutRow>) {
    if (workouts.isEmpty()) return

    SectionHeader("Last Workouts", overline = "Activity", trailing = "14 days")
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        workouts.take(4).chunked(2).forEach { rowWorkouts ->
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                rowWorkouts.forEach { workout ->
                    StatTile(
                        modifier = Modifier.weight(1f),
                        label = WorkoutEditing.displaySport(workout.sport),
                        value = workoutDuration(workout),
                        caption = workoutCaption(workout),
                        accent = workout.strain?.let { Palette.effortTint(it / StrainScorer.maxStrain) } ?: Palette.textPrimary,
                        delta = workout.energyKcal?.let { "${it.roundToInt()} kcal" },
                        deltaColor = Palette.metricAmber,
                        // Keep the duration value readable beside the kcal chip on narrow phones — the
                        // chip yields width instead of starving the value down to "4…"/"2…" (#332).
                        compactDelta = true,
                    )
                }
                if (rowWorkouts.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun TodaySourcesSection(
    footer: TodayFooterState,
    strapBatteryPct: Int? = null,
    strapBatteryEstimate: String? = null,
    // S5: collapse to a single "Synced from: ..." summary line by default; tapping expands the full
    // per-source rows + strap battery inline. Nothing is removed, only folded behind a tap.
    expanded: Boolean = true,
    onToggle: () -> Unit = {},
) {
    SectionHeader("Data Sources", overline = "Provenance")
    val whoopPresent = (footer.whoopDays ?: 0) > 0 || strapBatteryPct != null
    val applePresent = (footer.appleDays ?: 0) > 0 || (footer.appleWorkouts ?: 0) > 0
    val hcPresent = (footer.hcDays ?: 0) > 0 || (footer.hcWorkouts ?: 0) > 0
    if (!expanded) {
        // Collapsed: one tappable "Synced from: ..." line. Health Connect folds under the "Apple Watch"
        // bucket in the summary (both are the phone's health store to the audience); the expanded card
        // still lists every source by name, so no provenance detail is lost.
        NoopCard(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClickLabel = "Show what NOOP is synced from", onClick = onToggle),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    syncedFromSummary(hasWhoop = whoopPresent, hasApple = applePresent || hcPresent, hasXiaomi = false),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        return
    }
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // A header row to collapse it back, an obvious "less" cue on the expanded card.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClickLabel = "Hide data source detail", onClick = onToggle),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Synced from", style = NoopType.overline, color = Palette.textTertiary, modifier = Modifier.weight(1f))
                Icon(
                    Icons.Filled.KeyboardArrowUp,
                    contentDescription = null,
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(16.dp),
                )
            }
            Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline))
            SourceRow(
                badge = "Whoop",
                tint = Palette.accent,
                // A live battery reading means the strap IS connected, even before the first banked
                // night, don't contradict it with "Not connected" (#159).
                present = whoopPresent,
                detail = countDetail(footer.whoopDays, footer.whoopWorkouts, "workouts"),
                batteryPct = strapBatteryPct,
                batteryEstimate = strapBatteryEstimate,
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(Palette.hairline),
            )
            SourceRow(
                badge = "Apple Health",
                tint = Palette.metricCyan,
                present = applePresent,
                detail = countDetail(footer.appleDays, footer.appleWorkouts, "workouts"),
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(Palette.hairline),
            )
            SourceRow(
                badge = "Health Connect",
                tint = Palette.metricPurple,
                present = hcPresent,
                detail = countDetail(footer.hcDays, footer.hcWorkouts, "workouts"),
            )
        }
    }
}

@Composable
private fun SourceRow(
    badge: String,
    tint: Color,
    present: Boolean,
    detail: String,
    batteryPct: Int? = null,
    batteryEstimate: String? = null,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        SourceBadge(badge, tint = if (present) tint else Palette.textTertiary)
        // Compact strap-battery readout beside the source badge — same pill + tone bands as the
        // Settings Strap section; absent entirely when there's no live reading (#159).
        batteryPct?.let { pct ->
            Spacer(Modifier.width(8.dp))
            StatePill(title = "$pct%", tone = batteryPillTone(pct), showsDot = false)
            // The "~X left" runtime estimate sits beside the %, dimmer, only when we have a trusted one (#713).
            batteryEstimate?.let { est ->
                Spacer(Modifier.width(6.dp))
                Text(
                    text = est,
                    style = NoopType.captionNumber,
                    color = Palette.textTertiary,
                    maxLines = 1,
                )
            }
        }
        Spacer(Modifier.weight(1f))
        Text(
            text = if (present) detail else "Not connected",
            style = NoopType.captionNumber,
            color = if (present) Palette.textSecondary else Palette.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// MARK: - Readiness card (ported from TodayView.swift readinessSection)
//
// On-device training-readiness synthesis. Calls the analytics ReadinessEngine over the
// view model's day history and renders the macOS card: a colored level dot + headline,
// an optional acute:chronic "load X.XX" read-out, the plain-English summary, then one
// row per driving signal (a small flag-colored dot + label + detail). The whole card is
// suppressed until there is enough history (level == INSUFFICIENT), matching macOS.

@Composable
private fun ReadinessSection(days: List<DailyMetric>, carriedDay: DailyMetric? = null) {
    // Logical day (rolls at 04:00 local), so readiness keeps reading the evening's row in the small
    // hours instead of an empty new-calendar-day row (#144). Mirrors the Today-row resolution.
    //
    // Carry-over (#543): Readiness anchors on the day whose row carries today's vitals. Right after the
    // rollover today has no scored row, so `evaluate` would read INSUFFICIENT and the whole card would
    // VANISH while live HR ticks — the same blank the carried Charge/Synthesis avoid. So when carrying,
    // anchor on the last scored day's key instead, and stamp the overline "Last night · <date>". Honest:
    // it's the real prior read; today's own readiness wins the instant tonight is scored.
    val anchorKey = carriedDay?.day ?: logicalDayKeyNow()
    val readiness = remember(days, anchorKey) { ReadinessEngine.evaluate(days, today = anchorKey) }
    if (readiness.level == ReadinessEngine.Level.INSUFFICIENT) return

    val overline = carriedDay?.let { carriedCaption(it.day) } ?: "Should you push today?"
    SectionHeader("Readiness", overline = overline)
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Headline row: level dot + headline, then the ACWR load read-out.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(readinessColor(readiness.level)),
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    readiness.headline,
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                readiness.acwr?.let { acwr ->
                    Text(
                        "load ${String.format(Locale.US, "%.2f", acwr)}",
                        style = NoopType.captionNumber,
                        color = Palette.textTertiary,
                    )
                }
            }

            // Plain-English summary.
            Text(
                readiness.summary,
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )

            // Per-signal rows: flag dot + fixed-width label + detail.
            if (readiness.signals.isNotEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(1.dp)
                        .background(Palette.hairline),
                )
                readiness.signals.forEach { signal ->
                    Row(verticalAlignment = Alignment.Top) {
                        Box(
                            modifier = Modifier
                                .padding(top = 5.dp)
                                .size(7.dp)
                                .clip(CircleShape)
                                .background(flagColor(signal.flag)),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            signal.label,
                            style = NoopType.caption,
                            color = Palette.textSecondary,
                            modifier = Modifier.width(104.dp),
                        )
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(1.dp),
                        ) {
                            Text(
                                signal.detail,
                                style = NoopType.caption,
                                color = Palette.textTertiary,
                            )
                            // The numbers behind the read (e.g. "48 vs 55 ms"), as a small mono caption —
                            // mirrors the macOS readiness card and the "load X.XX" numeric readout above.
                            signal.evidence?.let { evidence ->
                                Text(
                                    evidence,
                                    style = NoopType.captionNumber,
                                    color = Palette.textTertiary,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * S4 (#205): the one-word readiness read kept on the hero (Push / Maintain / Rest) now the full Readiness
 * card folded into the Charge-ring tap. PURE mapping of the existing [ReadinessEngine.Level]; INSUFFICIENT
 * returns null (the hero then shows no word, matching the old card hiding itself). Byte-identical twin of
 * the Swift TodayView.readinessWord.
 */
internal fun readinessWord(level: ReadinessEngine.Level): String? = when (level) {
    ReadinessEngine.Level.PRIMED -> "Push"
    ReadinessEngine.Level.BALANCED -> "Maintain"
    ReadinessEngine.Level.STRAINED -> "Rest"
    ReadinessEngine.Level.RUNDOWN -> "Rest"
    ReadinessEngine.Level.INSUFFICIENT -> null
}

/**
 * S5: the collapsed Data Sources footer summary, "Synced from: WHOOP, Apple Watch", listing only sources
 * with data (Apple Health reads as "Apple Watch", the device the audience knows), or "No sources yet".
 * PURE + unit-tested. Byte-identical twin of the Swift TodayView.syncedFromSummary.
 */
internal fun syncedFromSummary(hasWhoop: Boolean, hasApple: Boolean, hasXiaomi: Boolean): String {
    val names = buildList {
        if (hasWhoop) add("WHOOP")
        if (hasApple) add("Apple Watch")
        if (hasXiaomi) add("Mi Band")
    }
    return if (names.isEmpty()) "No sources yet" else "Synced from: " + names.joinToString(", ")
}

/** S5: the Key-Metric overflow cap, mirroring TodayView.metricsCollapsedCap (two columns, three rows). */
internal const val METRICS_COLLAPSED_CAP = 6

/** Level → color, mirroring TodayView.readinessColor. */
private fun readinessColor(level: ReadinessEngine.Level): Color = when (level) {
    ReadinessEngine.Level.PRIMED -> Palette.accent
    ReadinessEngine.Level.BALANCED -> Palette.statusPositive
    ReadinessEngine.Level.STRAINED -> Palette.statusWarning
    ReadinessEngine.Level.RUNDOWN -> Palette.metricRose
    ReadinessEngine.Level.INSUFFICIENT -> Palette.textTertiary
}

/** Flag → color, mirroring TodayView.flagColor. */
private fun flagColor(flag: ReadinessEngine.Flag): Color = when (flag) {
    ReadinessEngine.Flag.GOOD -> Palette.accent
    ReadinessEngine.Flag.NEUTRAL -> Palette.textTertiary
    ReadinessEngine.Flag.WATCH -> Palette.statusWarning
    ReadinessEngine.Flag.BAD -> Palette.metricRose
}

// MARK: - SparkStatTile
//
// A fixed-height metric tile: overline label, big value + caption, and a 14-day
// Sparkline anchored along the bottom edge. Mirrors the macOS StatTile-with-sparkline
// while reusing the locked surfaces/typography (NoopCard, Overline, NoopType). Built
// here rather than mutating the shared StatTile so other screens keep the plain tile.

@Composable
private fun SparkStatTile(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    caption: String? = null,
    accent: Color = Palette.textPrimary,
    spark: List<Double> = emptyList(),
    sparkColor: Color = Palette.accent,
    onInfo: (() -> Unit)? = null,
    badge: String? = null,
) {
    NoopCard(modifier = modifier.height(Metrics.tileHeight), padding = Metrics.space14) {
        Column(modifier = Modifier.fillMaxWidth()) {
            // Label row carries the overline, an optional low-confidence [badge] (H9 — e.g. "Estimated"
            // stages), and, for the three headline scores only, a trailing ⓘ that opens the scoring guide
            // at this score. Other tiles render exactly as before.
            if (onInfo != null || badge != null) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Overline(label)
                    if (badge != null) {
                        Spacer(Modifier.width(Metrics.space6))
                        // A tertiary-tinted pill — honest "this is estimated, not measured" signal, the same
                        // muted treatment as a provenance badge so it informs without alarming. (H9)
                        SourceBadge(badge, tint = Palette.textTertiary)
                    }
                    Spacer(Modifier.weight(1f))
                    if (onInfo != null) ScoreInfoButton(section = null, onClick = onInfo, compact = true)
                }
            } else {
                Overline(label)
            }
            Spacer(Modifier.weight(1f))
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Bottom,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    // Shrink-to-fit (down to 0.6×) so a value never ellipsizes to "100%"→"10…" /
                    // "15.5"→"15…" next to the inline sparkline, matching the Swift tile's
                    // minimumScaleFactor (#332). fillMaxWidth() is load-bearing: AutoSizeValue only
                    // shrinks when its Text is given a hard width to overflow against — without it the
                    // single-line Text takes its intrinsic width, `didOverflowWidth` never trips, and
                    // the value silently truncates at full size. The plain StatTile worked because it
                    // passes weight(1f) (a hard width); this column-child needs fillMaxWidth instead.
                    AutoSizeValue(
                        value,
                        style = NoopType.tileValueLarge,
                        color = accent,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (caption != null) {
                        Text(
                            caption,
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(top = Metrics.space2),
                        )
                    }
                }
                if (spark.size >= 2) {
                    // Sparkline forces fillMaxWidth + a fixed height internally, so we
                    // bound it in a sized Box to keep it a compact inline trend.
                    SparkTailBox(wide = true) {
                        Sparkline(values = spark, color = sparkColor)
                    }
                }
            }
        }
    }
}

// MARK: - Illness banner (ported from HealthAlertBanner.swift)

@Composable
private fun IllnessBanner(message: String) {
    // Frosted Bevel warning card (amber tint) — matches the Swift HealthAlertBanner.
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cardRadius))
            .frostedCardSurface(tint = Palette.statusWarning, cornerRadius = Metrics.cardRadius)
            .padding(Metrics.space14),
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(Palette.statusWarning.copy(alpha = StrandAlpha.warningFill)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Warning, contentDescription = null, tint = Palette.statusWarning)
        }
        Text(message, style = NoopType.subhead, color = Palette.textPrimary)
    }
}

// MARK: - 14-day sparkline windows (built from recentDays)

/** The trailing-window series for each tile, oldest → newest. */
private data class Window(
    val recovery: List<Double>,
    val strain: List<Double>,
    val sleepMin: List<Double>,
    val hrv: List<Double>,
    val rhr: List<Double>,
    val spo2: List<Double>,
    val resp: List<Double>,
)

/**
 * Build the 14-day windows from `recentDays`. Each series drops null days from the
 * trailing calendar window only, so stale imports do not draw a current-day trend.
 */
@Composable
private fun remember14(days: List<com.noop.data.DailyMetric>, anchorDay: LocalDate): Window =
    androidx.compose.runtime.remember(days, anchorDay) {
        // Trailing 14 CALENDAR days ending today — NOT the last 14 stored rows, which on an old import
        // were months-old data shown as a "14-day trend" (issue #23). ISO yyyy-MM-dd sorts chronologically.
        val cutoff = anchorDay.minusDays(13).toString()
        val end = anchorDay.toString()
        val recent = days.filter { it.day >= cutoff && it.day <= end }
        fun series(pick: (DailyMetric) -> Double?): List<Double> = recent.mapNotNull(pick)
        Window(
            recovery = series { it.recovery },
            strain = series { it.strain },
            sleepMin = series { it.totalSleepMin },
            hrv = series { it.avgHrv },
            rhr = series { it.restingHr?.toDouble() },
            spo2 = series { it.spo2Pct },
            resp = series { it.respRateBpm },
        )
    }

// MARK: - Derived text (ported from TodayView.swift)

private fun greetingWord(): String {
    val h = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
    return when {
        h < 12 -> "Good morning"
        h < 17 -> "Good afternoon"
        else -> "Good evening"
    }
}

private fun synthesisWord(score: Double?): String {
    if (score == null) return "No Data"
    return when {
        score < 25 -> "Depleted"
        score < 50 -> "Low"
        score < 70 -> "Steady"
        score < 88 -> "Primed"
        else -> "Peak"
    }
}

private fun synthesisDetail(d: DailyMetric?): String {
    val rec = d?.recovery
        ?: return "No metrics yet. Import your WHOOP export or wear the strap to begin."
    val recPart = when {
        rec < 50 -> "Charge is low"
        rec < 70 -> "Charge is steady"
        else -> "Charge is strong"
    }
    val sleepPart = d.totalSleepMin?.let { mins ->
        if (mins / 60.0 >= 7) " and sleep was consistent" else " but sleep ran short"
    } ?: ""
    return "$recPart$sleepPart."
}

private fun sleepValue(d: DailyMetric?): String {
    val m = d?.totalSleepMin ?: return NO_DATA
    val total = m.roundToInt()
    return "${total / 60}h ${total % 60}m"
}

/**
 * The Rest tile's caption — hours-in-bed for the day, the figure that used to be the tile's VALUE
 * before #248 moved the Rest score there. Falls back to the efficiency read-out when no duration is
 * banked, and to null so the tile shows no caption line when neither exists. Mirrors macOS restCaption.
 */
private fun restCaption(d: DailyMetric?): String? = when {
    d?.totalSleepMin != null -> sleepValue(d)
    d?.efficiency != null -> String.format(Locale.US, "%.0f%% eff", d.efficiency)
    else -> null
}

/**
 * H9 — whether THIS night's sleep STAGING is low-confidence, read from the core's existing
 * [ScoreConfidence] rule (never fabricated). True exactly when the night has staged sleep (so the base
 * Rest tier is SOLID) yet the H9 overload DOWNGRADES it — a high-efficiency night whose deep+REM share
 * is implausibly low, far more likely a staging miss (the EEG-free classifier's weak spot) than a real
 * night with almost no restorative sleep. We surface that honestly with a small "Stages estimated" badge
 * rather than faking stages or tanking the Rest score. Reads only the day's banked stage figures
 * (efficiency is the engine's 0..1 fraction; restorative = deep+REM), so it's the SAME decision the
 * daily pass made into `restConfidence`. Returns false for a missing day, a calibrating/building base
 * tier, or any night the core deems SOLID. Pure + unit-tested. Mirrors the iOS Sleep H9 badge gate.
 */
internal fun restStageLowConfidence(d: DailyMetric?): Boolean {
    val asleepMin = d?.totalSleepMin ?: return false
    val efficiency = d.efficiency ?: return false
    val restorativeMin = (d.deepMin ?: 0.0) + (d.remMin ?: 0.0)
    val hasStaged = restorativeMin > 0.0
    // The base (pre-H9) tier: SOLID only when there's staged sleep. If the base isn't SOLID the badge
    // doesn't apply — a calibrating/no-stage night has its own honest treatment, not a "stages off" flag.
    if (ScoreConfidence.forRest(hasSession = true, hasStagedSleep = hasStaged) != ScoreConfidence.SOLID) {
        return false
    }
    // The H9 overload: SOLID stays SOLID unless the high-efficiency / low-restorative staging-miss fires.
    return ScoreConfidence.forRest(
        hasSession = true,
        hasStagedSleep = hasStaged,
        asleepSeconds = asleepMin * 60.0,
        restorativeSeconds = restorativeMin * 60.0,
        efficiency = efficiency,
    ) == ScoreConfidence.BUILDING
}

/**
 * Short "it's coming, not broken" caption for an unscored tile on TODAY only (#527, extended for H10).
 * Rest fills in after a night's sleep; Effort fills in once cardio load is logged; the overnight vitals
 * (Blood Oxygen) and the on-device Steps fill in over the next few nights / today's wear; Charge needs a
 * few nights to learn your baseline. Returns null off-today so a navigated PAST day with no score
 * honestly stays a bare dash (missing data, not mid-calibration) — mirrors the recoveryCalibration
 * today-only rule the Charge tile uses. Each call site only reaches here when the value is genuinely
 * absent, so the hint never overwrites a real reading. No em-dashes (house style). Pure + unit-tested.
 */
internal fun buildingHint(metric: KeyMetric, isToday: Boolean): String? {
    if (!isToday) return null
    return when (metric) {
        KeyMetric.REST -> "Building, wear it tonight"
        KeyMetric.EFFORT -> "Building, moves as you do"
        // H10: an unscored Charge today that ISN'T mid-calibration and has nothing to carry — say what's
        // needed rather than a bare "No Data". (The "Calibrating N of 4" copy still owns the calibrating
        // case at the call site; this only shows once there's genuinely nothing.)
        KeyMetric.CHARGE -> "Building, wear it tonight"
        // H10: the overnight blood-oxygen reading builds from sleep, like the other in-sleep vitals.
        KeyMetric.BLOOD_OXYGEN -> "Building, wear it tonight"
        // H10: on-device steps fill in across today as you move (5/MG counter / imported HC).
        KeyMetric.STEPS -> "Building, moves as you do"
        else -> null
    }
}

// MARK: - Steps / Weight / Calories tile logic (issue #107)
//
// Steps and Calories read straight off today's DailyMetric (the on-device WHOOP5 derivations); the
// pure helpers below back the Weight tile, which has no daily strap source and instead falls back to
// the user's profile weight. Kept pure + file-internal so TodayMetricTilesTest is the oracle.

/** The Weight tile's display string and an honest caption ("from profile" only on fallback). */
internal data class WeightTileText(val value: String, val caption: String?)

/**
 * The newest body weight across the two Apple-side sources (apple-health + health-connect), or null
 * when neither carries one. Days are ISO `yyyy-MM-dd`, which sorts chronologically, so the lexically
 * greatest day with a non-null `weightKg` is the most recent — no date parsing needed. (#107)
 */
internal fun latestWeightKg(apple: List<AppleDaily>, healthConnect: List<AppleDaily>): Double? =
    (apple + healthConnect)
        .filter { it.weightKg != null }
        .maxByOrNull { it.day }
        ?.weightKg

/**
 * Steps for [dayKey] from the imported Apple Health / Health Connect daily aggregates, or null when
 * neither source carries a step total for that day. Backs the Today Steps-tile fallback for straps
 * NOOP can't read steps off over Bluetooth — notably the WHOOP 4.0, which DOES count steps (in the
 * official WHOOP app) but doesn't expose them to NOOP — so on a 4.0 the tile shows imported steps
 * rather than "No Data". On-device WHOOP 5/MG steps (DailyMetric.steps) still take precedence at the
 * call site. When both sources report the same day, the larger (most-complete) total wins so we never
 * sum and double-count. Mirrors the macOS TodayView, which already falls back to imported steps. (#150)
 */
internal fun stepsForDay(apple: List<AppleDaily>, healthConnect: List<AppleDaily>, dayKey: String): Int? =
    (apple + healthConnect)
        .filter { it.day == dayKey }
        .mapNotNull { it.steps }
        .maxOrNull()

/**
 * Resolve the Weight tile text: prefer the latest Apple/Health-Connect weight, else fall back to the
 * SI profile weight with a "from profile" caption so the source stays honest. Both are formatted
 * through the shared [UnitFormatter] so the Imperial/Metric toggle reaches this tile too. (#107)
 */
internal fun weightTile(latestWeightKg: Double?, profileWeightKg: Double, system: UnitSystem): WeightTileText =
    if (latestWeightKg != null) {
        WeightTileText(UnitFormatter.massFromKilograms(latestWeightKg, system), "latest")
    } else {
        WeightTileText(UnitFormatter.massFromKilograms(profileWeightKg, system), "from profile")
    }

/** Group-separated integer display from a Double (e.g. 12 345 steps), matching the Apple Health tiles. */
private fun intString(v: Double): String {
    val n = v.roundToInt()
    return if (kotlin.math.abs(n) >= 1000) String.format(Locale.US, "%,d", n) else "$n"
}

private const val NO_DATA = "No Data"

/** The dashboard-card placeholder for a baseline-relative metric (Stress) that is still seeding its window —
 *  an honest "building your baseline" state rather than a bare dash (#706/#684). Rendered dimmed like NO_DATA. */
private const val STRESS_CALIBRATING = "Calibrating"

private val workoutDateFmt: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM", Locale.US).withZone(ZoneId.systemDefault())
private val workoutTimeFmt: DateTimeFormatter =
    // Respect the device's 12-/24-hour locale (#337): "7:10 AM" where 12-hour is preferred, "19:10"
    // where 24-hour is — instead of forcing 24-hour on everyone.
    DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
        .withLocale(Locale.getDefault()).withZone(ZoneId.systemDefault())

private fun countDetail(days: Int?, workouts: Int?, workoutLabel: String): String {
    if (days == null || workouts == null) return "Counting..."
    return "${grouped(days)} days · ${grouped(workouts)} $workoutLabel"
}

/** Same bands as the Settings Strap battery pill, so the % reads the same colour everywhere (#159). */
private fun batteryPillTone(pct: Int): StrandTone = when {
    pct <= 15 -> StrandTone.Critical
    pct <= 30 -> StrandTone.Warning
    else -> StrandTone.Positive
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

/** "d MMM · HH:mm–HH:mm" (#157); start-only when the end isn't after the start (zero/unknown span). */
private fun workoutCaption(row: WorkoutRow): String {
    val date = workoutDateFmt.format(Instant.ofEpochSecond(row.startTs))
    val start = workoutTimeFmt.format(Instant.ofEpochSecond(row.startTs))
    return if (row.endTs > row.startTs) {
        "$date · $start–${workoutTimeFmt.format(Instant.ofEpochSecond(row.endTs))}"
    } else {
        "$date · $start"
    }
}

private fun grouped(value: Int): String =
    String.format(Locale.US, "%,d", value)

// MARK: - Key-Metrics layout editor (#251)
//
// A Today-local dialog (no new nav destination — another lane owns the nav graph) for choosing which
// Key-Metric tiles show on the Control Center and in what order. Display-only: it edits the persisted
// `today.keyMetrics` layout, never any stored metric. A switch hides/shows a tile and the up/down arrows
// reorder it — explicit arrows rather than drag so it behaves the same on every device. Mirrors the macOS
// KeyMetricsEditorSheet.

/** One editor row: a tile with its current enabled flag. The working list is rebuilt on each edit. */
private data class EditableMetric(val metric: KeyMetric, val enabled: Boolean)

@Composable
private fun KeyMetricsEditorDialog(
    initial: List<KeyMetric>,
    onDismiss: () -> Unit,
    onSave: (List<KeyMetric>) -> Unit,
) {
    // Working copy: enabled tiles first (saved order), then the disabled remainder in the default order —
    // so toggling one on drops it at the end of the visible set, and every known tile is listed once.
    val items = remember {
        val enabledSet = initial.toHashSet()
        mutableStateListOf<EditableMetric>().apply {
            initial.forEach { add(EditableMetric(it, true)) }
            KeyMetric.defaultOrder.filter { it !in enabledSet }.forEach { add(EditableMetric(it, false)) }
        }
    }

    fun move(from: Int, to: Int) {
        if (from in items.indices && to in items.indices) {
            val item = items.removeAt(from)
            items.add(to, item)
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            color = Palette.surfaceOverlay,
            shape = RoundedCornerShape(16.dp),
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text("Edit Key Metrics", style = NoopType.title2, color = Palette.textPrimary)
                    Text(
                        "Choose which tiles show on your Control Center and reorder them with the arrows.",
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }

                Column(
                    modifier = Modifier
                        .heightIn(max = 360.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    items.forEachIndexed { index, item ->
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Switch(
                                checked = item.enabled,
                                onCheckedChange = { items[index] = item.copy(enabled = it) },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = Palette.surfaceBase,
                                    checkedTrackColor = Palette.accent,
                                    uncheckedThumbColor = Palette.textSecondary,
                                    uncheckedTrackColor = Palette.surfaceInset,
                                    uncheckedBorderColor = Palette.hairline,
                                ),
                                modifier = Modifier.semantics { contentDescription = "Show ${item.metric.title}" },
                            )
                            Spacer(Modifier.width(12.dp))
                            Text(
                                item.metric.title,
                                style = NoopType.body,
                                color = if (item.enabled) Palette.textPrimary else Palette.textTertiary,
                                modifier = Modifier.weight(1f),
                            )
                            IconButton(
                                onClick = { move(index, index - 1) },
                                enabled = index > 0,
                                modifier = Modifier.size(Metrics.iconButton),
                            ) {
                                Icon(
                                    Icons.Filled.KeyboardArrowUp,
                                    contentDescription = "Move ${item.metric.title} up",
                                    tint = if (index > 0) Palette.textSecondary else Palette.textTertiary,
                                    modifier = Modifier.size(Metrics.iconSmall),
                                )
                            }
                            IconButton(
                                onClick = { move(index, index + 1) },
                                enabled = index < items.lastIndex,
                                modifier = Modifier.size(Metrics.iconButton),
                            ) {
                                Icon(
                                    Icons.Filled.KeyboardArrowDown,
                                    contentDescription = "Move ${item.metric.title} down",
                                    tint = if (index < items.lastIndex) Palette.textSecondary else Palette.textTertiary,
                                    modifier = Modifier.size(Metrics.iconSmall),
                                )
                            }
                        }
                        if (index < items.lastIndex) {
                            HorizontalDivider(color = Palette.hairline, thickness = 1.dp)
                        }
                    }
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        onClick = {
                            // Reset to the canonical default: every tile enabled, original order.
                            items.clear()
                            KeyMetric.defaultOrder.forEach { items.add(EditableMetric(it, true)) }
                        },
                        colors = ButtonDefaults.textButtonColors(contentColor = Palette.textSecondary),
                    ) { Text("Reset", style = NoopType.body) }
                    Spacer(Modifier.weight(1f))
                    Button(
                        onClick = { onSave(items.filter { it.enabled }.map { it.metric }) },
                        // At least one tile must stay visible — an empty grid reads as a bug, not a choice.
                        enabled = items.any { it.enabled },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) { Text("Done", style = NoopType.captionNumber) }
                }
            }
        }
    }
}
