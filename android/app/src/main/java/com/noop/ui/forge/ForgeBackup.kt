package com.noop.ui.forge

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreBackup
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate

/** What the screen is telling the wearer after an export or import. */
private sealed interface Notice {
    /** An export or an import in progress; an import of a large store can take many minutes. */
    data class Working(val importing: Boolean = false) : Notice
    data object Exported : Notice
    data object Imported : Notice
    data object TooLarge : Notice
    data class Failed(val why: String) : Notice
}

private const val BACKUP_MIME = "application/octet-stream"
private const val BACKUP_NAME_PREFIX = "NOOP-Forge-"
private const val BACKUP_EXTENSION = ".noopbak"

/** Starts a `.noopbak` export or import of the core's store; the picker, the work and the dialogs follow. */
class BackupActions(val export: () -> Unit, val import: () -> Unit)

/**
 * Fork (DX23876), Android plan E-3e: `.noopbak` export and import of the core's store (the same format and checks
 * as the Apple apps) with the dialogs that report them, for More and for Settings, Data & Backup. The dialogs are
 * drawn where this is called.
 */
@Composable
fun rememberBackupActions(): BackupActions {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var notice by remember { mutableStateOf<Notice?>(null) }

    fun finish(result: CoreBackup.Result) {
        notice = when (result) {
            CoreBackup.Result.Done -> Notice.Exported
            CoreBackup.Result.Imported -> Notice.Imported
            is CoreBackup.Result.TooLarge -> Notice.TooLarge
            is CoreBackup.Result.Failed -> Notice.Failed(result.why)
        }
    }

    val exportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(BACKUP_MIME)) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        notice = Notice.Working()
        scope.launch {
            finish(withContext(Dispatchers.IO) {
                context.contentResolver.openOutputStream(uri)?.use { CoreBackup.export(context, it) }
                    ?: CoreBackup.Result.Failed("openOutput")
            })
        }
    }
    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        notice = Notice.Working(importing = true)
        scope.launch {
            finish(withContext(Dispatchers.IO) {
                context.contentResolver.openInputStream(uri)?.use { CoreBackup.import(context, it) }
                    ?: CoreBackup.Result.Failed("openInput")
            })
        }
    }

    notice?.let { current ->
        NoticeDialog(current, onDismiss = { notice = null },
                     onRestart = { ForgeUi.restart(context) },
                     onImportAnyway = {
                         notice = Notice.Working(importing = true)
                         scope.launch { finish(withContext(Dispatchers.IO) { CoreBackup.importStagedAnyway(context) }) }
                     })
    }
    return remember(exportLauncher, importLauncher) {
        BackupActions(export = { exportLauncher.launch(BACKUP_NAME_PREFIX + LocalDate.now() + BACKUP_EXTENSION) },
                      import = { importLauncher.launch(arrayOf("*/*")) })
    }
}

@Composable
private fun NoticeDialog(notice: Notice, onDismiss: () -> Unit, onRestart: () -> Unit, onImportAnyway: () -> Unit) {
    when (notice) {
        is Notice.Working -> AlertDialog(
            onDismissRequest = {}, confirmButton = {},
            text = {
                // A real iPhone store of 4 GB took about an hour to check and copy on an emulator (2026-10-26),
                // so an import says that it can take long instead of a bare "Working…".
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(24.dp))
                    Spacer(Modifier.width(ForgeMetrics.space4))
                    Text(stringResource(if (notice.importing) R.string.forge_backup_importing else R.string.forge_working))
                }
            })
        Notice.Exported -> AlertDialog(
            onDismissRequest = onDismiss, text = { Text(stringResource(R.string.forge_backup_exported)) },
            confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(android.R.string.ok)) } })
        Notice.Imported -> AlertDialog(
            onDismissRequest = {}, title = { Text(stringResource(R.string.forge_backup_imported_title)) },
            text = { Text(stringResource(R.string.forge_backup_imported_body)) },
            confirmButton = { TextButton(onClick = onRestart) { Text(stringResource(R.string.forge_backup_restart)) } })
        Notice.TooLarge -> AlertDialog(
            onDismissRequest = onDismiss, text = { Text(stringResource(R.string.forge_backup_too_large)) },
            confirmButton = { TextButton(onClick = onImportAnyway) { Text(stringResource(R.string.forge_backup_import_anyway)) } },
            dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.forge_cancel)) } })
        is Notice.Failed -> AlertDialog(
            onDismissRequest = onDismiss, text = { Text(failureText(notice.why)) },
            confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(android.R.string.ok)) } })
    }
}

/** The wearer-facing reason for a failed export or import; the core's code only where no plain sentence fits. */
@Composable
private fun failureText(why: String): String = when {
    why == "notSQLite" || why == "noDatabaseEntry" || why.startsWith("archiveUnreadable") ->
        stringResource(R.string.forge_backup_not_backup)
    why == "foreignBackup" -> stringResource(R.string.forge_backup_foreign)
    why == "damaged" || why.startsWith("postRestore") -> stringResource(R.string.forge_backup_damaged)
    why.startsWith("copyFailedKept") -> stringResource(R.string.forge_backup_not_written)
    else -> stringResource(R.string.forge_backup_failed, why)
}
