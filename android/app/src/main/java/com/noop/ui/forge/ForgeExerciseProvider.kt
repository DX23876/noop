package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import com.noop.R
import com.noop.core.CoreExerciseProvider
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** One explicit metadata request and review; loading alone never inserts a definition or fetches media. */
@Composable
fun ForgeExerciseProviderPage(onClose: () -> Unit, onImported: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var endpoint by remember { mutableStateOf("") }
    var header by remember { mutableStateOf("") }
    var key by remember { mutableStateOf("") }
    var storedKey by remember { mutableStateOf(false) }
    var initialized by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var preview by remember { mutableStateOf<CoreExerciseProvider.Preview?>(null) }
    var selected by remember { mutableStateOf<Set<String>>(emptySet()) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        val initial = withContext(Dispatchers.IO) { CoreExerciseProvider.defaults() to CoreExerciseProvider.hasKey(context) }
        initial.first?.let { defaults ->
            endpoint = NoopPrefs.of(context).getString(CoreExerciseProvider.ENDPOINT, defaults.endpoint) ?: defaults.endpoint
            header = NoopPrefs.of(context).getString(CoreExerciseProvider.HEADER, defaults.header) ?: defaults.header
        }
        storedKey = initial.second; initialized = initial.first != null
        if (!initialized) error = "coreUnavailable"
    }
    DisposableEffect(Unit) { onDispose { CoreExerciseProvider.invalidate() } }
    fun invalidateReview() { preview = null; selected = emptySet(); error = null }
    fun load() = scope.launch {
        val requestedEndpoint = endpoint; val requestedHeader = header; val requestedKey = key
        loading = true; invalidateReview()
        val response = withContext(Dispatchers.IO) { CoreExerciseProvider.load(context, requestedEndpoint, requestedHeader, requestedKey) }
        storedKey = withContext(Dispatchers.IO) { CoreExerciseProvider.hasKey(context) }
        preview = response.preview
        selected = response.preview?.exercises?.map { it.id }?.toSet().orEmpty()
        error = response.error; loading = false
    }
    val close = { if (!saving) onClose() }
    BackHandler(onBack = close)
    LazyColumn(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding(),
        contentPadding = PaddingValues(ForgeMetrics.screenPadding), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        item { PageTitle(stringResource(R.string.forge_provider_title), close) }
        item { ForgeCard(Modifier.fillMaxWidth()) {
            ReportNote(stringResource(R.string.forge_provider_detail))
            OutlinedTextField(endpoint, { endpoint = it; invalidateReview() }, label = { Text(stringResource(R.string.forge_provider_endpoint)) },
                enabled = initialized && !loading && !saving, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth())
            OutlinedTextField(header, { header = it; invalidateReview() }, label = { Text(stringResource(R.string.forge_provider_header)) },
                enabled = initialized && !loading && !saving, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(key, { key = it.take(4096); invalidateReview() },
                label = { Text(stringResource(if (storedKey) R.string.forge_provider_replace_key else R.string.forge_provider_key)) },
                enabled = initialized && !loading && !saving, singleLine = true, visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth())
            if (storedKey) TextButton(enabled = !loading && !saving, onClick = {
                scope.launch {
                    invalidateReview()
                    if (withContext(Dispatchers.IO) { CoreExerciseProvider.forgetKey(context) }) { key = ""; storedKey = false }
                    else error = "credentialUnavailable"
                }
            }) { Text(stringResource(R.string.forge_provider_remove_key)) }
            TextButton(enabled = initialized && !loading && !saving, onClick = { load() }) { Text(stringResource(R.string.forge_provider_load)) }
            if (loading || saving) LinearProgressIndicator(Modifier.fillMaxWidth())
        } }
        error?.let { code -> item { ReportNote(stringResource(when (code) {
            "credentialUnavailable" -> R.string.forge_provider_credentials_failed
            "limitExceeded" -> R.string.forge_provider_too_large
            "saveFailed" -> R.string.forge_provider_save_failed
            "invalidEndpoint" -> R.string.forge_provider_invalid_endpoint
            "coreUnavailable" -> R.string.forge_library_unavailable
            else -> R.string.forge_provider_failed
        })) } }
        val review = preview
        if (review != null) {
            item { ForgeCard(Modifier.fillMaxWidth()) {
                ReportHeading(stringResource(R.string.forge_provider_preview))
                ReportNote(stringResource(R.string.forge_provider_selected_only))
                TextButton(enabled = !saving, onClick = {
                    selected = if (selected.size == review.exercises.size) emptySet() else review.exercises.map { it.id }.toSet()
                }) { Text(stringResource(if (selected.size == review.exercises.size) R.string.forge_provider_clear_selection else R.string.forge_provider_select_all)) }
                TextButton(enabled = !saving && selected.isNotEmpty(), onClick = {
                    scope.launch {
                        val chosen = selected.toList()
                        saving = true
                        val ok = withContext(Dispatchers.IO) { CoreExerciseProvider.accept(review, chosen) }
                        saving = false
                        if (ok) onImported() else { invalidateReview(); error = "saveFailed" }
                    }
                }) { Text(stringResource(R.string.forge_provider_add_selected)) }
            } }
            items(review.exercises, key = { it.id }) { exercise ->
                ForgeCard(Modifier.fillMaxWidth()) {
                    Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
                        .toggleable(exercise.id in selected, enabled = !saving, role = Role.Checkbox) { checked ->
                            selected = if (checked) selected + exercise.id else selected - exercise.id
                        }, verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(exercise.id in selected, onCheckedChange = null)
                        Column(Modifier.weight(1f)) {
                            ReportHeading(exercise.title)
                            ReportNote(exercise.primary?.let { muscleName(it) } ?: stringResource(R.string.forge_session_unmapped))
                            ReportNote(measurementName(exercise.mode))
                        }
                    }
                }
            }
        }
        item { Spacer(Modifier.height(ForgeMetrics.tabBarClearance)) }
    }
}
