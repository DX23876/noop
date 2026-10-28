package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreCoach
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The coach's memory, as the iOS Memory page (`CoachSettingsView.memorySubpage`): every fact with its category and
 * where it came from, a way to add one, and per fact Edit, Expire today (or Remove expiry) and Delete; Forget
 * everything asks first. The facts live in the shared coach (`CoachMemory`).
 */
@Composable
fun CoachMemoryPage() {
    val scope = rememberCoroutineScope()
    var memory by remember { mutableStateOf<CoreCoach.Memory?>(null) }
    fun run(op: String? = null, id: String? = null, text: String? = null, category: String? = null) {
        scope.launch { withContext(Dispatchers.IO) { CoreCoach.memory(op, id, text, category) }?.let { memory = it } }
    }
    LaunchedEffect(Unit) { run() }
    var draft by remember { mutableStateOf("") }
    var category by remember { mutableStateOf("other") }
    var editing by remember { mutableStateOf<CoreCoach.Fact?>(null) }
    var editText by remember { mutableStateOf("") }
    var confirmForget by remember { mutableStateOf(false) }
    val m = memory

    ScreenScaffold(title = stringResource(R.string.coach_memory)) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Overline(stringResource(R.string.coach_memory_add))
                    OutlinedTextField(value = draft, onValueChange = { draft = it }, modifier = Modifier.fillMaxWidth(),
                                      colors = noopFieldColors(), shape = RoundedCornerShape(14.dp))
                    var menu by remember { mutableStateOf(false) }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(m?.categories?.firstOrNull { it.id == category }?.label ?: category, style = NoopType.subhead,
                             color = Palette.accent,
                             modifier = Modifier.clip(RoundedCornerShape(50)).clickable { menu = true }.padding(vertical = 6.dp))
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            m?.categories?.forEach { c ->
                                DropdownMenuItem(text = { Text(c.label) }, onClick = { category = c.id; menu = false })
                            }
                        }
                        androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
                        TextButton(enabled = draft.isNotBlank(), onClick = { run("add", text = draft, category = category); draft = "" }) {
                            Text(stringResource(R.string.coach_memory_add_action))
                        }
                    }
                }
            }
            if (m != null && m.facts.isEmpty()) {
                Text(stringResource(R.string.coach_memory_empty), style = NoopType.subhead, color = Palette.textSecondary)
            }
            m?.facts?.forEach { f -> FactRow(f, onEdit = { editing = f; editText = f.text },
                onExpire = { run(if (f.expires != null) "unexpire" else "expire", id = f.id) }, onDelete = { run("remove", id = f.id) }) }
            if (m != null && m.facts.isNotEmpty()) {
                TextButton(onClick = { confirmForget = true }) {
                    Text(stringResource(R.string.coach_memory_forget_all), color = Palette.statusCritical)
                }
            }
        }
    }
    editing?.let { f ->
        AlertDialog(
            onDismissRequest = { editing = null },
            title = { Text(stringResource(R.string.coach_memory_edit)) },
            text = { OutlinedTextField(value = editText, onValueChange = { editText = it }, colors = noopFieldColors()) },
            confirmButton = { TextButton(onClick = { run("update", id = f.id, text = editText); editing = null }) {
                Text(stringResource(R.string.coach_memory_save)) } },
            dismissButton = { TextButton(onClick = { editing = null }) { Text(stringResource(R.string.l10n_coach_screen_cancel_77dfd213)) } },
        )
    }
    if (confirmForget) {
        AlertDialog(
            onDismissRequest = { confirmForget = false },
            title = { Text(stringResource(R.string.coach_memory_forget_all_title)) },
            text = { Text(stringResource(R.string.coach_memory_forget_all_body)) },
            confirmButton = { TextButton(onClick = { run("clear"); confirmForget = false }) {
                Text(stringResource(R.string.coach_memory_forget_all), color = Palette.statusCritical) } },
            dismissButton = { TextButton(onClick = { confirmForget = false }) { Text(stringResource(R.string.l10n_coach_screen_cancel_77dfd213)) } },
        )
    }
}

@Composable
private fun FactRow(f: CoreCoach.Fact, onEdit: () -> Unit, onExpire: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(Modifier.fillMaxWidth().clickable { menu = true }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(f.text, style = NoopType.body, color = if (f.active) Palette.textPrimary else Palette.textTertiary)
            Text("${f.categoryLabel} · ${f.source}", style = NoopType.caption, color = Palette.textTertiary)
            if (!f.active) {
                Text(stringResource(R.string.coach_memory_expired), style = NoopType.caption, color = Palette.textTertiary,
                     modifier = Modifier.clip(RoundedCornerShape(50)).background(Palette.surfaceInset).padding(horizontal = 8.dp, vertical = 2.dp))
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text(stringResource(R.string.coach_memory_edit)) }, onClick = { menu = false; onEdit() })
                DropdownMenuItem(
                    text = { Text(stringResource(if (f.expires != null) R.string.coach_memory_unexpire else R.string.coach_memory_expire)) },
                    onClick = { menu = false; onExpire() })
                DropdownMenuItem(text = { Text(stringResource(R.string.coach_memory_delete), color = Palette.statusCritical) },
                                 onClick = { menu = false; onDelete() })
            }
        }
    }
}
