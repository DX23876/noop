package com.noop.ui.forge

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
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Air
import androidx.compose.material.icons.rounded.Battery5Bar
import androidx.compose.material.icons.rounded.BatteryChargingFull
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.EditNote
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.WbSunny
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.noop.R
import com.noop.alarm.WindDownStore
import com.noop.core.CoreCoach
import com.noop.core.CoreRead
import com.noop.ui.AppViewModel
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime

/** The card head the new design's wide widgets share, as iOS's `ForgeWidgetCard`: the title and a chevron. */
@Composable
private fun WidgetHead(title: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text,
             modifier = Modifier.weight(1f))
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = Forge.colors.textTertiary)
    }
    Spacer(Modifier.height(ForgeMetrics.space3))
}

/**
 * Fork (DX23876), Forge parity 2026-11: Today's "Tonight" card, as iOS's `ForgeTonightWidget`. Tonight's bedtime is
 * tomorrow's wake time minus the sleep need, the same inputs the wind-down nudge counts back from (the phone alarm's
 * wake time, its per-day override and the wind-down sleep need), so the card and the reminder name one bedtime.
 * A band runs from the moon to the sun, and under it how long until bed and the alarm time. Opens the alarms.
 */
@Composable
internal fun TodayTonightForge(viewModel: AppViewModel, onOpen: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val wakeBase by viewModel.phoneAlarmTargetMinutes.collectAsState()
    val overrides by viewModel.phoneAlarmDayOverrides.collectAsState()
    var now by remember { androidx.compose.runtime.mutableLongStateOf(System.currentTimeMillis() / 1000) }
    LaunchedEffect(Unit) { while (true) { delay(60_000); now = System.currentTimeMillis() / 1000 } }
    val need = remember(now) { WindDownStore.from(context).sleepNeedMinutes }
    val zone = ZoneId.systemDefault()
    val tomorrow = java.time.Instant.ofEpochSecond(now).atZone(zone).toLocalDate().plusDays(1)
    // Calendar.DAY_OF_WEEK, the key the per-day wake overrides use: Sunday 1 through Saturday 7.
    val dow = tomorrow.dayOfWeek.value % 7 + 1
    val wake: ZonedDateTime = tomorrow.atStartOfDay(zone).plusMinutes((overrides[dow] ?: wakeBase).toLong())
    val bed = wake.minusMinutes(need.toLong())
    val clock = rememberClockFormatter()
    ForgeCard(Modifier.fillMaxWidth().clickable(onClick = onOpen)) {
        WidgetHead(stringResource(R.string.forge_w_tonight))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(bed.format(clock), style = Forge.type.title1.copy(fontSize = 28.sp, fontWeight = FontWeight.SemiBold),
                 color = colors.text)
            Text(stringResource(R.string.forge_tn_in_bed), style = Forge.type.subhead, color = colors.textSecondary,
                 modifier = Modifier.padding(start = 8.dp, bottom = 4.dp))
            Spacer(Modifier.weight(1f))
            Text(stringResource(R.string.forge_pair_words, TodayTimeline.hoursMinutes(need.toDouble()), stringResource(R.string.forge_goals_u_h)),
                 style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.rest,
                 modifier = Modifier.padding(bottom = 4.dp))
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clearAndSetSemantics { }) {
            Icon(Icons.Rounded.Bedtime, contentDescription = null, tint = colors.rest, modifier = Modifier.size(15.dp))
            Box(Modifier.weight(1f).padding(horizontal = 8.dp).height(8.dp).background(
                Brush.horizontalGradient(listOf(colors.rest, colors.rest.copy(alpha = 0.45f), colors.effort.copy(alpha = 0.7f))),
                CircleShape))
            Icon(Icons.Rounded.WbSunny, contentDescription = null, tint = colors.effort, modifier = Modifier.size(15.dp))
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Row {
            val minutes = ((bed.toEpochSecond() - now) / 60).toInt()
            val left = when {
                minutes <= 0 -> stringResource(R.string.forge_tn_now)
                minutes > 4 * 60 -> stringResource(R.string.forge_tn_full)
                minutes < 60 -> stringResource(R.string.forge_tn_in_min, minutes)
                else -> stringResource(R.string.forge_tn_in_h, TodayTimeline.hoursMinutes(minutes.toDouble()))
            }
            Text(left, style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.rest,
                 modifier = Modifier.weight(1f))
            Text(stringResource(R.string.forge_tn_alarm, wake.format(clock)), style = Forge.type.caption,
                 color = colors.textSecondary)
        }
    }
}

/**
 * Fork (DX23876), Forge parity 2026-11: Today's "This week's plan" card, as iOS's `ForgeWeekPlanWidget`: a dot per
 * day of the training week, filled in the Effort colour where a workout happened, ringed where the coach's plan holds
 * an agreed session, and how many days had one. The week starts on the day Training's own week does.
 */
@Composable
internal fun TodayWeekPlanForge(viewModel: AppViewModel, onOpen: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val workouts by viewModel.workouts.collectAsState()
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val zone = ZoneId.systemDefault()
    val today = com.noop.ui.logicalDayNow()
    val sundayFirst = remember { NoopPrefs.of(context).getString("training.weekStartsOn", null) == "sunday" }
    val start = if (sundayFirst) today.minusDays((today.dayOfWeek.value % 7).toLong())
                else today.minusDays((today.dayOfWeek.value - 1).toLong())
    val days = (0L until 7L).map { start.plusDays(it) }
    val done = remember(workouts, start) {
        workouts.map { java.time.Instant.ofEpochSecond(it.startTs).atZone(zone).toLocalDate() }
            .filter { it >= start && it <= start.plusDays(6) }.toSet()
    }
    val scale = remember { com.noop.ui.UnitPrefs.effortScale(context).raw }
    val planned by produceState(emptySet<LocalDate>(), coreRevision, start) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                CoreRead.open(context)
                CoreCoach.plan(scale)?.agreed.orEmpty().mapNotNull { runCatching { LocalDate.parse(it.day) }.getOrNull() }.toSet()
            }.getOrDefault(emptySet())
        }
    }
    val a11y = stringResource(R.string.forge_wp_a11y, done.size)
    ForgeCard(Modifier.fillMaxWidth().clickable(onClick = onOpen)) {
        WidgetHead(stringResource(R.string.forge_w_week_plan))
        Row(Modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = a11y }) {
            days.forEach { day ->
                val isDone = day in done
                val ringed = isDone || day in planned
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally,
                       verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Box(Modifier.size(20.dp)
                            .background(if (isDone) colors.effort else Color.Transparent, CircleShape)
                            .border(1.5.dp, if (ringed) colors.effort else colors.textSecondary.copy(alpha = 0.3f), CircleShape))
                    Text(day.dayOfWeek.getDisplayName(java.time.format.TextStyle.NARROW, java.util.Locale.getDefault()),
                         style = Forge.type.caption, color = colors.textSecondary)
                }
            }
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Text(stringResource(R.string.forge_wp_days, done.size), style = Forge.type.caption, color = colors.textSecondary)
    }
}

/** Two calm minutes as a small tile beside the measures, as iOS's `ForgeBreatheWidget`. Opens the breathing exercise. */
@Composable
internal fun TodayBreatheTile(onOpen: () -> Unit, dense: Boolean = false, modifier: Modifier = Modifier.fillMaxWidth()) {
    // iOS's `ForgeBreatheWidget`: two minutes, and how to start, as a Today tile.
    ForgeTodayTile(Icons.Rounded.Air, Forge.colors.charge, stringResource(R.string.forge_w_breathe), "2",
                   stringResource(R.string.forge_goals_u_min), stringResource(R.string.forge_br_tap), "", dense,
                   modifier.clickable(onClick = onOpen))
}

/**
 * The strap's battery and its last sync as a small tile, as iOS's `ForgeStrapWidget`. iOS also says "Off the wrist"
 * from a wrist event on this link; Android's live state keeps only the latest event of any kind, so that line is left
 * out rather than guessed. Opens Settings, where the strap page sits (Android has no battery page of its own).
 */
@Composable
internal fun TodayStrapTile(viewModel: AppViewModel, onOpen: () -> Unit, dense: Boolean = false,
                            modifier: Modifier = Modifier.fillMaxWidth(), detailed: Boolean = false) {
    val live by viewModel.live.collectAsState()
    val synced = live.lastSyncAt?.takeIf { it > 0 }
    // The wrist only from an event on this link, as iOS: the stored default says nothing. Over two columns the state
    // and the last sync together.
    val state = when {
        live.wristThisLink == false -> stringResource(R.string.forge_st_off_wrist)
        live.charging == true -> stringResource(R.string.forge_st_charging)
        else -> null
    }
    val sync = if (synced == null) stringResource(R.string.forge_st_not_synced)
               else stringResource(R.string.forge_st_synced, android.text.format.DateUtils.getRelativeTimeSpanString(
                   synced * 1000, System.currentTimeMillis(), android.text.format.DateUtils.MINUTE_IN_MILLIS).toString())
    val caption = if (state == null) sync else if (detailed) "$state · $sync" else state
    // iOS's `ForgeStrapWidget`: the battery as the figure, the wrist, charge or last sync as its line.
    ForgeTodayTile(if (live.charging == true) Icons.Rounded.BatteryChargingFull else Icons.Rounded.Battery5Bar,
                   if (live.connected) Forge.colors.charge else Forge.colors.textSecondary, stringResource(R.string.forge_w_strap),
                   live.batteryPct?.let { Math.round(it).toString() }, "%", caption, "", dense, modifier.clickable(onClick = onOpen))
}

/** One of the coming seven days and the first routine planned on it, if any. */
private data class NextDay(val day: LocalDate, val routine: com.noop.core.CoreTraining.Routine?)

/**
 * Fork (DX23876), Forge parity 2026-11: Today's "Next session" card, as iOS's `ForgeNextSessionWidget`: the next
 * planned routine of the coming seven days with its first exercises, Start when it is today, and a dot per day where
 * one is planned. Days of this training week come from the core's schedule (which knows a moved day); later days from
 * each routine's weekdays. Start opens a session in the core and goes to Training, where it waits to be resumed.
 */
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
internal fun TodayNextSessionForge(onOpenTraining: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val today = com.noop.ui.logicalDayNow()
    val loaded by produceState<Pair<List<NextDay>, Map<String, String>>?>(null, coreRevision, today) {
        value = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val s = com.noop.core.CoreTraining.snapshot(days = 14) ?: return@withContext emptyList<NextDay>() to emptyMap()
            val byId = s.routines.associateBy { it.id }
            val planned = s.week.associate { it.day to it.routineIds }
            val week = (0L until 7L).map { offset ->
                val day = today.plusDays(offset)
                val ids = planned[day.toString()] ?: s.routines.filter { day.dayOfWeek.value in it.weekdays }.map { it.id }
                NextDay(day, ids.firstNotNullOfOrNull { byId[it] })
            }
            week to s.exercises.associate { it.id to it.title }
        }
    }
    val week = loaded?.first.orEmpty()
    val names = loaded?.second.orEmpty()
    val next = week.firstOrNull { it.routine != null }
    val locale = java.util.Locale.getDefault()
    val title = next?.let {
        val dayText = when (it.day) {
            today -> stringResource(R.string.forge_nx_today)
            today.plusDays(1) -> stringResource(R.string.forge_nx_tomorrow)
            else -> it.day.dayOfWeek.getDisplayName(java.time.format.TextStyle.FULL, locale)
        }
        stringResource(R.string.forge_nx_next_up, dayText)
    } ?: stringResource(R.string.forge_w_next)
    ForgeCard(Modifier.fillMaxWidth().clickable(onClick = onOpenTraining)) {
        WidgetHead(title)
        val routine = next?.routine
        if (next != null && routine != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(40.dp).background(colors.accent.copy(alpha = 0.18f), RoundedCornerShape(10.dp)),
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.FitnessCenter, contentDescription = null, tint = colors.accent, modifier = Modifier.size(20.dp))
                }
                Column(Modifier.weight(1f).padding(start = 12.dp)) {
                    Text(routine.title, style = Forge.type.headline, color = colors.text, maxLines = 1)
                    Text(androidx.compose.ui.res.pluralStringResource(R.plurals.forge_nx_exercises, routine.exerciseCount, routine.exerciseCount),
                         style = Forge.type.caption, color = colors.textSecondary)
                }
                if (next.day == today) {
                    Row(Modifier.padding(start = 8.dp).heightIn(min = 40.dp).background(colors.accent, CircleShape)
                            .clickable(role = androidx.compose.ui.semantics.Role.Button) {
                                scope.launch {
                                    withContext(Dispatchers.IO) { CoreRead.open(context); com.noop.core.CoreTraining.startDraft(listOf(routine.id)) }
                                    onOpenTraining()
                                }
                            }.padding(horizontal = 16.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.PlayArrow, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                        Text(stringResource(R.string.forge_nx_start), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                             color = Color.White, modifier = Modifier.padding(start = 4.dp))
                    }
                }
            }
            val titles = routine.exerciseIds.mapNotNull { names[it] }
            if (titles.isNotEmpty()) {
                Spacer(Modifier.height(ForgeMetrics.space2))
                androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp),
                                                           verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    (titles.take(3) + listOfNotNull(if (titles.size > 3) "+${titles.size - 3}" else null)).forEachIndexed { i, name ->
                        Text(name, style = Forge.type.caption.copy(fontWeight = FontWeight.Medium),
                             color = if (i < 3) colors.text else colors.textSecondary, maxLines = 1,
                             modifier = Modifier.background(colors.textSecondary.copy(alpha = 0.12f), CircleShape)
                                 .padding(horizontal = 10.dp, vertical = 5.dp))
                    }
                }
            }
        } else if (loaded != null) {
            Text(stringResource(R.string.forge_nx_plan), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = colors.accent)
        }
        if (week.isNotEmpty()) {
            Spacer(Modifier.height(ForgeMetrics.space3))
            Row(Modifier.fillMaxWidth().clearAndSetSemantics { }) {
                week.forEach { entry ->
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally,
                           verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Box(Modifier.size(10.dp).background(
                            if (entry.routine == null) colors.textSecondary.copy(alpha = 0.18f) else colors.accent, CircleShape))
                        Text(entry.day.dayOfWeek.getDisplayName(java.time.format.TextStyle.NARROW, locale),
                             style = Forge.type.caption.copy(fontWeight = if (entry.day == today) FontWeight.Bold else FontWeight.Normal),
                             color = colors.textSecondary)
                    }
                }
            }
        }
    }
}

/**
 * Fork (DX23876), Forge parity 2026-11: Today's "What works for your Charge" card, as iOS's `ForgeWhatWorksWidget`:
 * the three journal habits that moved Charge the most, from the same ranking the Insights page draws, each on a bar
 * out from the middle (right raised it, left lowered it) in the colours of better and worse. Opens Insights. iOS
 * gives each habit its own symbol; Android has no such table yet, so every row carries the journal's.
 */
@Composable
internal fun TodayWhatWorksForge(viewModel: AppViewModel, onOpen: () -> Unit) {
    val colors = Forge.colors
    val days by viewModel.recentDays.collectAsState()
    val hub = remember { com.noop.ui.InsightsHubViewModel() }
    val state by hub.state.collectAsState()
    LaunchedEffect(days) { withContext(Dispatchers.IO) { hub.load(viewModel, days) } }
    val top = remember(state) { hub.rankFor(state, com.noop.ui.InsightsOutcome.Recovery).take(3) }
    ForgeCard(Modifier.fillMaxWidth().clickable(onClick = onOpen)) {
        WidgetHead(stringResource(R.string.forge_w_what_works))
        if (top.isEmpty()) {
            if (state.loaded) Text(stringResource(R.string.forge_ww_empty), style = Forge.type.caption, color = colors.textSecondary)
        } else {
            val widest = top.maxOf { kotlin.math.abs(it.effect.pctChange ?: 0.0) }.coerceAtLeast(1.0)
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                top.forEach { r ->
                    val pct = r.effect.pctChange ?: 0.0
                    val tint = if (pct >= 0) colors.charge else colors.effort
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(24.dp).background(colors.accent.copy(alpha = 0.16f), RoundedCornerShape(6.dp)),
                                contentAlignment = Alignment.Center) {
                                Icon(Icons.Rounded.EditNote, contentDescription = null, tint = colors.accent, modifier = Modifier.size(14.dp))
                            }
                            Text(r.behavior, style = Forge.type.footnote.copy(fontWeight = FontWeight.Medium), color = colors.text,
                                 maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                                 modifier = Modifier.weight(1f).padding(horizontal = 8.dp))
                            Text(stringResource(R.string.forge_ww_pct, if (pct >= 0) "+" else "−", Math.round(kotlin.math.abs(pct)).toInt()),
                                 style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
                        }
                        androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxWidth().height(6.dp)
                                .background(colors.textSecondary.copy(alpha = 0.14f), CircleShape)) {
                            val half = maxWidth / 2
                            val width = maxOf(4.dp, half * (kotlin.math.abs(pct) / widest).toFloat())
                            Box(Modifier.padding(start = half).width(1.dp).height(6.dp).background(colors.textSecondary.copy(alpha = 0.4f)))
                            Box(Modifier.padding(start = if (pct >= 0) half else half - width).width(width).height(6.dp)
                                    .background(tint, CircleShape))
                        }
                    }
                }
            }
        }
    }
}
