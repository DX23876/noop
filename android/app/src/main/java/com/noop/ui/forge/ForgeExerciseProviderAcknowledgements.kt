package com.noop.ui.forge

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.noop.R
import com.noop.core.CoreExerciseProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Provider credit is visible here without adding a second task to the exercise selection flow. */
@Composable
internal fun ForgeExerciseProviderAcknowledgements(onClose: () -> Unit) {
    val context = LocalContext.current
    var provider by remember { mutableStateOf<CoreExerciseProvider.Defaults?>(null) }
    LaunchedEffect(Unit) { provider = withContext(Dispatchers.IO) { CoreExerciseProvider.defaults() } }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_provider_acknowledgements), onClose)
        ForgeCard(Modifier.fillMaxWidth()) {
            provider?.let { source ->
                ReportHeading(source.attribution)
                ReportNote(stringResource(R.string.forge_provider_acknowledgements_detail))
                TextButton(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(source.documentation))) }) {
                    Text(stringResource(R.string.forge_provider_documentation))
                }
            } ?: ReportNote(stringResource(R.string.forge_library_unavailable))
        }
    }
}
