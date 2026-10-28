package com.noop.ui.forge

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.noop.R
import com.noop.core.CoreTrainingReminders
import com.noop.notif.SessionRatingReminderWorker
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The same notification choice as Apple; deliberate ratings remain available with reminders off. */
@Composable
internal fun ForgeSessionRatingPreferences(onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var selected by remember { mutableStateOf(CoreTrainingReminders.prompt(context)) }
    val ids = listOf("off", "whenUseful", "always")
    val labels = listOf(stringResource(R.string.forge_rating_reminder_off),
        stringResource(R.string.forge_rating_reminder_useful), stringResource(R.string.forge_rating_reminder_always))
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_rating_reminder_channel), onClose)
        ForgeCard(Modifier.fillMaxWidth()) {
            ReportNote(stringResource(R.string.forge_rating_reminder_policy))
            ReportPicker(labels[ids.indexOf(selected).coerceAtLeast(0)], labels) { index ->
                selected = ids[index]
                NoopPrefs.of(context).edit().putString(CoreTrainingReminders.PREFERENCE, selected).apply()
                scope.launch { withContext(Dispatchers.IO) { SessionRatingReminderWorker.synchronize(context) } }
            }
        }
    }
}
