package com.noop.ui.forge

import android.text.format.DateUtils
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.IosShare
import androidx.compose.material.icons.rounded.Upload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.noop.BuildConfig
import com.noop.R
import com.noop.core.CoreBackup
import com.noop.ui.AddDeviceWizard
import com.noop.ui.AppViewModel
import com.noop.ui.LogExport
import com.noop.ui.Palette
import com.noop.ui.StrapLogBuffer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import kotlin.math.roundToInt

/** What the More screen is telling the wearer after an export or import. */
private sealed interface Notice {
    data object Working : Notice
    data object Exported : Notice
    data object Imported : Notice
    data object TooLarge : Notice
    data class Failed(val why: String) : Notice
}

private const val BACKUP_MIME = "application/octet-stream"
private const val BACKUP_NAME_PREFIX = "NOOP-Forge-"
private const val BACKUP_EXTENSION = ".noopbak"

/**
 * Fork (DX23876), Android plan E-3e/E-3f: the More tab. The strap (link state, battery, last sync, connect and
 * pairing through the app's view model), `.noopbak` export and import of the core's store (the same format
 * and checks as the Apple apps), sharing the strap log for a bug report, the version and the way back to the
 * classic screens for what the Forge screens do not cover yet.
 */
@Composable
fun ForgeMoreScreen(padding: PaddingValues, viewModel: AppViewModel) {
    val context = LocalContext.current
    var pairing by remember { mutableStateOf(false) }
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
        notice = Notice.Working
        scope.launch {
            finish(withContext(Dispatchers.IO) {
                context.contentResolver.openOutputStream(uri)?.use { CoreBackup.export(context, it) }
                    ?: CoreBackup.Result.Failed("openOutput")
            })
        }
    }
    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        notice = Notice.Working
        scope.launch {
            finish(withContext(Dispatchers.IO) {
                context.contentResolver.openInputStream(uri)?.use { CoreBackup.import(context, it) }
                    ?: CoreBackup.Result.Failed("openInput")
            })
        }
    }

    val colors = Forge.colors
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding)
            .padding(horizontal = ForgeMetrics.screenPadding),
        verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap),
    ) {
        Text(stringResource(R.string.nav_more), style = Forge.type.title1, color = colors.text,
             modifier = Modifier.padding(top = ForgeMetrics.space4, bottom = ForgeMetrics.space2))

        SectionHeader(stringResource(R.string.forge_strap_section))
        StrapCard(viewModel, onPair = { pairing = true })

        SectionHeader(stringResource(R.string.forge_backup_section))
        ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
            MoreRow(Icons.Rounded.Upload, colors.accent, stringResource(R.string.forge_backup_export),
                    stringResource(R.string.forge_backup_export_detail)) {
                exportLauncher.launch(BACKUP_NAME_PREFIX + LocalDate.now() + BACKUP_EXTENSION)
            }
            HorizontalDivider(color = colors.divider.copy(alpha = 0.4f), modifier = Modifier.padding(start = 56.dp))
            MoreRow(Icons.Rounded.Download, colors.rest, stringResource(R.string.forge_backup_import),
                    stringResource(R.string.forge_backup_import_detail)) {
                importLauncher.launch(arrayOf("*/*"))
            }
        }

        SectionHeader(stringResource(R.string.forge_strap_log_section))
        ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
            MoreRow(Icons.Rounded.IosShare, colors.effort, stringResource(R.string.forge_strap_log_share),
                    stringResource(R.string.forge_strap_log_detail)) {
                scope.launch { LogExport.shareStrapLog(context, StrapLogBuffer.snapshot()) }
            }
        }

        SectionHeader(stringResource(R.string.forge_about_section))
        ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
            MoreRow(Icons.Rounded.History, colors.textSecondary, stringResource(R.string.forge_classic_screens),
                    stringResource(R.string.forge_classic_screens_detail)) {
                ForgeUi.setEnabled(context, false)
                ForgeUi.restart(context)
            }
        }
        Text(stringResource(R.string.forge_version, BuildConfig.VERSION_NAME), style = Forge.type.caption,
             color = colors.textTertiary, modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        Text(stringResource(R.string.forge_privacy), style = Forge.type.caption, color = colors.textTertiary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        Spacer(Modifier.height(ForgeMetrics.space2))
    }

    if (pairing) {
        // Pairing keeps the classic wizard until its Forge version exists; it runs on the same view model.
        Dialog(onDismissRequest = { pairing = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Surface(Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                AddDeviceWizard(viewModel = viewModel, onClose = { pairing = false })
            }
        }
    }

    notice?.let { current ->
        NoticeDialog(current, onDismiss = { notice = null },
                     onRestart = { ForgeUi.restart(context) },
                     onImportAnyway = {
                         notice = Notice.Working
                         scope.launch { finish(withContext(Dispatchers.IO) { CoreBackup.importStagedAnyway(context) }) }
                     })
    }
}

/** The strap as the app sees it now: name, link state, battery and last sync, with connect and pairing. */
@Composable
private fun StrapCard(viewModel: AppViewModel, onPair: () -> Unit) {
    val colors = Forge.colors
    val live by viewModel.live.collectAsState()
    val name by viewModel.activeDeviceName.collectAsState()
    val linked = live.connected || live.bonded || live.streamingLiveHR
    val (status, tint) = when {
        live.backfilling -> stringResource(R.string.forge_strap_syncing) to colors.rest
        linked -> stringResource(R.string.forge_strap_connected) to colors.charge
        live.scanning -> stringResource(R.string.forge_strap_searching) to colors.effort
        else -> stringResource(R.string.forge_strap_disconnected) to colors.textTertiary
    }
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(12.dp).background(tint, CircleShape))
            Spacer(Modifier.width(ForgeMetrics.space2 + ForgeMetrics.space1))
            Column(Modifier.weight(1f)) {
                Text(name ?: stringResource(R.string.forge_strap_none), style = Forge.type.headline, color = colors.text)
                Text(status, style = Forge.type.subhead, color = colors.textSecondary)
            }
            live.batteryPct?.let { pct ->
                Text(stringResource(R.string.forge_strap_battery, pct.roundToInt()), style = Forge.type.captionNumber,
                     color = colors.textSecondary)
            }
        }
        live.lastSyncAt?.let { at ->
            Spacer(Modifier.height(ForgeMetrics.space2))
            Text(stringResource(R.string.forge_strap_last_sync,
                                DateUtils.getRelativeTimeSpanString(at * 1000, System.currentTimeMillis(),
                                                                    DateUtils.MINUTE_IN_MILLIS).toString()),
                 style = Forge.type.caption, color = colors.textTertiary)
        }
        Spacer(Modifier.height(ForgeMetrics.space4))
        Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
            if (name != null) {
                OutlinedButton(onClick = { if (linked || live.scanning) viewModel.disconnect() else viewModel.connect() },
                               modifier = Modifier.weight(1f)) {
                    Text(stringResource(if (linked || live.scanning) R.string.forge_strap_disconnect
                                        else R.string.forge_strap_connect), maxLines = 1)
                }
            }
            Button(onClick = onPair, modifier = Modifier.weight(1f)) {
                Text(stringResource(R.string.forge_strap_add), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun MoreRow(icon: ImageVector, tint: Color, title: String, detail: String, onClick: () -> Unit) {
    val colors = Forge.colors
    Row(
        Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget).clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = ForgeMetrics.cardPadding, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(ForgeMetrics.space4))
        Column(Modifier.weight(1f)) {
            Text(title, style = Forge.type.headline, color = colors.text)
            Text(detail, style = Forge.type.subhead, color = colors.textSecondary)
        }
        Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary)
    }
}

@Composable
private fun NoticeDialog(notice: Notice, onDismiss: () -> Unit, onRestart: () -> Unit, onImportAnyway: () -> Unit) {
    when (notice) {
        Notice.Working -> AlertDialog(
            onDismissRequest = {}, confirmButton = {},
            text = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(24.dp))
                    Spacer(Modifier.width(ForgeMetrics.space4))
                    Text(stringResource(R.string.forge_working))
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
    else -> stringResource(R.string.forge_backup_failed, why)
}
