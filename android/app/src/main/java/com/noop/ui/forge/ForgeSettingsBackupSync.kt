package com.noop.ui.forge

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.text.format.DateUtils
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.data.DataBackup
import com.noop.ui.BackupSync
import com.noop.ui.BackupSyncPrefs
import com.noop.ui.uiString
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Settings subpages, wave 2: Backup & Sync (iOS `BackupSyncView`, Forge body) in the Forge look. The state and every call
// are the classic `BackupSyncScreen`'s (the SAF folder, `BackupSyncPrefs`, `BackupSync`, `DataBackup`); only the chrome is
// the shared Settings blocks. Android keeps "Backup time" (A-17) and its SAF folder tip; the iOS "NOOP's own folder
// (Files)" and "Move to iCloud Drive" rows are PLATFORM and have no row here.

/** Retention choices of the "Keep last snapshots" menu, as the classic screen offers them. */
private val KEEP_OPTIONS = listOf(1, 3, 5, 7, 10, 14)

/** The restore file picker is held to the backup container types, never the all-files wildcard. */
private val RESTORE_MIME_TYPES = arrayOf("application/octet-stream", "application/zip", "application/x-sqlite3")

@Composable
internal fun BackupSyncSettingsPage(onBack: () -> Unit) {
    SettingsColumn {
        PageTitle(stringResource(R.string.l10n_settings_screen_automatic_backups_8a772f3c), onBack)
        Text(stringResource(R.string.fsw2_bk_blurb), style = Forge.type.subhead, color = Forge.sceneInk.secondary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        BackupSyncSettings()
    }
}

@Composable
private fun BackupSyncSettings() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val colors = Forge.colors

    var treeUri by remember { mutableStateOf(BackupSyncPrefs.treeUri(context)) }
    var auto by remember { mutableStateOf(BackupSyncPrefs.autoEnabled(context)) }
    var lastMs by remember { mutableStateOf(BackupSyncPrefs.lastBackupMs(context)) }
    var busy by remember { mutableStateOf(false) }
    var backupFailure by remember { mutableStateOf<String?>(null) }
    var keep by remember { mutableStateOf(BackupSyncPrefs.keepCount(context)) }
    var keepMenu by remember { mutableStateOf(false) }
    var backupMinute by remember { mutableStateOf(BackupSyncPrefs.backupMinute(context)) }
    var snapshots by remember { mutableStateOf<List<BackupSync.SnapshotDoc>>(emptyList()) }
    var showSnapshotPicker by remember { mutableStateOf(false) }
    var pendingRestore by remember { mutableStateOf<Pair<String, Uri>?>(null) }

    fun runRestore(uri: Uri) {
        busy = true
        scope.launch {
            // Cleared in a `finally` so it clears on any exit; the NeedsRestart branch exits the process first, which is
            // wanted: the page stays disabled through the restart instead of taking taps against a swapped database.
            try {
                when (val r = withContext(Dispatchers.IO) { DataBackup.importFrom(context, uri) }) {
                    is DataBackup.ImportResult.NeedsRestart -> {
                        // #57: the restore closed and swapped the database file, so the process is relaunched to
                        // re-open it. NonCancellable: leaving the page must not cancel the restart.
                        Toast.makeText(context, uiString(R.string.fsw2_bk_restored), Toast.LENGTH_LONG).show()
                        withContext(NonCancellable) {
                            delay(800)
                            val ctx = context.applicationContext
                            ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
                                ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                                ?.let { ctx.startActivity(it) }
                            Runtime.getRuntime().exit(0)
                        }
                    }
                    is DataBackup.ImportResult.Failed -> backupFailure = r.message
                    is DataBackup.ImportResult.TooLarge -> backupFailure = r.message
                }
            } finally {
                busy = false
            }
        }
    }

    val pickFolder = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        runCatching {
            context.contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
        BackupSyncPrefs.setTreeUri(context, uri)
        treeUri = uri
        runCatching { BackupSync.reschedule(context) }
    }
    val pickRestoreFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        pendingRestore = uiString(R.string.fsw2_bk_selected_file) to uri
    }
    val hasFolder = treeUri != null

    // Where it goes.
    SettingsCard(title = stringResource(R.string.l10n_backup_sync_screen_backup_folder_2a33df93), blurb = null) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Text(treeUri?.let { stringResource(R.string.fsw2_bk_saving_to, folderLabel(context, it)) }
                     ?: stringResource(R.string.fsw2_bk_no_folder),
                 style = Forge.type.footnote, color = colors.textSecondary)
            Text(stringResource(R.string.l10n_backup_sync_screen_tip_a_desktop_drive_dropbox_app_2eaff1e3),
                 style = Forge.type.caption, color = colors.accent)
            // #644: the snapshots are a plain, unencrypted ZIP; a cloud sync app uploads that readable file. Said before
            // anyone turns auto-backup on.
            Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                Icon(Icons.Rounded.WarningAmber, contentDescription = null, tint = warning(), modifier = Modifier.size(16.dp))
                Text(stringResource(R.string.l10n_backup_sync_screen_these_backups_are_unencrypted_too_if_53e70fe8),
                     style = Forge.type.caption, color = warning(), modifier = Modifier.weight(1f))
            }
        }
        RowDivider()
        Gated(!busy) {
            LinkRow(stringResource(if (hasFolder) R.string.cx_change_folder else R.string.cx_choose_folder), null) {
                pickFolder.launch(null)
            }
        }
    }

    // What happens by itself.
    SettingsCard(title = stringResource(R.string.fsw2_bk_automatic), blurb = null, active = auto && hasFolder) {
        ToggleRow(stringResource(R.string.l10n_backup_sync_screen_daily_auto_backup_e5627357),
                  stringResource(R.string.l10n_backup_sync_screen_writes_a_fresh_dated_backup_to_bd964fc5, keep),
                  auto, enabled = hasFolder && !busy) {
            auto = it
            BackupSyncPrefs.setAutoEnabled(context, it)
            runCatching { BackupSync.reschedule(context) }
        }
        RowDivider()
        Column {
            Gated(hasFolder && !busy) {
                SettingRow(stringResource(R.string.l10n_backup_sync_screen_keep_last_snapshots_cd5c9ea9)) {
                    Box {
                        Text(keep.toString(), style = Forge.type.bodyNumber, color = colors.accent,
                             modifier = Modifier.background(colors.inset, RoundedCornerShape(8.dp))
                                 .clickable(role = Role.Button) { keepMenu = true }
                                 .padding(horizontal = 12.dp, vertical = 8.dp))
                        DropdownMenu(expanded = keepMenu, onDismissRequest = { keepMenu = false }) {
                            KEEP_OPTIONS.forEach { n ->
                                DropdownMenuItem(
                                    text = { Text(n.toString(), style = Forge.type.body, color = if (n == keep) colors.accent else colors.text) },
                                    onClick = {
                                        keep = n
                                        BackupSyncPrefs.setKeepCount(context, n)
                                        keepMenu = false
                                    },
                                )
                            }
                        }
                    }
                }
            }
            Text(stringResource(R.string.l10n_backup_sync_screen_older_backups_beyond_this_many_are_00b7daa6),
                 style = Forge.type.footnote, color = colors.textSecondary)
        }
        RowDivider()
        Column {
            SettingRow(stringResource(R.string.l10n_backup_sync_screen_backup_time_81557aaa)) {
                // Picking a time re-anchors the schedule at once (BackupSync.applyTimeChange); WorkManager is best-effort.
                TimeChip(backupMinute, stringResource(R.string.fsw2_bk_time_a11y)) { m ->
                    backupMinute = m
                    BackupSyncPrefs.setBackupMinute(context, m)
                    runCatching { BackupSync.applyTimeChange(context) }
                }
            }
            Text(stringResource(R.string.l10n_backup_sync_screen_roughly_when_the_daily_backup_runs_71de04e1),
                 style = Forge.type.footnote, color = colors.textSecondary)
        }
        RowDivider()
        Text(if (lastMs > 0L) stringResource(R.string.fsw2_bk_last, DateUtils.getRelativeTimeSpanString(lastMs).toString())
             else stringResource(R.string.cx_backup_none_yet),
             style = Forge.type.caption, color = colors.textSecondary)
        // Auto is on but the last successful backup is stale: the daily catch-up is not landing (a lost folder grant, or
        // the app unopened for a while). Surfaced here rather than discovered at restore.
        if (auto && hasFolder && lastMs > 0L && BackupSync.isBackupStale(lastMs, System.currentTimeMillis())) {
            Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                Icon(Icons.Rounded.WarningAmber, contentDescription = null, tint = warning(), modifier = Modifier.size(16.dp))
                Text(stringResource(R.string.l10n_backup_sync_screen_auto_backup_hasn_t_run_in_e3cd484e),
                     style = Forge.type.caption, color = warning(), modifier = Modifier.weight(1f))
            }
        }
    }

    // By hand.
    SettingsCard(title = null, blurb = null) {
        Gated(hasFolder && !busy) {
            LinkRow(stringResource(if (busy) R.string.cx_working else R.string.cx_back_up_now), null, busy = busy) {
                busy = true
                scope.launch {
                    // Cleared in a `finally`: the page stays disabled until the work has genuinely finished.
                    try {
                        val ok = withContext(Dispatchers.IO) { BackupSync.backupNow(context) }
                        lastMs = BackupSyncPrefs.lastBackupMs(context)
                        Toast.makeText(context, uiString(if (ok) R.string.fsw2_bk_done else R.string.fsw2_bk_failed), Toast.LENGTH_LONG).show()
                    } finally {
                        busy = false
                    }
                }
            }
        }
    }

    // Restore stands apart, last.
    SettingsCard(title = stringResource(R.string.l10n_backup_sync_screen_restore_3cbe6d6b),
                 blurb = stringResource(R.string.l10n_backup_sync_screen_replace_this_device_s_data_with_b8679c51)) {
        Gated(!busy) {
            LinkRow(stringResource(R.string.l10n_backup_sync_screen_restore_from_a_backup_c28917c6), null) {
                val tree = treeUri
                if (tree == null) {
                    pickRestoreFile.launch(RESTORE_MIME_TYPES)
                } else {
                    scope.launch {
                        val found = withContext(Dispatchers.IO) {
                            runCatching { BackupSync.listSnapshotDocs(context, tree) }.getOrDefault(emptyList())
                        }
                        if (found.isEmpty()) {
                            // The folder holds no snapshot we wrote: point at a file instead.
                            pickRestoreFile.launch(RESTORE_MIME_TYPES)
                        } else {
                            snapshots = found
                            showSnapshotPicker = true
                        }
                    }
                }
            }
        }
    }

    // The folder's backups, newest first.
    if (showSnapshotPicker) {
        AlertDialog(
            onDismissRequest = { showSnapshotPicker = false },
            containerColor = Forge.colors.surface,
            title = { Text(stringResource(R.string.l10n_backup_sync_screen_choose_a_backup_2fbfb0d6), style = Forge.type.title2, color = colors.text) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(stringResource(R.string.l10n_backup_sync_screen_newest_first_restoring_replaces_this_device_97dbcd8b),
                         style = Forge.type.footnote, color = colors.textSecondary)
                    snapshots.forEach { snap ->
                        // A hand-named backup with no resolved date shows its name, not 1 Jan 1970.
                        val whenLabel = if (snap.timeMs > 0L) DateUtils.getRelativeTimeSpanString(snap.timeMs).toString() else snap.name
                        Text(whenLabel, style = Forge.type.body, color = colors.text,
                             modifier = Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
                                 .clickable {
                                     showSnapshotPicker = false
                                     pendingRestore = (if (snap.timeMs > 0L) uiString(R.string.fsw2_bk_from_date, whenLabel) else snap.name) to snap.uri
                                 }
                                 .padding(vertical = 10.dp))
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showSnapshotPicker = false }) {
                    Text(stringResource(R.string.l10n_backup_sync_screen_cancel_77dfd213), color = colors.textSecondary)
                }
            },
        )
    }

    // An explicit confirm before any destructive restore, on every path.
    pendingRestore?.let { (label, uri) ->
        AlertDialog(
            onDismissRequest = { pendingRestore = null },
            containerColor = Forge.colors.surface,
            title = { Text(stringResource(R.string.l10n_backup_sync_screen_replace_all_current_data_e9244799), style = Forge.type.title2, color = colors.text) },
            text = {
                Text(stringResource(R.string.l10n_backup_sync_screen_replace_all_current_data_with_label_b7799a16, label),
                     style = Forge.type.subhead, color = colors.textSecondary)
            },
            confirmButton = {
                TextButton(onClick = { pendingRestore = null; runRestore(uri) }) {
                    Text(stringResource(R.string.l10n_backup_sync_screen_replace_a7cf7b25),
                         color = ForgeTokens.StrandPalette.statusCritical.resolve())
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingRestore = null }) {
                    Text(stringResource(R.string.l10n_backup_sync_screen_cancel_77dfd213), color = colors.textSecondary)
                }
            },
        )
    }

    // #1014 family: a failure carries its next step in its last clause, which a toast drops, so it is held in a dialog.
    backupFailure?.let { failure ->
        AlertDialog(
            onDismissRequest = { backupFailure = null },
            containerColor = Forge.colors.surface,
            text = { Text(failure, style = Forge.type.subhead, color = colors.textSecondary) },
            confirmButton = {
                TextButton(onClick = { backupFailure = null }) {
                    Text(stringResource(R.string.l10n_components_close_bbfa773e), color = colors.accent)
                }
            },
            dismissButton = {
                TextButton(onClick = {
                    val clip = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                    clip?.setPrimaryClip(ClipData.newPlainText("NOOP backup error", failure))
                    backupFailure = null
                }) { Text(stringResource(R.string.l10n_components_copy_af74f7c5), color = colors.textSecondary) }
            },
        )
    }
}

/** A control that is dimmed and ignores taps while [enabled] is false, as a disabled SwiftUI row is. */
@Composable
private fun Gated(enabled: Boolean, content: @Composable () -> Unit) {
    Box(Modifier.alpha(if (enabled) 1f else 0.45f)) {
        content()
        // Swallows taps over the dimmed control; the rows themselves have no `enabled` of their own.
        if (!enabled) Box(Modifier.matchParentSize().clickable(enabled = true, onClick = {}))
    }
}

@Composable
private fun warning() = ForgeTokens.StrandPalette.statusWarningForeground.resolve()

/** A short, human label for a SAF tree Uri: the part after the volume colon. */
private fun folderLabel(context: Context, treeUri: Uri): String {
    val seg = treeUri.lastPathSegment ?: return uiString(R.string.fsw2_bk_selected_folder)
    return seg.substringAfterLast(':').ifBlank { seg }
}
