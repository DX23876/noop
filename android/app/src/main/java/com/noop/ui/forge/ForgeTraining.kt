package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.rounded.ListAlt
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.NoopApplication
import com.noop.analytics.Sport
import com.noop.analytics.WorkoutSport
import com.noop.core.CoreRead
import com.noop.core.CoreTraining
import com.noop.ui.AppViewModel
import com.noop.ui.LiveWorkoutScreen
import com.noop.ui.NoopPrefs
import com.noop.ui.RecentSportsPrefs
import com.noop.ui.StartWorkoutSheet
import com.noop.ui.rememberRequestLocation
import com.noop.ui.sportIcon
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle
import java.util.Locale

/** Runs [block] on the IO dispatcher with the core's store open. */
private suspend fun <T> core(context: android.content.Context, block: () -> T): T =
    withContext(Dispatchers.IO) { CoreRead.open(context); block() }

/** The same active-strap dismissal spans supplied to the daily core pass. */
internal suspend fun dismissedTrainingWorkouts(context: android.content.Context): List<String> {
    val app = context.applicationContext as NoopApplication
    return app.repository.dismissedDetectedUnion(app.activeDeviceId).map { "${it.startTs}:${it.endTs}" }
}

/** What the Training tab has open over itself; one page at a time, as the Forge overlay host holds one. */
private sealed interface TrainingPage {
    data object Session : TrainingPage
    data class Routine(val routine: CoreTraining.Routine?) : TrainingPage
    data object Schedule : TrainingPage
    data object Starters : TrainingPage
    data class Detail(val session: CoreTraining.Session) : TrainingPage
    data object Muscles : TrainingPage
    data object Load : TrainingPage
    data object Strength : TrainingPage
    data object Cardio : TrainingPage
    data object Library : TrainingPage
}

/** Activities offered before the wearer's own recents fill the list (`WorkoutQuickStart.starterNames`). */
private val STARTER_SPORTS = listOf("Walking", "Running", "Cycling")

/** Sports that start the strength logger instead (`ActiveSessionController.strengthSportKeys`). */
private val STRENGTH_SPORTS = setOf("strength", "strength training", "bodybuilding", "weightlifting", "powerlifting",
                                    "calisthenics", "traditional strength training", "functional strength training")

/**
 * Fork (DX23876), Android parity plan 2.3: the Training tab as iOS lays it out (`TrainingHubView`): start a workout,
 * the planned week, the routines with their muscles, the recent sessions, a year of consistency and the muscle
 * analytics. Everything is read from and written through the shared core (`CoreTraining`), so a session started here
 * is prefilled, progressed and completed by the same code as on the iPhone, and the figures shade the same readings.
 */
@Composable
fun ForgeTrainingScreen(padding: PaddingValues, viewModel: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var snapshot by remember { mutableStateOf<CoreTraining.Snapshot?>(null) }
    var revision by remember { mutableIntStateOf(0) }
    var page by remember { mutableStateOf<TrainingPage?>(null) }
    var deleting by remember { mutableStateOf<CoreTraining.Routine?>(null) }
    var showLive by remember { mutableStateOf(false) }
    var showAll by remember { mutableStateOf(false) }
    var configuring by remember { mutableStateOf<Sport?>(null) }
    val activeWorkout by viewModel.activeWorkout.collectAsStateWithLifecycle()
    LaunchedEffect(revision) {
        val dismissed = withContext(Dispatchers.IO) { dismissedTrainingWorkouts(context) }
        snapshot = core(context) { CoreTraining.snapshot(dismissed) }
    }
    fun reload() { revision++ }
    fun start(routineIds: List<String>) = scope.launch {
        core(context) { CoreTraining.startDraft(routineIds) }
        page = TrainingPage.Session
    }
    var pendingSport by remember { mutableStateOf<Sport?>(null) }
    val startWithGps = rememberRequestLocation { granted ->
        pendingSport?.let { viewModel.startWorkout(it, gpsEnabled = granted) }
        showLive = true
    }
    fun startCardio(sport: Sport, gps: Boolean) {
        RecentSportsPrefs.record(context, sport.name)
        QuickStartPrefs.setRoute(context, sport.name, gps)
        if (gps) { pendingSport = sport; startWithGps() } else { viewModel.startWorkout(sport, gpsEnabled = false); showLive = true }
    }

    val s = snapshot
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding)
            .padding(horizontal = ForgeMetrics.screenPadding).widthIn(max = ForgeMetrics.maxContentWidth),
        verticalArrangement = Arrangement.spacedBy(ForgeMetrics.sectionGap),
    ) {
        Column(Modifier.padding(top = ForgeMetrics.space4)) {
            Text(stringResource(R.string.forge_training_overline).uppercase(), style = Forge.type.overline,
                 color = Forge.sceneInk.secondary)
            Text(stringResource(R.string.forge_training), style = Forge.type.title1, color = Forge.sceneInk.text)
        }
        if (s == null) return@Column
        val live = activeWorkout
        if (s.hasDraft || live != null) {
            InProgressCard(subtitle = live?.sport?.name, onResume = {
                if (live != null) showLive = true else page = TrainingPage.Session
            })
        } else {
            val today = s.week.firstOrNull { it.isToday }?.routineIds.orEmpty()
            QuickStartCard(
                todayTitles = s.routines.filter { it.id in today }.map { it.title },
                onStrength = { start(today) },
                onSport = { sport -> startCardio(sport, QuickStartPrefs.route(context, sport)) },
                onSettings = { configuring = it },
                onAll = { showAll = true })
        }

        Section(stringResource(R.string.forge_th_this_week), stringResource(R.string.forge_th_schedule),
                trailing = { TintButton(stringResource(R.string.forge_th_edit)) { page = TrainingPage.Schedule } }) {
            WeekStrip(s.week) { page = TrainingPage.Schedule }
        }

        Section(stringResource(R.string.forge_th_routines), stringResource(R.string.forge_th_your_training), trailing = {
            var menu by remember { mutableStateOf(false) }
            Box {
                TintButton(stringResource(R.string.forge_th_add), Icons.Rounded.Add) { menu = true }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.forge_training_new_routine)) },
                                     onClick = { menu = false; page = TrainingPage.Routine(null) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.forge_th_browse_starters)) },
                                     onClick = { menu = false; page = TrainingPage.Starters })
                }
            }
        }) {
            if (s.routines.isEmpty()) {
                ForgeCard(Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.forge_th_build_plan), style = Forge.type.headline, color = Forge.colors.text)
                    Spacer(Modifier.height(ForgeMetrics.space2))
                    Text(stringResource(R.string.forge_th_build_plan_detail), style = Forge.type.subhead,
                         color = Forge.colors.textSecondary)
                    Spacer(Modifier.height(ForgeMetrics.space2))
                    Text(stringResource(R.string.forge_th_browse_starters), style = Forge.type.subhead,
                         color = Forge.colors.accent,
                         modifier = Modifier.background(Forge.colors.accent.copy(alpha = 0.15f), RoundedCornerShape(8.dp))
                             .clickable { page = TrainingPage.Starters }.padding(horizontal = 12.dp, vertical = 7.dp))
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
                    s.routines.forEach { routine ->
                        RoutineCard(routine, onStart = { start(listOf(routine.id)) },
                                    onEdit = { page = TrainingPage.Routine(routine) },
                                    onDuplicate = { title ->
                                        scope.launch { core(context) { CoreTraining.duplicateRoutine(routine.id, title) }; reload() }
                                    },
                                    onDelete = { deleting = routine })
                    }
                }
            }
        }

        Section(stringResource(R.string.forge_th_recent), stringResource(R.string.forge_th_logged_in_noop)) {
            ForgeCard(Modifier.fillMaxWidth()) {
                if (s.sessions.isEmpty()) {
                    Text(stringResource(R.string.forge_th_no_recent), style = Forge.type.subhead,
                         color = Forge.colors.textSecondary)
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        s.sessions.take(5).forEach { session ->
                            SessionRow(session) { page = TrainingPage.Detail(session) }
                        }
                    }
                }
            }
        }

        Section(stringResource(R.string.forge_th_consistency), stringResource(R.string.forge_th_past_year)) {
            ForgeCard(Modifier.fillMaxWidth()) {
                ActivityHeatmap(s.activity)
                Spacer(Modifier.height(ForgeMetrics.space2))
                Text(stringResource(R.string.forge_th_consistency_caption), style = Forge.type.caption,
                     color = Forge.colors.textTertiary)
            }
        }

        Section(stringResource(R.string.forge_th_muscle_analytics), stringResource(R.string.forge_th_all_sources)) {
            ForgeCard(Modifier.fillMaxWidth()) {
                MuscleAnalyticsSurface(s.muscles, compact = true) { _, _ -> page = TrainingPage.Muscles }
                Spacer(Modifier.height(ForgeMetrics.space3))
                PanelButton(stringResource(R.string.forge_th_explore_muscles), Icons.Rounded.FitnessCenter) {
                    page = TrainingPage.Muscles
                }
            }
        }

        Section(stringResource(R.string.forge_th_understand), stringResource(R.string.forge_th_noop_analysis)) {
            ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
                AnalysisRow(stringResource(R.string.forge_th_strength), stringResource(R.string.forge_th_strength_detail),
                            Icons.Rounded.FitnessCenter) { page = TrainingPage.Strength }
                AnalysisRow(stringResource(R.string.forge_tl_cardio), stringResource(R.string.forge_th_cardio_detail),
                            Icons.Rounded.Speed) { page = TrainingPage.Cardio }
                AnalysisRow(stringResource(R.string.forge_library_title), stringResource(R.string.forge_library_subtitle),
                            Icons.Rounded.Search) { page = TrainingPage.Library }
                AnalysisRow(stringResource(R.string.forge_th_load_title), stringResource(R.string.forge_th_load_detail),
                            Icons.Rounded.Speed) { page = TrainingPage.Load }
            }
        }
        Spacer(Modifier.height(ForgeMetrics.space4))
    }

    page?.let { open ->
        val close: () -> Unit = { page = null; reload() }
        ForgeOverlayPage(onDismiss = close) {
            ForgeSceneBackdrop(ForgeBackdrop.Canvas) {
                when (open) {
                    TrainingPage.Session -> ForgeTrainingSession(s?.exercises.orEmpty(), onClose = close)
                    is TrainingPage.Routine -> RoutineEditor(s?.exercises.orEmpty(), open.routine, onClose = close)
                    TrainingPage.Schedule -> ScheduleEditor(s?.routines.orEmpty(), onClose = close)
                    TrainingPage.Starters -> StarterPlans(onClose = close)
                    is TrainingPage.Detail -> SessionDetail(open.session, onClose = close)
                    TrainingPage.Muscles -> s?.let { MuscleAnalyticsPage(it.muscles, onClose = close) }
                    TrainingPage.Load -> ForgeTrainingLoadPage(onClose = close)
                    TrainingPage.Strength -> ForgeStrengthPage(onClose = close)
                    TrainingPage.Cardio -> ForgeCardioPage(onClose = close)
                    TrainingPage.Library -> ForgeExerciseLibrary(onClose = close, onAdded = {
                        scope.launch {
                            val dismissed = withContext(Dispatchers.IO) { dismissedTrainingWorkouts(context) }
                            snapshot = core(context) { CoreTraining.snapshot(dismissed) }
                            page = TrainingPage.Session
                        }
                    })
                }
            }
        }
    }
    if (showLive) {
        Dialog(onDismissRequest = { showLive = false; reload() },
               properties = DialogProperties(usePlatformDefaultWidth = false)) {
            LiveWorkoutScreen(vm = viewModel, onClose = { showLive = false; reload() })
        }
    }
    if (showAll) StartWorkoutSheet(vm = viewModel, onDismiss = { showAll = false; reload() })
    configuring?.let { sport ->
        var route by remember(sport) { mutableStateOf(QuickStartPrefs.route(context, sport)) }
        AlertDialog(
            onDismissRequest = { configuring = null },
            title = { Text(sport.name) },
            text = {
                if (sport.isDistanceSport) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.forge_th_route), style = Forge.type.body, modifier = Modifier.weight(1f))
                        Switch(checked = route, onCheckedChange = { route = it })
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { configuring = null; startCardio(sport, route && sport.isDistanceSport) }) {
                    Text(stringResource(R.string.forge_training_start_routine, sport.name))
                }
            },
            dismissButton = { TextButton(onClick = { configuring = null }) { Text(stringResource(R.string.forge_th_cancel)) } },
        )
    }
    deleting?.let { routine ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            text = { Text(stringResource(R.string.forge_training_delete_routine) + ": " + routine.title) },
            confirmButton = {
                TextButton(onClick = {
                    deleting = null
                    scope.launch { core(context) { CoreTraining.deleteRoutine(routine.id) }; reload() }
                }) { Text(stringResource(R.string.forge_th_delete), color = ForgeTokens.Color.systemRed.resolve()) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text(stringResource(R.string.forge_th_cancel)) } },
        )
    }
}

/** The route choice each activity starts with, remembered per sport (iOS `WorkoutStartSettings.remembered`). */
private object QuickStartPrefs {
    private fun key(name: String) = "training.quickStart.route.$name"
    fun route(context: android.content.Context, sport: Sport): Boolean =
        sport.isDistanceSport && context.getSharedPreferences(NoopPrefs.NAME, android.content.Context.MODE_PRIVATE)
            .getBoolean(key(sport.name), true)
    fun setRoute(context: android.content.Context, name: String, on: Boolean) {
        context.getSharedPreferences(NoopPrefs.NAME, android.content.Context.MODE_PRIVATE).edit()
            .putBoolean(key(name), on).apply()
    }
}

/** A section as iOS heads it (`SectionHeader(title, overline:)`): small caps over a title, an action on the right. */
@Composable
private fun Section(title: String, overline: String, trailing: (@Composable () -> Unit)? = null,
                    content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        Row(verticalAlignment = Alignment.Bottom) {
            Column(Modifier.weight(1f).padding(horizontal = ForgeMetrics.space1),
                   verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(overline.uppercase(), style = Forge.type.overline, color = Forge.sceneInk.secondary)
                Text(title, style = Forge.type.title2, color = Forge.sceneInk.text)
            }
            trailing?.invoke()
        }
        content()
    }
}

/** A text button in the app tint (iOS tints the tab bar and plain buttons with the Charge colour). */
@Composable
private fun TintButton(label: String, icon: ImageVector? = null, onClick: () -> Unit) {
    Row(Modifier.heightIn(min = ForgeMetrics.minHitTarget).clickable(onClick = onClick).padding(horizontal = ForgeMetrics.space1),
        verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = Forge.colors.charge, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(ForgeMetrics.space1))
        }
        Text(label, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.charge)
    }
}

/** One analysis destination (`analysisRow`): a cyan glyph, its title and what it covers, a chevron. */
@Composable
private fun AnalysisRow(title: String, subtitle: String, icon: ImageVector, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick)
            .padding(horizontal = ForgeMetrics.cardPadding, vertical = ForgeMetrics.space3),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, contentDescription = null, tint = ForgeTokens.StrandPalette.metricCyan.resolve(),
             modifier = Modifier.width(28.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
            Text(subtitle, style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = Forge.colors.textTertiary,
             modifier = Modifier.size(16.dp))
    }
}

/** A secondary button on the raised panel surface (`NoopButton(kind: .secondary)`). */
@Composable
private fun PanelButton(label: String, icon: ImageVector, onClick: () -> Unit) {
    Row(Modifier.heightIn(min = 48.dp)
            .background(Forge.colors.surfaceTop, RoundedCornerShape(ForgeTokens.NoopButtonMetrics.cornerRadius.dp))
            .border(BorderStroke(ForgeMetrics.hairline, Forge.colors.divider.copy(alpha = 0.4f)),
                    RoundedCornerShape(ForgeTokens.NoopButtonMetrics.cornerRadius.dp))
            .clickable(onClick = onClick).padding(horizontal = ForgeTokens.NoopButtonMetrics.hPadding.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = Forge.colors.text, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(ForgeTokens.NoopButtonMetrics.iconSpacing.dp))
        Text(label, style = Forge.type.headline, color = Forge.colors.text)
    }
}

@Composable
private fun InProgressCard(subtitle: String?, onResume: () -> Unit) {
    ForgeCard(Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.forge_th_in_progress), style = Forge.type.headline, color = Forge.colors.text)
        if (subtitle != null) Text(subtitle, style = Forge.type.subhead, color = Forge.colors.textSecondary)
        Spacer(Modifier.height(ForgeMetrics.space3))
        Row(Modifier.fillMaxWidth().background(Forge.colors.accent, RoundedCornerShape(12.dp)).clickable(onClick = onResume)
                .padding(vertical = ForgeMetrics.space3),
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.PlayArrow, contentDescription = null, tint = Color.White)
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(stringResource(R.string.forge_th_resume), style = Forge.type.headline, color = Color.White)
        }
    }
}

private val ICON_SIZE = 40.dp

/** The top of the tab (`TrainingQuickStartCard`): today's plan or freestyle, recent activities, all workouts. */
@Composable
private fun QuickStartCard(todayTitles: List<String>, onStrength: () -> Unit, onSport: (Sport) -> Unit,
                           onSettings: (Sport) -> Unit, onAll: () -> Unit) {
    val context = LocalContext.current
    val activities = remember {
        val picked = mutableListOf<Sport>()
        fun add(name: String) {
            if (picked.size >= 4 || name.lowercase() in STRENGTH_SPORTS) return
            val sport = WorkoutSport.all.firstOrNull { it.name.equals(name, ignoreCase = true) } ?: return
            if (picked.none { it.name == sport.name }) picked.add(sport)
        }
        RecentSportsPrefs.recent(context).forEach(::add)
        for (name in STARTER_SPORTS) if (picked.size < 3) add(name)
        picked.toList()
    }
    val effort = ForgeTokens.StrandPalette.effortColor.resolve()
    ForgeCard(Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.forge_th_start_workout), style = Forge.type.headline, color = Forge.colors.text)
        Spacer(Modifier.height(ForgeMetrics.space2))
        if (todayTitles.isNotEmpty()) {
            QuickStartRow(stringResource(R.string.forge_th_start_today), todayTitles.joinToString(" · "),
                          onStart = onStrength) { SymbolIcon(Icons.Rounded.CalendarMonth) }
        } else {
            QuickStartRow(stringResource(R.string.forge_th_freestyle), stringResource(R.string.forge_th_freestyle_detail),
                          onStart = onStrength) { SymbolIcon(Icons.Rounded.FitnessCenter) }
        }
        QuickStartDivider()
        activities.forEach { sport ->
            val detail = if (!sport.isDistanceSport) null
                         else stringResource(if (QuickStartPrefs.route(context, sport)) R.string.forge_th_route
                                             else R.string.forge_th_no_route)
            QuickStartRow(sport.name, detail, onStart = { onSport(sport) }, onSettings = { onSettings(sport) }) {
                Box(Modifier.size(ICON_SIZE).background(effort.copy(alpha = 0.12f), CircleShape),
                    contentAlignment = Alignment.Center) {
                    Icon(sportIcon(sport.name), contentDescription = null, tint = effort, modifier = Modifier.size(20.dp))
                }
            }
            QuickStartDivider()
        }
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(onClick = onAll).padding(vertical = ForgeMetrics.space2),
            verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(ICON_SIZE).background(Forge.colors.surface, CircleShape)
                    .border(BorderStroke(ForgeMetrics.hairline, Forge.colors.divider.copy(alpha = 0.35f)), CircleShape),
                contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.Search, contentDescription = null, tint = Forge.colors.textSecondary,
                     modifier = Modifier.size(20.dp))
            }
            Spacer(Modifier.width(ForgeMetrics.space3))
            Text(stringResource(R.string.forge_th_all_workouts), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = Forge.colors.text, modifier = Modifier.weight(1f))
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = Forge.colors.textTertiary)
        }
    }
}

@Composable
private fun QuickStartDivider() {
    HorizontalDivider(color = Forge.colors.divider.copy(alpha = 0.5f), thickness = ForgeMetrics.hairline,
                      modifier = Modifier.padding(start = ICON_SIZE + ForgeMetrics.space3))
}

@Composable
private fun SymbolIcon(icon: ImageVector) {
    Box(Modifier.size(ICON_SIZE).background(Forge.colors.accent.copy(alpha = 0.12f), CircleShape),
        contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = null, tint = Forge.colors.accent, modifier = Modifier.size(20.dp))
    }
}

/** One startable line: the row starts at once, the settings button opens the choices first (`QuickStartRow`). */
@Composable
private fun QuickStartRow(title: String, detail: String?, onStart: () -> Unit, onSettings: (() -> Unit)? = null,
                          icon: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(vertical = ForgeMetrics.space2),
        verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.weight(1f).clickable(onClick = onStart), verticalAlignment = Alignment.CenterVertically) {
            icon()
            Spacer(Modifier.width(ForgeMetrics.space3))
            Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
                Text(title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text,
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (detail != null) {
                    Text(detail, style = Forge.type.footnote, color = Forge.colors.textSecondary, maxLines = 1,
                         overflow = TextOverflow.Ellipsis)
                }
            }
        }
        if (onSettings != null) {
            Box(Modifier.size(44.dp).clickable(onClick = onSettings), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.Tune, stringResource(R.string.forge_th_workout_settings),
                     tint = Forge.colors.textSecondary, modifier = Modifier.size(20.dp))
            }
        }
        Box(Modifier.size(44.dp).clickable(onClick = onStart), contentAlignment = Alignment.Center) {
            Box(Modifier.size(32.dp).background(Forge.colors.accent, CircleShape), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.PlayArrow, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
            }
        }
    }
}

@Composable
private fun WeekStrip(week: List<CoreTraining.PlannedDay>, onDay: () -> Unit) {
    val locale = Locale.getDefault()
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            week.forEach { d ->
                val date = LocalDate.parse(d.day)
                Column(
                    Modifier.weight(1f)
                        .background(if (d.isToday) Forge.colors.accent.copy(alpha = 0.10f) else Color.Transparent,
                                    RoundedCornerShape(12.dp))
                        .clickable(onClick = onDay).padding(vertical = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(date.dayOfWeek.getDisplayName(TextStyle.NARROW, locale), style = Forge.type.caption,
                         color = Forge.colors.textTertiary)
                    Text(date.dayOfMonth.toString(), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                         color = Forge.colors.text)
                    Box(Modifier.size(6.dp).background(
                        if (d.routineIds.isEmpty()) Forge.colors.border else Forge.colors.accent, CircleShape))
                }
            }
        }
    }
}

/** A routine card (`routinesCard`): its muscles, title and size, Start, and the options menu. */
@Composable
private fun RoutineCard(routine: CoreTraining.Routine, onStart: () -> Unit, onEdit: () -> Unit,
                        onDuplicate: (String) -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val copyTitle = stringResource(R.string.forge_th_copy_title, routine.title)
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (routine.muscles.isEmpty()) {
                Box(Modifier.width(72.dp), contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Rounded.ListAlt, contentDescription = null, tint = Forge.colors.accent)
                }
            } else {
                MiniMusclePreview(routine.muscles)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(routine.title, style = Forge.type.headline, color = Forge.colors.text, maxLines = 2,
                     overflow = TextOverflow.Ellipsis)
                Text(stringResource(R.string.forge_training_exercises_count, routine.exerciseCount),
                     style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
            Box(Modifier.height(34.dp).width(44.dp).background(Forge.colors.accent, RoundedCornerShape(17.dp))
                    .clickable(onClick = onStart), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.PlayArrow, stringResource(R.string.forge_training_start_routine, routine.title),
                     tint = Color.White, modifier = Modifier.size(18.dp))
            }
            Box {
                Box(Modifier.size(28.dp).border(BorderStroke(1.5.dp, Forge.colors.textSecondary), CircleShape)
                        .clickable { menu = true }, contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.MoreHoriz, stringResource(R.string.forge_th_routine_options),
                         tint = Forge.colors.textSecondary, modifier = Modifier.size(16.dp))
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.forge_th_edit)) },
                                     onClick = { menu = false; onEdit() })
                    DropdownMenuItem(text = { Text(stringResource(R.string.forge_th_duplicate)) },
                                     onClick = { menu = false; onDuplicate(copyTitle) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.forge_th_delete),
                                                   color = ForgeTokens.Color.systemRed.resolve()) },
                                     onClick = { menu = false; onDelete() })
                }
            }
        }
    }
}

@Composable
private fun SessionRow(session: CoreTraining.Session, onOpen: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onOpen), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(session.title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text,
                 maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(stringResource(R.string.forge_th_session_line, session.exerciseCount, session.workingSets),
                 style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
        Text(longDate(session.startTs), style = Forge.type.caption, color = Forge.colors.textTertiary)
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = Forge.colors.textTertiary,
             modifier = Modifier.size(16.dp))
    }
}

private fun longDate(ts: Long): String = Instant.ofEpochSecond(ts).atZone(ZoneId.systemDefault())
    .format(DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG).withLocale(Locale.getDefault()))

/**
 * A year of training days (`TrainingActivityHeatmap`): one column per week, one row per weekday, the squares scaled
 * to the card's width, darker for more time logged.
 */
@Composable
private fun ActivityHeatmap(days: List<CoreTraining.ActivityDay>) {
    val columns = maxOf(1, (days.size + 6) / 7)
    val accent = Forge.colors.accent
    val empty = Forge.colors.border.copy(alpha = Forge.colors.border.alpha * 0.55f)
    Canvas(Modifier.fillMaxWidth().aspectRatio(columns / 7f)) {
        val pitch = size.width / columns
        val gap = maxOf(1f, pitch * 0.22f)
        val cell = pitch - gap
        days.forEachIndexed { index, day ->
            val color = if (day.minutes <= 0) empty
                        else accent.copy(alpha = 0.25f + (day.minutes / 90).coerceIn(0.18, 1.0).toFloat() * 0.75f)
            drawRoundRect(color, Offset((index / 7) * pitch, (index % 7) * pitch), Size(cell, cell),
                          CornerRadius(minOf(2.dp.toPx(), cell * 0.25f)))
        }
    }
}

// MARK: - Pages

/** A logged session's exercises and working sets (iOS `StrengthSessionDetailView`, the set list). */
@Composable
private fun SessionDetail(session: CoreTraining.Session, onClose: () -> Unit) {
    BackHandler { onClose() }
    val kg = stringResource(R.string.forge_training_kg)
    SettingsColumn {
        PageTitle(session.title, onClose)
        Text(longDate(session.startTs), style = Forge.type.subhead, color = Forge.sceneInk.secondary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        session.lines.forEach { line ->
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                Text(line.title, style = Forge.type.headline, color = Forge.colors.text)
                Spacer(Modifier.height(ForgeMetrics.space2))
                line.sets.forEachIndexed { i, set ->
                    Row(Modifier.padding(vertical = 3.dp)) {
                        Text((i + 1).toString(), style = Forge.type.bodyNumber, color = Forge.colors.textTertiary,
                             modifier = Modifier.width(32.dp))
                        Text(setText(set, kg), style = Forge.type.bodyNumber, color = Forge.colors.text)
                    }
                }
            }
        }
    }
}

private fun setText(set: CoreTraining.SetLine, kg: String): String {
    val parts = mutableListOf<String>()
    set.weightKg?.let { parts += "${formatKg(it)} $kg" }
    set.reps?.let { parts += it.toString() }
    if (parts.isEmpty()) set.durationS?.let { parts += "${(it / 60).toInt()}:${(it % 60).toInt().toString().padStart(2, '0')}" }
    return parts.joinToString(" × ")
}

/** The weekly schedule (`TrainingScheduleEditorView`): per weekday, a switch for each routine. */
@Composable
private fun ScheduleEditor(routines: List<CoreTraining.Routine>, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val schedule = remember {
        mutableStateMapOf<Int, List<String>>().apply {
            for (day in 1..7) put(day, routines.filter { day in it.weekdays }.map { it.id })
        }
    }
    BackHandler { onClose() }
    val locale = Locale.getDefault()
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_th_weekly_schedule), onClose, trailing = {
            TextButton(enabled = routines.isNotEmpty(), onClick = {
                scope.launch { core(context) { CoreTraining.setSchedule(schedule.toMap()) }; onClose() }
            }) { Text(stringResource(R.string.forge_th_save), color = Forge.colors.charge,
                      style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold)) }
        })
        if (routines.isEmpty()) {
            ForgeCard(Modifier.fillMaxWidth()) {
                Column(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space5),
                       horizontalAlignment = Alignment.CenterHorizontally,
                       verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                    Icon(Icons.Rounded.CalendarMonth, contentDescription = null, tint = Forge.colors.textTertiary)
                    Text(stringResource(R.string.forge_th_no_routines_yet), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                         color = Forge.colors.text)
                    Text(stringResource(R.string.forge_th_no_routines_detail), style = Forge.type.caption,
                         color = Forge.colors.textSecondary)
                }
            }
        } else {
            for (day in 1..7) {
                Column {
                    SectionHeader(DayOfWeek.of(day).getDisplayName(TextStyle.FULL, locale),
                                  Modifier.padding(bottom = ForgeMetrics.space1))
                    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius,
                              contentPadding = ForgeMetrics.space2) {
                        routines.forEachIndexed { i, routine ->
                            Box(Modifier.padding(horizontal = ForgeMetrics.space2)) {
                                ToggleRow(routine.title, null, routine.id in schedule[day].orEmpty()) { enabled ->
                                    val ids = schedule[day].orEmpty()
                                    schedule[day] = if (enabled) (ids + routine.id).distinct() else ids - routine.id
                                }
                            }
                            if (i < routines.lastIndex) RowDivider()
                        }
                    }
                }
            }
        }
    }
}

/** The starter plans (`starterPlans`): a tap adds one as an editable routine. */
@Composable
private fun StarterPlans(onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var starters by remember { mutableStateOf<List<CoreTraining.Starter>>(emptyList()) }
    LaunchedEffect(Unit) { starters = core(context) { CoreTraining.starters() } }
    BackHandler { onClose() }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_th_starter_plans), onClose)
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
            starters.forEachIndexed { i, starter ->
                Column(Modifier.fillMaxWidth().clickable {
                    scope.launch { core(context) { CoreTraining.addStarter(starter.index) }; onClose() }
                }.padding(horizontal = ForgeMetrics.cardPadding, vertical = 10.dp),
                       verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(starter.title, style = Forge.type.headline, color = Forge.colors.text)
                    Text(starter.exercises.joinToString(" · "), style = Forge.type.caption,
                         color = Forge.colors.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                if (i < starters.lastIndex) HubDivider()
            }
        }
        Text(stringResource(R.string.forge_th_starter_footer), style = Forge.type.footnote,
             color = Forge.sceneInk.secondary, modifier = Modifier.padding(horizontal = ForgeMetrics.space4))
    }
}

// MARK: - The session in progress

/**
 * A strength session in progress (iOS `LiftSessionView`, list form): each exercise with its sets, weight and reps
 * editable, a set ticked off when done, sets and exercises added or removed. Every change goes through the core and
 * the draft it saves, so a session survives the app being closed exactly as on the iPhone.
 */
@Composable
private fun ForgeTrainingSession(exercises: List<CoreTraining.Exercise>, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var draft by remember { mutableStateOf<CoreTraining.Draft?>(null) }
    var picking by remember { mutableStateOf(false) }
    var finishing by remember { mutableStateOf(false) }
    var emptyNotice by remember { mutableStateOf(false) }
    val definitions = remember(exercises) { exercises.associateBy { it.id } }
    LaunchedEffect(Unit) { draft = core(context) { CoreTraining.draft() } }
    fun change(block: () -> CoreTraining.Draft?) = scope.launch { core(context, block)?.let { draft = it } }
    BackHandler { onClose() }

    if (picking) {
        BackHandler { picking = false }
        ExercisePicker(multiple = false, onBack = { picking = false }) { ids ->
            picking = false
            ids.firstOrNull()?.let { id -> change { CoreTraining.addExercise(id) } }
        }
        return
    }
    val d = draft
    SettingsColumn {
        PageTitle(d?.title ?: stringResource(R.string.forge_training), onClose)
        if (d == null) return@SettingsColumn
        d.exercises.forEach { exercise ->
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(definitions[exercise.exerciseId]?.title ?: stringResource(R.string.forge_report_exercise), style = Forge.type.headline,
                         color = Forge.colors.text, modifier = Modifier.weight(1f))
                    IconButton(onClick = { change { CoreTraining.removeExercise(exercise.id) } }) {
                        Icon(Icons.Rounded.Delete, stringResource(R.string.forge_training_remove_exercise),
                             tint = Forge.colors.textTertiary)
                    }
                }
                val definition = definitions[exercise.exerciseId]
                val mode = definition?.mode ?: "weight_reps"
                val columns = TrainingSetInput.columns(mode, definition?.unilateral == true)
                val massUnits = strengthUnits()
                val distanceUnits = com.noop.ui.UnitPrefs.distanceSystem(context)
                ReportNote(measurementName(mode))
                Row(Modifier.padding(vertical = ForgeMetrics.space1), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
                    Text(stringResource(R.string.forge_training_set), style = Forge.type.caption,
                         color = Forge.colors.textTertiary, modifier = Modifier.width(ForgeMetrics.space6))
                    columns.forEach { field -> Text(setInputLabel(field, massUnits, distanceUnits), style = Forge.type.caption,
                        color = Forge.colors.textTertiary, modifier = Modifier.weight(1f)) }
                    Spacer(Modifier.width(ForgeMetrics.minHitTarget))
                }
                exercise.sets.forEachIndexed { i, set ->
                    SetRow(i + 1, set, columns, massUnits, distanceUnits) { updated ->
                        change { CoreTraining.setValues(exercise.id, updated) }
                    }
                }
                TintButton(stringResource(R.string.forge_training_add_set), Icons.Rounded.Add) {
                    change { CoreTraining.addSet(exercise.id) }
                }
            }
        }
        PanelButton(stringResource(R.string.forge_training_add_exercise), Icons.Rounded.Add) { picking = true }
        Row(Modifier.fillMaxWidth().background(Forge.colors.accent, RoundedCornerShape(12.dp)).clickable {
                if (d.exercises.any { e -> e.sets.any { it.done } }) finishing = true else emptyNotice = true
            }.padding(vertical = ForgeMetrics.space3),
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.Check, contentDescription = null, tint = Color.White)
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(stringResource(R.string.forge_training_finish), style = Forge.type.headline, color = Color.White)
        }
        TextButton(onClick = {
            scope.launch { core(context) { CoreTraining.discard(d.id) }; onClose() }
        }, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.forge_training_discard), color = ForgeTokens.Color.systemRed.resolve())
        }
    }
    if (emptyNotice) {
        AlertDialog(onDismissRequest = { emptyNotice = false },
                    text = { Text(stringResource(R.string.forge_training_finish_empty)) },
                    confirmButton = { TextButton(onClick = { emptyNotice = false }) { Text(stringResource(android.R.string.ok)) } })
    }
    if (finishing) {
        var rpe by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { finishing = false },
            title = { Text(stringResource(R.string.forge_training_effort)) },
            text = { NumberField(rpe, onChange = { rpe = it.filter(Char::isDigit).take(2) }) },
            confirmButton = {
                TextButton(onClick = {
                    finishing = false
                    val value = rpe.toIntOrNull()?.takeIf { it in 1..10 }?.toDouble()
                    scope.launch { if (core(context) { CoreTraining.finish(value) }) onClose() else emptyNotice = true }
                }) { Text(stringResource(R.string.forge_training_save)) }
            },
            dismissButton = {
                TextButton(onClick = {
                    finishing = false
                    scope.launch { if (core(context) { CoreTraining.finish(null) }) onClose() else emptyNotice = true }
                }) { Text(stringResource(R.string.forge_training_skip)) }
            },
        )
    }
}

@Composable
private fun setInputLabel(field: TrainingSetInput, mass: com.noop.ui.UnitSystem, distance: com.noop.ui.UnitSystem): String = when (field) {
    TrainingSetInput.Weight -> com.noop.ui.UnitFormatter.massUnit(mass)
    TrainingSetInput.Reps -> stringResource(R.string.forge_training_reps)
    TrainingSetInput.Left -> stringResource(R.string.forge_library_left)
    TrainingSetInput.Right -> stringResource(R.string.forge_library_right)
    TrainingSetInput.Seconds -> stringResource(R.string.forge_library_seconds)
    TrainingSetInput.Distance -> com.noop.ui.UnitFormatter.distanceUnit(distance)
}

@Composable
private fun SetRow(number: Int, set: CoreTraining.DraftSet, columns: List<TrainingSetInput>,
                   massUnits: com.noop.ui.UnitSystem, distanceUnits: com.noop.ui.UnitSystem,
                   onChange: (CoreTraining.DraftSet) -> Unit) {
    val initialWeight = remember(set.id, set.weightKg, massUnits) { set.weightKg?.let { inputDecimal(TrainingSetInput.massForInput(it, massUnits)) } ?: "" }
    val initialDistance = remember(set.id, set.distanceM, distanceUnits) { set.distanceM?.let { inputDecimal(TrainingSetInput.distanceForInput(it, distanceUnits)) } ?: "" }
    var weight by remember(set.id, set.weightKg, massUnits) { mutableStateOf(initialWeight) }
    var reps by remember(set.id, set.reps) { mutableStateOf(set.reps?.toString() ?: "") }
    var left by remember(set.id, set.leftReps, set.reps) { mutableStateOf((set.leftReps ?: set.reps)?.toString() ?: "") }
    var right by remember(set.id, set.rightReps, set.reps) { mutableStateOf((set.rightReps ?: set.reps)?.toString() ?: "") }
    var duration by remember(set.id, set.durationS) { mutableStateOf(set.durationS?.toString() ?: "") }
    var distance by remember(set.id, set.distanceM, distanceUnits) { mutableStateOf(initialDistance) }
    fun commit(done: Boolean = set.done) = onChange(set.copy(
        weightKg = if (TrainingSetInput.Weight in columns) TrainingSetInput.editedMeasurement(set.weightKg, initialWeight, weight) { TrainingSetInput.massForStore(it, massUnits) } else set.weightKg,
        reps = if (TrainingSetInput.Reps in columns) reps.toIntOrNull() else if (TrainingSetInput.Left in columns) null else set.reps,
        leftReps = if (TrainingSetInput.Left in columns) left.toIntOrNull() else set.leftReps,
        rightReps = if (TrainingSetInput.Right in columns) right.toIntOrNull() else set.rightReps,
        durationS = if (TrainingSetInput.Seconds in columns) duration.toIntOrNull() else set.durationS,
        distanceM = if (TrainingSetInput.Distance in columns) TrainingSetInput.editedMeasurement(set.distanceM, initialDistance, distance) { TrainingSetInput.distanceForStore(it, distanceUnits) } else set.distanceM,
        done = done))
    Row(verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space1), modifier = Modifier.padding(vertical = ForgeMetrics.space1)) {
        Text(if (set.warmup) stringResource(R.string.forge_training_warmup_short) else number.toString(),
             style = Forge.type.bodyNumber, color = Forge.colors.textSecondary, modifier = Modifier.width(ForgeMetrics.space6))
        columns.forEach { field ->
            val value = when (field) {
                TrainingSetInput.Weight -> weight; TrainingSetInput.Reps -> reps; TrainingSetInput.Left -> left
                TrainingSetInput.Right -> right; TrainingSetInput.Seconds -> duration; TrainingSetInput.Distance -> distance
            }
            Box(Modifier.weight(1f)) { NumberField(value, decimal = field == TrainingSetInput.Weight || field == TrainingSetInput.Distance,
                onChange = { input ->
                    val number = input.filter { it.isDigit() || ((field == TrainingSetInput.Weight || field == TrainingSetInput.Distance) && (it == '.' || it == ',')) }
                    when (field) {
                        TrainingSetInput.Weight -> weight = number; TrainingSetInput.Reps -> reps = number; TrainingSetInput.Left -> left = number
                        TrainingSetInput.Right -> right = number; TrainingSetInput.Seconds -> duration = number; TrainingSetInput.Distance -> distance = number
                    }
                }, onDone = { commit() }) }
        }
        IconButton(onClick = { commit(!set.done) }, modifier = Modifier.size(ForgeMetrics.minHitTarget)
            .background(if (set.done) Forge.colors.charge else Forge.colors.inset, CircleShape)) {
            Icon(Icons.Rounded.Check, contentDescription = stringResource(if (set.done) R.string.forge_library_uncomplete_set else R.string.forge_library_complete_set),
                 tint = if (set.done) Color.White else Forge.colors.textTertiary)
        }
    }
}

private fun inputDecimal(value: Double): String = java.text.NumberFormat.getNumberInstance(Locale.getDefault()).apply {
    maximumFractionDigits = 6; isGroupingUsed = false
}.format(value)

private fun formatKg(v: Double): String =
    if (v % 1.0 == 0.0) v.toInt().toString()
    else java.text.NumberFormat.getNumberInstance(Locale.getDefault()).apply { maximumFractionDigits = 1 }.format(v)

@Composable
private fun NumberField(value: String, decimal: Boolean = false, onChange: (String) -> Unit, onDone: () -> Unit = {}) {
    val colors = Forge.colors
    OutlinedTextField(
        value = value, onValueChange = onChange, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = if (decimal) KeyboardType.Decimal else KeyboardType.Number),
        keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { onDone() }),
        shape = RoundedCornerShape(10.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = colors.inset, unfocusedContainerColor = colors.inset,
            focusedBorderColor = colors.accent, unfocusedBorderColor = Color.Transparent,
            focusedTextColor = colors.text, unfocusedTextColor = colors.text),
        modifier = Modifier.fillMaxWidth().onFocusLost(onDone),
    )
}

/** Runs [action] when the field loses focus, so a value typed and left is saved without pressing Done. */
private fun Modifier.onFocusLost(action: () -> Unit): Modifier = composed {
    var focused by remember { mutableStateOf(false) }
    onFocusChanged {
        if (focused && !it.isFocused) action()
        focused = it.isFocused
    }
}

// MARK: - Exercise picker and routine editor

@Composable
private fun ExercisePicker(multiple: Boolean, onBack: () -> Unit, onPicked: (List<String>) -> Unit) {
    ForgeExerciseLibrary(onClose = onBack, multiple = multiple, onPicked = onPicked)
}

/**
 * A routine's name, exercises and weekdays (iOS `RoutineEditorView`, its first section): a new routine when [routine] is
 * null, otherwise that one, its exercises keeping their planned sets.
 */
@Composable
private fun RoutineEditor(exercises: List<CoreTraining.Exercise>, routine: CoreTraining.Routine?, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var title by remember { mutableStateOf(routine?.title ?: "") }
    val chosen = remember { mutableStateListOf<String>().apply { routine?.exerciseIds?.let(::addAll) } }
    val weekdays = remember { mutableStateListOf<Int>().apply { routine?.weekdays?.let(::addAll) } }
    var picking by remember { mutableStateOf(false) }
    val titles = remember(exercises) { exercises.associate { it.id to it.title } }
    if (picking) {
        BackHandler { picking = false }
        ExercisePicker(multiple = true, onBack = { picking = false }) { ids ->
            picking = false
            ids.filterNot { it in chosen }.forEach(chosen::add)
        }
        return
    }
    BackHandler { onClose() }
    val locale = Locale.getDefault()
    SettingsColumn {
        PageTitle(routine?.title ?: stringResource(R.string.forge_training_new_routine), onClose, trailing = {
            TextButton(enabled = title.isNotBlank() && chosen.isNotEmpty(), onClick = {
                scope.launch {
                    core(context) { CoreTraining.createRoutine(title.trim(), chosen.toList(), routine?.id, weekdays.sorted()) }
                    onClose()
                }
            }) { Text(stringResource(R.string.forge_training_save), color = Forge.colors.charge,
                      style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold)) }
        })
        OutlinedTextField(
            value = title, onValueChange = { title = it }, singleLine = true,
            label = { Text(stringResource(R.string.forge_training_routine_name)) },
            colors = OutlinedTextFieldDefaults.colors(
                focusedContainerColor = Forge.colors.surface, unfocusedContainerColor = Forge.colors.surface,
                focusedTextColor = Forge.colors.text, unfocusedTextColor = Forge.colors.text),
            modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (day in 1..7) {
                val on = day in weekdays
                Box(Modifier.weight(1f).height(36.dp)
                        .background(if (on) Forge.colors.accent else Forge.colors.surface, RoundedCornerShape(10.dp))
                        .clickable { if (on) weekdays.remove(day) else weekdays.add(day) },
                    contentAlignment = Alignment.Center) {
                    Text(DayOfWeek.of(day).getDisplayName(TextStyle.SHORT, locale), style = Forge.type.caption,
                         color = if (on) Color.White else Forge.colors.text, maxLines = 1)
                }
            }
        }
        if (chosen.isNotEmpty()) {
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
                chosen.forEachIndexed { i, id ->
                    Row(Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.cardPadding, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Text(titles[id] ?: id, style = Forge.type.body, color = Forge.colors.text, modifier = Modifier.weight(1f))
                        IconButton(onClick = { chosen.remove(id) }) {
                            Icon(Icons.Rounded.Delete, stringResource(R.string.forge_training_remove_exercise),
                                 tint = Forge.colors.textTertiary)
                        }
                    }
                    if (i < chosen.lastIndex) HubDivider()
                }
            }
        }
        PanelButton(stringResource(R.string.forge_training_add_exercise), Icons.Rounded.Add) { picking = true }
        if (routine != null) {
            TextButton(onClick = {
                scope.launch { core(context) { CoreTraining.deleteRoutine(routine.id) }; onClose() }
            }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_training_delete_routine), color = ForgeTokens.Color.systemRed.resolve())
            }
        }
    }
}
