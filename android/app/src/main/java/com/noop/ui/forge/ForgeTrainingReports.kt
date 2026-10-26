package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.KeyboardArrowLeft
import androidx.compose.material.icons.rounded.KeyboardArrowRight
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import com.noop.R
import com.noop.core.CoreRead
import com.noop.core.CoreTrainingReports
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.UnitFormatter
import com.noop.ui.UnitPrefs
import com.noop.ui.UnitSystem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.roundToInt

private const val ALL_HISTORY_DAYS = 20 * 365 + 5 // TrainingHistoryWindow.allDays in StrandCore.
private val windows = listOf(120, 365, ALL_HISTORY_DAYS)

/** Strength uses the same prepared readings, compact editor and mapping as the Apple page. */
@Composable
fun ForgeStrengthPage(onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val massUnits = strengthUnits()
    var days by rememberSaveable { mutableIntStateOf(120) }
    var weekOffset by rememberSaveable { mutableIntStateOf(0) }
    var exerciseId by rememberSaveable { mutableStateOf<String?>(null) }
    var revision by remember { mutableIntStateOf(0) }
    var report by remember { mutableStateOf<CoreTrainingReports.Strength?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var detail by remember { mutableStateOf<CoreTrainingReports.LoggedSession?>(null) }
    var editor by remember { mutableStateOf<CoreTrainingReports.GenericSession?>(null) }
    var mapping by remember { mutableStateOf<String?>(null) }
    var feedback by remember { mutableStateOf<String?>(null) }
    var actionError by remember { mutableStateOf(false) }
    var actionBusy by remember { mutableStateOf(false) }
    LaunchedEffect(days, weekOffset, exerciseId, revision) {
        loaded = false
        report = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreTrainingReports.strength(days, weekOffset, exerciseId,
                firstWeekday = if (NoopPrefs.of(context).getString("training.weekStartsOn", null) == "sunday") 1 else 2,
                dismissedWorkouts = dismissedTrainingWorkouts(context))
        }
        loaded = true
    }
    fun openSession(id: String) {
        scope.launch {
            actionBusy = true
            val found = withContext(Dispatchers.IO) { CoreTrainingReports.session(id) }
            actionBusy = false
            if (found == null) actionError = true else detail = found
        }
    }
    BackHandler {
        when { detail != null -> detail = null; editor != null -> editor = null; else -> onClose() }
    }
    detail?.let { LoggedSessionPage(it, massUnits) { detail = null }; return }
    editor?.let { session ->
        StrengthDetailsPage(session, report?.muscles.orEmpty().map { it.id }, onClose = { editor = null }) {
            editor = null; revision++
        }
        return
    }
    mapping?.let { title ->
        StrengthMappingDialog(title, report?.muscles.orEmpty().map { it.id }, onClose = { mapping = null }) {
            mapping = null; revision++
        }
    }
    feedback?.let { muscle ->
        MuscleFeedbackDialog(muscle, onClose = { feedback = null }) { feedback = null; revision++ }
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_th_strength), onClose)
        ReportRange(days) { days = it; weekOffset = 0; exerciseId = null }
        if (!loaded) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (!loaded && report == null) return@SettingsColumn
        val r = report ?: run { ReportUnavailable { revision++ }; return@SettingsColumn }
        ReportWeek(r.selection) { weekOffset = it }
        val lane = r.lane
        LoadHeroCard(TrainingLane.Strength, lane.percent, LoadPill.of(lane.band, lane.guardState),
            stringResource(R.string.forge_tl_working_sets, lane.sevenDayWorkingSets),
            r.ratios.mapNotNull { it.strength }, strengthEvidence(lane),
            if (lane.possibleCount > lane.measuredCount) stringResource(R.string.forge_tl_caveat_rpe,
                lane.measuredCount, lane.possibleCount) else null, capNote(lane),
            stringResource(R.string.forge_tl_strength_load))
        ReportNote(stringResource(R.string.forge_report_rolling_through, shortDate(r.selection.readingDay)))
        ReportFacts(listOf(
            stringResource(R.string.forge_report_sessions) to integer(r.sessions),
            stringResource(R.string.forge_report_working_sets) to integer(r.workingSets),
            stringResource(R.string.forge_report_volume) to if (r.volumeSets > 0) mass(r.volumeKg, massUnits) else "—"))
        if (r.volumeSets < r.workingSets) ReportNote(stringResource(R.string.forge_report_volume_coverage, r.volumeSets, r.workingSets))
        if (r.charge != null || r.effort != null) ForgeCard(Modifier.fillMaxWidth()) {
            r.charge?.let { ReportFact(stringResource(R.string.forge_report_charge), integer(it.roundToInt())) }
            r.effort?.let { ReportFact(stringResource(R.string.forge_effort), decimal(it, 1)) }
        }
        if (r.bodyweightSets > 0 || r.unpricedBodyweightSets > 0) ForgeCard(Modifier.fillMaxWidth()) {
            ReportFact(stringResource(R.string.forge_report_bodyweight_volume), mass(r.bodyweightKg, massUnits))
            ReportNote(stringResource(R.string.forge_report_bodyweight_coverage, r.bodyweightSets, r.unpricedBodyweightSets))
        }
        ReportLoadChart(r.ratios, TrainingLane.Strength)
        OverlineHeader(stringResource(R.string.forge_report_muscles), weekLabel(r.selection))
        ForgeCard(Modifier.fillMaxWidth()) {
            ReportNote(stringResource(R.string.forge_report_muscle_method))
            r.muscles.filter { it.primarySets > 0 || it.secondarySets > 0 || (it.fatigue ?: 0.0) > 0.01 }
                .sortedByDescending { it.primarySets }.forEach { muscle ->
                    Column(Modifier.fillMaxWidth().clickable { feedback = muscle.id }.padding(vertical = ForgeMetrics.space2)) {
                        ReportFact(hevyMuscleName(muscle.id),
                            stringResource(R.string.forge_report_primary_secondary, muscle.primarySets, muscle.secondarySets))
                        muscle.usualSets?.let { ReportNote(stringResource(R.string.forge_report_usual_sets,
                            decimal(it.lower, 0), decimal(it.upper, 0))) }
                        muscle.band?.let { ReportNote(bandLabel(it)) }
                        ReportNote(stringResource(R.string.forge_report_feedback_prompt))
                    }
                }
            if (r.muscles.none { it.primarySets > 0 || it.secondarySets > 0 }) ReportNote(stringResource(R.string.forge_no_data))
            if (r.unattributedSets > 0) ReportFact(stringResource(R.string.forge_report_unattributed), integer(r.unattributedSets))
            r.unmappedExercises.forEach { title -> ReportRow(title, stringResource(R.string.forge_report_map_exercise)) { mapping = title } }
        }
        if (r.balance.isNotEmpty()) {
            OverlineHeader(stringResource(R.string.forge_report_balance), stringResource(R.string.forge_report_muscles))
            ForgeCard(Modifier.fillMaxWidth()) {
                r.balance.forEach { axis ->
                    val names = balanceNames(axis.axis)
                    ReportFact(names, "${integer(axis.setsA)} : ${integer(axis.setsB)}")
                }
                ReportNote(stringResource(R.string.forge_report_balance_method))
            }
        }
        OverlineHeader(stringResource(R.string.forge_report_strength_history), rangeLabel(r.selection.days))
        ForgeCard(Modifier.fillMaxWidth()) {
            ReportFact(stringResource(R.string.forge_report_sessions), integer(r.overview.sessions))
            ReportFact(stringResource(R.string.forge_report_working_sets), integer(r.overview.workingSets))
            ReportFact(stringResource(R.string.forge_report_active_weeks), "${integer(r.overview.activeWeeks)} / ${integer(r.overview.observedWeeks)}")
            ReportFact(stringResource(R.string.forge_report_duration),
                if (r.overview.durationSessions > 0) minutes(r.overview.durationSeconds / 60.0) else "—")
            if (r.overview.durationSessions < r.overview.sessions) ReportNote(stringResource(R.string.forge_report_duration_coverage,
                r.overview.durationSessions, r.overview.sessions))
            r.overview.averageRPE?.let {
                ReportFact(stringResource(R.string.forge_report_average_rpe), decimal(it, 1))
                ReportNote(stringResource(R.string.forge_report_rated_sets, r.overview.ratedSets, r.overview.workingSets))
            }
            if (r.overview.records.isNotEmpty()) {
                ReportDivider()
                ReportHeading(stringResource(R.string.forge_report_personal_records))
                r.overview.records.take(6).forEach { record ->
                    ReportRow(record.exerciseTitle,
                        "${stringResource(R.string.forge_report_best_e1rm)}: ${mass(record.estimatedOneRepMaxKg, massUnits)} · ${sessionDate(record.timestamp)}") { openSession(record.workoutId) }
                }
            }
        }
        OverlineHeader(stringResource(R.string.forge_report_exercise_progress), rangeLabel(r.selection.days))
        ForgeCard(Modifier.fillMaxWidth()) {
            ReportPicker(r.exercise.choices.firstOrNull { it.id == r.exercise.selectedId }?.title
                ?: stringResource(R.string.forge_report_exercise), r.exercise.choices.map { it.title }) {
                exerciseId = r.exercise.choices[it].id
            }
            val format: (Double) -> String = { mass(it, massUnits) }
            ReportChart(r.exercise.points, TrainingLane.Strength.color,
                stringResource(if (r.exercise.isVolume) R.string.forge_report_volume else R.string.forge_report_best_e1rm), format)
            r.exercise.trend?.let { trend ->
                ReportFact(stringResource(R.string.forge_report_progress),
                    if (trend.unclear) stringResource(R.string.forge_tl_unclear)
                    else stringResource(R.string.forge_report_per_week, signed(trend.slopePerWeek, format)))
            }
            listOf(R.string.forge_report_best_e1rm to r.exercise.bestEstimatedOneRepMax,
                R.string.forge_report_heaviest_set to r.exercise.heaviestSet,
                R.string.forge_report_best_volume to r.exercise.bestSessionVolume).forEach { (label, record) ->
                record?.let { ReportRow(stringResource(label), "${format(it.value)} · ${shortDate(it.day)}") { openSession(it.workoutId) } }
            }
            r.exercise.repRecords.toSortedMap().forEach { (band, record) ->
                ReportRow(repBandName(band), "${format(record.value)} · ${shortDate(record.day)}") { openSession(record.workoutId) }
            }
        }
        OverlineHeader(stringResource(R.string.forge_report_recent_sessions), rangeLabel(r.selection.days))
        ForgeCard(Modifier.fillMaxWidth()) {
            if (r.recentSessions.isEmpty() && r.genericSessions.isEmpty()) ReportNote(stringResource(R.string.forge_no_data))
            r.genericSessions.take(6).forEach { session ->
                ReportRow(session.title, "${sessionDate(session.startTs)} · ${stringResource(R.string.forge_report_add_details)}") { editor = session }
            }
            r.recentSessions.filter { session -> r.genericSessions.none { it.manualWorkoutId == session.id } }.take(10).forEach { session -> ReportRow(session.title, sessionDate(session.startTs)) { detail = session } }
        }
        if (actionBusy) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (actionError) ReportNote(stringResource(R.string.forge_report_session_unavailable))
        Spacer(Modifier.height(ForgeMetrics.space4))
    }
}

/** Cardio keeps measured zone time separate from average-HR estimates. */
@Composable
fun ForgeCardioPage(onClose: () -> Unit) {
    val context = LocalContext.current
    val units = UnitPrefs.distanceSystem(context)
    var days by rememberSaveable { mutableIntStateOf(120) }
    var weekOffset by rememberSaveable { mutableIntStateOf(0) }
    var sport by rememberSaveable { mutableStateOf<String?>(null) }
    var retry by remember { mutableIntStateOf(0) }
    var report by remember { mutableStateOf<CoreTrainingReports.Cardio?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var detail by remember { mutableStateOf<CoreTrainingReports.CardioSession?>(null) }
    LaunchedEffect(days, weekOffset, sport, retry) {
        loaded = false
        report = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val profile = ProfileStore.from(context)
            val maxHR = profile.hrMax.toDouble()
            val edges = profile.hrZoneThresholds?.map(Int::toDouble)?.let { it + maxOf(maxHR, it.last()) }
            CoreTrainingReports.cardio(maxHR, profile.sex, edges, days, weekOffset, sport,
                dismissedTrainingWorkouts(context))
        }
        loaded = true
    }
    BackHandler { if (detail != null) detail = null else onClose() }
    detail?.let { CardioSessionPage(it, units) { detail = null }; return }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_tl_cardio), onClose)
        ReportRange(days) { days = it; weekOffset = 0; sport = null }
        if (!loaded) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (!loaded && report == null) return@SettingsColumn
        val r = report ?: run { ReportUnavailable { retry++ }; return@SettingsColumn }
        ReportWeek(r.selection) { weekOffset = it }
        r.lane?.let { lane ->
            val total = stringResource(R.string.forge_tl_trimp, lane.sevenDayTotal.roundToInt())
            LoadHeroCard(TrainingLane.Cardio, lane.percent, LoadPill.of(lane.band, lane.guardState),
                if (lane.isLowerBound) stringResource(R.string.forge_tl_at_least, total) else total,
                r.ratios.mapNotNull { it.cardio }, cardioEvidence(lane),
                if (lane.isLowerBound) stringResource(R.string.forge_tl_caveat_lower_bound, lane.measuredCount, lane.possibleCount) else null,
                capNote(lane), stringResource(R.string.forge_tl_cardiovascular_load))
        }
        ReportNote(stringResource(R.string.forge_report_rolling_through, shortDate(r.selection.readingDay)))
        ReportFacts(listOf(
            stringResource(R.string.forge_report_sessions) to integer(r.weekSessions),
            stringResource(R.string.forge_report_duration) to minutes(r.minutes),
            stringResource(R.string.forge_report_distance) to UnitFormatter.distanceFromMeters(r.distanceM, units)))
        ReportNote(stringResource(R.string.forge_report_distance_coverage, r.sessionsWithDistance, r.weekSessions))
        if (r.averageHr != null || r.charge != null) ForgeCard(Modifier.fillMaxWidth()) {
            r.averageHr?.let { ReportFact(stringResource(R.string.forge_report_average_hr), "${integer(it.roundToInt())} bpm") }
            r.charge?.let { ReportFact(stringResource(R.string.forge_report_charge), integer(it.roundToInt())) }
        }
        ReportLoadChart(r.ratios, TrainingLane.Cardio)
        OverlineHeader(stringResource(R.string.forge_report_intensity), stringResource(R.string.forge_report_time_in_zone))
        ForgeCard(Modifier.fillMaxWidth()) {
            val zones = r.zones
            if (zones == null || zones.minutes.sum() <= 0) ReportNote(stringResource(R.string.forge_tl_caveat_no_trace))
            else {
                val total = zones.minutes.sum()
                val colors = listOf(ForgeTokens.StrandPalette.cZone1, ForgeTokens.StrandPalette.cZone2,
                    ForgeTokens.StrandPalette.cZone3, ForgeTokens.StrandPalette.cZone4, ForgeTokens.StrandPalette.cZone5)
                zones.minutes.forEachIndexed { index, value ->
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
                        Text(stringResource(R.string.l10n_live_workout_screen_z_z_d3991a28, index + 1), style = Forge.type.caption, color = Forge.colors.text)
                        LinearProgressIndicator(progress = { (value / total).toFloat().coerceIn(0f, 1f) },
                            modifier = Modifier.weight(1f), color = colors[index.coerceAtMost(colors.lastIndex)].resolve())
                        Text(minutes(value), style = Forge.type.caption, color = Forge.colors.textSecondary)
                    }
                }
                ReportNote(stringResource(R.string.forge_report_zone_coverage, zones.sessionsRead, zones.sessionsPossible))
                if (zones.usedMinuteBuckets) ReportNote(stringResource(R.string.forge_report_minute_buckets))
            }
        }
        OverlineHeader(stringResource(R.string.forge_report_week_spent), stringResource(R.string.forge_report_moving_time))
        ForgeCard(Modifier.fillMaxWidth()) {
            if (r.sports.isEmpty()) ReportNote(stringResource(R.string.forge_no_data))
            r.sports.forEach { ReportFact(it.name, minutes(it.minutes)) }
        }
        if (r.loadShares.isNotEmpty()) ForgeCard(Modifier.fillMaxWidth()) {
            ReportHeading(stringResource(R.string.forge_report_load_share))
            r.loadShares.forEach { ReportFact(it.sport, "${decimal(it.share * 100, 0)}%") }
        }
        OverlineHeader(stringResource(R.string.forge_report_progress), rangeLabel(r.selection.days))
        ForgeCard(Modifier.fillMaxWidth()) {
            val progress = r.progress
            ReportPicker(progress.selectedSport ?: stringResource(R.string.forge_report_sport), progress.choices) { sport = progress.choices[it] }
            val format: (Double) -> String = if (progress.metric == "speed") {
                { UnitFormatter.speedFromKilometersPerHour(it, units) ?: "—" }
            } else { { reportPace(it, progress.modality, units) } }
            if (progress.metric != "none") {
                ReportChart(progress.pace, TrainingLane.Cardio.color,
                    stringResource(if (progress.metric == "speed") R.string.forge_report_speed else R.string.forge_report_pace), format)
                progress.paceTrend?.let { trend ->
                    ReportFact(stringResource(R.string.forge_report_progress), if (trend.unclear) stringResource(R.string.forge_tl_unclear)
                        else stringResource(R.string.forge_report_per_week,
                            signed(trend.slopePerWeek) { rate -> cardioRate(rate, progress.metric, progress.modality, units) }))
                }
            }
            if (progress.efficiency.isNotEmpty()) {
                ReportChart(progress.efficiency, TrainingLane.Cardio.color,
                    stringResource(R.string.forge_report_heart_cost)) { value ->
                    val converted = if (units == UnitSystem.IMPERIAL) value / UnitFormatter.MILES_PER_KILOMETER else value
                    "${decimal(converted, 0)} /${UnitFormatter.distanceUnit(units)}"
                }
                ReportNote(stringResource(R.string.forge_report_heart_cost_method))
            }
            if (progress.paceBests.isNotEmpty()) {
                ReportHeading(stringResource(R.string.forge_report_bests))
                progress.paceBests.toSortedMap().forEach { (band, best) ->
                    val session = r.sessions.firstOrNull { it.startTs == best.startTs && it.sport == best.sport }
                    val value = if (progress.metric == "speed") UnitFormatter.speedFromKilometersPerHour(session?.speedKmh, units) ?: "—"
                        else reportPace(best.value, progress.modality, units)
                    ReportRow(distanceBandName(band), "$value · ${shortDate(best.day)}") { detail = session }
                }
            }
            progress.farthest?.let { best ->
                ReportRow(stringResource(R.string.forge_report_distance), "${UnitFormatter.distanceFromMeters(best.value, units)} · ${shortDate(best.day)}") {
                    detail = r.sessions.firstOrNull { it.startTs == best.startTs && it.sport == best.sport }
                }
            }
            progress.longest?.let { best ->
                ReportRow(stringResource(R.string.forge_report_duration), "${minutes(best.value / 60)} · ${shortDate(best.day)}") {
                    detail = r.sessions.firstOrNull { it.startTs == best.startTs && it.sport == best.sport }
                }
            }
        }
        OverlineHeader(stringResource(R.string.forge_report_recent_sessions), rangeLabel(r.selection.days))
        if (r.sessions.isEmpty()) ForgeCard(Modifier.fillMaxWidth()) { ReportNote(stringResource(R.string.forge_no_data)) }
        r.sessions.groupBy { it.family }.forEach { (family, sessions) ->
            ForgeCard(Modifier.fillMaxWidth()) {
                ReportHeading(familyName(family))
                sessions.take(10).forEach { session -> ReportRow(session.sport, sessionDate(session.startTs)) { detail = session } }
            }
        }
        Spacer(Modifier.height(ForgeMetrics.space4))
    }
}

@Composable
private fun ReportRange(days: Int, choose: (Int) -> Unit) {
    ForgeSegmented(windows.map { rangeLabel(it) }, windows.indexOf(days).coerceAtLeast(0), Modifier.fillMaxWidth()) { choose(windows[it]) }
}

@Composable
private fun rangeLabel(days: Int): String = when (days) {
    120 -> stringResource(R.string.forge_report_120_days)
    365 -> stringResource(R.string.forge_th_past_year)
    else -> stringResource(R.string.forge_report_all)
}

@Composable
private fun weekLabel(selection: CoreTrainingReports.Selection) = "${reportDate(selection.monday)} – ${reportDate(selection.sunday)}"

@Composable
private fun ReportWeek(selection: CoreTrainingReports.Selection, choose: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { choose(selection.weekOffset - 1) }, enabled = selection.weekOffset > selection.minWeekOffset) {
            Icon(Icons.Rounded.KeyboardArrowLeft, stringResource(R.string.forge_report_previous_week), tint = Forge.sceneInk.text)
        }
        Text(weekLabel(selection), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.sceneInk.text,
            modifier = Modifier.weight(1f), textAlign = TextAlign.Center)
        IconButton(onClick = { choose(selection.weekOffset + 1) }, enabled = selection.weekOffset < 0) {
            Icon(Icons.Rounded.KeyboardArrowRight, stringResource(R.string.forge_report_next_week), tint = Forge.sceneInk.text)
        }
    }
}

@Composable
private fun ReportLoadChart(ratios: List<CoreTrainingReports.Ratio>, lane: TrainingLane) {
    OverlineHeader(stringResource(R.string.forge_tl_strength_load).let { if (lane == TrainingLane.Strength) it else stringResource(R.string.forge_tl_cardiovascular_load) },
        stringResource(R.string.forge_report_progress))
    ForgeCard(Modifier.fillMaxWidth()) {
        val points = ratios.map { point -> CoreTrainingReports.Point(point.day,
            java.time.LocalDate.parse(point.day).atStartOfDay(ZoneId.systemDefault()).toEpochSecond(),
            if (lane == TrainingLane.Strength) point.strength else point.cardio) }
        ReportChart(points, lane.color, stringResource(R.string.forge_report_relative_load)) { "${decimal(it * 100, 0)}%" }
    }
}

/** Time is spaced by timestamps; a missing measurement breaks the line and never becomes zero. */
@Composable
private fun ReportChart(points: List<CoreTrainingReports.Point>, tint: Color, label: String, format: (Double) -> String) {
    val ordered = points.sortedBy { it.startTs }
    val valid = ordered.filter { it.value?.isFinite() == true }
    ReportHeading(label)
    if (valid.isEmpty()) { ReportNote(stringResource(R.string.forge_no_data)); return }
    val lo = valid.minOf { it.value!! }; val hi = valid.maxOf { it.value!! }
    val span = (hi - lo).takeIf { it > 0 } ?: maxOf(1.0, kotlin.math.abs(hi) * 0.1)
    val lower = lo - span * 0.1; val upper = hi + span * 0.1
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        ReportNote(format(lo)); ReportNote(format(hi))
    }
    val description = label + ": " + valid.joinToString("; ") { "${reportDate(it.day)} ${format(it.value!!)}" }
    val grid = Forge.colors.inset
    Canvas(Modifier.fillMaxWidth().height(ForgeMetrics.chartHeight).semantics { contentDescription = description }) {
        val padding = ForgeMetrics.space2.toPx()
        val start = ordered.first().startTs; val end = ordered.last().startTs
        val width = size.width - padding * 2; val height = size.height - padding * 2
        drawLine(grid, Offset(padding, size.height - padding), Offset(size.width - padding, size.height - padding), ForgeMetrics.hairline.toPx())
        var previous: Offset? = null
        ordered.forEach { point ->
            val value = point.value?.takeIf { it.isFinite() }
            if (value == null) previous = null else {
                val x = if (end == start) size.width / 2 else padding + width * ((point.startTs - start).toDouble() / (end - start)).toFloat()
                val y = padding + height * (1 - (value - lower) / (upper - lower)).toFloat()
                val current = Offset(x, y)
                previous?.let { drawLine(tint, it, current, ForgeMetrics.hairline.toPx() * 2) }
                drawCircle(tint, ForgeMetrics.hairline.toPx() * 3, current)
                previous = current
            }
        }
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        ReportNote(reportDate(ordered.first().day)); ReportNote(reportDate(ordered.last().day))
    }
}

@Composable
private fun ReportUnavailable(retry: () -> Unit) {
    ForgeCard(Modifier.fillMaxWidth()) {
        ReportNote(stringResource(R.string.forge_report_load_failed))
        TextButton(onClick = retry) { Text(stringResource(R.string.forge_report_retry)) }
    }
}

@Composable
private fun ReportFacts(items: List<Pair<String, String>>) {
    ForgeCard(Modifier.fillMaxWidth()) { items.forEach { (name, value) -> ReportFact(name, value) } }
}

@Composable
internal fun ReportFact(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space1), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        Text(label, style = Forge.type.subhead, color = Forge.colors.textSecondary, modifier = Modifier.weight(1f))
        Text(value, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text,
            textAlign = TextAlign.End, modifier = Modifier.weight(1f))
    }
}

@Composable
internal fun ReportNote(text: String) { Text(text, style = Forge.type.caption, color = Forge.colors.textSecondary) }
@Composable
internal fun ReportHeading(text: String) { Text(text, style = Forge.type.headline, color = Forge.colors.text) }
@Composable
private fun ReportRow(title: String, subtitle: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
            ReportNote(subtitle)
        }
        Icon(Icons.Rounded.KeyboardArrowRight, contentDescription = null, tint = Forge.colors.textTertiary)
    }
}
@Composable
internal fun ReportPicker(title: String, choices: List<String>, choose: (Int) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clickable(enabled = choices.isNotEmpty()) { expanded = true }.padding(vertical = ForgeMetrics.space2),
        verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = Forge.type.headline, color = Forge.colors.text, modifier = Modifier.weight(1f))
        Icon(Icons.Rounded.KeyboardArrowRight, null, tint = Forge.colors.textSecondary)
        DropdownMenu(expanded, { expanded = false }, Modifier.heightIn(max = ForgeMetrics.chartHeight)) {
            choices.forEachIndexed { index, choice -> DropdownMenuItem(text = { Text(choice) }, onClick = { expanded = false; choose(index) }) }
        }
    }
}
@Composable
private fun ReportDivider() { Spacer(Modifier.height(ForgeMetrics.space2)) }

@Composable
private fun LoggedSessionPage(s: CoreTrainingReports.LoggedSession, massUnits: UnitSystem, onClose: () -> Unit) {
    val units = UnitPrefs.distanceSystem(LocalContext.current)
    SettingsColumn {
        PageTitle(s.title, onClose)
        ReportNote(sessionDate(s.startTs))
        ForgeCard(Modifier.fillMaxWidth()) {
            s.durationS?.let { ReportFact(stringResource(R.string.forge_report_duration), minutes(it / 60)) }
            ReportFact(stringResource(R.string.forge_report_source), strengthSource(s.source))
        }
        s.exercises.forEach { exercise ->
            ForgeCard(Modifier.fillMaxWidth()) {
                ReportHeading(exercise.title)
                exercise.sets.forEachIndexed { index, set ->
                    val measure = listOfNotNull(set.weightKg?.let { mass(it, massUnits) },
                        set.reps?.let { stringResource(R.string.forge_report_reps, it) },
                        set.durationS?.let { minutes(it / 60) }, set.distanceM?.let { UnitFormatter.distanceFromMeters(it, units) },
                        set.rpe?.let { "RPE ${decimal(it, 1)}" })
                    ReportFact("${index + 1} · ${setTypeName(set.type)}", measure.joinToString(" · ").ifEmpty { "—" })
                }
            }
        }
    }
}

@Composable
private fun CardioSessionPage(s: CoreTrainingReports.CardioSession, units: UnitSystem, onClose: () -> Unit) {
    SettingsColumn {
        PageTitle(s.sport, onClose)
        ReportNote(sessionDate(s.startTs))
        ForgeCard(Modifier.fillMaxWidth()) {
            s.durationS?.let { ReportFact(stringResource(R.string.forge_report_duration), minutes(it / 60)) }
            s.distanceM?.let { ReportFact(stringResource(R.string.forge_report_distance), UnitFormatter.distanceFromMeters(it, units)) }
            s.avgHr?.let { ReportFact(stringResource(R.string.forge_report_average_hr), "${integer(it)} bpm") }
            s.maxHr?.let { ReportFact(stringResource(R.string.forge_report_max_hr), "${integer(it)} bpm") }
            s.cardioLoad?.let { ReportFact(stringResource(R.string.forge_tl_cardiovascular_load), decimal(it, 0)) }
            when (s.modality) {
                "cycling", "rowing" -> s.speedKmh?.let { ReportFact(stringResource(R.string.forge_report_speed), UnitFormatter.speedFromKilometersPerHour(it, units) ?: "—") }
                "foot", "swimming" -> s.paceSecPerKm?.let { ReportFact(stringResource(R.string.forge_report_pace), reportPace(it, s.modality, units)) }
            }
            s.energyKcal?.let { ReportFact(stringResource(R.string.forge_report_energy), "${integer(it.roundToInt())} kcal") }
            ReportFact(stringResource(R.string.forge_report_source), s.source)
        }
    }
}

@Composable
internal fun strengthUnits(): UnitSystem {
    val context = LocalContext.current
    return when (NoopPrefs.of(context).getString("training.weightUnit", null)) {
        "pounds" -> UnitSystem.IMPERIAL
        "kilograms" -> UnitSystem.METRIC
        else -> UnitPrefs.system(context)
    }
}
internal fun sessionDate(ts: Long): String = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
    .withLocale(Locale.getDefault()).withZone(ZoneId.systemDefault()).format(Instant.ofEpochSecond(ts))
private fun integer(value: Int): String = NumberFormat.getIntegerInstance(Locale.getDefault()).format(value)
private fun decimal(value: Double, digits: Int): String = NumberFormat.getNumberInstance(Locale.getDefault()).apply {
    maximumFractionDigits = digits; minimumFractionDigits = digits
}.format(value)
private fun signed(value: Double, format: (Double) -> String): String = (if (value < 0) "−" else "+") + format(kotlin.math.abs(value))
private fun mass(kg: Double, units: UnitSystem): String = UnitFormatter.massFromKilograms(kg, units)
private fun minutes(value: Double): String = "${integer(value.roundToInt())} min"
internal fun reportPace(secondsPerKm: Double, modality: String, units: UnitSystem): String {
    if (modality != "swimming") return UnitFormatter.paceFromSecPerKm(secondsPerKm, units)
    val seconds = (secondsPerKm / 10).roundToInt()
    return "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')} /100 m"
}
internal fun cardioRate(rate: Double, metric: String, modality: String, units: UnitSystem): String = when {
    metric == "speed" -> UnitFormatter.speedFromKilometersPerHour(rate, units) ?: "—"
    modality == "swimming" -> "${decimal(rate / 10, 1)} s/100 m"
    else -> "${decimal(if (units == UnitSystem.IMPERIAL) rate / UnitFormatter.MILES_PER_KILOMETER else rate, 1)} s/${UnitFormatter.distanceUnit(units)}"
}

private fun reportDate(day: String): String = java.time.LocalDate.parse(day)
    .format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(Locale.getDefault()))
