package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.RemoveCircle
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.noop.core.CoreCoachDrafts
import com.noop.core.CoreRead
import com.noop.ui.ProfileStore
import com.noop.ui.noopFieldColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.text.DateFormat
import java.time.DayOfWeek
import java.time.format.TextStyle
import java.util.Locale

// MARK: - Shared pieces

@Composable
private fun DraftSection(title: String, overline: String? = null, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        overline?.let { GoalSectionHeader(it) }
        Text(title, style = Forge.type.headline, color = Forge.sceneInk.text)
        content()
    }
}

@Composable
private fun DraftButton(label: String, enabled: Boolean = true, primary: Boolean = true, onClick: () -> Unit) {
    Box(Modifier.alpha(if (enabled) 1f else 0.45f).clip(RoundedCornerShape(14.dp))
            .background(if (primary) Forge.colors.accent else Forge.colors.inset)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick).padding(horizontal = 18.dp, vertical = 12.dp)) {
        Text(label, style = Forge.type.headline, color = if (primary) Color.White else Forge.colors.text)
    }
}

@Composable
private fun ExerciseCard(e: CoreCoachDrafts.Exercise, numbered: Boolean) {
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(e.title, style = Forge.type.headline, color = Forge.colors.text, modifier = Modifier.weight(1f))
                e.superset?.let { Text(it, style = Forge.type.caption, color = Forge.colors.textTertiary) }
            }
            e.sets.forEachIndexed { i, set ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (numbered) Text((i + 1).toString(), style = Forge.type.caption, color = Forge.colors.textTertiary, modifier = Modifier.width(16.dp))
                    Text(set, style = Forge.type.subhead, color = Forge.colors.textSecondary)
                }
            }
            e.rest?.let { Text(it, style = Forge.type.caption, color = Forge.colors.textTertiary) }
            e.notes?.let { Text(it, style = Forge.type.caption, color = Forge.colors.textTertiary) }
        }
    }
}

@Composable
private fun ErrorCard(text: String) {
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        Text(text, style = Forge.type.subhead, color = Forge.colors.effort)
    }
}

// MARK: - Hevy routine (`HevyRoutineReviewView`)

@Composable
internal fun RoutineReviewPage(onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var drafts by remember { mutableStateOf<CoreCoachDrafts.Drafts?>(null) }
    var routine by remember { mutableStateOf<CoreCoachDrafts.Routine?>(null) }
    var sending by remember { mutableStateOf(false) }
    var sent by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        drafts = withContext(Dispatchers.IO) { CoreRead.open(context); CoreCoachDrafts.drafts(context) }
        routine = drafts?.routine
    }
    BackHandler(onBack = onClose)
    val l = drafts?.labels ?: return
    SettingsColumn {
        PageTitle(l["routineTitle"], onClose) { TextButton(onClick = onClose) { Text(l["later"].orEmpty(), color = Forge.colors.accent) } }
        val r = routine
        if (r == null) {
            Text(l["decided"].orEmpty(), style = Forge.type.headline, color = Forge.sceneInk.text)
            Text(l["askAgain"].orEmpty(), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        DraftSection(r.header, l["hevy"]) {
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(r.title, style = Forge.type.title2, color = Forge.colors.text)
                    Text(r.counts, style = Forge.type.subhead, color = Forge.colors.textSecondary)
                    if (r.rationale.isNotEmpty()) {
                        RowDivider()
                        Text(r.rationale, style = Forge.type.subhead, color = Forge.colors.textSecondary)
                    }
                    Text(l["nothingSent"].orEmpty(), style = Forge.type.caption, color = Forge.colors.textTertiary)
                }
            }
        }
        if (r.warnings.isNotEmpty()) DraftSection(l["worth"].orEmpty(), l["check"]) {
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    r.warnings.forEach { w ->
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Icon(Icons.Rounded.Warning, null, tint = Forge.colors.effort, modifier = Modifier.size(14.dp))
                            Text(w, style = Forge.type.subhead, color = Forge.colors.text)
                        }
                    }
                    Text(l["checkNote"].orEmpty(), style = Forge.type.caption, color = Forge.colors.textTertiary)
                }
            }
        }
        if (r.replaces) DraftSection(l["changes"].orEmpty(), l["beforeAfter"]) {
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(l["replaces"].orEmpty(), style = Forge.type.subhead, color = Forge.colors.text)
                    ChangeList(l["removed"].orEmpty(), r.removed, Icons.Rounded.RemoveCircle, Forge.colors.effort)
                    ChangeList(l["added"].orEmpty(), r.added, Icons.Rounded.AddCircle, Forge.colors.charge)
                    if (r.removed.isEmpty() && r.added.isEmpty()) {
                        Text(l["same"].orEmpty(), style = Forge.type.caption, color = Forge.colors.textTertiary)
                    }
                }
            }
        }
        DraftSection(l["routine"].orEmpty(), l["sets"]) {
            r.exercises.forEach { ExerciseCard(it, numbered = true) }
        }
        (error ?: r.error)?.let { ErrorCard(it) }
        val done = sent
        if (done != null) {
            Text(done, style = Forge.type.subhead, color = Forge.colors.charge)
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                DraftButton(if (sending) l["sending"].orEmpty() else l["send"].orEmpty(), enabled = !sending) {
                    sending = true
                    scope.launch {
                        val next = withContext(Dispatchers.IO) { CoreCoachDrafts.drafts(context, "routine.send", r.id) }
                        sending = false
                        if (next?.sent != null) sent = next.sent else error = next?.error
                    }
                }
                DraftButton(l["discard"].orEmpty(), enabled = !sending, primary = false) {
                    scope.launch {
                        withContext(Dispatchers.IO) { CoreCoachDrafts.drafts(context, "routine.decline", r.id) }
                        onClose()
                    }
                }
                if (sending) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            }
            Text(l["onlyButton"].orEmpty(), style = Forge.type.caption, color = Forge.sceneInk.secondary)
        }
    }
}

@Composable
private fun ChangeList(title: String, names: List<String>, icon: ImageVector, tint: Color) {
    if (names.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title.uppercase(), style = Forge.type.overline, color = Forge.colors.textTertiary)
        names.forEach { name ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, null, tint = tint, modifier = Modifier.size(12.dp))
                Text(name, style = Forge.type.subhead, color = Forge.colors.text)
            }
        }
    }
}

// MARK: - Hevy workout (`HevyWorkoutReviewView`)

@Composable
internal fun WorkoutReviewPage(onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var drafts by remember { mutableStateOf<CoreCoachDrafts.Drafts?>(null) }
    var sending by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { drafts = withContext(Dispatchers.IO) { CoreRead.open(context); CoreCoachDrafts.drafts(context) } }
    BackHandler(onBack = onClose)
    val d = drafts ?: return
    val l = d.labels
    SettingsColumn {
        PageTitle(l["workoutTitle"], onClose) { TextButton(onClick = onClose) { Text(l["close"].orEmpty(), color = Forge.colors.accent) } }
        val w = d.workout ?: return@SettingsColumn
        DraftSection(w.header, l["review"]) {
            w.cards.forEach { c ->
                ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(c.label.uppercase(), style = Forge.type.overline, color = Forge.colors.textTertiary)
                        Text(c.title, style = Forge.type.headline, color = Forge.colors.text)
                        Text(c.date, style = Forge.type.caption, color = Forge.colors.textSecondary)
                        c.exercises.forEach { e ->
                            Text(e.title, style = Forge.type.subhead, color = Forge.colors.text)
                            e.sets.forEach { Text(it, style = Forge.type.caption, color = Forge.colors.textSecondary) }
                        }
                        Text(c.volume, style = Forge.type.caption, color = Forge.colors.textSecondary)
                    }
                }
            }
        }
        w.createNote?.let { Text(it, style = Forge.type.caption, color = Forge.colors.effort) }
        (error ?: w.error)?.let { ErrorCard(it) }
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = {
                scope.launch { withContext(Dispatchers.IO) { CoreCoachDrafts.drafts(context, "workout.decline", w.id) }; onClose() }
            }) { Text(l["decline"].orEmpty(), color = Forge.colors.accent) }
            Spacer(Modifier.weight(1f))
            DraftButton(if (sending) l["sending"].orEmpty() else l["send"].orEmpty(), enabled = !sending) {
                sending = true
                scope.launch {
                    val next = withContext(Dispatchers.IO) { CoreCoachDrafts.drafts(context, "workout.send", w.id) }
                    sending = false
                    if (next?.sent != null) onClose() else error = next?.error
                }
            }
        }
    }
}

// MARK: - Goal and routine draft (`CoachGoalSetupReviewView`)

@Composable
internal fun GoalDraftReviewPage(proposalId: String, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val weightKg = remember { ProfileStore.from(context).toUserProfile().weightKg }
    var review by remember { mutableStateOf<CoreCoachDrafts.Review?>(null) }
    var editing by remember { mutableStateOf<CoreCoachDrafts.ReviewRoutine?>(null) }
    var reason by remember { mutableStateOf("") }
    var picking by remember { mutableStateOf(false) }

    fun step(op: String, args: JSONObject = JSONObject()) {
        scope.launch {
            val next = withContext(Dispatchers.IO) { CoreCoachDrafts.review(op, args.put("weightKg", weightKg)) }
            if (next != null) review = if (next.open || next.error != null) next else next.copy(open = review?.open ?: false)
            if (next?.applied == true || (op == "decline")) onClose()
        }
    }
    fun set(key: String, value: Any) = step("set", JSONObject().put(key, value))
    LaunchedEffect(proposalId) {
        review = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreCoachDrafts.review("open", JSONObject().put("id", proposalId).put("weightKg", weightKg))
        }
    }
    BackHandler(onBack = onClose)
    val r = review ?: return
    val l = r.labels
    SettingsColumn {
        PageTitle(r.title.ifEmpty { null }, onClose) {
            TextButton(onClick = onClose) { Text(l["later"].orEmpty(), color = Forge.colors.accent) }
        }
        if (!r.open) {
            r.error?.let { Text(it, style = Forge.type.subhead, color = Forge.sceneInk.secondary) }
            return@SettingsColumn
        }
        if (r.rationale.isNotEmpty()) DraftSection(l["reasoning"].orEmpty()) {
            Text(r.rationale, style = Forge.type.subhead, color = Forge.sceneInk.secondary)
        }
        r.goal?.let { g ->
            DraftSection(l["goal"].orEmpty()) {
                ForgeCard(Modifier.fillMaxWidth().alpha(if (g.include) 1f else 0.6f), radius = ForgeMetrics.groupedRadius) {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        ToggleLine(g.includeLabel, g.include) { set("includeGoal", it) }
                        if (g.templateTitle != null) {
                            ValueLine(l["type"].orEmpty(), g.templateTitle)
                        } else {
                            Text(l["type"].orEmpty().uppercase(), style = Forge.type.overline, color = Forge.colors.textTertiary)
                            g.kinds.chunked(3).forEach { row ->
                                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    row.forEach { k -> Pill(k.label, k.id == g.kind, Modifier.weight(1f)) { set("kind", k.id) } }
                                    repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                                }
                            }
                        }
                        ReviewField(l["goalTitle"].orEmpty(), g.title) { set("title", it) }
                        if (g.showBaseline) ReviewField(g.baselineLabel, g.baseline, numeric = true) { set("baseline", it) }
                        if (g.showTarget) ReviewField(g.targetLabel, g.target, numeric = true) { set("target", it) }
                        g.evidence?.let { Text(it, style = Forge.type.caption, color = Forge.colors.textTertiary) }
                        if (g.dateAllowed) {
                            ToggleLine(l["targetDate"].orEmpty(), g.hasDate) { set("hasDate", it) }
                            if (g.hasDate) {
                                Text(DateFormat.getDateInstance(DateFormat.MEDIUM).format(java.util.Date((g.date * 1000).toLong())),
                                     style = Forge.type.body, color = Forge.colors.accent,
                                     modifier = Modifier.clip(RoundedCornerShape(10.dp)).background(Forge.colors.inset)
                                         .clickable(role = Role.Button) { picking = true }.padding(horizontal = 12.dp, vertical = 8.dp))
                            }
                        }
                        Text(l["why"].orEmpty().uppercase(), style = Forge.type.overline, color = Forge.colors.textTertiary)
                        g.tags.forEach { t -> CheckLine(t.label, t.on) { set("tag", t.id) } }
                        g.safetyWarning?.let { WarningLine(it) }
                        g.volumeWarning?.let { WarningLine(it) }
                    }
                }
            }
        }
        if (r.routines.isNotEmpty()) DraftSection(l["routines"].orEmpty()) {
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    r.routines.forEach { rt ->
                        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            SelectIcon(rt.selected, enabled = !rt.unavailable) { set("routine", rt.id) }
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text(rt.title, style = Forge.type.footnote, color = Forge.colors.text)
                                if (rt.detail.isNotEmpty()) Text(rt.detail, style = Forge.type.caption, color = Forge.colors.textTertiary)
                                Text(rt.linked, style = Forge.type.caption, color = Forge.colors.textSecondary)
                                if (rt.unavailable) Text(l["unavailable"].orEmpty(), style = Forge.type.caption, color = Forge.colors.effort)
                            }
                            Text(l["edit"].orEmpty(), style = Forge.type.caption, color = Forge.colors.accent,
                                 modifier = Modifier.clickable(role = Role.Button) { editing = rt })
                        }
                    }
                }
            }
        }
        if (r.periods.isNotEmpty()) DraftSection(l["periods"].orEmpty()) {
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    r.periods.forEach { p ->
                        Row(Modifier.alpha(if (p.selected) 1f else 0.6f), verticalAlignment = Alignment.Top,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            SelectIcon(p.selected) { set("period", p.id) }
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(p.title, style = Forge.type.footnote, color = Forge.colors.text)
                                p.sports?.let { Text(it, style = Forge.type.caption, color = Forge.colors.textTertiary) }
                                p.serves?.let { Text(it, style = Forge.type.caption, color = Forge.colors.textSecondary) }
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(p.amount, style = Forge.type.captionNumber, color = Forge.colors.text, modifier = Modifier.weight(1f))
                                    Pill("−", false) { step("set", JSONObject().put("periodStep", p.id).put("delta", -1)) }
                                    Pill("+", false) { step("set", JSONObject().put("periodStep", p.id).put("delta", 1)) }
                                }
                                p.note?.let { WarningLine(it) }
                            }
                        }
                    }
                }
            }
        }
        Text(l["inactive"].orEmpty(), style = Forge.type.caption, color = Forge.sceneInk.secondary)
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { step("decline") }) { Text(l["decline"].orEmpty(), color = Forge.colors.effort) }
            Spacer(Modifier.weight(1f))
            DraftButton(l["apply"].orEmpty(), enabled = r.canApply) { step("apply", JSONObject().put("stage", "start")) }
        }
    }

    if (picking) r.goal?.let { g ->
        GoalDatePicker(g.date, onDismiss = { picking = false }) { secs -> picking = false; set("date", secs) }
    }
    editing?.let { rt ->
        RoutineEditorDialog(rt, r.goals, l, onDismiss = { editing = null }) { args ->
            editing = null
            step("routine", args.put("id", rt.id))
        }
    }
    when (r.ask) {
        "replace" -> AlertDialog(
            onDismissRequest = { review = r.copy(ask = null) },
            title = { Text(l["replaceTitle"].orEmpty()) },
            text = { Text(l["replaceText"].orEmpty()) },
            confirmButton = {
                Column(horizontalAlignment = Alignment.End) {
                    TextButton(onClick = { step("apply", JSONObject().put("stage", "replace")) }) { Text(l["replace"].orEmpty()) }
                    if (r.keepBoth) TextButton(onClick = { step("apply", JSONObject().put("stage", "keep")) }) { Text(l["keepBoth"].orEmpty()) }
                }
            },
            dismissButton = { TextButton(onClick = { review = r.copy(ask = null) }) { Text(l["cancel"].orEmpty()) } },
        )
        "reason" -> AlertDialog(
            onDismissRequest = { review = r.copy(ask = null) },
            title = { Text(l["reasonTitle"].orEmpty()) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(l["reasonText"].orEmpty())
                    OutlinedTextField(reason, { reason = it }, placeholder = { Text(l["reasonHint"].orEmpty()) }, colors = noopFieldColors())
                }
            },
            confirmButton = {
                TextButton(onClick = { step("apply", JSONObject().put("stage", "reason").put("reason", reason)) }) { Text(l["applyAnyway"].orEmpty()) }
            },
            dismissButton = { TextButton(onClick = { review = r.copy(ask = null) }) { Text(l["cancel"].orEmpty()) } },
        )
    }
    if (r.open && r.error != null) AlertDialog(
        onDismissRequest = { review = r.copy(error = null) },
        title = { Text(l["errorTitle"].orEmpty()) },
        text = { Text(r.error) },
        confirmButton = { TextButton(onClick = { review = r.copy(error = null) }) { Text(l["ok"].orEmpty()) } },
    )
}

@Composable
private fun ToggleLine(title: String, on: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = Forge.type.subhead, color = Forge.colors.text, modifier = Modifier.weight(1f))
        Switch(checked = on, onCheckedChange = onChange, colors = forgeSwitchColors())
    }
}

@Composable
private fun ValueLine(title: String, value: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = Forge.type.subhead, color = Forge.colors.text, modifier = Modifier.weight(1f))
        Text(value, style = Forge.type.subhead, color = Forge.colors.textSecondary)
    }
}

@Composable
private fun CheckLine(title: String, on: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(role = Role.Checkbox, onClick = onClick), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(if (on) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked, null,
             tint = if (on) Forge.colors.accent else Forge.colors.textTertiary, modifier = Modifier.size(20.dp))
        Text(title, style = Forge.type.subhead, color = Forge.colors.text)
    }
}

@Composable
private fun SelectIcon(on: Boolean, enabled: Boolean = true, onClick: () -> Unit) {
    Icon(if (on) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked, null,
         tint = if (on) Forge.colors.accent else Forge.colors.textTertiary,
         modifier = Modifier.size(22.dp).alpha(if (enabled) 1f else 0.4f).clip(CircleShape)
             .clickable(enabled = enabled, role = Role.Checkbox, onClick = onClick))
}

@Composable
private fun WarningLine(text: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(Icons.Rounded.Warning, null, tint = Forge.colors.effort, modifier = Modifier.size(14.dp))
        Text(text, style = Forge.type.caption, color = Forge.colors.effort)
    }
}

@Composable
private fun Pill(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Text(label, style = Forge.type.caption, color = if (selected) Forge.colors.accent else Forge.colors.text,
         modifier = modifier.clip(RoundedCornerShape(10.dp))
             .background(if (selected) Forge.colors.accent.copy(alpha = 0.14f) else Forge.colors.inset)
             .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 10.dp, vertical = 8.dp))
}

/** A field that keeps what is typed and hands it on, so a slow answer never overwrites a newer keystroke. */
@Composable
private fun ReviewField(label: String, value: String, numeric: Boolean = false, onChange: (String) -> Unit) {
    var text by remember(label) { mutableStateOf(value) }
    OutlinedTextField(text, { text = it; onChange(it) }, Modifier.fillMaxWidth(), singleLine = true,
                      label = { Text(label) }, colors = noopFieldColors(),
                      keyboardOptions = if (numeric) KeyboardOptions(keyboardType = KeyboardType.Decimal) else KeyboardOptions.Default)
}

/** `CoachRoutineDraftEditor`: name, what it measures, the days, and the goals it supports. */
@Composable
private fun RoutineEditorDialog(
    routine: CoreCoachDrafts.ReviewRoutine, goals: List<CoreCoachDrafts.Choice>, l: Map<String, String>,
    onDismiss: () -> Unit, onSave: (JSONObject) -> Unit,
) {
    val e = routine.edit
    var title by remember { mutableStateOf(e.title) }
    var kind by remember { mutableStateOf(e.kind) }
    var steps by remember { mutableStateOf(e.steps) }
    var sports by remember { mutableStateOf(e.sports) }
    var minutes by remember { mutableStateOf(e.minutes) }
    var hasMinimum by remember { mutableStateOf(e.hasMinimum) }
    var daily by remember { mutableStateOf(e.daily) }
    var weekdays by remember { mutableStateOf(e.weekdays.toSet()) }
    var goalIds by remember { mutableStateOf(e.goalIds.toSet()) }
    // Sleep and energy routines stay what they are; the three types the editor offers are steps, workout and manual.
    val canSave = title.isNotBlank() && goalIds.isNotEmpty() && (daily || weekdays.isNotEmpty()) &&
        (kind != "workout" || sports.isNotBlank())
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(l["editRoutine"].orEmpty()) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(title, { title = it }, Modifier.fillMaxWidth(), label = { Text(l["name"].orEmpty()) },
                                  singleLine = true, colors = noopFieldColors())
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf("steps" to l["steps"], "workout" to l["workout"], "manual" to l["manual"]).forEach { (id, label) ->
                        Pill(label.orEmpty(), kind == id, Modifier.weight(1f)) { kind = id }
                    }
                }
                when (kind) {
                    "steps" -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("%,d".format(steps), style = Forge.type.subhead, modifier = Modifier.weight(1f))
                        Pill("−", false) { steps = (steps - 500).coerceAtLeast(1_000) }
                        Pill("+", false) { steps = (steps + 500).coerceAtMost(50_000) }
                    }
                    "workout" -> {
                        OutlinedTextField(sports, { sports = it }, Modifier.fillMaxWidth(), label = { Text(l["activities"].orEmpty()) },
                                          singleLine = true, colors = noopFieldColors())
                        ToggleLine(l["minimum"].orEmpty(), hasMinimum) { hasMinimum = it }
                        // The core's "%lld minutes", filled in here as the count moves.
                        val minutesText = l["minutes"].orEmpty().replace("%lld", minutes.toString())
                        if (hasMinimum) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(minutesText, style = Forge.type.subhead, modifier = Modifier.weight(1f))
                            Pill("−", false) { minutes = (minutes - 5).coerceAtLeast(5) }
                            Pill("+", false) { minutes = (minutes + 5).coerceAtMost(240) }
                        }
                    }
                }
                Text(l["schedule"].orEmpty().uppercase(), style = Forge.type.overline)
                ToggleLine(l["everyDay"].orEmpty(), daily) { daily = it }
                if (!daily) Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    (1..7).forEach { day ->
                        // 1 is Sunday, as `Calendar.shortStandaloneWeekdaySymbols` counts.
                        val name = DayOfWeek.of(if (day == 1) 7 else day - 1).getDisplayName(TextStyle.SHORT_STANDALONE, Locale.getDefault()).take(2)
                        Pill(name, day in weekdays, Modifier.weight(1f)) { weekdays = if (day in weekdays) weekdays - day else weekdays + day }
                    }
                }
                Text(l["supports"].orEmpty().uppercase(), style = Forge.type.overline)
                goals.forEach { g -> CheckLine(g.label, g.id in goalIds) { goalIds = if (g.id in goalIds) goalIds - g.id else goalIds + g.id } }
            }
        },
        confirmButton = {
            TextButton(enabled = canSave, onClick = {
                onSave(JSONObject().put("title", title).put("kind", kind).put("steps", steps).put("sports", sports)
                           .put("minutes", minutes).put("hasMinimum", hasMinimum).put("daily", daily)
                           .put("weekdays", JSONArray(weekdays.sorted())).put("goalIds", JSONArray(goalIds.toList())))
            }) { Text(l["save"].orEmpty()) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(l["cancel"].orEmpty()) } },
    )
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun GoalDatePicker(seconds: Double, onDismiss: () -> Unit, onPick: (Double) -> Unit) {
    val utc = java.time.ZoneOffset.UTC
    val zone = java.time.ZoneId.systemDefault()
    val initial = java.time.Instant.ofEpochSecond(seconds.toLong()).atZone(zone).toLocalDate()
    val state = androidx.compose.material3.rememberDatePickerState(
        initialSelectedDateMillis = initial.atStartOfDay(utc).toInstant().toEpochMilli())
    androidx.compose.material3.DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = {
                state.selectedDateMillis?.let {
                    val day = java.time.Instant.ofEpochMilli(it).atZone(utc).toLocalDate()
                    onPick(day.atTime(12, 0).atZone(zone).toEpochSecond().toDouble())
                }
            }) { Text(androidx.compose.ui.res.stringResource(android.R.string.ok)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(androidx.compose.ui.res.stringResource(android.R.string.cancel)) } },
    ) { androidx.compose.material3.DatePicker(state) }
}
