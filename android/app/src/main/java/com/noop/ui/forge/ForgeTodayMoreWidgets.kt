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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Bedtime
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
            Text("${TodayTimeline.hoursMinutes(need.toDouble())} ${stringResource(R.string.forge_goals_u_h)}",
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
