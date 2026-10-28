package com.noop.ui.forge

import android.text.format.DateUtils
import androidx.compose.foundation.ExperimentalFoundationApi
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
    LaunchedEffect(Unit) {
        plan = withContext(Dispatchers.IO) { CoreRead.open(context); CoreCoach.plan(scale) }
        loaded = true
    }
    fun act(op: String, row: CoreCoach.PlanRow, reason: String? = null, feedback: String? = null) {
        scope.launch { withContext(Dispatchers.IO) { CoreCoach.plan(scale, op, row.id, reason, feedback) }?.let { plan = it } }
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
                        TextButton(onClick = { act("accept", row) }) { Text(stringResource(R.string.forge_cp_accept)) }
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
