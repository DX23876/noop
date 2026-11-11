package com.noop.ui.forge

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.DirectionsWalk
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.MedicalServices
import androidx.compose.material.icons.rounded.Psychology
import androidx.compose.material.icons.rounded.Science
import androidx.compose.material.icons.rounded.SentimentSatisfied
import androidx.compose.material.icons.rounded.Thermostat
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material.icons.rounded.WaterDrop
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.noop.R
import com.noop.core.CoreCycle
import com.noop.data.CycleLogStore
import com.noop.notif.CyclePagePrefs
import com.noop.notif.FertileReminderWorker
import com.noop.ui.AppViewModel
import com.noop.ui.HostedPalette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle
import java.time.temporal.TemporalAdjusters
import java.util.Locale
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/*
 * Fork (DX23876), Forge parity 2026-11: the cycle as one place, as iOS `ForgeCycleView` (prototype board
 * "CycleWheel"): the cycle day on a dial of real days, the three ways to log, what this phase tends to mean, the
 * nightly temperature of this cycle, a calendar, the history and the settings, with the fertile-days page, the topic
 * pages and the log sheet. The phase, the shift and the next-period window are the engine's; the cycle day counts from
 * the start the wearer logged. Awareness only, opt-in, on this phone. Analysis migration required: no.
 */

@Composable
internal fun CycleText.text(): String = if (args.isEmpty()) stringResource(res) else stringResource(res, *args.toTypedArray())

/** The colour a phase is drawn in. */
@Composable
internal fun CyclePhase.color(): Color = when (this) {
    CyclePhase.Period -> Forge.colors.cyclePeriod
    CyclePhase.Follicular -> Forge.colors.cycleFollicular
    CyclePhase.Shift -> Forge.colors.cycleShift
    CyclePhase.Luteal -> Forge.colors.rest
}

@Composable
private fun CyclePush.Tone.color(): Color = when (this) {
    CyclePush.Tone.Period -> Forge.colors.cyclePeriod
    CyclePush.Tone.Follicular -> Forge.colors.cycleFollicular
    CyclePush.Tone.Shift -> Forge.colors.cycleShift
    CyclePush.Tone.Rest -> Forge.colors.rest
    CyclePush.Tone.Effort -> Forge.colors.effort
    CyclePush.Tone.Charge -> Forge.colors.charge
    CyclePush.Tone.Text -> Forge.colors.text
}

private val CycleTopic.icon: ImageVector get() = when (this) {
    CycleTopic.Mind -> Icons.Rounded.Psychology
    CycleTopic.Exercise -> Icons.AutoMirrored.Rounded.DirectionsWalk
    CycleTopic.Body -> Icons.Rounded.Thermostat
}

/** The loaded state of the cycle: the starts, the day log, the snapshot and the training pattern. */
internal class CycleLoaded(val starts: List<String>, val log: Map<String, CycleLogStore.Day>, val snap: CycleSnapshot?,
                           val pattern: CoreCycle.Pattern?)

/** Reads the logged days, builds the snapshot off the main thread and re-arms the fertile reminder. */
@Composable
internal fun rememberCycle(viewModel: AppViewModel, reload: Int, learning: Boolean = false, showFertile: Boolean): CycleLoaded? {
    val context = LocalContext.current
    val enabled by viewModel.cycleTrackingEnabled.collectAsState()
    val starts by viewModel.periodStarts.collectAsState()
    val v5 by viewModel.v5Signals.collectAsState()
    val days by viewModel.recentDays.collectAsState()
    val loaded by produceState<CycleLoaded?>(null, enabled, starts, v5?.cycle, days, reload, learning, showFertile) {
        if (!enabled) { value = null; return@produceState }
        value = withContext(Dispatchers.IO) {
            val today = LocalDate.now()
            val log = runCatching { CycleLogStore(viewModel.repo).read(today.minusDays(180).toString(), today.toString()) }
                .getOrDefault(emptyMap())
            val result = v5?.cycle
            val snap = CycleSnapshot.make(result, starts, log, days, today,
                if (showFertile) { past, rise, test, day -> runCatching { CoreCycle.fertile(past, rise, test, day) }.getOrNull() } else null)
            runCatching { FertileReminderWorker.reschedule(context, snap.fertileStartAhead) }
            val pattern = if (learning) runCatching {
                CoreCycle.pattern(context, CycleSnapshot.cycles(starts, log, result), dismissedTrainingWorkouts(context))
            }.getOrNull() else null
            CycleLoaded(starts, log, snap, pattern)
        }
    }
    return loaded
}

private enum class CycleSub { Log, Fertile, History }

@Composable
internal fun ForgeCyclePage(viewModel: AppViewModel, onBack: () -> Unit, startLogging: Boolean = false) {
    val context = LocalContext.current
    val colors = Forge.colors
    val enabled by viewModel.cycleTrackingEnabled.collectAsState()
    var learning by remember { mutableStateOf(CyclePagePrefs.learning(context)) }
    var showFertile by remember { mutableStateOf(CyclePagePrefs.showFertile(context)) }
    var reload by remember { mutableIntStateOf(0) }
    val loaded = rememberCycle(viewModel, reload, learning, showFertile)
    var sub by remember { mutableStateOf(if (startLogging) CycleSub.Log else null) }
    var topic by remember { mutableStateOf<CycleTopic?>(null) }
    val days by viewModel.recentDays.collectAsState()
    val charge = days.lastOrNull { it.day == LocalDate.now().toString() }?.recovery

    when {
        sub == CycleSub.Log && loaded != null -> {
            BackHandler { sub = null }
            CycleLogPage(viewModel, loaded, onDone = { sub = null; reload++ })
            return
        }
        sub == CycleSub.Fertile && loaded?.snap != null -> {
            BackHandler { sub = null }
            CycleFertilePage(loaded.snap, onBack = { sub = null }, onLog = { sub = CycleSub.Log })
            return
        }
        topic != null && loaded?.snap?.phase != null -> {
            BackHandler { topic = null }
            val snap = loaded.snap
            CycleTopicPage(topic!!, snap.phase!!, snap, CyclePush.make(topic!!, snap.phase, charge, if (learning) loaded.pattern else null),
                           if (learning) loaded.pattern else null, onBack = { topic = null })
            return
        }
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_cy_title), onBack)
        if (!enabled) {
            CycleOptIn(onTurnOn = { viewModel.setCycleTrackingEnabled(true) }, showFertile = false)
            return@SettingsColumn
        }
        val snap = loaded?.snap
        if (snap == null) {
            Spacer(Modifier.height(ForgeMetrics.space8))
            return@SettingsColumn
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            CycleDial(snap)
            snap.fertileLine?.let { (title, detail) ->
                Spacer(Modifier.height(ForgeMetrics.space3))
                val hint = stringResource(R.string.forge_cy_how_the_fertile_days_are)
                Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
                        .background(colors.cycleFertile.copy(alpha = 0.14f), RoundedCornerShape(22.dp))
                        .clickable(role = Role.Button, onClickLabel = hint) { sub = CycleSub.Fertile }
                        .padding(horizontal = ForgeMetrics.space4, vertical = ForgeMetrics.space2),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(9.dp).background(colors.cycleFertile, CircleShape))
                    Spacer(Modifier.width(ForgeMetrics.space2))
                    val line = title.text() + (detail?.let { " · " + it.text() } ?: "")
                    Text(line, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text, modifier = Modifier.weight(1f))
                    Icon(Icons.Rounded.Info, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(18.dp))
                }
            }
        }
        CycleLogRow { sub = CycleSub.Log }
        snap.phase?.let { phase ->
            SleepSectionTitle(stringResource(R.string.forge_cy_this_phase_for_you))
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CycleTopic.entries.forEach { t ->
                    CycleTopicCard(t, phase, snap, CyclePush.make(t, phase, charge, if (learning) loaded.pattern else null)) { topic = t }
                }
            }
        }
        if (snap.temps.size > 2) CycleTemperatureCard(snap)
        ForgeCard(Modifier.fillMaxWidth()) { CycleCalendar(snap) }
        val result = viewModel.v5Signals.collectAsState().value?.cycle
        if (result != null) {
            ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
                TrainingGroupRow(Icons.Rounded.CalendarMonth, colors.textSecondary, stringResource(R.string.forge_cy_cycle_history),
                                 snap.historyLine.text(), false) { sub = CycleSub.History }
            }
        }
        SleepSectionTitle(stringResource(R.string.forge_cy_settings))
        ForgeCard(Modifier.fillMaxWidth()) {
            ToggleRow(stringResource(R.string.forge_cy_learn_from_my_training), stringResource(R.string.forge_cy_compares_how_hard_your_sessions),
                      learning) { on -> learning = on; CyclePagePrefs.setLearning(context, on) }
            ToggleRow(stringResource(R.string.forge_cy_show_likely_fertile_days), stringResource(R.string.forge_cy_a_rough_estimate_from_your),
                      showFertile) { on -> showFertile = on; CyclePagePrefs.setShowFertile(context, on) }
            if (showFertile) FertileReminderToggles()
            Text(stringResource(R.string.forge_cy_turn_off_cycle_tracking), style = Forge.type.body, color = colors.cyclePeriod,
                 modifier = Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
                     .clickable(role = Role.Button) { viewModel.setCycleTrackingEnabled(false) }
                     .padding(vertical = ForgeMetrics.space3))
        }
        CycleFooter(showFertile)
        Spacer(Modifier.height(ForgeMetrics.space6))
    }
    if (sub == CycleSub.History) {
        val result = viewModel.v5Signals.collectAsState().value?.cycle
        val starts by viewModel.periodStarts.collectAsState()
        if (result == null) sub = null else CycleClassic {
            com.noop.ui.CycleTrackerDialog(result = result, starts = starts, onLog = viewModel::logPeriodStart,
                onDelete = viewModel::deletePeriodStart, onDeleteAll = viewModel::deleteAllPeriodStarts, onDismiss = { sub = null })
        }
    }
}

@Composable
private fun CycleClassic(content: @Composable () -> Unit) {
    val colors = Forge.colors
    val tokens = remember(colors) { hostedTokens(colors) }
    HostedPalette(tokens, colors.dark) { content() }
}

@Composable
private fun CycleOptIn(onTurnOn: () -> Unit, showFertile: Boolean) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.forge_cy_track_your_cycle_privately), style = Forge.type.title2, color = colors.text)
        Spacer(Modifier.height(ForgeMetrics.space3))
        Text(stringResource(R.string.forge_cy_log_your_period_and_noop), style = Forge.type.body, color = colors.textSecondary)
        Spacer(Modifier.height(ForgeMetrics.space3))
        Text(stringResource(R.string.forge_cy_turn_on_cycle_tracking), style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold),
             color = colors.surface, textAlign = TextAlign.Center,
             modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp).background(colors.accent, CircleShape)
                 .clickable(role = Role.Button, onClick = onTurnOn).padding(vertical = 14.dp))
        Spacer(Modifier.height(ForgeMetrics.space3))
        CycleFooter(showFertile)
    }
}

@Composable
private fun CycleFooter(showFertile: Boolean) {
    Text(stringResource(if (showFertile) R.string.forge_cy_awareness_only_fertile_days_are else R.string.forge_cy_awareness_only_not_contraception_not),
         style = Forge.type.caption, color = Forge.colors.textTertiary, modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
}

/** iOS `ForgeFertileReminderToggles`; Android 13 and later ask for the notification permission when it is turned on. */
@Composable
private fun FertileReminderToggles() {
    val context = LocalContext.current
    var enabled by remember { mutableStateOf(CyclePagePrefs.reminder(context)) }
    var discreet by remember { mutableStateOf(CyclePagePrefs.discreet(context)) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        enabled = granted; CyclePagePrefs.setReminder(context, granted)
    }
    ToggleRow(stringResource(R.string.forge_cy_remind_me_of_my_fertile), stringResource(R.string.forge_cy_a_notification_the_evening_before), enabled) { on ->
        if (on && Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            ask.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else { enabled = on; CyclePagePrefs.setReminder(context, on) }
    }
    if (enabled) {
        ToggleRow(stringResource(R.string.forge_cy_discreet_on_the_lock_screen), stringResource(R.string.forge_cy_shows_only_cycle_update_so), discreet) { on ->
            discreet = on; CyclePagePrefs.setDiscreet(context, on)
        }
    }
}

@Composable
private fun CycleLogRow(onLog: () -> Unit) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        listOf(Triple(R.string.forge_cy_period, Icons.Rounded.WaterDrop, Forge.colors.cyclePeriod),
               Triple(R.string.forge_cy_symptoms, Icons.Rounded.MedicalServices, Forge.colors.effort),
               Triple(R.string.forge_cy_mood, Icons.Rounded.SentimentSatisfied, Forge.colors.rest)).forEach { (title, icon, tint) ->
            val label = stringResource(title)
            val a11y = stringResource(R.string.forge_cy_log_x, label)
            ForgeCard(Modifier.weight(1f).semantics { contentDescription = a11y }.clickable(role = Role.Button, onClick = onLog),
                      contentPadding = ForgeMetrics.space2) {
                Column(Modifier.fillMaxWidth().heightIn(min = 72.dp), horizontalAlignment = Alignment.CenterHorizontally,
                       verticalArrangement = Arrangement.Center) {
                    Box(Modifier.size(40.dp).background(tint.copy(alpha = 0.14f), CircleShape), contentAlignment = Alignment.Center) {
                        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(label, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text, maxLines = 1)
                }
            }
        }
    }
}

/** iOS `ForgeCycleDial`: every day of this cycle as a dot, past days in their phase colour, today large. */
@Composable
private fun CycleDial(snap: CycleSnapshot) {
    val colors = Forge.colors
    val phaseColors = CyclePhase.entries.associateWith { it.color() }
    val summary = listOfNotNull(snap.cycleDayText.text(), snap.phase?.let { stringResource(it.title) }, snap.nextLine?.text()).joinToString(", ")
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(280.dp).semantics { contentDescription = summary }, contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(280.dp)) {
                val n = maxOf(snap.wheelDays, 1)
                val c = Offset(size.width / 2, size.height / 2)
                val r = minOf(size.width, size.height) / 2 - 18.dp.toPx()
                drawCircle(colors.inset, r, c, style = Stroke(22.dp.toPx()))
                val today = snap.todayOnWheel
                val next = snap.nextWindow?.let { w -> today?.let { (it + w.first)..(it + w.last) } }
                fun angle(d: Double) = -Math.PI / 2 + (d - 1) / n * 2 * Math.PI
                snap.fertile?.let { f ->
                    val start = Math.toDegrees(angle(f.firstDay - 0.35)).toFloat()
                    val sweep = Math.toDegrees(angle(f.lastDay + 0.35) - angle(f.firstDay - 0.35)).toFloat()
                    drawArc(colors.cycleFertile.copy(alpha = 0.28f), start, sweep, false, Offset(c.x - r, c.y - r), Size(2 * r, 2 * r),
                            style = Stroke(22.dp.toPx(), cap = StrokeCap.Round))
                }
                for (d in 1..n) {
                    val a = angle(d.toDouble())
                    val p = Offset(c.x + r * cos(a).toFloat(), c.y + r * sin(a).toFloat())
                    val fertileDay = snap.isFertile(d)
                    val colour = if (fertileDay && today != null && d >= today) colors.cycleFertile
                                 else snap.phase(d)?.let { phaseColors[it] } ?: colors.textTertiary
                    when {
                        d == today -> { drawCircle(colour, 13.dp.toPx(), p); drawCircle(colors.surface, 13.dp.toPx(), p, style = Stroke(3.dp.toPx())) }
                        today != null && d < today -> drawCircle(colour, 6.5.dp.toPx(), p)
                        next != null && d in next -> drawCircle(colors.cyclePeriod, 6.dp.toPx(), p,
                            style = Stroke(2.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 2.4.dp.toPx()))))
                        fertileDay -> drawCircle(colors.cycleFertile.copy(alpha = 0.85f), 6.dp.toPx(), p)
                        else -> drawCircle(colour.copy(alpha = 0.3f), 5.dp.toPx(), p)
                    }
                }
            }
            Column(Modifier.padding(horizontal = 60.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(stringResource(R.string.forge_cy_cycle_day), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
                val centre = snap.cycleDay?.toString() ?: snap.dayRange?.let { if (it.first == it.last) "${it.first}" else "${it.first}–${it.last}" } ?: "–"
                Text(centre, style = Forge.type.heroNumber, color = colors.text, maxLines = 1)
                val phase = snap.phase
                if (phase != null) Text(stringResource(phase.title), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = phase.color())
                else Text(stringResource(if (snap.engineConfidence == com.noop.analytics.CyclePhaseEngine.Confidence.LEARNING)
                              R.string.forge_cy_learning_your_pattern else R.string.forge_cy_no_clear_pattern_yet),
                          style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary, textAlign = TextAlign.Center)
                snap.nextLine?.let {
                    Text(it.text(), style = Forge.type.caption, color = colors.textSecondary, textAlign = TextAlign.Center,
                         modifier = Modifier.widthIn(max = 160.dp).padding(top = 4.dp))
                }
            }
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            CyclePhase.entries.forEach { p -> LegendDot(phaseColors.getValue(p), stringResource(p.short)) }
        }
        if (snap.fertile != null || snap.nextWindow != null) {
            Spacer(Modifier.height(6.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                if (snap.fertile != null) LegendDot(colors.cycleFertile, stringResource(R.string.forge_cy_likely_fertile))
                if (snap.nextWindow != null) LegendDot(colors.cyclePeriod, stringResource(R.string.forge_cy_likely_next), dashed = true)
            }
        }
    }
}

@Composable
private fun LegendDot(color: Color, label: String, dashed: Boolean = false) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Canvas(Modifier.size(9.dp)) {
            if (dashed) drawCircle(color, size.minDimension / 2 - 0.75.dp.toPx(),
                style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(2.dp.toPx(), 2.dp.toPx()))))
            else drawCircle(color)
        }
        Spacer(Modifier.width(4.dp))
        Text(label, style = Forge.type.caption, color = Forge.colors.textSecondary, maxLines = 1)
    }
}

/** "Nights +0.3 °C, resting heart rate +3 bpm, HRV −6 ms against the first half of this cycle." */
@Composable
private fun bodyLine(snap: CycleSnapshot): String? {
    val c = snap.compare ?: return null
    val parts = listOfNotNull(
        c.tempDelta?.let { stringResource(R.string.forge_cy_nights_x_c, signed(it, 1)) },
        c.rhrDelta?.let { stringResource(R.string.forge_cy_resting_heart_rate_x_bpm, signed(it, 0)) },
        c.hrvDelta?.let { stringResource(R.string.forge_cy_hrv_x_ms, signed(it, 0)) })
    if (parts.isEmpty()) return null
    return stringResource(R.string.forge_cy_against_the_first_half_of, parts.joinToString(", "))
}

private fun signed(v: Double, digits: Int): String =
    (if (v < 0) "−" else "+") + String.format(Locale.getDefault(), "%.${digits}f", abs(v))

@Composable
private fun CycleTopicCard(topic: CycleTopic, phase: CyclePhase, snap: CycleSnapshot, push: CyclePush?, onClick: () -> Unit) {
    val colors = Forge.colors
    val tint = phase.color()
    ForgeCard(Modifier.width(250.dp).heightIn(min = 190.dp).fillMaxHeight().clickable(role = Role.Button, onClick = onClick)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(40.dp).background(tint.copy(alpha = 0.14f), CircleShape), contentAlignment = Alignment.Center) {
                Icon(topic.icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
            }
            Spacer(Modifier.width(10.dp))
            Text(stringResource(topic.title), style = Forge.type.headline, color = colors.text)
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        if (push != null) {
            Text(push.headline.text(), style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = push.tone.color())
            Text(push.reason.map { it.text() }.joinToString(" "), style = Forge.type.body, color = colors.textSecondary)
        } else {
            val line = (if (topic == CycleTopic.Body) bodyLine(snap) else null) ?: stringResource(topic.summary(phase))
            Text(line, style = Forge.type.body, color = colors.textSecondary)
        }
        Spacer(Modifier.weight(1f, fill = false))
        Spacer(Modifier.height(ForgeMetrics.space2))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.forge_cy_more), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.accent)
            Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.accent, modifier = Modifier.size(16.dp))
        }
    }
}

/** One card's page: the phase, the short and the longer read, the wearer's own nights and the studies behind it. */
@Composable
private fun CycleTopicPage(topic: CycleTopic, phase: CyclePhase, snap: CycleSnapshot, push: CyclePush?, pattern: CoreCycle.Pattern?,
                           onBack: () -> Unit) {
    val colors = Forge.colors
    val tint = phase.color()
    SettingsColumn {
        PageTitle(null, onBack)
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(stringResource(R.string.forge_cy_x_x, stringResource(phase.title), snap.cycleDayText.text()),
                 style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = colors.surface,
                 modifier = Modifier.background(tint, CircleShape).padding(horizontal = ForgeMetrics.space3, vertical = 6.dp))
            Spacer(Modifier.height(10.dp))
            Box(Modifier.size(84.dp).background(tint.copy(alpha = 0.14f), CircleShape), contentAlignment = Alignment.Center) {
                Icon(topic.icon, contentDescription = null, tint = tint, modifier = Modifier.size(40.dp))
            }
            Spacer(Modifier.height(10.dp))
            Text(stringResource(topic.title), style = Forge.type.title1, color = colors.text)
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                if (push != null) {
                    Text(push.headline.text(), style = Forge.type.title2, color = push.tone.color())
                    Text(push.reason.map { it.text() }.joinToString(" "), style = Forge.type.body, color = colors.textSecondary)
                }
                Text(stringResource(topic.summary(phase)), style = Forge.type.body, color = colors.text)
                Text(stringResource(topic.more(phase)), style = Forge.type.body, color = colors.text)
            }
        }
        val lines = topicDataLines(topic, phase, snap, pattern)
        if (lines.isNotEmpty()) {
            SleepSectionTitle(stringResource(R.string.forge_cy_in_your_data))
            ForgeCard(Modifier.fillMaxWidth()) {
                Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                    lines.forEach { Text(it, style = Forge.type.body, color = colors.text) }
                }
            }
        }
        SleepSectionTitle(stringResource(R.string.forge_cy_what_this_is_based_on))
        ForgeCard(Modifier.fillMaxWidth()) {
            Text(topic.sources(phase).map { stringResource(it) }.joinToString(" "), style = Forge.type.caption, color = colors.textSecondary)
        }
        CycleFooter(false)
        Spacer(Modifier.height(ForgeMetrics.space6))
    }
}

@Composable
private fun topicDataLines(topic: CycleTopic, phase: CyclePhase, snap: CycleSnapshot, pattern: CoreCycle.Pattern?): List<String> {
    val out = mutableListOf<String>()
    if (topic == CycleTopic.Exercise) CyclePush.patternLine(pattern, phase)?.let { out += it.text() }
    val c = snap.compare ?: return out
    when (topic) {
        CycleTopic.Body -> bodyLine(snap)?.let { out += it }
        CycleTopic.Exercise -> if (c.chargeNow != null && c.chargeBefore != null)
            out += stringResource(R.string.forge_cy_charge_in_this_phase_n, Math.round(c.chargeNow).toInt(), Math.round(c.chargeBefore).toInt())
        CycleTopic.Mind -> {
            if (c.wakeNow != null && c.wakeBefore != null)
                out += stringResource(R.string.forge_cy_wake_ups_a_night_n, Math.round(c.wakeNow).toInt(), Math.round(c.wakeBefore).toInt())
            snap.moodsThisPhase.entries.sortedByDescending { it.value }.take(2).forEach { (id, count) ->
                moodTitle(id)?.let { out += stringResource(R.string.forge_cy_you_logged_x_on_n, stringResource(it), count) }
            }
        }
    }
    return out
}

private fun flowTitle(level: Int): Int = when (level) {
    1 -> R.string.forge_cy_spotting; 2 -> R.string.forge_cy_light; 3 -> R.string.forge_cy_medium; else -> R.string.forge_cy_heavy
}

private fun symptomTitle(id: String): Int? = when (id) {
    "cramps" -> R.string.forge_cy_cramps; "headache" -> R.string.forge_cy_headache; "bloating" -> R.string.forge_cy_bloating
    "tender_breasts" -> R.string.forge_cy_tender_breasts; "back_pain" -> R.string.forge_cy_back_pain; "acne" -> R.string.forge_cy_acne
    "tired" -> R.string.forge_cy_tired; "cravings" -> R.string.forge_cy_cravings; else -> null
}

private fun moodTitle(id: String): Int? = when (id) {
    "calm" -> R.string.forge_cy_calm; "happy" -> R.string.forge_cy_happy; "irritable" -> R.string.forge_cy_irritable
    "low" -> R.string.forge_cy_low; "anxious" -> R.string.forge_cy_anxious; "sensitive" -> R.string.forge_cy_sensitive; else -> null
}

/** The nightly skin temperature of this cycle against the wearer's usual, the rise marked where the engine found it. */
@Composable
private fun CycleTemperatureCard(snap: CycleSnapshot) {
    val colors = Forge.colors
    val a11y = stringResource(R.string.forge_cy_skin_temperature_over_this_cycle)
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.Top) {
            Text(stringResource(R.string.forge_cy_your_nights_this_cycle), style = Forge.type.headline, color = colors.text, modifier = Modifier.weight(1f))
            Text(stringResource(R.string.forge_cy_skin_temperature_against_your_usual), style = Forge.type.caption, color = colors.textSecondary,
                 textAlign = TextAlign.End, modifier = Modifier.widthIn(max = 160.dp))
        }
        Spacer(Modifier.height(10.dp))
        val lo = snap.tempFloor; val hi = snap.tempCeiling
        val maxDay = maxOf(snap.wheelDays, snap.temps.lastOrNull()?.first ?: 1)
        Row {
            Column(Modifier.height(120.dp), verticalArrangement = Arrangement.SpaceBetween) {
                listOf(hi, (hi + lo) / 2, lo).forEach {
                    Text(String.format(Locale.getDefault(), "%+.1f", it), style = Forge.type.caption, color = colors.textSecondary)
                }
            }
            Spacer(Modifier.width(6.dp))
            Canvas(Modifier.weight(1f).height(120.dp).semantics { contentDescription = a11y }) {
                fun x(d: Int) = if (maxDay <= 1) 0f else (d - 1f) / (maxDay - 1f) * size.width
                fun y(v: Double) = ((hi - v) / (hi - lo) * size.height).toFloat()
                listOf(hi, (hi + lo) / 2, lo).forEach { drawLine(colors.divider, Offset(0f, y(it)), Offset(size.width, y(it)), 1f) }
                val line = Path(); val area = Path()
                snap.temps.forEachIndexed { i, (d, v) ->
                    if (i == 0) { line.moveTo(x(d), y(v)); area.moveTo(x(d), size.height); area.lineTo(x(d), y(v)) }
                    else { line.lineTo(x(d), y(v)); area.lineTo(x(d), y(v)) }
                }
                snap.temps.lastOrNull()?.let { area.lineTo(x(it.first), size.height); area.close() }
                drawPath(area, colors.rest.copy(alpha = 0.14f))
                drawPath(line, colors.rest, style = Stroke(2.4.dp.toPx(), cap = StrokeCap.Round))
                snap.shiftDay?.let { s ->
                    drawLine(colors.cycleShift.copy(alpha = 0.7f), Offset(x(s), 0f), Offset(x(s), size.height), 1.dp.toPx(),
                             pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx())))
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(start = 34.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            listOf(1, (maxDay + 1) / 2, maxDay).distinct().forEach {
                Text(stringResource(R.string.forge_cy_day_n, it), style = Forge.type.caption, color = colors.textSecondary)
            }
        }
        Spacer(Modifier.height(10.dp))
        Text(snap.shiftDay?.let { stringResource(R.string.forge_cy_the_rise_around_day_n, it) } ?: stringResource(R.string.forge_cy_no_rise_in_temperature_yet),
             style = Forge.type.caption, color = colors.textSecondary)
    }
}

/** iOS `ForgeCycleCalendar`: five weeks around this cycle, logged period days filled, the likely next window dashed. */
@Composable
private fun CycleCalendar(snap: CycleSnapshot) {
    val colors = Forge.colors
    val today = LocalDate.now()
    val anchor = snap.startDate ?: today.minusDays(20)
    val first = anchor.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
    val days = (0 until 35).map { first.plusDays(it.toLong()) }
    val next = snap.nextWindow?.let { w -> (w.first..w.last).map { today.plusDays(it.toLong()).toString() }.toSet() }.orEmpty()
    val locale = Locale.getDefault()
    val short = DateTimeFormatter.ofPattern("d MMM", locale)
    Row(verticalAlignment = Alignment.Bottom) {
        Text(stringResource(R.string.forge_cy_calendar), style = Forge.type.headline, color = colors.text, modifier = Modifier.weight(1f))
        val span = listOf(days.first(), days.last()).joinToString(" – ") { it.format(short) }
        Text(span, style = Forge.type.caption, color = colors.textSecondary)
    }
    Spacer(Modifier.height(10.dp))
    Row(Modifier.fillMaxWidth()) {
        (0 until 7).forEach { i ->
            Text(DayOfWeek.MONDAY.plus(i.toLong()).getDisplayName(TextStyle.NARROW, locale), style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold),
                 color = colors.textSecondary, textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
        }
    }
    val periodLabel = stringResource(R.string.forge_cy_period)
    val fertileLabel = stringResource(R.string.forge_cy_likely_fertile)
    val nextLabel = stringResource(R.string.forge_cy_likely_next_period)
    val full = DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG).withLocale(locale)
    days.chunked(7).forEach { week ->
        Row(Modifier.fillMaxWidth().padding(top = 6.dp)) {
            week.forEach { d ->
                val key = d.toString()
                val isToday = d == today
                val period = key in snap.periodDays
                val fertile = key in snap.fertileDays
                val likely = key in next
                val state = when { period -> periodLabel; fertile -> fertileLabel; likely -> nextLabel; else -> "" }
                val label = listOf(d.format(full), state).filter { it.isNotEmpty() }.joinToString(", ")
                Box(Modifier.weight(1f).semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
                    val base = Modifier.size(32.dp)
                    val styled = when {
                        isToday -> base.background(colors.text, CircleShape)
                        period -> base.background(colors.cyclePeriod, CircleShape)
                        fertile -> base.background(colors.cycleFertile.copy(alpha = 0.28f), CircleShape)
                        likely -> base.border(1.5.dp, colors.cyclePeriod, CircleShape)
                        else -> base
                    }
                    Box(styled, contentAlignment = Alignment.Center) {
                        Text(d.dayOfMonth.toString(), style = Forge.type.subhead.copy(fontWeight = if (isToday) FontWeight.Bold else FontWeight.Normal),
                             color = when { isToday -> colors.surface; period -> Color.White; else -> colors.text })
                    }
                }
            }
        }
    }
    Spacer(Modifier.height(10.dp))
    Text(stringResource(if (snap.fertileDays.isEmpty()) R.string.forge_cy_filled_periods_you_logged_dashed else R.string.forge_cy_red_periods_you_logged_green),
         style = Forge.type.caption, color = colors.textSecondary)
}

/**
 * iOS `ForgeCycleLogSheet`: today's flow, symptoms, mood and an ovulation test. Logging flow with no period start in
 * the last ten days also logs today as cycle day 1.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CycleLogPage(viewModel: AppViewModel, loaded: CycleLoaded, onDone: () -> Unit) {
    val colors = Forge.colors
    val scope = rememberCoroutineScope()
    val today = LocalDate.now()
    val key = today.toString()
    val existing = loaded.log[key] ?: CycleLogStore.Day()
    var draft by remember { mutableStateOf(existing) }
    var saving by remember { mutableStateOf(false) }
    fun save() {
        if (saving) return
        saving = true
        scope.launch {
            withContext(Dispatchers.IO) { runCatching { CycleLogStore(viewModel.repo).save(key, draft, existing) } }
            if (draft.flow != null && existing.flow == null) {
                val recent = loaded.starts.mapNotNull { runCatching { LocalDate.parse(it) }.getOrNull() }
                    .any { abs(java.time.temporal.ChronoUnit.DAYS.between(it, today)) < 10 }
                if (!recent) viewModel.logPeriodStart(key)
            }
            onDone()
        }
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_cy_log_today), onDone) {
            TextButton(onClick = ::save, enabled = !saving) {
                Text(stringResource(R.string.forge_cy_save), style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = colors.accent)
            }
        }
        @Composable
        fun section(title: Int, chips: @Composable () -> Unit) {
            ForgeCard(Modifier.fillMaxWidth()) {
                Text(stringResource(title), style = Forge.type.headline, color = colors.text)
                Spacer(Modifier.height(10.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) { chips() }
            }
        }
        section(R.string.forge_cy_period) {
            LogChip(stringResource(R.string.forge_cy_none), draft.flow == null, colors.cyclePeriod) { draft = draft.copy(flow = null) }
            (1..4).forEach { f -> LogChip(stringResource(flowTitle(f)), draft.flow == f, colors.cyclePeriod) { draft = draft.copy(flow = f) } }
        }
        section(R.string.forge_cy_symptoms) {
            CycleLogStore.SYMPTOMS.forEach { id ->
                val on = id in draft.symptoms
                LogChip(stringResource(symptomTitle(id)!!), on, colors.effort) {
                    draft = draft.copy(symptoms = if (on) draft.symptoms - id else draft.symptoms + id)
                }
            }
        }
        section(R.string.forge_cy_mood) {
            CycleLogStore.MOODS.forEach { id ->
                val on = id in draft.moods
                LogChip(stringResource(moodTitle(id)!!), on, colors.rest) {
                    draft = draft.copy(moods = if (on) draft.moods - id else draft.moods + id)
                }
            }
        }
        section(R.string.forge_cy_ovulation_test) {
            LogChip(stringResource(R.string.forge_cy_positive_test_today), draft.ovulationTest, colors.cycleFertile) {
                draft = draft.copy(ovulationTest = !draft.ovulationTest)
            }
        }
        Text(stringResource(R.string.forge_cy_log_note), style = Forge.type.caption, color = colors.textSecondary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        Spacer(Modifier.height(ForgeMetrics.space6))
    }
}

@Composable
private fun LogChip(title: String, on: Boolean, tint: Color, onClick: () -> Unit) {
    val colors = Forge.colors
    Text(title, style = Forge.type.subhead.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal),
         color = if (on) Color.White else colors.text,
         modifier = Modifier.heightIn(min = 40.dp).background(if (on) tint else colors.inset, CircleShape)
             .clickable(role = Role.Checkbox, onClick = onClick).padding(horizontal = 14.dp, vertical = 10.dp))
}

/** iOS `ForgeCycleFertileInfo`: how the likely fertile days are worked out, with the wearer's own numbers. */
@Composable
private fun CycleFertilePage(snap: CycleSnapshot, onBack: () -> Unit, onLog: () -> Unit) {
    val colors = Forge.colors
    val f = snap.fertile
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_cy_fertile_days), onBack)
        ForgeCard(Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.Top) {
                Icon(Icons.Rounded.Warning, contentDescription = null, tint = colors.effort, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(10.dp))
                Text(stringResource(R.string.forge_cy_not_birth_control).trim() + " " + stringResource(R.string.forge_cy_this_is_a_rough_estimate),
                     style = Forge.type.body, color = colors.text)
            }
        }
        ForgeCard(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.forge_cy_how_noop_estimates_your_fertile), style = Forge.type.headline, color = colors.text)
            Spacer(Modifier.height(ForgeMetrics.space3))
            val lo = f?.pastRiseDays?.minOrNull(); val hi = f?.pastRiseDays?.maxOrNull()
            FertileStep(1, stringResource(R.string.forge_cy_your_temperature_rises_a_day),
                        if (lo != null && hi != null) stringResource(R.string.forge_cy_in_your_last_n_cycles, f.pastRiseDays.size, lo, hi) else null)
            FertileStep(2, stringResource(R.string.forge_cy_sperm_can_live_up_to),
                        f?.let { stringResource(R.string.forge_cy_for_you_this_cycle_about, it.firstDay, it.lastDay) })
            FertileStep(3, stringResource(R.string.forge_cy_once_your_nights_show_the),
                        if (f?.basis == "ovulationTest") stringResource(R.string.forge_cy_this_cycle_uses_your_positive) else null)
        }
        if (f != null && f.pastRiseDays.isNotEmpty()) {
            SleepSectionTitle(stringResource(R.string.forge_cy_your_last_cycles))
            ForgeCard(Modifier.fillMaxWidth()) {
                Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                    f.pastRiseDays.forEachIndexed { i, day ->
                        Row {
                            Text(if (i == 0) stringResource(R.string.forge_cy_last_cycle) else stringResource(R.string.forge_cy_n_cycles_ago, i + 1),
                                 style = Forge.type.body, color = colors.textSecondary, modifier = Modifier.weight(1f))
                            Text(stringResource(R.string.forge_cy_rise_on_day_n, day), style = Forge.type.body, color = colors.text)
                        }
                    }
                    Text(stringResource(R.string.forge_cy_the_wider_your_rises_spread), style = Forge.type.caption, color = colors.textSecondary)
                }
            }
        }
        ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
            TrainingGroupRow(Icons.Rounded.Science, colors.cycleFertile, stringResource(R.string.forge_cy_log_an_ovulation_test),
                             stringResource(R.string.forge_cy_a_positive_test_narrows_the), false, onLog)
        }
        Text(stringResource(R.string.forge_cy_shown_only_after_3_cycles), style = Forge.type.caption, color = colors.textTertiary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        Spacer(Modifier.height(ForgeMetrics.space6))
    }
}

@Composable
private fun FertileStep(n: Int, text: String, detail: String?) {
    val colors = Forge.colors
    Row(Modifier.padding(bottom = ForgeMetrics.space3), verticalAlignment = Alignment.Top) {
        Box(Modifier.size(26.dp).background(colors.inset, CircleShape), contentAlignment = Alignment.Center) {
            Text(n.toString(), style = Forge.type.footnote.copy(fontWeight = FontWeight.Bold), color = colors.text)
        }
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column {
            Text(text, style = Forge.type.body, color = colors.text)
            detail?.let { Text(it, style = Forge.type.caption, color = colors.textSecondary) }
        }
    }
}

/**
 * iOS `ForgeCycleSummaryCard`: the cycle at a glance on Today and Health, the cycle day, nine days around today, one
 * line on the fertile days or the phase, and the three ways to log. Shown only while tracking is on and a period is
 * logged; a tap opens the cycle page.
 */
@Composable
internal fun ForgeCycleSummaryCard(viewModel: AppViewModel, onOpen: () -> Unit, onLog: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val loaded = rememberCycle(viewModel, 0, showFertile = remember { CyclePagePrefs.showFertile(context) })
    val snap = loaded?.snap ?: return
    if (loaded.starts.isEmpty()) return
    ForgeCard(Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.forge_cy_cycle_x, snap.cycleDayText.text()), style = Forge.type.headline, color = colors.text,
                     modifier = Modifier.weight(1f))
                snap.phase?.let { Text(stringResource(it.title), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = it.color()) }
                Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.height(ForgeMetrics.space3))
            val phaseColors = CyclePhase.entries.associateWith { it.color() }
            Row(Modifier.fillMaxWidth().height(30.dp), verticalAlignment = Alignment.CenterVertically) {
                (-4..4).forEach { offset ->
                    val d = (snap.todayOnWheel ?: 1) + offset
                    val fertile = snap.isFertile(d)
                    val colour = if (fertile) colors.cycleFertile else if (d >= 1) snap.phase(d)?.let { phaseColors[it] } ?: colors.textTertiary else colors.textTertiary
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        val s = if (offset == 0) 18.dp else 12.dp
                        Box(Modifier.size(if (offset == 0) 28.dp else s).then(if (offset == 0) Modifier.border(2.dp, colors.text, CircleShape) else Modifier),
                            contentAlignment = Alignment.Center) {
                            Box(Modifier.size(s).background(colour.copy(alpha = if (offset <= 0 || fertile) 1f else 0.35f), CircleShape))
                        }
                    }
                }
            }
            Spacer(Modifier.height(ForgeMetrics.space3))
            val title = snap.fertileLine?.first?.text() ?: snap.phase?.let { stringResource(it.title) } ?: stringResource(R.string.forge_cy_no_clear_pattern_yet)
            Text(title, style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
            val parts = mutableListOf<String>()
            if (snap.fertile?.status == "during") snap.fertileLine?.second?.text()?.let { d -> parts += d.replaceFirstChar { it.uppercase() } + "." }
            snap.nextLine?.text()?.let { parts += "$it." }
            if (snap.fertile != null) parts += stringResource(R.string.forge_cy_rough_estimate_not_birth_control)
            if (parts.isNotEmpty()) Text(parts.joinToString(" "), style = Forge.type.caption, color = colors.textSecondary)
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            listOf(Triple(R.string.forge_cy_period, Icons.Rounded.WaterDrop, colors.cyclePeriod),
                   Triple(R.string.forge_cy_symptoms, Icons.Rounded.MedicalServices, colors.effort),
                   Triple(R.string.forge_cy_mood, Icons.Rounded.SentimentSatisfied, colors.rest)).forEach { (title, icon, tint) ->
                val label = stringResource(title)
                val a11y = stringResource(R.string.forge_cy_log_x, label)
                Row(Modifier.weight(1f).heightIn(min = 40.dp).background(colors.inset, CircleShape)
                        .semantics { contentDescription = a11y }.clickable(role = Role.Button, onClick = onLog),
                    horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(label, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text, maxLines = 1)
                }
            }
        }
    }
}

/** The cycle page as an overlay, opened on the log sheet when [logFirst]. */
@Composable
internal fun ForgeCycleOverlay(viewModel: AppViewModel, logFirst: Boolean = false, onDismiss: () -> Unit) {
    ForgeOverlayPage(onDismiss = onDismiss) {
        ForgeSceneBackdrop(ForgeBackdrop.Canvas) {
            BackHandler { onDismiss() }
            ForgeCyclePage(viewModel, onBack = onDismiss, startLogging = logFirst)
        }
    }
}
