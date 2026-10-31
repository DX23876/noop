package com.noop.ui.forge

import android.content.Context
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.DirectionsRun
import androidx.compose.material.icons.automirrored.rounded.DirectionsWalk
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DirectionsBike
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.noop.core.CoreActivity
import com.noop.core.CoreRead
import com.noop.data.WorkoutRow
import com.noop.notif.ActivitySuggestionNotifier
import com.noop.ui.ProfileStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Calendar
import java.util.Date

/**
 * Activity detection on Android (decision 2026-10-31), the same three surfaces as on iOS: the prompt pinned above
 * Today's arranged sections, the rows in the Updates inbox and the logging dialog every path opens. One state,
 * [ActivitySuggestionState], read from the shared core, so an answer anywhere is the answer everywhere.
 */
object ActivitySuggestionState {
    val result = MutableStateFlow<CoreActivity.Result?>(null)
    /** Put off with "Later" in this process; nothing is written, a later start asks again. */
    val snoozed = MutableStateFlow<Set<String>>(emptySet())
    private val shownAt = HashMap<String, Long>()

    /** Re-reads the suggestions (refreshing the recent days) and hands the newest to the notifier. Blocking. */
    fun reload(context: Context) {
        if (!CoreActivity.enabled(context)) { result.value = null; return }
        CoreRead.open(context)
        val app = context.applicationContext as com.noop.NoopApplication
        val dismissed = kotlinx.coroutines.runBlocking { dismissedTrainingWorkouts(app) } +
            com.noop.ui.AutoWorkoutPrefs.dismissedTokens(app)
        val r = CoreActivity.list(app, ProfileStore.from(app).hrMax, dismissed, snoozed.value) ?: return
        result.value = r
        ActivitySuggestionNotifier.update(app, r)
    }

    fun markShown(item: CoreActivity.Item) { shownAt.putIfAbsent(item.id, System.currentTimeMillis() / 1000) }
    fun shownAt(item: CoreActivity.Item): Long? = shownAt[item.id]
}

private fun icon(kind: String): ImageVector = when (kind) {
    "walk" -> Icons.AutoMirrored.Rounded.DirectionsWalk
    "run" -> Icons.AutoMirrored.Rounded.DirectionsRun
    "cycle" -> Icons.Rounded.DirectionsBike
    "strength" -> Icons.Rounded.FitnessCenter
    else -> Icons.Rounded.MonitorHeart
}

/** "Walk detected" or "Activity detected", from the core's catalog words. */
internal fun titleOf(r: CoreActivity.Result, item: CoreActivity.Item): String =
    r.label(if (item.track == "walk") "walkTitle" else "activityTitle")

internal fun kindName(r: CoreActivity.Result, kind: String): String = r.label("kind.$kind")

/** "Today, 14:05 to 14:40", in the catalog's words and the phone's time format. */
internal fun whenLine(r: CoreActivity.Result, item: CoreActivity.Item, withMinutes: Boolean = false): String {
    val fmt = DateFormat.getTimeInstance(DateFormat.SHORT)
    val from = fmt.format(Date(item.start * 1000)); val to = fmt.format(Date(item.end * 1000))
    val start = Calendar.getInstance().apply { timeInMillis = item.start * 1000 }
    val today = Calendar.getInstance()
    val yesterday = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -1) }
    fun same(a: Calendar, b: Calendar) = a.get(Calendar.YEAR) == b.get(Calendar.YEAR) &&
        a.get(Calendar.DAY_OF_YEAR) == b.get(Calendar.DAY_OF_YEAR)
    val day = DateFormat.getDateInstance(DateFormat.FULL).format(Date(item.start * 1000))
    val prefix = if (withMinutes) "span" else "when"
    val format = when {
        same(start, today) -> r.label("${prefix}Today")
        same(start, yesterday) -> r.label("${prefix}Yesterday")
        else -> r.label("${prefix}Day")
    }
    val args = if (same(start, today) || same(start, yesterday)) listOf(from, to) else listOf(day, from, to)
    return fill(format, args, item.minutes)
}

/** Fills `%@`/`%1$@` and `%lld` the way the catalog writes them. */
internal fun fill(format: String, strings: List<String>, number: Long): String {
    var next = 0
    return Regex("%(\\d+\\$)?(@|lld)").replace(format) { m ->
        val pos = m.groupValues[1].dropLast(1).toIntOrNull()?.minus(1)
        if (m.groupValues[2] == "lld") number.toString()
        else strings.getOrNull(pos ?: next++).orEmpty()
    }
}

/** The prompt pinned above Today's sections: the newest open suggestion, until answered or put off. */
@Composable
internal fun ForgeActivityPrompt() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var resumes by remember { mutableIntStateOf(0) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { resumes++ }
    LaunchedEffect(resumes) { withContext(Dispatchers.IO) { ActivitySuggestionState.reload(context) } }
    val result by ActivitySuggestionState.result.collectAsState()
    val snoozed by ActivitySuggestionState.snoozed.collectAsState()
    val r = result ?: return
    val toAsk = r.toAsk.filter { it.id !in snoozed }
    var listOpen by remember { mutableStateOf(false) }
    var adjusting by remember { mutableStateOf<CoreActivity.Item?>(null) }
    AnimatedVisibility(visible = toAsk.isNotEmpty()) {
        val item = toAsk.firstOrNull() ?: return@AnimatedVisibility
        LaunchedEffect(item.id) { ActivitySuggestionState.markShown(item) }
        SuggestionCard(r, item, more = toAsk.size - 1, onMore = { listOpen = true },
            onLater = { ActivitySuggestionState.snoozed.value = snoozed + item.id },
            onOther = { adjusting = item },
            onAnswer = { answer, kind ->
                scope.launch(Dispatchers.IO) {
                    val sport = kind?.let(CoreActivity::sportToken)
                    CoreActivity.answer(item, answer, "today", sport = sport, shownAt = ActivitySuggestionState.shownAt(item))
                    ActivitySuggestionNotifier.answered(context, item.id)
                    ActivitySuggestionState.reload(context)
                }
            })
    }
    adjusting?.let { item -> ActivityLogDialog(item, origin = "today") { adjusting = null } }
    if (listOpen) {
        ForgeOverlayPage(onDismiss = { listOpen = false }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) {
                Column(Modifier.fillMaxWidth().padding(20.dp)) { ForgeActivityInboxSection() }
            }
        }
    }
}

@Composable
private fun SuggestionCard(r: CoreActivity.Result, item: CoreActivity.Item, more: Int, onMore: () -> Unit,
                           onLater: () -> Unit, onOther: () -> Unit, onAnswer: (String, String?) -> Unit) {
    val colors = Forge.colors
    val tint = colors.effort
    ForgeCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(icon(item.likelyKind), contentDescription = null, tint = tint,
                     modifier = Modifier.size(30.dp).clip(CircleShape).background(tint.copy(alpha = 0.16f)).padding(6.dp))
                val title = titleOf(r, item)
                Text(title, style = Forge.type.headline, color = colors.text, modifier = Modifier.weight(1f))
                Icon(Icons.Rounded.Close, contentDescription = r.label("later"), tint = colors.textTertiary,
                     modifier = Modifier.size(28.dp).clip(CircleShape).clickable(role = Role.Button, onClick = onLater).padding(5.dp))
            }
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(item.minutes.toString(), style = Forge.type.heroNumber.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Light),
                     color = colors.text)
                Text(r.label("min"), style = Forge.type.subhead, color = colors.textSecondary,
                     modifier = Modifier.padding(bottom = 6.dp))
            }
            // "Today, 18:54 to 19:30 · avg 106 bpm": the span and the effort in one secondary line.
            val avg = item.avgBpm?.let { " · " + fill(r.label("avg"), emptyList(), it.toLong()) }.orEmpty()
            Text(whenLine(r, item) + avg, style = Forge.type.footnote, color = colors.textSecondary)
            // One row of three compact answers, as on iOS: save as the most likely kind, the rest behind one menu,
            // "Not training" to discard it for good.
            val likely = item.likelyKind
            val others = (if (item.track == "walk") listOf("run", "strength") else item.kinds.drop(1).take(2)).filter { it != likely }
            var menu by remember { mutableStateOf(false) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Pill(kindName(r, likely), Icons.Rounded.Check, tint, prominent = true) {
                    onAnswer(if (likely == "walk") "walk" else "sport", likely)
                }
                androidx.compose.foundation.layout.Box {
                    Pill(r.label("otherKind"), null, tint) { menu = true }
                    androidx.compose.material3.DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        others.forEach { kind ->
                            androidx.compose.material3.DropdownMenuItem(
                                text = { val name = kindName(r, kind); Text(name) },
                                leadingIcon = { Icon(icon(kind), contentDescription = null) },
                                onClick = { menu = false; onAnswer(if (kind == "walk") "walk" else "sport", kind) })
                        }
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text(r.label("housework")) },
                            onClick = { menu = false; onAnswer("housework", null) })
                        androidx.compose.material3.HorizontalDivider()
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text(r.label("adjust")) },
                            onClick = { menu = false; onOther() })
                    }
                }
                Pill(r.label("notTraining"), null, tint) { onAnswer("everyday", null) }
            }
            if (more > 0) {
                Text(fill(r.label("more"), emptyList(), more.toLong()), style = Forge.type.subhead, color = tint,
                     modifier = Modifier.clickable(role = Role.Button, onClick = onMore))
            }
        }
    }
}

@Composable
private fun Pill(label: String, icon: ImageVector?, tint: Color, prominent: Boolean = false, onClick: () -> Unit) {
    val colors = Forge.colors
    Row(
        Modifier.clip(RoundedCornerShape(50))
            .background(if (prominent) tint else tint.copy(alpha = 0.14f))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        val fg = if (prominent) colors.onDark else colors.text
        icon?.let { Icon(it, contentDescription = null, tint = fg, modifier = Modifier.size(15.dp)) }
        Text(label, style = Forge.type.subhead, color = fg, maxLines = 1)
    }
}

/** The inbox rows: the last two weeks, open first, answered ones faded with Undo. Nothing while detection is off. */
@Composable
internal fun ForgeActivityInboxSection() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { withContext(Dispatchers.IO) { ActivitySuggestionState.reload(context) } }
    val result by ActivitySuggestionState.result.collectAsState()
    val r = result ?: return
    if (r.inbox.isEmpty()) return
    var adjusting by remember { mutableStateOf<CoreActivity.Item?>(null) }
    val colors = Forge.colors
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(r.label("section"), style = Forge.type.headline, color = colors.text)
        r.inbox.forEach { item ->
            val open = item.state == "open"
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(colors.inset).padding(12.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(icon(item.likelyKind), contentDescription = null, tint = colors.effort.copy(alpha = if (open) 1f else 0.6f),
                     modifier = Modifier.size(28.dp).clip(CircleShape).background(colors.effort.copy(alpha = 0.14f)).padding(6.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    val title = titleOf(r, item)
                    Text(title, style = Forge.type.subhead, color = if (open) colors.text else colors.textSecondary)
                    Text(whenLine(r, item, withMinutes = true), style = Forge.type.caption, color = colors.textSecondary)
                    if (!open) {
                        val line = when (item.state) {
                            "logged" -> r.label("logged")
                            "walk" -> r.label("savedWalk")
                            "sport" -> r.label("savedTraining")
                            "housework" -> r.label("housework")
                            else -> r.label("notTraining")
                        }
                        Text(line, style = Forge.type.caption, color = colors.textTertiary)
                    }
                }
                when (item.state) {
                    "open" -> Text(r.label("answer"), style = Forge.type.subhead, color = colors.effort,
                                   modifier = Modifier.clickable(role = Role.Button) { adjusting = item })
                    "logged" -> Unit
                    else -> Text(r.label("undo"), style = Forge.type.subhead, color = colors.effort,
                                 modifier = Modifier.clickable(role = Role.Button) {
                                     scope.launch(Dispatchers.IO) {
                                         CoreActivity.undo(item)
                                         ActivitySuggestionState.reload(context)
                                     }
                                 })
                }
            }
        }
    }
    adjusting?.let { item -> ActivityLogDialog(item, origin = "inbox") { adjusting = null } }
}

/** The logging dialog (`ManualWorkoutDialog`) opened on a suggestion; saving confirms it under its own source. */
@Composable
internal fun ActivityLogDialog(item: CoreActivity.Item, origin: String, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefill = WorkoutRow(
        deviceId = "", startTs = item.start, endTs = item.end, sport = CoreActivity.sportToken(item.likelyKind),
        source = "manual", durationS = (item.end - item.start).toDouble(), avgHr = item.avgBpm,
    )
    com.noop.ui.ManualWorkoutDialog(editing = prefill, onDismiss = onClose, onSave = { row, _ ->
        onClose()
        scope.launch(Dispatchers.IO) {
            val walk = com.noop.ui.WorkoutEditing.displaySport(row.sport).lowercase().contains("walk")
            CoreActivity.answer(item, if (walk) "walk" else "sport", origin, sport = row.sport, start = row.startTs,
                                end = row.endTs, shownAt = ActivitySuggestionState.shownAt(item))
            ActivitySuggestionNotifier.answered(context, item.id)
            ActivitySuggestionState.reload(context)
        }
    })
}

/** Whether the active strap counts no steps (a WHOOP 4.0), so the walk track has nothing to read. Blocking. */
internal fun activeStrapCountsNoSteps(context: Context): Boolean = runCatching {
    val app = context.applicationContext as com.noop.NoopApplication
    val row = kotlinx.coroutines.runBlocking { app.deviceRegistry.all() }.firstOrNull { it.id == app.activeDeviceId }
    com.noop.protocol.DeviceFamily.forRegistryDevice(row?.model, row?.brand) == com.noop.protocol.DeviceFamily.WHOOP4
}.getOrDefault(false)
