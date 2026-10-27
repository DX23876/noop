package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.noop.R
import com.noop.core.CoreRead
import com.noop.core.CoreTrainingSession
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

/** One detail page is used by the training hub, personal records, Strength and Cardio. */
@Composable
fun ForgeTrainingSessionDetailPage(id: String, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val massUnits = strengthUnits()
    val distanceUnits = UnitPrefs.distanceSystem(context)
    var output by remember { mutableStateOf<CoreTrainingSession.Output?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var revision by remember { mutableIntStateOf(0) }
    var editing by rememberSaveable { mutableStateOf(false) }
    var draft by rememberSaveable { mutableFloatStateOf(7f) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf(false) }
    LaunchedEffect(id, revision) {
        loaded = false
        output = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val profile = ProfileStore.from(context)
            val maxHR = profile.hrMax.toDouble()
            val edges = profile.hrZoneThresholds?.map(Int::toDouble)?.let { it + maxOf(maxHR, it.last()) }
            CoreTrainingSession.read(id, maxHR, edges, dismissedTrainingWorkouts(context))
        }
        loaded = true
    }
    fun save(remove: Boolean) = scope.launch {
        saving = true; error = false
        val ok = withContext(Dispatchers.IO) { CoreTrainingSession.rate(id, draft.toDouble(), remove, dismissedTrainingWorkouts(context)) }
        saving = false
        if (ok) { editing = false; revision++ } else error = true
    }
    BackHandler { if (editing) editing = false else onClose() }
    SettingsColumn {
        PageTitle(output?.title ?: stringResource(R.string.forge_session_title), onClose)
        if (!loaded) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (!loaded) return@SettingsColumn
        val s = output ?: run {
            ReportNote(stringResource(R.string.forge_report_session_unavailable))
            TextButton(onClick = { revision++ }) { Text(stringResource(R.string.forge_report_retry)) }
            return@SettingsColumn
        }
        ReportNote(sessionDate(s.startTs) + " – " + sessionTime(s.endTs))
        ForgeCard(Modifier.fillMaxWidth()) {
            s.durationS?.let { ReportFact(stringResource(R.string.forge_report_duration), sessionDuration(it)) }
            s.avgHr?.let { ReportFact(stringResource(R.string.forge_report_average_hr), "$it bpm") }
            s.maxHr?.let { ReportFact(stringResource(R.string.forge_report_max_hr), "$it bpm") }
            s.distanceM?.let { ReportFact(stringResource(R.string.forge_report_distance), UnitFormatter.distanceFromMeters(it, distanceUnits)) }
            s.energyKcal?.let { ReportFact(stringResource(R.string.forge_report_energy), sessionNumber(it, 0) + " kcal") }
            s.summary?.let { summary ->
                ReportFact(stringResource(R.string.forge_report_working_sets), summary.workingSets.toString())
                ReportFact(stringResource(R.string.forge_report_volume), UnitFormatter.massFromKilograms(summary.volumeKg, massUnits))
                ReportNote(stringResource(R.string.forge_report_volume_coverage, summary.volumeSets, summary.workingSets))
                if (summary.bodyweightVolumeKg > 0) ReportFact(stringResource(R.string.forge_report_bodyweight_volume), UnitFormatter.massFromKilograms(summary.bodyweightVolumeKg, massUnits))
                if (summary.unpricedBodyweightSets > 0) ReportNote(stringResource(R.string.forge_session_bodyweight_unpriced, summary.unpricedBodyweightSets))
                summary.meanRPE?.let {
                    ReportFact(stringResource(R.string.forge_report_average_rpe), sessionNumber(it))
                    ReportNote(stringResource(R.string.forge_report_rated_sets, summary.ratedSets, summary.workingSets))
                }
                summary.densityKgPerMinute?.let {
                    ReportFact(stringResource(R.string.forge_session_density), UnitFormatter.massFromKilograms(it, massUnits) + "/min")
                }
            }
            ReportFact(stringResource(R.string.forge_report_source), if (s.kind == "strength" && s.summary != null) strengthSource(s.source) else s.source)
        }
        OverlineHeader(stringResource(R.string.forge_session_heart_rate), stringResource(R.string.forge_session_body_response))
        ForgeCard(Modifier.fillMaxWidth()) {
            if (s.heartRate.isEmpty()) ReportNote(stringResource(R.string.forge_session_no_hr))
            else {
                SessionHeartChart(s)
                ReportNote(stringResource(R.string.forge_session_hr_note))
            }
        }
        s.zoneMinutes?.takeIf { it.size == 5 && it.sum() > 0 }?.let { zones ->
            OverlineHeader(stringResource(R.string.forge_report_time_in_zone), stringResource(R.string.forge_session_recorded_hr))
            ForgeCard(Modifier.fillMaxWidth()) {
                val colors = listOf(ForgeTokens.StrandPalette.cZone1, ForgeTokens.StrandPalette.cZone2,
                    ForgeTokens.StrandPalette.cZone3, ForgeTokens.StrandPalette.cZone4, ForgeTokens.StrandPalette.cZone5)
                val total = zones.sum()
                zones.forEachIndexed { index, value ->
                    ReportFact("Z${index + 1}", sessionDuration(value * 60))
                    LinearProgressIndicator(progress = { (value / total).toFloat() }, color = colors[index].resolve(), modifier = Modifier.fillMaxWidth())
                }
                ReportNote(stringResource(R.string.forge_session_zone_note))
            }
        }
        OverlineHeader(stringResource(R.string.forge_tl_session_load), stringResource(R.string.forge_session_perception))
        ForgeCard(Modifier.fillMaxWidth()) {
            val rating = s.rating
            if (editing) {
                ReportHeading(stringResource(R.string.forge_session_whole_rpe))
                ReportFact(stringResource(R.string.forge_session_rating), sessionNumber(draft.toDouble()) + " / 10")
                Slider(value = draft, onValueChange = { draft = it }, valueRange = 1f..10f, steps = 17, enabled = !saving,
                    modifier = Modifier.semantics { contentDescription = context.getString(R.string.forge_session_whole_rpe) })
                TextButton(onClick = { save(false) }, enabled = !saving) { Text(stringResource(R.string.forge_session_save_rating)) }
                if (rating != null) TextButton(onClick = { save(true) }, enabled = !saving) { Text(stringResource(R.string.forge_session_remove_rating)) }
                TextButton(onClick = { editing = false }, enabled = !saving) { Text(stringResource(R.string.forge_th_cancel)) }
            } else if (rating == null) {
                ReportHeading(stringResource(R.string.forge_session_question))
                ReportNote(stringResource(R.string.forge_session_rating_note))
                TextButton(onClick = { draft = 7f; editing = true }) { Text(stringResource(R.string.forge_session_rate)) }
            } else {
                ReportFact(stringResource(R.string.forge_session_whole_rpe), sessionNumber(rating.rpe))
                rating.loadAU?.let { ReportFact(stringResource(R.string.forge_tl_session_load), sessionNumber(it, 0) + " AU") }
                rating.durationMinutes?.let { ReportNote(stringResource(R.string.forge_session_rating_formula, sessionNumber(rating.rpe), sessionMinutes(it))) }
                    ?: ReportNote(stringResource(R.string.forge_session_duration_missing))
                ReportNote(stringResource(when (rating.timing) {
                    "about30Minutes" -> R.string.forge_session_rated_delayed
                    "immediately" -> R.string.forge_session_rated_immediate
                    "later" -> R.string.forge_session_rated_later
                    else -> R.string.forge_session_rated_unknown
                }))
                TextButton(onClick = { draft = rating.rpe.toFloat(); editing = true }) { Text(stringResource(R.string.forge_th_edit)) }
            }
            if (saving) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (error) ReportNote(stringResource(R.string.forge_session_save_failed))
        }
        if (s.groups.isNotEmpty()) OverlineHeader(stringResource(R.string.forge_session_what), stringResource(R.string.forge_session_exercises))
        s.groups.forEach { group -> ForgeCard(Modifier.fillMaxWidth()) {
            if (group.size > 1) ReportHeading(stringResource(R.string.forge_session_superset))
            group.forEach { exercise ->
                ReportHeading(exercise.title)
                ReportNote(exercise.primary?.let { hevyMuscleName(it) } ?: stringResource(R.string.forge_session_unmapped))
                if (exercise.secondary.isNotEmpty()) ReportNote(stringResource(R.string.forge_library_also_involved) + ": " + exercise.secondary.map { hevyMuscleName(it) }.joinToString(", "))
                exercise.sets.forEach { set -> SessionSetLine(set, exercise.kind, massUnits, distanceUnits) }
                exercise.notes?.takeIf { it.isNotBlank() }?.let { ReportNote(it) }
            }
        } }
        s.notes?.takeIf { it.isNotBlank() }?.let { note ->
            OverlineHeader(stringResource(R.string.forge_session_notes), stringResource(R.string.forge_session_log))
            ForgeCard(Modifier.fillMaxWidth()) { ReportNote(note) }
        }
        if (s.groups.isNotEmpty()) ReportNote(stringResource(R.string.forge_session_estimate_note))
    }
}

@Composable
private fun SessionSetLine(s: CoreTrainingSession.Set, kind: String, mass: UnitSystem, distance: UnitSystem) {
    val parts = mutableListOf<String>()
    s.weightKg?.takeIf { it > 0 }?.let { value ->
        val sign = if (kind == "assistedBodyweight") "−" else if (kind in listOf("weightedBodyweight", "bodyweightReps") && value > 0) "+" else ""
        parts += sign + UnitFormatter.massFromKilograms(if (kind == "assistedBodyweight") kotlin.math.abs(value) else value, mass)
    } ?: s.bodyweightLoadKg?.let { parts += UnitFormatter.massFromKilograms(it, mass) + " " + stringResource(R.string.forge_session_bodyweight) }
    if (s.leftReps != null || s.rightReps != null) {
        s.leftReps?.let { parts += stringResource(R.string.forge_library_left) + " " + it }
        s.rightReps?.let { parts += stringResource(R.string.forge_library_right) + " " + it }
    } else s.reps?.let { parts += stringResource(R.string.forge_report_reps, it) }
    s.durationS?.let { parts += sessionDuration(it) }
    s.distanceM?.let { parts += UnitFormatter.distanceFromMeters(it, distance) }
    val label = "${s.index + 1} · ${setTypeName(s.type)}"
    Column(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2)) {
        Text(label, style = Forge.type.caption, color = if (s.isWorking) Forge.colors.textSecondary else Forge.colors.textTertiary)
        Text(parts.joinToString(" · ").ifEmpty { "—" }, style = Forge.type.bodyNumber,
            color = if (s.isWorking) Forge.colors.text else Forge.colors.textTertiary)
        s.rpe?.let { ReportNote(stringResource(R.string.forge_session_set_rpe, sessionNumber(it))) }
        if (s.isWorking) s.e1rmKg?.let { ReportNote(stringResource(R.string.forge_session_e1rm, UnitFormatter.massFromKilograms(it, mass))) }
    }
}

/** Gaps wider than the source bucket spacing break the line; a sparse trace stays sparse. */
@Composable
private fun SessionHeartChart(s: CoreTrainingSession.Output) {
    val points = s.heartRate
    val low = points.minOf { it.bpm }; val high = points.maxOf { it.bpm }
    val padding = maxOf(5.0, (high - low) * 0.15)
    val lower = low - padding; val upper = high + padding
    val tint = ForgeTokens.StrandPalette.metricRose.resolve()
    val text = points.joinToString("; ") { sessionTime(it.ts) + " " + sessionNumber(it.bpm, 0) + " bpm" }
    Canvas(Modifier.fillMaxWidth().height(ForgeMetrics.chartHeight * 0.65f).semantics { contentDescription = text }) {
        var previous: Offset? = null
        var previousTs: Long? = null
        points.forEach { point ->
            val current = Offset((size.width * (point.ts - s.startTs).toDouble() / (s.endTs - s.startTs).coerceAtLeast(1)).toFloat(),
                (size.height * (1 - (point.bpm - lower) / (upper - lower))).toFloat())
            if (previousTs?.let { point.ts - it <= s.bucketSeconds * 2 } == true) previous?.let {
                drawLine(tint, it, current, ForgeMetrics.hairline.toPx() * 2)
            }
            drawCircle(tint, ForgeMetrics.hairline.toPx() * 2, current)
            previous = current; previousTs = point.ts
        }
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        ReportNote(sessionTime(s.startTs)); ReportNote("${sessionNumber(low, 0)}–${sessionNumber(high, 0)} bpm"); ReportNote(sessionTime(s.endTs))
    }
}

private fun sessionMinutes(value: Double): String = NumberFormat.getNumberInstance(Locale.getDefault()).apply {
    minimumFractionDigits = 0; maximumFractionDigits = 2
}.format(value)

private fun sessionTime(ts: Long): String = Instant.ofEpochSecond(ts).atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(Locale.getDefault()))
private fun sessionNumber(value: Double, digits: Int = 1): String = NumberFormat.getNumberInstance(Locale.getDefault()).apply {
    minimumFractionDigits = digits; maximumFractionDigits = digits
}.format(value)

@Composable
private fun sessionDuration(seconds: Double): String = if (seconds < 60)
    stringResource(R.string.forge_session_seconds, sessionNumber(seconds, 0))
else stringResource(R.string.forge_session_minutes_seconds, (seconds / 60).toInt(), (seconds % 60).toInt())
