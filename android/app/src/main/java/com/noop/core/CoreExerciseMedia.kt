package com.noop.core

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import androidx.work.*
import com.noop.R
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

/** Explicit platform download and private files; Swift interprets archives and resolves exercise ids. */
object CoreExerciseMedia {
    val changes = MutableStateFlow(0L)
    private fun changed() { changes.update { it + 1 } }
    private const val PREFS = "noop_exercise_media"
    private const val ID = "downloadId"
    private const val WORK = "noop.installExerciseMedia"
    private const val FILE = "noop-exercise-media.zip"
    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun manager(context: Context) = context.getSystemService(DownloadManager::class.java)
    private fun archive(context: Context) = File(context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: error("storageUnavailable"), FILE)
    private fun call(op: String, args: JSONObject = JSONObject()): JSONObject =
        JSONObject(SwiftCore.call(op, args.toString()) ?: error("coreUnavailable"))

    data class Provider(val source: String, val attribution: String, val rightsHolder: String, val approximateBytes: Long)
    data class Info(val state: String, val disabled: Boolean, val withdrawn: Boolean, val bytes: Long,
                    val files: Int, val checksum: String?, val provider: Provider, val progress: Float?, val error: String?)

    fun configure(context: Context) {
        val reply = call("media.configure", JSONObject().put("root", context.noBackupFilesDir.absolutePath)
            .put("disabled", prefs(context).getBoolean("disabled", false)))
        check(reply.has("state"))
    }
    fun info(context: Context): Info? = runCatching {
        configure(context)
        val root = call("media.info")
        var state = root.getString("state")
        var progress: Float? = null
        var error = root.optString("error").takeIf { it.isNotEmpty() && it != "null" }
            ?: prefs(context).getString("failure", null)
        val id = downloadId(context)
        if (id > 0) manager(context).query(DownloadManager.Query().setFilterById(id))?.use { row ->
            if (row.moveToFirst()) {
                when (row.getInt(row.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))) {
                    DownloadManager.STATUS_SUCCESSFUL -> { enqueueInstall(context); state = "installing" }
                    DownloadManager.STATUS_FAILED -> { state = "failed"; error = "downloadFailed" }
                    else -> {
                        state = "downloading"
                        val total = row.getLong(row.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
                        val received = row.getLong(row.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                        if (total > 0) progress = (received.toDouble() / total).coerceIn(0.0, 1.0).toFloat()
                    }
                }
            } else { state = "failed"; error = "downloadFailed" }
        }
        if (root.getBoolean("disabled") || root.getBoolean("withdrawn")) state = "disabled"
        val provider = root.getJSONObject("provider")
        val manifest = root.optJSONObject("manifest")
        Info(state, root.getBoolean("disabled"), root.getBoolean("withdrawn"), root.getLong("bytes"),
            manifest?.getJSONArray("files")?.length() ?: 0, manifest?.optString("archiveSHA256"),
            Provider(provider.getString("source"), provider.getString("attribution"), provider.getString("rightsHolder"),
                provider.getLong("approximateBytes")), progress, error)
    }.getOrNull()

    /** Only called by the disclosure screen's explicit confirmation. No launch or strap action starts a download. */
    fun begin(context: Context): Boolean = runCatching {
        val info = info(context) ?: return false
        if (info.disabled || info.withdrawn || info.state in listOf("downloading", "installing")) return false
        cancel(context)
        val uri = Uri.parse(info.provider.source)
        check(uri.scheme == "https")
        val target = archive(context)
        target.parentFile?.mkdirs()
        check(!target.exists() || target.delete())
        val request = DownloadManager.Request(uri).setDestinationUri(Uri.fromFile(target))
            .setTitle(context.getString(R.string.forge_media_title))
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
        val id = manager(context).enqueue(request)
        val saved = prefs(context).edit().putLong(ID, id).remove("failure").commit()
        if (!saved) manager(context).remove(id)
        saved
    }.getOrDefault(false)

    fun cancel(context: Context) {
        val id = downloadId(context)
        // Clear the authorization token first: a completion broadcast racing removal cannot install it.
        prefs(context).edit().remove(ID).apply()
        if (id > 0) manager(context).remove(id)
        WorkManager.getInstance(context).cancelUniqueWork(WORK)
        runCatching { call("media.cancel") }
    }
    fun setDisabled(context: Context, disabled: Boolean) {
        prefs(context).edit().putBoolean("disabled", disabled).apply()
        if (disabled) cancel(context)
        configure(context)
        changed()
    }
    fun delete(context: Context): Boolean = runCatching {
        cancel(context)
        configure(context)
        val deleted = call("media.delete").optBoolean("ok")
        if (deleted) {
            archive(context).delete()
            prefs(context).edit().remove("failure").apply()
        }
        changed()
        deleted
    }.getOrDefault(false)
    fun resolve(context: Context, exerciseId: String, still: Boolean): String? = runCatching {
        configure(context)
        CoreRead.open(context)
        val result = call("training.exerciseMedia", JSONObject().put("id", exerciseId).put("still", still))
        if (result.optBoolean("available")) result.getString("path") else null
    }.getOrNull()

    internal fun failDownload(context: Context, id: Long) {
        if (id <= 0 || downloadId(context) != id) return
        prefs(context).edit().remove(ID).putString("failure", "installFailed").apply()
        runCatching { manager(context).remove(id) }
    }
    internal fun downloadId(context: Context): Long = prefs(context).getLong(ID, -1)
    internal fun enqueueInstall(context: Context, completed: Boolean = false) {
        WorkManager.getInstance(context).enqueueUniqueWork(WORK, if (completed) ExistingWorkPolicy.APPEND_OR_REPLACE else ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<ExerciseMediaInstallWorker>().build())
    }
    internal fun finishDownload(context: Context): Boolean {
        val id = downloadId(context)
        if (id <= 0) return true
        configure(context)
        val provider = call("media.info").getJSONObject("provider")
        val expected = archive(context).canonicalFile
        val downloaded = manager(context).query(DownloadManager.Query().setFilterById(id))?.use { row ->
            if (!row.moveToFirst() || row.getInt(row.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) != DownloadManager.STATUS_SUCCESSFUL) return true
            check(row.getString(row.getColumnIndexOrThrow(DownloadManager.COLUMN_URI)) == provider.getString("source"))
            val uri = Uri.parse(row.getString(row.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI)))
            check(uri.scheme == "file" && File(uri.path!!).canonicalFile == expected)
            expected
        } ?: return false
        if (downloadId(context) != id) return true
        val reply = call("media.install", JSONObject().put("archive", downloaded.absolutePath))
        if (downloadId(context) != id) return true
        val installed = reply.optString("state") == "ready"
        prefs(context).edit().remove(ID).apply {
            if (installed) remove("failure") else putString("failure", reply.optString("error", "installFailed"))
        }.commit()
        manager(context).remove(id)
        changed()
        return installed
    }
}

class ExerciseMediaInstallWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val id = CoreExerciseMedia.downloadId(applicationContext)
        try { if (CoreExerciseMedia.finishDownload(applicationContext)) Result.success() else Result.failure() }
        catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (_: Exception) { CoreExerciseMedia.failDownload(applicationContext, id); Result.failure() }
    }
}

class ExerciseMediaDownloadReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == DownloadManager.ACTION_DOWNLOAD_COMPLETE &&
            intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1) == CoreExerciseMedia.downloadId(context)) {
            CoreExerciseMedia.enqueueInstall(context, completed = true)
        }
    }
}
