package com.noop.ui.forge

import android.text.format.DateUtils
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import com.noop.R
import com.noop.core.CoreCoach
import com.noop.core.CoreRead
import com.noop.ui.UnitPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Fork (DX23876), Android parity plan 2.3: the coach's conversation history after `CoachHistoryView`. Every saved
 * thread of the shared coach, pinned ones first and archived ones last, searchable; tap switches to it, a long
 * press renames, pins, archives or deletes it.
 */
@Composable
internal fun ForgeCoachHistoryPage(onBack: () -> Unit, onPicked: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var rows by remember { mutableStateOf<List<CoreCoach.Conversation>?>(null) }
    var search by remember { mutableStateOf("") }
    var renaming by remember { mutableStateOf<CoreCoach.Conversation?>(null) }
    LaunchedEffect(Unit) { rows = withContext(Dispatchers.IO) { CoreRead.open(context); CoreCoach.conversations() } }
    fun op(op: String, id: String, title: String? = null, value: Boolean? = null, picked: Boolean = false) {
        scope.launch {
            withContext(Dispatchers.IO) { CoreCoach.conversationOp(op, id, title, value) }?.let { rows = it }
            if (picked) onPicked()
        }
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_ch_title), onBack) {
            TextButton(onClick = {
                scope.launch { withContext(Dispatchers.IO) { CoreCoach.newConversation() }; onPicked() }
            }) { Text(stringResource(R.string.forge_ch_new)) }
        }
        val all = rows
        if (all == null) return@SettingsColumn
        if (all.isEmpty()) {
            Text(stringResource(R.string.forge_ch_empty), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        OutlinedTextField(value = search, onValueChange = { search = it }, singleLine = true,
                          placeholder = { Text(stringResource(R.string.forge_ch_search)) }, modifier = Modifier.fillMaxWidth())
        val query = search.trim()
        val matching = all.filter { query.isEmpty() || it.searchText.contains(query, ignoreCase = true) }
        if (query.isNotEmpty() && matching.isEmpty()) {
            Text(stringResource(R.string.forge_ch_nothing_found, query), style = Forge.type.footnote, color = Forge.colors.textTertiary)
        }
        val sections = listOf(
            R.string.forge_ch_pinned to matching.filter { it.pinned && !it.archived },
            null to matching.filter { !it.pinned && !it.archived },
            R.string.forge_ch_archived to matching.filter { it.archived },
        )
        sections.filter { it.second.isNotEmpty() }.forEach { (title, list) ->
            SettingsCard(title = title?.let { stringResource(it) }, blurb = null) {
                list.forEachIndexed { i, c ->
                    ConversationRow(c, onPick = { op("switch", c.id, picked = true) }, onRename = { renaming = c },
                                    onPin = { op("pin", c.id, value = !c.pinned) },
                                    onArchive = { op("archive", c.id, value = !c.archived) },
                                    onDelete = { op("delete", c.id) })
                    if (i < list.lastIndex) RowDivider()
                }
            }
        }
    }
    renaming?.let { c ->
        var text by remember(c.id) { mutableStateOf(c.title) }
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text(stringResource(R.string.forge_ch_rename_title)) },
            text = {
                OutlinedTextField(value = text, onValueChange = { text = it }, singleLine = true,
                                  label = { Text(stringResource(R.string.forge_ch_field_title)) })
            },
            confirmButton = {
                TextButton(onClick = { renaming = null; op("rename", c.id, title = text) }) { Text(stringResource(R.string.forge_ch_save)) }
            },
            dismissButton = { TextButton(onClick = { renaming = null }) { Text(stringResource(R.string.forge_ch_cancel)) } },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ConversationRow(c: CoreCoach.Conversation, onPick: () -> Unit, onRename: () -> Unit, onPin: () -> Unit,
                            onArchive: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.fillMaxWidth().combinedClickable(onClick = onPick, onLongClick = { menu = true })
                .padding(vertical = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
                Text(c.title, style = Forge.type.subhead, color = Forge.colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(c.preview, style = Forge.type.footnote, color = Forge.colors.textTertiary, maxLines = 1,
                     overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.width(ForgeMetrics.space2))
            Column(horizontalAlignment = Alignment.End) {
                if (c.active) {
                    Icon(Icons.Rounded.CheckCircle, contentDescription = stringResource(R.string.forge_ch_current), tint = Forge.colors.accent)
                }
                Text(DateUtils.getRelativeTimeSpanString(c.updatedAt).toString(), style = Forge.type.footnote,
                     color = Forge.colors.textTertiary)
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text(stringResource(R.string.forge_ch_rename)) }, onClick = { menu = false; onRename() })
            DropdownMenuItem(text = { Text(stringResource(if (c.pinned) R.string.forge_ch_unpin else R.string.forge_ch_pin)) },
                             onClick = { menu = false; onPin() })
            DropdownMenuItem(text = { Text(stringResource(if (c.archived) R.string.forge_ch_unarchive else R.string.forge_ch_archive)) },
                             onClick = { menu = false; onArchive() })
            DropdownMenuItem(text = { Text(stringResource(R.string.forge_ch_delete), color = ForgeTokens.Color.systemRed.resolve()) },
                             onClick = { menu = false; onDelete() })
        }
    }
}

/**
 * Fork (DX23876), Android parity plan 2.3: the coach's plan book after `CoachPlanView`: proposals waiting for a
 * yes, what was agreed from today on, and the last ten decided ones with how they went. Accepting here keeps the
 * session untimed; the time, day and swap sheets of the Apple page are not on Android yet.
 */
@Composable
internal fun ForgeCoachPlanPage(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val scale = remember { UnitPrefs.effortScale(context).raw }
    var plan by remember { mutableStateOf<CoreCoach.Plan?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var skipping by remember { mutableStateOf<CoreCoach.PlanRow?>(null) }
    var rating by remember { mutableStateOf<CoreCoach.PlanRow?>(null) }
    var timing by remember { mutableStateOf<Pair<CoreCoach.PlanRow, Boolean>?>(null) }
    var moving by remember { mutableStateOf<CoreCoach.PlanRow?>(null) }
    var swapping by remember { mutableStateOf<CoreCoach.PlanRow?>(null) }
    LaunchedEffect(Unit) {
        plan = withContext(Dispatchers.IO) { CoreRead.open(context); CoreCoach.plan(scale) }
        loaded = true
    }
    fun act(op: String, row: CoreCoach.PlanRow, reason: String? = null, feedback: String? = null, time: Long? = null,
            day: String? = null, sport: String? = null, intent: String? = null) {
        scope.launch {
            withContext(Dispatchers.IO) { CoreCoach.plan(scale, op, row.id, reason, feedback, time, day, sport, intent) }?.let { plan = it }
        }
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_cp_title), onBack)
        val p = plan
        if (p == null) {
            if (!loaded) Text(stringResource(R.string.forge_goals_loading), style = Forge.type.body, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        if (p.pending.isNotEmpty()) {
            SettingsCard(title = stringResource(R.string.forge_cp_waiting), blurb = null) {
                p.pending.forEachIndexed { i, row ->
                    PlanHeader(row)
                    if (row.rationale.isNotEmpty()) {
                        Text(row.rationale, style = Forge.type.footnote, color = Forge.colors.textSecondary)
                    }
                    Row {
                        TextButton(onClick = { timing = row to true }) { Text(stringResource(R.string.forge_cp_accept)) }
                        TextButton(onClick = { swapping = row }) { Text(stringResource(R.string.forge_cp_change)) }
                        TextButton(onClick = { act("decline", row) }) { Text(stringResource(R.string.forge_cp_not_this)) }
                    }
                    if (i < p.pending.lastIndex) RowDivider()
                }
            }
        }
        if (p.agreed.isNotEmpty()) {
            SettingsCard(title = stringResource(R.string.forge_cp_agreed), blurb = null) {
                p.agreed.forEachIndexed { i, row ->
                    PlanHeader(row)
                    row.swappedFrom?.let {
                        Text(stringResource(R.string.forge_cp_swapped, it), style = Forge.type.footnote, color = Forge.colors.textTertiary)
                    }
                    if (row.status == "completed") {
                        FeedbackButton(row) { rating = row }
                    } else {
                        Row {
                            TextButton(onClick = { timing = row to false }) {
                                Text(stringResource(if (row.time == null) R.string.forge_cp_set_time else R.string.forge_cp_change_time))
                            }
                            TextButton(onClick = { moving = row }) { Text(stringResource(R.string.forge_cp_move_day)) }
                            TextButton(onClick = { swapping = row }) { Text(stringResource(R.string.forge_cp_swap)) }
                        }
                        Row {
                            TextButton(onClick = { act("complete", row) }) { Text(stringResource(R.string.forge_cp_done)) }
                            TextButton(onClick = { skipping = row }) {
                                Text(stringResource(R.string.forge_cp_didnt), color = Forge.colors.textSecondary)
                            }
                        }
                    }
                    if (i < p.agreed.lastIndex) RowDivider()
                }
            }
        }
        if (p.recent.isNotEmpty()) {
            SettingsCard(title = stringResource(R.string.forge_cp_recently), blurb = null) {
                p.recent.forEachIndexed { i, row ->
                    Row(verticalAlignment = Alignment.Top) {
                        Column(Modifier.weight(1f)) {
                            Text(row.summary, style = Forge.type.footnote, color = Forge.colors.textSecondary)
                            Text(row.statusLine, style = Forge.type.caption, color = Forge.colors.textTertiary)
                        }
                        Text(row.dayLabel, style = Forge.type.caption, color = Forge.colors.textTertiary)
                    }
                    if (row.status == "completed") FeedbackButton(row) { rating = row }
                    if (i < p.recent.lastIndex) RowDivider()
                }
            }
        }
        if (p.empty) {
            SettingsCard(title = stringResource(R.string.forge_cp_empty_title), blurb = stringResource(R.string.forge_cp_empty_body)) {}
        }
    }
    skipping?.let { row ->
        ChoiceDialog(stringResource(R.string.forge_cp_why), plan?.skipReasons.orEmpty(), onDismiss = { skipping = null }) { reason ->
            skipping = null; act("skip", row, reason = reason)
        }
    }
    timing?.let { (row, accepting) ->
        TimeDialog(row, accepting, onDismiss = { timing = null },
                   onSet = { ts -> timing = null; act(if (accepting) "accept" else "setTime", row, time = ts) },
                   onUntimed = { timing = null; act(if (accepting) "accept" else "clearTime", row) })
    }
    moving?.let { row ->
        MoveDialog(row, onDismiss = { moving = null }) { day -> moving = null; act("reschedule", row, day = day, time = row.time) }
    }
    swapping?.let { row ->
        SwapDialog(row, plan?.intents.orEmpty(), onDismiss = { swapping = null }) { sport, intent ->
            swapping = null; act("swap", row, sport = sport, intent = intent)
        }
    }
    rating?.let { row ->
        ChoiceDialog(stringResource(R.string.forge_cp_afterwards), plan?.feedbacks.orEmpty(), onDismiss = { rating = null }) { feedback ->
            rating = null; act("feedback", row, feedback = feedback)
        }
    }
}

@Composable
private fun PlanHeader(row: CoreCoach.PlanRow) {
    Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
        Text(row.summary, style = Forge.type.subhead, color = Forge.colors.text, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(ForgeMetrics.space2))
        Text(row.dayLabel.uppercase(), style = Forge.type.overline, color = Forge.colors.textSecondary)
    }
}

@Composable
private fun FeedbackButton(row: CoreCoach.PlanRow, onClick: () -> Unit) {
    TextButton(onClick = onClick) {
        Text(row.feedbackLabel ?: stringResource(R.string.forge_cp_feel),
             color = if (row.feedbackLabel == null) Forge.colors.accent else Forge.colors.textSecondary)
    }
}

@Composable
private fun ChoiceDialog(title: String, choices: List<Pair<String, String>>, onDismiss: () -> Unit, onPick: (String) -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column {
                choices.forEach { (id, label) ->
                    TextButton(onClick = { onPick(id) }, modifier = Modifier.fillMaxWidth()) { Text(label) }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.forge_ch_cancel)) } },
    )
}

/** `PlanTimeSheet`: a time on the session's day, or none (accepting untimed, or removing the time). */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun TimeDialog(row: CoreCoach.PlanRow, accepting: Boolean, onDismiss: () -> Unit, onSet: (Long) -> Unit, onUntimed: () -> Unit) {
    val zone = java.time.ZoneId.systemDefault()
    val start = row.time?.let { java.time.Instant.ofEpochSecond(it).atZone(zone).toLocalTime() } ?: java.time.LocalTime.of(18, 0)
    val state = androidx.compose.material3.rememberTimePickerState(start.hour, start.minute, android.text.format.DateFormat.is24HourFormat(LocalContext.current))
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(row.summary) },
        text = { androidx.compose.material3.TimePicker(state) },
        confirmButton = {
            TextButton(onClick = {
                val day = runCatching { java.time.LocalDate.parse(row.day) }.getOrDefault(java.time.LocalDate.now())
                onSet(day.atTime(state.hour, state.minute).atZone(zone).toEpochSecond())
            }) { Text(stringResource(R.string.forge_cp_set)) }
        },
        dismissButton = {
            Row {
                if (accepting) TextButton(onClick = onUntimed) { Text(stringResource(R.string.forge_cp_accept_untimed)) }
                else if (row.time != null) TextButton(onClick = onUntimed) { Text(stringResource(R.string.forge_cp_remove_time)) }
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.forge_ch_cancel)) }
            }
        },
    )
}

/** `PlanRescheduleSheet`: another day from today on; the time stays. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun MoveDialog(row: CoreCoach.PlanRow, onDismiss: () -> Unit, onMove: (String) -> Unit) {
    val today = java.time.LocalDate.now()
    val initial = runCatching { java.time.LocalDate.parse(row.day) }.getOrDefault(today).let { if (it.isBefore(today)) today else it }
    val utc = java.time.ZoneOffset.UTC
    val state = androidx.compose.material3.rememberDatePickerState(
        initialSelectedDateMillis = initial.atStartOfDay(utc).toInstant().toEpochMilli(),
        selectableDates = object : androidx.compose.material3.SelectableDates {
            override fun isSelectableDate(utcTimeMillis: Long) =
                !java.time.Instant.ofEpochMilli(utcTimeMillis).atZone(utc).toLocalDate().isBefore(today)
        })
    androidx.compose.material3.DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = {
                state.selectedDateMillis?.let { onMove(java.time.Instant.ofEpochMilli(it).atZone(utc).toLocalDate().toString()) }
            }) { Text(stringResource(R.string.forge_cp_move)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.forge_ch_cancel)) } },
    ) { androidx.compose.material3.DatePicker(state) }
}

/** `PlanSwapSheet`: another activity in the same slot, with how hard. */
@Composable
private fun SwapDialog(row: CoreCoach.PlanRow, intents: List<Pair<String, String>>, onDismiss: () -> Unit,
                       onSwap: (String, String) -> Unit) {
    var sport by remember(row.id) { mutableStateOf("") }
    var intent by remember(row.id) { mutableStateOf(row.intent.ifEmpty { "moderate" }) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.forge_cp_instead, row.sport)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                OutlinedTextField(value = sport, onValueChange = { sport = it }, singleLine = true,
                                  placeholder = { Text(stringResource(R.string.forge_cp_eg)) })
                Text(stringResource(R.string.forge_cp_how_hard), style = Forge.type.caption, color = Forge.colors.textSecondary)
                intents.forEach { (id, label) ->
                    Row(Modifier.fillMaxWidth().clickable { intent = id }, verticalAlignment = Alignment.CenterVertically) {
                        androidx.compose.material3.RadioButton(selected = intent == id, onClick = { intent = id })
                        Text(label)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(enabled = sport.isNotBlank(), onClick = { onSwap(sport.trim(), intent) }) { Text(stringResource(R.string.forge_cp_swap)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.forge_ch_cancel)) } },
    )
}

