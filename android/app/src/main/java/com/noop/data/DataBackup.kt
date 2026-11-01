package com.noop.data

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import com.noop.core.CoreBackup
import java.io.File
import java.io.IOException

/**
 * Whole-store EXPORT / IMPORT for device migration, for the classic Settings card and the scheduled folder backup
 * ([com.noop.ui.BackupSync]).
 *
 * Fork (DX23876), Android without Room: the store is the shared core's, so both directions go through
 * [CoreBackup] and the Swift `BackupArchive` the Apple apps use (verified write, integrity checks, the previous
 * store kept beside a restore, rollback). A Room `.noopbak` from ryanbr's app or an older Forge build is converted
 * into a core store on the way in (`RoomStoreAdoption`). This object only keeps the classic screens' result types
 * and their sentences.
 */
object DataBackup {

    /** The restore ceiling (`BackupArchive.maxSQLiteBytes`, 5 GiB); larger needs the wearer's go-ahead. */
    internal const val MAX_BACKUP_SQLITE_BYTES = 5_368_709_120L

    /** Outcome of an [importFrom] call. On success the app must be restarted. */
    sealed interface ImportResult {
        /** The new database is in place; tell the user to relaunch NOOP. */
        data object NeedsRestart : ImportResult

        /** Import failed and the original database is untouched. */
        data class Failed(val message: String) : ImportResult

        /** The restore stopped ONLY because the database exceeds the ceiling; the caller can offer to go ahead. */
        data class TooLarge(val message: String, val limitBytes: Long) : ImportResult
    }

    /** What an export produced. [overRestoreCeiling] is true when restoring it will ask the wearer to confirm. */
    data class ExportOutcome(val bytes: Long, val overRestoreCeiling: Boolean, val limitBytes: Long)

    /** Export the core's store to [uri] as a `.noopbak`. Throws on failure with the sentence to show. */
    @Throws(IOException::class)
    fun exportTo(context: Context, uri: Uri): ExportOutcome {
        val appContext = context.applicationContext
        val resolver = appContext.contentResolver
        val result = (resolver.openOutputStream(uri, "wt")
            ?: throw IOException("Could not open the chosen file for writing.")).use { CoreBackup.export(appContext, it) }
        if (result != CoreBackup.Result.Done) {
            runCatching { DocumentsContract.deleteDocument(resolver, uri) }
            throw IOException(exportFailure((result as? CoreBackup.Result.Failed)?.why ?: result.toString()))
        }
        val bytes = runCatching { resolver.openFileDescriptor(uri, "r")?.use { it.statSize } }.getOrNull() ?: 0L
        val store = File(appContext.filesDir, "core/noop-core.sqlite").length()
        return ExportOutcome(bytes, store > MAX_BACKUP_SQLITE_BYTES, MAX_BACKUP_SQLITE_BYTES)
    }

    /**
     * Restore the backup at [uri] over the core's store. On any error the current store is left as it was. On
     * success the caller MUST restart the app.
     */
    fun importFrom(context: Context, uri: Uri, allowOversize: Boolean = false): ImportResult {
        val appContext = context.applicationContext
        val input = runCatching { appContext.contentResolver.openInputStream(uri) }.getOrNull()
            ?: return ImportResult.Failed("Could not open the chosen file.")
        return when (val result = input.use { CoreBackup.import(appContext, it, allowOversize) }) {
            CoreBackup.Result.Imported -> ImportResult.NeedsRestart
            is CoreBackup.Result.TooLarge ->
                ImportResult.TooLarge("The backup archive is too large to restore safely.", MAX_BACKUP_SQLITE_BYTES)
            is CoreBackup.Result.Failed -> ImportResult.Failed(importFailure(result.why))
            CoreBackup.Result.Done -> ImportResult.Failed(importFailure("done"))
        }
    }

    internal fun exportFailure(why: String): String = when {
        why.startsWith("integrity") ->
            "Couldn't export: the NOOP database failed its integrity check, so a backup of it would not restore. " +
                "Export the WHOOP-format CSV instead to save what's still readable."
        why == "incomplete" ->
            "Couldn't finish the backup: the file written was incomplete, so it was removed rather than left " +
                "looking like a good backup. The destination may be out of space. Try again, or choose somewhere else."
        why == "unverified" ->
            "The backup was written, but couldn't be read back to check it, so it has been left in place rather " +
                "than deleted on a guess. Open it before you rely on it, or export again somewhere else."
        why == "noCore" || why == "noSession" -> "No database to export yet."
        else -> "Couldn't export: $why"
    }

    internal fun importFailure(why: String): String = when {
        why == "notSQLite" || why == "foreignBackup" ->
            "That file is not a NOOP backup - it doesn't look like a .noopbak archive or a SQLite database."
        why == "noDatabaseEntry" -> "The backup archive doesn't contain a database file."
        why.startsWith("archiveUnreadable") -> "Could not read the chosen file: ${why.substringAfter(':', why)}"
        why.startsWith("damaged") ->
            "This backup file is damaged, so nothing was restored. Your current data is untouched. " +
                "Try an earlier backup file."
        else -> "Import failed, your data is unchanged: $why"
    }
}
