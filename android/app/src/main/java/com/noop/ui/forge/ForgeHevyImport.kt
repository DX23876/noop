package com.noop.ui.forge

import com.noop.ui.noopFieldColors

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import com.noop.R
import com.noop.core.CoreHevyImport
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** The API connection is explicit and default off. Local imported history survives disconnection. */
@Composable
internal fun ForgeHevyCard(onRoutines: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var loaded by remember { mutableStateOf(false) }
    var connected by remember { mutableStateOf(false) }
    var info by remember { mutableStateOf<CoreHevyImport.Info?>(null) }
    var draft by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<CoreHevyImport.Status?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmForget by remember { mutableStateOf(false) }
    suspend fun refresh() {
        withContext(Dispatchers.IO) {
            runCatching { connected = CoreHevyImport.connected(context); info = CoreHevyImport.info(context) }
                .onFailure { error = "credentialUnavailable" }
        }
    }
    LaunchedEffect(Unit) { refresh(); loaded = true }
    fun sync(key: String? = null) = scope.launch {
        busy = true; error = null; status = null
        try {
            if (key != null) {
                status = CoreHevyImport.Status(state = "running", phase = "verifying")
                error = withContext(Dispatchers.IO) { CoreHevyImport.connect(context, key) }
                if (error != null) return@launch
                connected = true
            }
            status = withContext(Dispatchers.IO) { CoreHevyImport.sync(context) { status = it } }
            error = status?.error
            refresh()
        } finally { busy = false }
    }
    ForgeCard(Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.forge_hevy_title), style = Forge.type.headline, color = Forge.colors.text)
        Spacer(Modifier.height(ForgeMetrics.space2))
        Text(stringResource(R.string.forge_hevy_detail), style = Forge.type.subhead, color = Forge.colors.textSecondary)
        TextButton(enabled = !busy, onClick = {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://hevy.com/settings?developer")))
        }) { Text(stringResource(R.string.forge_hevy_get_key)) }
        if (!loaded) CircularProgressIndicator() else if (!connected) {
            OutlinedTextField(draft, onValueChange = { if (it.length <= 4096) draft = it },
                label = { Text(stringResource(R.string.forge_hevy_key)) }, enabled = !busy, singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth(), colors = noopFieldColors())
            Button(enabled = !busy && draft.isNotBlank(), onClick = { val key = draft; draft = ""; sync(key) }) {
                Text(stringResource(R.string.forge_hevy_connect))
            }
        } else {
            Text(stringResource(R.string.forge_hevy_connected), style = Forge.type.subhead, color = Forge.colors.accent)
            if (!busy) {
                val s = status
                if (s?.state == "completed") Text(stringResource(R.string.forge_hevy_counts, s.stored, s.updated, s.deleted, s.skipped),
                    style = Forge.type.subhead, color = Forge.colors.textSecondary)
                else info?.let { Text(stringResource(R.string.forge_hevy_stored, it.stored), style = Forge.type.subhead, color = Forge.colors.textSecondary) }
                info?.takeIf { it.lastSync > 0 }?.let {
                    val date = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault()).format(Instant.ofEpochSecond(it.lastSync))
                    Text(stringResource(R.string.forge_hevy_last_sync, date), style = Forge.type.footnote, color = Forge.colors.textSecondary)
                }
            }
            Button(enabled = !busy, onClick = { sync() }) { Text(stringResource(R.string.forge_hevy_sync)) }
            TextButton(enabled = !busy, onClick = {
                scope.launch {
                    busy = true
                    val done = withContext(Dispatchers.IO) { CoreHevyImport.disconnect(context) }
                    if (done) { connected = false; status = null; error = null } else error = "credentialUnavailable"
                    busy = false
                }
            }) { Text(stringResource(R.string.forge_hevy_disconnect)) }
            TextButton(enabled = !busy, onClick = { confirmForget = true }) { Text(stringResource(R.string.forge_hevy_remove)) }
        }
        if (busy) {
            CircularProgressIndicator(Modifier.padding(ForgeMetrics.space2))
            HevyProgress(status)
            status?.takeIf { it.id.isNotBlank() }?.let { running ->
                TextButton(onClick = { scope.launch(Dispatchers.IO) { CoreHevyImport.cancel(running.id) } }) { Text(stringResource(R.string.forge_th_cancel)) }
            }
        }
        error?.let { Text(hevyError(it), style = Forge.type.subhead, color = Forge.colors.textSecondary) }
        TextButton(enabled = !busy && loaded, onClick = onRoutines) { Text(stringResource(R.string.forge_hevy_routines)) }
    }
    if (confirmForget) AlertDialog(onDismissRequest = { confirmForget = false },
        title = { Text(stringResource(R.string.forge_hevy_remove_title)) },
        text = { Text(stringResource(R.string.forge_hevy_remove_body)) },
        confirmButton = { TextButton(onClick = {
            confirmForget = false
            scope.launch {
                busy = true
                val done = withContext(Dispatchers.IO) { CoreHevyImport.disconnect(context, forget = true) }
                if (done) { connected = false; status = null; error = null; refresh() } else error = "storeUnavailable"
                busy = false
            }
        }) { Text(stringResource(R.string.forge_hevy_remove_confirm)) } },
        dismissButton = { TextButton(onClick = { confirmForget = false }) { Text(stringResource(R.string.forge_th_cancel)) } })
}

@Composable
private fun HevyProgress(status: CoreHevyImport.Status?) {
    val text = when (status?.phase) {
        "verifying" -> R.string.forge_hevy_verifying
        "catalogue" -> R.string.forge_hevy_catalogue
        "backfill" -> R.string.forge_hevy_history
        "incremental" -> R.string.forge_hevy_updates
        "routines" -> R.string.forge_hevy_loading_routines
        else -> R.string.forge_hevy_syncing
    }
    Text(stringResource(text), style = Forge.type.subhead, color = Forge.colors.textSecondary)
    if ((status?.totalPages ?: 0) > 1) Text(stringResource(R.string.forge_hevy_pages, status!!.page, status.totalPages),
        style = Forge.type.footnote, color = Forge.colors.textSecondary)
}

@Composable
private fun hevyError(code: String): String = stringResource(when (code) {
    "unauthorized" -> R.string.forge_hevy_bad_key
    "notPro" -> R.string.forge_hevy_not_pro
    "notConnected" -> R.string.forge_hevy_not_connected
    "rateLimited" -> R.string.forge_hevy_rate_limited
    "decode", "limitExceeded" -> R.string.forge_hevy_unreadable
    "credentialUnavailable" -> R.string.forge_hevy_credentials_failed
    "storeUnavailable", "coreUnavailable", "noStore" -> R.string.forge_hevy_store_failed
    "cancelled" -> R.string.forge_hevy_cancelled
    "busy" -> R.string.forge_hevy_syncing
    else -> R.string.forge_hevy_network_failed
})

/** Only selected reviewed routines are saved; cached routines remain available after disconnection. */
@Composable
internal fun ForgeHevyRoutines(onClose: () -> Unit, onConnect: (() -> Unit)? = null) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var connected by remember { mutableStateOf(false) }
    var preview by remember { mutableStateOf<CoreHevyImport.Preview?>(null) }
    var selected by remember { mutableStateOf<Set<String>>(emptySet()) }
    var loaded by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var remoteFailed by remember { mutableStateOf(false) }
    var saveFailed by remember { mutableStateOf(false) }
    var revision by remember { mutableIntStateOf(0) }
    var status by remember { mutableStateOf<CoreHevyImport.Status?>(null) }
    LaunchedEffect(revision) {
        loaded = false; failed = false; remoteFailed = false; saveFailed = false; preview = null
        withContext(Dispatchers.IO) {
            CoreRead.open(context)
            runCatching {
                connected = CoreHevyImport.connected(context)
                if (connected) {
                    status = CoreHevyImport.sync(context, routinesOnly = true) { status = it }
                    remoteFailed = status?.state != "completed"
                }
                preview = CoreHevyImport.preview(com.noop.ui.NoopPrefs.of(context).getInt("training.defaultRestSeconds", 120))
                selected = preview?.routines.orEmpty().map { it.id }.toSet()
                check(preview != null)
            }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it; failed = true }
        }
        loaded = true
    }
    BackHandler { if (!saving) onClose() }
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(ForgeMetrics.screenPadding), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        PageTitle(stringResource(R.string.forge_hevy_routines), onBack = { if (!saving) onClose() })
        ReportNote(stringResource(R.string.forge_hevy_routines_note))
        if (!loaded || saving) { CircularProgressIndicator(); HevyProgress(status) }
        if (failed || remoteFailed) {
            Text(stringResource(if (preview?.routines?.isNotEmpty() == true) R.string.forge_hevy_cached else R.string.forge_hevy_routines_failed),
                style = Forge.type.body, color = Forge.colors.textSecondary)
            TextButton(enabled = !saving, onClick = { revision++ }) { Text(stringResource(R.string.forge_hevy_retry)) }
        }
        if (saveFailed) Text(stringResource(R.string.forge_hevy_routine_save_failed), style = Forge.type.body, color = Forge.colors.textSecondary)
        if (loaded && !remoteFailed && preview?.routines?.isEmpty() == true) {
            Text(stringResource(if (connected) R.string.forge_hevy_routines_empty else R.string.forge_hevy_not_connected),
                style = Forge.type.body, color = Forge.colors.textSecondary)
            if (!connected && onConnect != null) Button(onClick = onConnect) { Text(stringResource(R.string.forge_hevy_connect)) }
        }
        preview?.let { p ->
            if (p.skipped > 0) Text(stringResource(R.string.forge_hevy_skipped_exercises, p.skipped), style = Forge.type.footnote, color = Forge.colors.textSecondary)
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                items(p.routines, key = { it.id }) { routine ->
                    ForgeCard(Modifier.fillMaxWidth()) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(checked = routine.id in selected, enabled = !saving,
                                onCheckedChange = { checked -> selected = if (checked) selected + routine.id else selected - routine.id })
                            Column(Modifier.weight(1f)) {
                                Text(routine.title, style = Forge.type.headline, color = Forge.colors.text)
                                Text(routine.exercises.joinToString(" · "), style = Forge.type.subhead, color = Forge.colors.textSecondary)
                            }
                        }
                    }
                }
            }
            Button(enabled = !saving && selected.isNotEmpty(), onClick = {
                scope.launch {
                    saving = true; saveFailed = false
                    val done = withContext(Dispatchers.IO) { CoreHevyImport.importRoutines(p, selected.toList()) }
                    saving = false
                    if (done) onClose() else saveFailed = true
                }
            }) { Text(stringResource(R.string.forge_hevy_import_selected)) }
        }
    }
}
