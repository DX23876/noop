package com.noop.ui.forge

import android.content.Context
import android.text.format.Formatter
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.noop.R
import com.noop.core.CoreStorage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

// Settings › Data & Backup › Storage (iOS `StorageView`, #590): where NOOP's on-device space is going and a one-tap
// clean-up. The database and its log are the core's to measure and truncate (`storage.report`, `storage.cleanUp`);
// the scratch copies an import leaves in the app's cache are plain files, read and removed here as file-system
// presentation. The iOS "leftover import copies" row is the picker's Inbox folder, which Android has none of.

/** What the page shows: the database, and the import scratch that can be reclaimed. Null [database] when unreadable. */
private data class StorageNumbers(val database: Long?, val scratch: Long)

/** NOOP's own import scratch folders in the app cache, the ones an interrupted import or backup can leave behind. */
private object ImportScratch {
    /** A folder or file written in the last minute may belong to a running import or backup; it is left alone. */
    private const val IN_FLIGHT_MS = 60_000L

    private fun candidates(context: Context): List<File> =
        context.cacheDir.listFiles().orEmpty().filter { it.name == "core-import" || it.name == "core-backup" || it.name.startsWith("xiaomi-") }

    fun bytes(context: Context): Long = candidates(context).sumOf(::size)

    /** Removes what is not in flight; the freed bytes are the difference of two readings. */
    fun purge(context: Context) {
        val now = System.currentTimeMillis()
        candidates(context).filter { now - it.lastModified() > IN_FLIGHT_MS }.forEach { it.deleteRecursively() }
    }

    private fun size(file: File): Long = if (file.isDirectory) file.listFiles().orEmpty().sumOf(::size) else file.length()
}

/** The Storage page: footprint, clean-up and the explainer, under its own title. */
@Composable
internal fun StorageSettingsPage(onBack: () -> Unit) {
    SettingsColumn {
        PageTitle(stringResource(R.string.fsp5_storage_title), onBack)
        StorageSection()
    }
}

@Composable
private fun StorageSection() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var numbers by remember { mutableStateOf<StorageNumbers?>(null) }
    var loading by remember { mutableStateOf(true) }
    var cleaning by remember { mutableStateOf(false) }
    var summary by remember { mutableStateOf<String?>(null) }
    val reclaimable = numbers?.scratch ?: 0L
    val none = stringResource(R.string.fsp5_storage_already_clean)
    val freedText = { freed: Long -> context.getString(R.string.fsp5_storage_reclaimed, size(context, freed)) }

    LaunchedEffect(Unit) {
        numbers = withContext(Dispatchers.IO) { read(context) }
        loading = false
    }

    val current = numbers
    if (loading && current == null) {
        SettingsCard(title = null, blurb = null) { Text(stringResource(R.string.fsp5_storage_measuring), style = Forge.type.body, color = Forge.colors.textSecondary) }
    } else if (current == null || current.database == null) {
        SettingsCard(title = stringResource(R.string.fsp5_storage_unavailable_title), blurb = stringResource(R.string.fsp5_storage_unavailable_body)) {}
    } else {
        SettingsCard(title = stringResource(R.string.fsp5_storage_footprint), blurb = null) {
            SettingRow(stringResource(R.string.fsp5_storage_database)) { Value(size(context, current.database)) }
            RowDivider()
            Column {
                SettingRow(stringResource(R.string.fsp5_storage_scratch)) { Value(size(context, current.scratch)) }
                if (current.scratch > 0) Text(stringResource(R.string.fsp5_storage_reclaimable), style = Forge.type.caption, color = ForgeTokens.StrandPalette.statusWarningForeground.resolve())
            }
        }
        SettingsCard(title = stringResource(R.string.fsp5_storage_cleanup_title), blurb = null) {
            Text(if (reclaimable > 0) stringResource(R.string.fsp5_storage_cleanup_some, size(context, reclaimable))
                 else stringResource(R.string.fsp5_storage_cleanup_none),
                 style = Forge.type.subhead, color = Forge.colors.textSecondary)
            summary?.let { Text(it, style = Forge.type.footnote, color = Forge.colors.charge) }
            // With nothing to reclaim the text above says so and the button is left out (iOS draws it disabled).
            if (reclaimable > 0 || cleaning) {
                RowDivider()
                LinkRow(stringResource(if (cleaning) R.string.fsp5_storage_cleaning else R.string.fsp5_storage_cleanup_now), null,
                        busy = cleaning) {
                    if (cleaning) return@LinkRow
                    cleaning = true
                    scope.launch {
                        val before = reclaimable
                        val after = withContext(Dispatchers.IO) {
                            ImportScratch.purge(context)
                            CoreStorage.cleanUp(context)
                            read(context)
                        }
                        numbers = after
                        val freed = maxOf(0L, before - after.scratch)
                        summary = if (freed > 0) freedText(freed) else none
                        cleaning = false
                    }
                }
            }
        }
    }
    SettingsCard(title = stringResource(R.string.fsp5_storage_why_title), blurb = stringResource(R.string.fsp5_storage_why_body)) {}
}

@Composable
private fun Value(text: String) {
    Text(text, style = Forge.type.bodyNumber, color = Forge.colors.textSecondary)
}

private fun read(context: Context): StorageNumbers = StorageNumbers(CoreStorage.databaseBytes(context), ImportScratch.bytes(context))

private fun size(context: Context, bytes: Long): String = Formatter.formatShortFileSize(context, bytes)
