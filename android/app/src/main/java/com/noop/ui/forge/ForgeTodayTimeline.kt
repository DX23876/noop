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
import androidx.compose.material.icons.rounded.MonitorWeight
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.Restaurant
import androidx.compose.material.icons.rounded.DirectionsWalk
import androidx.compose.foundation.clickable
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
 * It carries workouts (two or more detected or imported walks of a day as one entry, `TimelineFeed.walkBundles`),
 * waking up, naps, logged meals, ECG readings and the data's notices (`TodayNotices`) except the one the hint under
 * the rings already says. Coach notes, timed weigh-ins and the day's close are not on Android yet
 * (docs/fork/android/FORGE-PARITY.md).
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

        /** Two or more walks of one day the wearer did not start themselves, as one entry at the last one's end. */
        data class Walks(override val endTs: Long, val rows: List<WorkoutRow>) : Entry {
            val minutes: Double get() = rows.sumOf { ((it.durationS ?: (it.endTs - it.startTs).toDouble()) / 60).coerceAtLeast(0.0) }
        }

        data class Meal(override val endTs: Long, val meal: com.noop.core.CoreFood.Meal) : Entry

        data class Ecg(override val endTs: Long, val reading: com.noop.core.CoreEcg.Reading) : Entry

        data class Notice(override val endTs: Long, val notice: TodayNotices.Notice) : Entry

        /** A weigh-in that records its time (only those reach the rail, as on iOS), with the 30-day change. */
        data class Weight(override val endTs: Long, val kg: Double, val change30: Double?) : Entry
    }

    /** A walk that bundles: a walk from the strap, Health or detection, not one the wearer started or imported (iOS `bundlesAsWalk`). */
    fun bundlesAsWalk(row: WorkoutRow): Boolean =
        row.sport.contains("walk", ignoreCase = true) &&
            com.noop.ui.WorkoutEditing.classify(row.source) in setOf(
                com.noop.ui.WorkoutSource.WHOOP, com.noop.ui.WorkoutSource.APPLE, com.noop.ui.WorkoutSource.DETECTED)

    /**
     * Today's and yesterday's entries, newest first, by the day each one ended on. Nothing that ends after [now]
     * (a running workout belongs to the live screen, as on iOS). [nights] are the core's main nights and [naps] the
     * blocks off them (`SleepNight.naps`), so a short night stays the night. Pure, so the order and the split are
     * tested without a store.
     */
    fun entries(workouts: List<WorkoutRow>, nights: List<CoreRead.Night>, naps: List<CoreRead.Nap>, now: Long,
                zone: ZoneId, meals: List<com.noop.core.CoreFood.Meal> = emptyList(),
                ecgs: List<com.noop.core.CoreEcg.Reading> = emptyList(),
                notices: List<TodayNotices.Notice> = emptyList(),
                weighIns: List<Pair<Long, Double>> = emptyList(), weightChange30: Double? = null): List<Entry> {
        val today = Instant.ofEpochSecond(now).atZone(zone).toLocalDate()
        fun inRange(ts: Long): Boolean {
            val day = Instant.ofEpochSecond(ts).atZone(zone).toLocalDate()
            return ts <= now && (day == today || day == today.minusDays(1))
        }
        val out = mutableListOf<Entry>()
        val shown = workouts.filter { inRange(it.endTs) }
        // Two or more bundling walks of a day are one entry (`TimelineFeed.walkBundles`); a single walk stays its own.
        val bundles = shown.filter(::bundlesAsWalk)
            .groupBy { Instant.ofEpochSecond(it.endTs).atZone(zone).toLocalDate() }.filterValues { it.size >= 2 }
        val inBundles = bundles.values.flatten().toSet()
        bundles.values.forEach { walks -> val sorted = walks.sortedBy { it.endTs }; out += Entry.Walks(sorted.last().endTs, sorted) }
        shown.filter { it !in inBundles }.forEach { out += Entry.Workout(it) }
        meals.filter { inRange(it.start) }.forEach { out += Entry.Meal(it.start, it) }
        ecgs.filter { inRange(it.startTs) }.forEach { out += Entry.Ecg(it.startTs, it) }
        notices.filter { inRange(it.at) }.forEach { out += Entry.Notice(it.at, it) }
        weighIns.filter { inRange(it.first) }.forEach { (at, kg) -> out += Entry.Weight(at, kg, weightChange30) }
        nights.filter { inRange(it.endTs) }.forEach { n ->
            val m = n.minutes
            val awake = m?.get("wake") ?: 0.0
            val deep = m?.get("deep") ?: 0.0
            val rem = m?.get("rem") ?: 0.0
            val light = m?.get("light") ?: 0.0
            val staged = deep + rem + light
            val asleep = if (staged > 0) staged else (n.endTs - n.startTs) / 60.0 - awake
            if (asleep <= 0) return@forEach
            out += Entry.Wake(n.endTs, n.startTs, asleep, deep, rem, light, awake, nap = false)
        }
        naps.filter { inRange(it.endTs) && it.asleepMinutes > 0 }.forEach { n ->
            out += Entry.Wake(n.endTs, n.startTs, n.asleepMinutes, 0.0, 0.0, 0.0, 0.0, nap = true)
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
    var naps by remember { mutableStateOf<List<CoreRead.Nap>>(emptyList()) }
    // "Now" moves on by the minute and the rail reads again when the core has new data (a night synced while
    // Today stays open), as the Sleep tab does; read once, both stayed where the page was opened.
    val now by androidx.compose.runtime.produceState(System.currentTimeMillis() / 1000) {
        while (true) { kotlinx.coroutines.delay(60_000); value = System.currentTimeMillis() / 1000 }
    }
    var meals by remember { mutableStateOf<List<com.noop.core.CoreFood.Meal>>(emptyList()) }
    var ecgs by remember { mutableStateOf<List<com.noop.core.CoreEcg.Reading>>(emptyList()) }
    var notices by remember { mutableStateOf<List<TodayNotices.Notice>>(emptyList()) }
    var weighIns by remember { mutableStateOf<List<Pair<Long, Double>>>(emptyList()) }
    var weightChange by remember { mutableStateOf<Double?>(null) }
    var open by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    val live = rememberMomentumLive(viewModel)
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val todayKey = com.noop.ui.logicalDayNow(ZoneId.systemDefault()).toString()
    val weighTitle = stringResource(R.string.forge_hint_weigh_title)
    val weighDetail = stringResource(R.string.forge_hint_weigh_detail)
    LaunchedEffect(coreRevision, live) {
        val end = System.currentTimeMillis() / 1000
        withContext(Dispatchers.IO) {
            CoreRead.open(context)
            nights = CoreRead.nights(end - 3 * 86_400, end)
            naps = CoreRead.naps(end - 3 * 86_400, end)
            val today = java.time.LocalDate.now()
            meals = listOf(today.minusDays(1), today).flatMap { com.noop.core.CoreFood.day(it.toString())?.meals.orEmpty() }
            ecgs = com.noop.core.CoreEcg.readings().orEmpty()
            com.noop.core.CoreBody.snapshot(context, days = 30)?.let { body ->
                weighIns = body.weighIns.mapNotNull { r -> r.takenAt?.let { it to r.value } }
                weightChange = body.weightChangeKg
            }
            // The hint under the rings says its notice; the rail leaves that one out rather than say it twice.
            val (all, weighIn) = TodayHints.load(context, live, todayKey)
            val dismissed = TodayHints.dismissed(com.noop.ui.NoopPrefs.of(context).getString(TodayHints.DISMISSED_KEY, "") ?: "", todayKey)
            val hintId = TodayHints.candidates(all, weighIn, weighTitle, weighDetail, dismissed).firstOrNull()?.id
            notices = all.filter { it.key != hintId }
        }
    }
    val zone = ZoneId.systemDefault()
    val all = remember(workouts, nights, naps, now, meals, ecgs, notices, weighIns, weightChange) {
        TodayTimeline.entries(workouts, nights, naps, now, zone, meals, ecgs, notices, weighIns, weightChange)
    }
    // "Yesterday" by the logical day, as iOS's rail (`logicalDayKey`): an evening workout seen after midnight
    // still belongs to today.
    val today = com.noop.ui.logicalDayNow(zone)
    // Closed, the rail shows today's latest three entries; "Show all" opens the whole day and yesterday (iOS `dayOpen`).
    val entries = if (open) all else all.filter { Instant.ofEpochSecond(it.endTs).atZone(zone).toLocalDate() == today }.take(3)
    Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
        Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space3, bottom = ForgeMetrics.space3),
            verticalAlignment = Alignment.Bottom) {
            Text(stringResource(R.string.forge_timeline_title), style = Forge.type.title2.copy(fontWeight = FontWeight.Bold),
                 // The canvas text colour, as iOS's `ForgeSectionTitle`: the rail sits below the scene, where scene ink
                 // (white over the picture) all but vanished on the light canvas.
                 color = Forge.colors.text, modifier = Modifier.weight(1f))
            Text(stringResource(if (open) R.string.forge_hint_show_less else R.string.forge_tl_show_all),
                 style = Forge.type.subhead, color = Forge.colors.accent,
                 modifier = Modifier.clickable(role = androidx.compose.ui.semantics.Role.Button) { open = !open }.padding(4.dp))
        }
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
                is TodayTimeline.Entry.Walks -> RailRow(time(context, e.endTs), Forge.colors.effort, last) {
                    FactRow(Icons.Rounded.DirectionsWalk, Forge.colors.charge, stringResource(R.string.forge_tl_walks, e.rows.size), "",
                            TodayTimeline.hoursMinutes(e.minutes), stringResource(R.string.forge_tl_h_walked))
                }
                is TodayTimeline.Entry.Meal -> RailRow(time(context, e.endTs), Forge.colors.food, last) {
                    FactRow(Icons.Rounded.Restaurant, Forge.colors.food, mealName(e.meal.kind),
                            e.meal.entries.joinToString(", ") { it.name.substringBefore(", ") },
                            ((e.meal.totals["energy_kcal"] ?: 0.0).toInt()).toString(), "kcal")
                }
                is TodayTimeline.Entry.Ecg -> RailRow(time(context, e.endTs), Forge.colors.accent, last) {
                    FactRow(Icons.Rounded.MonitorHeart, Forge.colors.accent, stringResource(R.string.forge_tl_ecg), e.reading.title,
                            e.reading.averageHr?.toString(), "bpm")
                }
                is TodayTimeline.Entry.Weight -> RailRow(time(context, e.endTs), Forge.colors.rest, last) {
                    FactRow(Icons.Rounded.MonitorWeight, Forge.colors.rest, stringResource(R.string.forge_tl_weight),
                            e.change30?.let { c -> stringResource(R.string.forge_tl_weight_30,
                                (if (c >= 0) "+" else "−") + "%.1f kg".format(java.util.Locale.getDefault(), kotlin.math.abs(c))) } ?: "",
                            "%.1f".format(java.util.Locale.getDefault(), e.kg), "kg")
                }
                is TodayTimeline.Entry.Notice -> RailRow(time(context, e.endTs), Forge.colors.textTertiary, last) {
                    ForgeCard(Modifier.fillMaxWidth()) {
                        Text(e.notice.headline, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
                        if (e.notice.detail.isNotEmpty()) Text(e.notice.detail, style = Forge.type.caption, color = Forge.colors.textSecondary,
                                                               modifier = Modifier.padding(top = 4.dp))
                    }
                }
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
