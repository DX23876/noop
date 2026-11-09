package com.noop.ui.forge

import android.content.Context
import android.text.format.DateFormat
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.WbTwilight
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreRead
import com.noop.data.WorkoutRow
import com.noop.ui.AppViewModel
import com.noop.ui.UnitFormatter
import com.noop.ui.UnitPrefs
import com.noop.ui.WorkoutEditing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Fork (DX23876), Forge parity 2026-11: Today's timeline as the new iOS design draws it (`ForgeTimeline`,
 * `ForgeTodayView.dayList`): the day as a time rail, newest first, the time in a column on the left, a dot on a
 * thin line per entry, a "Now" marker on top and a divider where yesterday starts.
 *
 * This first Android step carries the strap's own events, workouts and waking up (naps as their own entry).
 * Coach notes, weigh-ins and logs follow (docs/fork/android/FORGE-PARITY.md).
 */
internal object TodayTimeline {
    sealed interface Entry {
        val endTs: Long

        data class Workout(val row: WorkoutRow) : Entry {
            override val endTs: Long get() = row.endTs
        }

        data class Wake(override val endTs: Long, val startTs: Long, val asleepMinutes: Double,
                        val deep: Double, val rem: Double, val light: Double, val awake: Double,
                        val nap: Boolean) : Entry
    }

    /** Below this a sleep block is a nap rather than the night. */
    private const val NAP_SECONDS = 3 * 3600L

    /**
     * Today's and yesterday's entries, newest first, by the day each one ended on. Nothing that ends after [now]
     * (a running workout belongs to the live screen). Pure, so the order and the split are tested without a store.
     */
    fun entries(workouts: List<WorkoutRow>, nights: List<CoreRead.Night>, now: Long, zone: ZoneId): List<Entry> {
        val today = Instant.ofEpochSecond(now).atZone(zone).toLocalDate()
        fun inRange(ts: Long): Boolean {
            val day = Instant.ofEpochSecond(ts).atZone(zone).toLocalDate()
            return ts <= now && (day == today || day == today.minusDays(1))
        }
        val out = mutableListOf<Entry>()
        workouts.filter { inRange(it.endTs) }.forEach { out += Entry.Workout(it) }
        nights.filter { inRange(it.endTs) }.forEach { n ->
            val m = n.minutes
            val awake = m?.get("wake") ?: 0.0
            val deep = m?.get("deep") ?: 0.0
            val rem = m?.get("rem") ?: 0.0
            val light = m?.get("light") ?: 0.0
            val staged = deep + rem + light
            val asleep = if (staged > 0) staged else (n.endTs - n.startTs) / 60.0 - awake
            if (asleep <= 0) return@forEach
            out += Entry.Wake(n.endTs, n.startTs, asleep, deep, rem, light, awake,
                              nap = n.endTs - n.startTs < NAP_SECONDS)
        }
        return out.sortedByDescending { it.endTs }
    }

    /** "7:26": hours and minutes, as iOS's `hoursMinutes`. */
    fun hoursMinutes(minutes: Double): String {
        val total = Math.round(minutes).toInt()
        return "%d:%02d".format(Locale.ROOT, total / 60, total % 60)
    }
}

@Composable
internal fun ForgeTodayTimeline(viewModel: AppViewModel, onSleep: () -> Unit) {
    val context = LocalContext.current
    val workouts by viewModel.workouts.collectAsState()
    var nights by remember { mutableStateOf<List<CoreRead.Night>>(emptyList()) }
    val now = remember { System.currentTimeMillis() / 1000 }
    LaunchedEffect(Unit) {
        nights = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreRead.nights(now - 3 * 86_400, now)
        }
    }
    val zone = ZoneId.systemDefault()
    val entries = remember(workouts, nights) { TodayTimeline.entries(workouts, nights, now, zone) }
    val today = LocalDate.now(zone)
    Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
        Text(stringResource(R.string.forge_timeline_title), style = Forge.type.title2.copy(fontWeight = FontWeight.Bold),
             color = Forge.sceneInk.text, modifier = Modifier.padding(top = ForgeMetrics.space3, bottom = ForgeMetrics.space3))
        RailRow(time = time(context, now), dot = Forge.colors.effort, last = entries.isEmpty()) {
            Text(stringResource(R.string.forge_timeline_now), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold),
                 color = Color.White,
                 modifier = Modifier.background(Forge.colors.effort, CircleShape).padding(horizontal = 10.dp, vertical = 3.dp))
        }
        var yesterdayShown = false
        entries.forEachIndexed { i, e ->
            val day = Instant.ofEpochSecond(e.endTs).atZone(zone).toLocalDate()
            if (day != today && !yesterdayShown) {
                yesterdayShown = true
                RailRow(time = null, dot = Forge.colors.text, last = false) {
                    Text(stringResource(R.string.today_day_yesterday), style = Forge.type.headline.copy(fontWeight = FontWeight.Bold),
                         color = Forge.colors.text)
                }
            }
            val last = i == entries.lastIndex
            when (e) {
                is TodayTimeline.Entry.Workout -> RailRow(time(context, e.endTs), Forge.colors.effort, last) { WorkoutEntry(e.row) }
                is TodayTimeline.Entry.Wake -> RailRow(time(context, e.endTs), Forge.colors.rest, last) { WakeEntry(e) }
            }
        }
    }
}

/** One row of the rail: the time in its column, a dot on the line, the entry beside them. */
@Composable
private fun RailRow(time: String?, dot: Color, last: Boolean, content: @Composable () -> Unit) {
    val line = Forge.colors.divider
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
        Box(Modifier.width(56.dp).padding(top = 14.dp)) {
            if (time != null) {
                Text(time, style = Forge.type.captionNumber, color = Forge.colors.textSecondary, maxLines = 1)
            }
        }
        Box(Modifier.width(20.dp).fillMaxHeight(), contentAlignment = Alignment.TopCenter) {
            Box(Modifier.width(1.dp).fillMaxHeight(if (last) 0.2f else 1f).background(line))
            Box(Modifier.padding(top = 17.dp).size(9.dp).background(dot, CircleShape))
        }
        Box(Modifier.weight(1f).padding(start = ForgeMetrics.space2, top = 6.dp, bottom = ForgeMetrics.space3)) { content() }
    }
}

@Composable
private fun WorkoutEntry(row: WorkoutRow) {
    val context = LocalContext.current
    val scale = remember { UnitPrefs.effortScale(context) }
    val system = remember { UnitPrefs.distanceSystem(context) }
    val minutes = ((row.durationS ?: (row.endTs - row.startTs).toDouble()) / 60).toInt()
    val detail = buildList {
        add(stringResource(R.string.forge_timeline_minutes, minutes))
        row.distanceM?.takeIf { it > 0 }?.let { add(UnitFormatter.distanceFromMeters(it, system)) }
    }.joinToString(" · ")
    FactRow(Icons.Rounded.FitnessCenter, Forge.colors.effort, WorkoutEditing.displaySport(row.sport), detail,
            row.strain?.let { UnitFormatter.effortDisplay(it, scale).removeSuffix(".0") }, stringResource(R.string.forge_effort))
}

@Composable
private fun WakeEntry(e: TodayTimeline.Entry.Wake) {
    val context = LocalContext.current
    val colors = Forge.colors
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        FactRow(if (e.nap) Icons.Rounded.Bedtime else Icons.Rounded.WbTwilight, colors.rest,
                stringResource(if (e.nap) R.string.forge_timeline_nap else R.string.forge_timeline_woke_up),
                "${time(context, e.startTs)} – ${time(context, e.endTs)}",
                TodayTimeline.hoursMinutes(e.asleepMinutes), stringResource(R.string.forge_timeline_h_asleep))
        val total = e.deep + e.rem + e.light + e.awake
        if (total > 0 && !e.nap) {
            Row(Modifier.fillMaxWidth().height(8.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                listOf(e.deep to colors.sleepDeep, e.light to colors.sleepLight, e.rem to colors.sleepRem,
                       e.awake to colors.sleepAwake).filter { it.first > 0 }.forEach { (m, c) ->
                    Box(Modifier.weight(m.toFloat()).fillMaxHeight().background(c, RoundedCornerShape(4.dp)))
                }
            }
        }
    }
}

/** The entry's icon on its wash, its title and detail, and the figure large with its unit small (iOS `factRow`). */
@Composable
private fun FactRow(icon: ImageVector, tint: Color, title: String, detail: String, value: String?, unit: String) {
    val colors = Forge.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(34.dp).background(tint.copy(alpha = 0.16f), CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(Modifier.weight(1f)) {
            Text(title, style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold), color = colors.text,
                 maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(detail, style = Forge.type.caption, color = colors.textSecondary, maxLines = 2)
        }
        if (value != null) {
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(buildAnnotatedString {
                append(value)
                withStyle(SpanStyle(fontSize = Forge.type.caption.fontSize, color = colors.textSecondary)) { append(" $unit") }
            }, style = Forge.type.bodyNumber.copy(fontSize = Forge.type.title2.fontSize), color = colors.text, maxLines = 1)
        }
    }
}

private fun time(context: Context, ts: Long): String {
    val pattern = if (DateFormat.is24HourFormat(context)) "H:mm" else "h:mm a"
    return Instant.ofEpochSecond(ts).atZone(ZoneId.systemDefault())
        .format(DateTimeFormatter.ofPattern(pattern, Locale.getDefault()))
}
