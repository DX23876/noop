package com.noop.core

import android.content.Context
import com.noop.BuildConfig
import com.noop.data.BackupSettingsBridge
import java.io.File
import java.io.InputStream
import java.io.OutputStream

/**
 * Fork (DX23876), Android plan E-3e: `.noopbak` export and import of the core's store, through the same Swift
 * `BackupArchive` the Apple apps use. The archive is staged in the cache and copied to or from the file the wearer
 * picked. Blocking; call off the main thread.
 */
object CoreBackup {
    sealed interface Result {
        data object Done : Result
        /** The restored store is read only after the app restarts. */
        data object Imported : Result
        data class TooLarge(val entry: String) : Result
        data class Failed(val why: String) : Result
    }

    /** The core's result line as a [Result]; anything unreadable is a failure carrying the line. */
    internal fun parse(line: String?): Result = when {
        line == null -> Result.Failed("noCore")
        line == "done" -> Result.Done
        line == "imported" -> Result.Imported
        line.startsWith("tooLarge:") -> Result.TooLarge(line.removePrefix("tooLarge:"))
        line.startsWith("failed:") -> Result.Failed(line.removePrefix("failed:"))
        else -> Result.Failed(line)
    }

    private fun scratch(context: Context) = File(context.cacheDir, "core-backup").apply { mkdirs() }

    fun export(context: Context, out: OutputStream): Result {
        if (!SwiftCore.available) return Result.Failed("noCore")
        CoreRead.open(context)
        if (!CoreUserInputs.ensure(context)) return Result.Failed("inputMigration")
        val dir = scratch(context)
        val staged = File(dir, "export.noopbak")
        val settings = runCatching { BackupSettingsBridge.snapshotJson(context) }.getOrNull()
        val result = parse(SwiftCore.exportBackup(staged.path, dir.path, BuildConfig.VERSION_NAME,
                                                  BuildConfig.VERSION_CODE.toString(), settings))
        if (result == Result.Done) staged.inputStream().use { it.copyTo(out) }
        staged.delete()
        return result
    }

    fun import(context: Context, input: InputStream, allowOversize: Boolean = false): Result {
        if (!SwiftCore.available) return Result.Failed("noCore")
        CoreRead.open(context)
        val dir = scratch(context)
        val staged = File(dir, "import.noopbak")
        staged.outputStream().use { input.copyTo(it) }
        restoredSettings(dir).delete()
        val result = parse(SwiftCore.importBackup(staged.path, dir.path, allowOversize))
        if (result !is Result.TooLarge) staged.delete()
        if (result == Result.Imported) afterRestore(context, dir)
        return result
    }

    /** Imports the file staged by the last [import] that answered [Result.TooLarge], this time allowing it. */
    fun importStagedAnyway(context: Context): Result {
        val dir = scratch(context)
        val staged = File(dir, "import.noopbak")
        if (!staged.isFile) return Result.Failed("noStagedFile")
        restoredSettings(dir).delete()
        return parse(SwiftCore.importBackup(staged.path, dir.path, true)).also {
            staged.delete()
            if (it == Result.Imported) afterRestore(context, dir)
        }
    }

    /** Where the core leaves the restored backup's `settings.json` (`CoreBackup.restoredSettingsURL`). */
    private fun restoredSettings(dir: File) = File(dir, "restored-settings.json")

    /** The app's own settings from the backup, applied once the store swapped; the restart follows. */
    private fun afterRestore(context: Context, dir: File) {
        CoreInputLanes.forgetRepairAfterRestore(context)
        val settings = restoredSettings(dir)
        if (settings.isFile) {
            runCatching { BackupSettingsBridge.apply(context, settings.readText()) }
            settings.delete()
        }
    }
}
