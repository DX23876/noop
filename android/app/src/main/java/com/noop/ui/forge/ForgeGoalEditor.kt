package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Schedule
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.AlertDialog
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.noop.core.CoreGoalEditor
import com.noop.core.CoreRead
import com.noop.ui.ProfileStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat

/**
 * The one-page goal editor (`CoachGoalEditorView`), opened on a goal from its journey's "Extend the date". The pace
 * and combined-load verdicts show live and never block; only a target equal to the start does, and says why. The
 * kind and ceiling gates and the reason for a very aggressive pace come before the save, as on iOS. [onClose] runs
 * whichever way it closes; `saved` says whether the goal changed.
 */
@Composable
internal fun GoalEditorPage(goalId: String, onClose: (saved: Boolean) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val weightKg = remember { ProfileStore.from(context).toUserProfile().weightKg }
    var state by remember { mutableStateOf<CoreGoalEditor.State?>(null) }
    var showReason by remember { mutableStateOf(false) }
    var showReplace by remember { mutableStateOf(false) }
    var showLimit by remember { mutableStateOf(false) }
    var replacing by remember { mutableStateOf<String?>(null) }
    var picking by remember { mutableStateOf(false) }

    fun call(draft: CoreGoalEditor.Draft, op: String? = null, to: String? = null, acknowledging: Boolean = false,
             replace: String? = null) {
        scope.launch {
            val next = withContext(Dispatchers.IO) { CoreGoalEditor.run(goalId, draft, weightKg, op, to, acknowledging, replace) }
            // A plain edit keeps the fields as typed meanwhile; only a kind or a save takes the core's draft.
            if (next != null) state = if (op == null) next.copy(draft = state?.draft ?: next.draft) else next
            if (next?.saved == true) onClose(true)
        }
    }
    LaunchedEffect(goalId) {
        state = withContext(Dispatchers.IO) { CoreRead.open(context); CoreGoalEditor.run(goalId, null, weightKg) }
    }
    BackHandler { onClose(false) }
    val s = state ?: return
    if (!s.found) {
        LaunchedEffect(Unit) { onClose(false) }
        return
    }
    val d = s.draft
    val l = s.labels
    val colors = Forge.colors
    fun edit(next: CoreGoalEditor.Draft) { state = s.copy(draft = next); call(next) }
    // The latest fields at the moment of the tap: the header's button can hold a lambda from an earlier composition.
    fun save(acknowledging: Boolean) {
        val latest = state?.draft ?: d
        call(latest, "save", acknowledging = acknowledging, replace = replacing)
    }
    fun proceedPastLimit() { if (s.needsReason) showReason = true else save(false) }
    fun attemptSave() {
        when (s.limit) {
            "kind" -> { replacing = s.replaceId; showReplace = true }
            "full" -> showLimit = true
            else -> proceedPastLimit()
        }
    }

    SettingsColumn {
        PageTitle(l["title"].orEmpty(), { onClose(false) }) {
            TextButton(onClick = ::attemptSave, enabled = s.canSave) {
                Text(l["save"].orEmpty(), color = if (s.canSave) colors.accent else colors.textTertiary)
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Overline(l["goalType"].orEmpty())
            s.kinds.chunked(2).forEach { pair ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    pair.forEach { k -> KindTile(k, selected = k.id == d.kind, Modifier.weight(1f)) { call(d, "kind", to = k.id) } }
                    if (pair.size == 1) Spacer(Modifier.weight(1f))
                }
            }
            s.kindNote?.let { Text(it, style = Forge.type.footnote, color = colors.textSecondary) }
        }
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Field(l["goal"].orEmpty(), d.title, s.placeholder) { edit(d.copy(title = it)) }
                if (s.quantified) {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Field(l["from"].orEmpty(), d.baseline, l["now"].orEmpty(), numeric = true, modifier = Modifier.weight(1f)) {
                            edit(d.copy(baseline = it))
                        }
                        Field(l["to"].orEmpty(), d.target, l["targetHint"].orEmpty(), numeric = true, modifier = Modifier.weight(1f)) {
                            edit(d.copy(target = it))
                        }
                    }
                }
                SwitchRow(l["targetDate"].orEmpty(), l["targetDateNote"].orEmpty(), d.hasTargetDate) {
                    edit(d.copy(hasTargetDate = it, targetDateTouched = true))
                }
                if (d.hasTargetDate) {
                    Text(DateFormat.getDateInstance(DateFormat.MEDIUM).format(java.util.Date((d.targetDate * 1000).toLong())),
                         style = Forge.type.body, color = colors.accent,
                         modifier = Modifier.clip(RoundedCornerShape(10.dp)).background(colors.inset)
                             .clickable(role = Role.Button) { picking = true }.padding(horizontal = 12.dp, vertical = 8.dp))
                }
            }
        }
        if (!s.rangeIsUsable) NoticeCard(Icons.Rounded.Warning, colors.effort, l["sameTitle"].orEmpty(), l["sameText"].orEmpty())
        s.warning?.let {
            NoticeCard(if (s.veryAggressive) Icons.Rounded.Warning else Icons.Rounded.Info,
                       if (s.veryAggressive) colors.effort else colors.accent, l["pace"].orEmpty(), it)
        }
        s.volumeWarning?.let { NoticeCard(Icons.Rounded.Schedule, colors.accent, l["volume"].orEmpty(), it) }
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Overline(l["after"].orEmpty())
                    Text(l["why"].orEmpty(), style = Forge.type.caption, color = colors.textSecondary)
                    s.tags.chunked(2).forEach { pair ->
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            pair.forEach { (id, label) ->
                                val on = id in d.tags
                                val shape = RoundedCornerShape(12.dp)
                                Text(label, style = Forge.type.footnote, color = colors.text,
                                     modifier = Modifier.weight(1f).clip(shape)
                                         .background(if (on) colors.accent.copy(alpha = 0.12f) else colors.inset)
                                         .then(if (on) Modifier.border(1.5.dp, colors.accent, shape) else Modifier)
                                         .clickable(role = Role.Button) { edit(d.copy(tags = if (on) d.tags - id else d.tags + id)) }
                                         .padding(horizontal = 10.dp, vertical = 8.dp))
                            }
                            if (pair.size == 1) Spacer(Modifier.weight(1f))
                        }
                    }
                }
                Spacer(Modifier.fillMaxWidth().height(1.dp).background(colors.divider))
                Field(l["personal"].orEmpty(), d.motivation, l["personalHint"].orEmpty()) { edit(d.copy(motivation = it)) }
                SwitchRow(l["share"].orEmpty(), if (d.share) l["shareOn"].orEmpty() else l["shareOff"].orEmpty(), d.share,
                          enabled = d.motivation.isNotBlank()) { edit(d.copy(share = it)) }
            }
        }
    }

    if (picking) TargetDateDialog(d.targetDate, onDismiss = { picking = false }) { secs ->
        picking = false
        edit(d.copy(targetDate = secs))
    }
    if (showReason) {
        var reason by remember { mutableStateOf(d.reason) }
        AlertDialog(
            onDismissRequest = { showReason = false },
            title = { Text(l["reasonTitle"].orEmpty()) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(l["reasonText"].orEmpty())
                    OutlinedTextField(reason, { reason = it }, placeholder = { Text(l["reasonHint"].orEmpty()) }, colors = forgeFieldColors())
                }
            },
            confirmButton = {
                TextButton(onClick = { showReason = false; call((state?.draft ?: d).copy(reason = reason), "save", acknowledging = true, replace = replacing) }) {
                    Text(l["saveAnyway"].orEmpty())
                }
            },
            dismissButton = { TextButton(onClick = { showReason = false }) { Text(l["cancel"].orEmpty()) } },
        )
    }
    if (showReplace) {
        AlertDialog(
            onDismissRequest = { showReplace = false; replacing = null },
            title = { Text(l["replaceTitle"].orEmpty()) },
            text = { Text(s.limitText.orEmpty()) },
            confirmButton = {
                Column(horizontalAlignment = Alignment.End) {
                    TextButton(onClick = { showReplace = false; proceedPastLimit() }) { Text(l["replace"].orEmpty()) }
                    if (s.hasRoom) TextButton(onClick = { showReplace = false; replacing = null; proceedPastLimit() }) { Text(l["keepBoth"].orEmpty()) }
                }
            },
            dismissButton = { TextButton(onClick = { showReplace = false; replacing = null }) { Text(l["cancel"].orEmpty()) } },
        )
    }
    if (showLimit) {
        AlertDialog(
            onDismissRequest = { showLimit = false },
            title = { Text(l["limitTitle"].orEmpty()) },
            text = { Text(s.limitText.orEmpty()) },
            confirmButton = { TextButton(onClick = { showLimit = false }) { Text(l["ok"].orEmpty()) } },
        )
    }
}

@Composable
private fun Overline(text: String) = Text(text.uppercase(), style = Forge.type.overline, color = Forge.colors.textTertiary)

/** An informational card with its icon (`sameRangeCard`, `paceCard`, `volumeCard`). */
@Composable
private fun NoticeCard(icon: ImageVector, tint: androidx.compose.ui.graphics.Color, title: String, text: String) {
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Overline(title)
                Text(text, style = Forge.type.footnote, color = Forge.colors.textSecondary)
            }
        }
    }
}
