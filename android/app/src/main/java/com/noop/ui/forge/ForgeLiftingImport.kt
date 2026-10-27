package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.noop.R
import com.noop.core.CoreLiftingImport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The file remains on the device; imported transcripts can be opened from Training history. */
@Composable
fun ForgeLiftingImport(onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<CoreLiftingImport.Result?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            busy = true
            result = null
            result = withContext(Dispatchers.IO) { CoreLiftingImport.read(context, uri) }
            busy = false
        }
    }
    BackHandler { if (!busy) onClose() }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_lifting_title), onBack = { if (!busy) onClose() })
        ReportNote(stringResource(R.string.forge_lifting_detail))
        ForgeCard(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.forge_lifting_privacy), style = Forge.type.body, color = Forge.colors.textSecondary)
            Spacer(Modifier.height(ForgeMetrics.space3))
            Button(enabled = !busy, onClick = { picker.launch(arrayOf("text/*", "application/json", "application/octet-stream")) }) {
                Text(stringResource(R.string.forge_lifting_choose))
            }
            if (busy) CircularProgressIndicator(Modifier.padding(ForgeMetrics.space3))
            result?.let { outcome ->
                Spacer(Modifier.height(ForgeMetrics.space3))
                Text(if (outcome.error == null) stringResource(R.string.forge_lifting_success, outcome.sessions, outcome.skipped)
                     else stringResource(R.string.forge_lifting_failed),
                     style = Forge.type.body, color = Forge.colors.text)
            }
        }
    }
}
