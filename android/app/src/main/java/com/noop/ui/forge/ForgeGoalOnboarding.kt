package com.noop.ui.forge

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.noop.core.CoreGoalOnboarding
import com.noop.core.CoreRead
import com.noop.ui.ProfileStore
import com.noop.ui.noopFieldColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset

/**
 * The guided goal setup (`CoachGoalOnboardingFlow`): welcome, kind, details, why and confirm, one question at a time.
 * The step machine, the kind's defaults, the pace check and the save are the shared `GoalOnboardingDraft` through
 * `goals.onboarding`; this page holds the draft and draws it. [onClose] runs whichever way it closes, saved or
 * skipped, so the coach's one-time offer is marked as asked.
 */
@Composable
internal fun GoalOnboardingPage(onClose: (saved: Boolean) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val weightKg = remember { ProfileStore.from(context).toUserProfile().weightKg }
    var state by remember { mutableStateOf<CoreGoalOnboarding.State?>(null) }
    var showReason by remember { mutableStateOf(false) }
    var showReplace by remember { mutableStateOf(false) }
    var showLimit by remember { mutableStateOf(false) }
    var replacing by remember { mutableStateOf<String?>(null) }
    var picking by remember { mutableStateOf(false) }

    fun call(draft: CoreGoalOnboarding.Draft, op: String? = null, to: String? = null, acknowledging: Boolean = false,
             replace: String? = null) {
        scope.launch {
            val next = withContext(Dispatchers.IO) { CoreGoalOnboarding.run(draft, weightKg, op, to, acknowledging, replace) }
            // A plain edit keeps the fields as typed meanwhile; only a step, kind or save takes the core's draft.
            if (next != null) state = if (op == null) next.copy(draft = state?.draft ?: next.draft) else next
            if (next?.saved == true) onClose(true)
        }
    }
    fun close() {
        scope.launch { withContext(Dispatchers.IO) { CoreGoalOnboarding.run(CoreGoalOnboarding.Draft(), weightKg, "asked") } }
        onClose(false)
    }
    LaunchedEffect(Unit) {
        state = withContext(Dispatchers.IO) { CoreRead.open(context); CoreGoalOnboarding.run(CoreGoalOnboarding.Draft(), weightKg) }
    }
    val s = state ?: return
    val d = s.draft
    val l = s.labels
    // Edits that need no rule only change the draft here; the next call carries them.
    fun edit(next: CoreGoalOnboarding.Draft) { state = s.copy(draft = next); call(next) }
    fun commit(acknowledging: Boolean) = call(d, "commit", acknowledging = acknowledging, replace = replacing)
    fun proceedPastLimit() { if (s.requiresReason) showReason = true else commit(false) }
    fun attemptCommit() {
        when (s.limit) {
            "kind" -> { replacing = s.replaceId; showReplace = true }
            "full" -> showLimit = true
            else -> proceedPastLimit()
        }
    }
    BackHandler { if (d.step > 0) call(d, "back") else close() }

    SettingsColumn {
        PageTitle(s.stepTitle, ::close) {
            TextButton(onClick = ::close) { Text(l["skip"].orEmpty(), color = Forge.colors.accent) }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            repeat(s.steps) {
                Box(Modifier.weight(1f).height(4.dp).clip(CircleShape)
                        .background(if (it <= d.step) Forge.colors.accent else Forge.colors.inset))
            }
        }
        Text(s.stepLabel, style = Forge.type.caption, color = Forge.sceneInk.secondary)
        when (d.step) {
            0 -> Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(l["welcome"].orEmpty(), style = Forge.type.body, color = Forge.sceneInk.text)
                Text(l["optional"].orEmpty(), style = Forge.type.footnote, color = Forge.sceneInk.secondary)
            }
            1 -> Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                s.kinds.chunked(2).forEach { pair ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        pair.forEach { k -> KindTile(k, selected = k.id == d.kind, Modifier.weight(1f)) { call(d, "kind", to = k.id) } }
                        if (pair.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
                s.kindNote?.let { Note(it) }
            }
            2 -> ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    val kind = s.kinds.firstOrNull { it.id == d.kind }
                    Field(l["goal"].orEmpty(), d.title, kind?.placeholder.orEmpty()) { edit(d.copy(title = it)) }
                    if (d.title.isBlank()) Note(l["nameNote"].orEmpty())
                    if (kind?.quantified == true) {
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Field(l["from"].orEmpty(), d.baseline, l["now"].orEmpty(), numeric = true, modifier = Modifier.weight(1f)) {
                                edit(d.copy(baseline = it))
                            }
                            Field(l["to"].orEmpty(), d.target, l["targetHint"].orEmpty(), numeric = true, modifier = Modifier.weight(1f)) {
                                edit(d.copy(target = it))
                            }
                        }
                        if (!s.rangeIsUsable) Note(l["rangeNote"].orEmpty())
                    }
                    SwitchRow(l["targetDate"].orEmpty(), l["targetDateNote"].orEmpty(), d.hasTargetDate) {
                        edit(d.copy(hasTargetDate = it, targetDateTouched = true))
                    }
                    if (d.hasTargetDate) {
                        Text(DateFormat.getDateInstance(DateFormat.MEDIUM).format(java.util.Date((d.targetDate * 1000).toLong())),
                             style = Forge.type.body, color = Forge.colors.accent,
                             modifier = Modifier.clip(RoundedCornerShape(10.dp)).background(Forge.colors.inset)
                                 .clickable(role = Role.Button) { picking = true }.padding(horizontal = 12.dp, vertical = 8.dp))
                    }
                }
            }
            3 -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(l["why"].orEmpty(), style = Forge.type.footnote, color = Forge.sceneInk.secondary)
                s.tags.chunked(2).forEach { pair ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        pair.forEach { (id, label) ->
                            val on = id in d.tags
                            Text(label, style = Forge.type.subhead, color = if (on) Forge.colors.accent else Forge.colors.text,
                                 modifier = Modifier.weight(1f).clip(RoundedCornerShape(12.dp))
                                     .background(if (on) Forge.colors.accent.copy(alpha = 0.12f) else Forge.colors.inset)
                                     .clickable(role = Role.Button) { edit(d.copy(tags = if (on) d.tags - id else d.tags + id)) }
                                     .padding(horizontal = 12.dp, vertical = 10.dp))
                        }
                        if (pair.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
                ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Field(l["personal"].orEmpty(), d.motivation, l["personalHint"].orEmpty()) { edit(d.copy(motivation = it)) }
                        SwitchRow(l["share"].orEmpty(), if (d.share) l["shareOn"].orEmpty() else l["shareOff"].orEmpty(), d.share,
                                  enabled = d.motivation.isNotBlank()) { edit(d.copy(share = it)) }
                    }
                }
            }
            else -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(s.goalTitle, style = Forge.type.headline, color = Forge.colors.text)
                        Text(s.summary, style = Forge.type.footnote, color = Forge.colors.textTertiary)
                    }
                }
                s.warning?.let { w ->
                    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Icon(if (s.veryAggressive) Icons.Rounded.Warning else Icons.Rounded.Info, contentDescription = null,
                                 tint = if (s.veryAggressive) Forge.colors.effort else Forge.colors.accent, modifier = Modifier.size(18.dp))
                            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(l["pace"].orEmpty().uppercase(), style = Forge.type.overline, color = Forge.colors.textTertiary)
                                Text(w, style = Forge.type.footnote, color = Forge.colors.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            if (d.step > 0) TextButton(onClick = { call(d, "back") }) { Text(l["back"].orEmpty(), color = Forge.colors.accent) }
            Spacer(Modifier.weight(1f))
            val last = d.step == s.steps - 1
            Box(Modifier.alpha(if (s.canAdvance) 1f else 0.45f).clip(RoundedCornerShape(14.dp)).background(Forge.colors.accent)
                    .clickable(enabled = s.canAdvance, role = Role.Button) { if (last) attemptCommit() else call(d, "advance") }
                    .padding(horizontal = 20.dp, vertical = 12.dp)) {
                Text(when { last -> l["set"]; d.step == 0 -> l["start"]; else -> l["next"] }.orEmpty(),
                     style = Forge.type.headline, color = Color.White)
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
                    OutlinedTextField(reason, { reason = it }, placeholder = { Text(l["reasonHint"].orEmpty()) }, colors = noopFieldColors())
                }
            },
            confirmButton = {
                TextButton(onClick = { showReason = false; call(d.copy(reason = reason), "commit", acknowledging = true, replace = replacing) }) {
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

/** A goal-kind tile (`GoalKindTile`): label and blurb, the accent marking the chosen one. */
@Composable
private fun KindTile(kind: CoreGoalOnboarding.Kind, selected: Boolean, modifier: Modifier, onTap: () -> Unit) {
    val colors = Forge.colors
    val shape = RoundedCornerShape(14.dp)
    Column(modifier.heightIn(min = 96.dp).clip(shape)
            .background(if (selected) colors.accent.copy(alpha = 0.12f) else colors.inset)
            .then(if (selected) Modifier.border(1.5.dp, colors.accent, shape) else Modifier)
            .clickable(role = Role.Button, onClick = onTap).padding(12.dp),
           verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(kind.label, style = Forge.type.subhead, color = colors.text)
        Text(kind.blurb, style = Forge.type.caption, color = colors.textTertiary)
    }
}

@Composable
private fun Note(text: String) = Text(text, style = Forge.type.footnote, color = Forge.colors.textTertiary)

@Composable
private fun Field(label: String, value: String, placeholder: String, numeric: Boolean = false, modifier: Modifier = Modifier,
                  onChange: (String) -> Unit) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(label.uppercase(), style = Forge.type.overline, color = Forge.colors.textTertiary)
        OutlinedTextField(value, onChange, Modifier.fillMaxWidth(), singleLine = true,
                          placeholder = { Text(placeholder) }, colors = noopFieldColors(),
                          keyboardOptions = if (numeric) KeyboardOptions(keyboardType = KeyboardType.Decimal) else KeyboardOptions.Default)
    }
}

@Composable
private fun SwitchRow(title: String, note: String, on: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(title, style = Forge.type.subhead, color = Forge.colors.text)
            Text(note, style = Forge.type.footnote, color = Forge.colors.textTertiary)
        }
        Spacer(Modifier.width(8.dp))
        Switch(checked = on, onCheckedChange = onChange, enabled = enabled)
    }
}

/** The target date, today or later, as the iOS picker's `in: Date()...`. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun TargetDateDialog(seconds: Double, onDismiss: () -> Unit, onPick: (Double) -> Unit) {
    val today = LocalDate.now()
    val utc = ZoneOffset.UTC
    val initial = Instant.ofEpochSecond(seconds.toLong()).atZone(ZoneId.systemDefault()).toLocalDate().let { if (it.isBefore(today)) today else it }
    val state = androidx.compose.material3.rememberDatePickerState(
        initialSelectedDateMillis = initial.atStartOfDay(utc).toInstant().toEpochMilli(),
        selectableDates = object : androidx.compose.material3.SelectableDates {
            override fun isSelectableDate(utcTimeMillis: Long) =
                !Instant.ofEpochMilli(utcTimeMillis).atZone(utc).toLocalDate().isBefore(today)
        })
    androidx.compose.material3.DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = {
                state.selectedDateMillis?.let {
                    val day = Instant.ofEpochMilli(it).atZone(utc).toLocalDate()
                    onPick(day.atTime(12, 0).atZone(ZoneId.systemDefault()).toEpochSecond().toDouble())
                }
            }) { Text(stringResourceOk()) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(androidx.compose.ui.res.stringResource(android.R.string.cancel)) } },
    ) { androidx.compose.material3.DatePicker(state) }
}

@Composable
private fun stringResourceOk() = androidx.compose.ui.res.stringResource(android.R.string.ok)
