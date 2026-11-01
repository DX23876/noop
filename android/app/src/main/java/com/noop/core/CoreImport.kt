package com.noop.core

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.noop.data.ImportSummary
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

/**
 * Fork (DX23876), Android without Room (`docs/fork/android/CORE-ONLY-PLAN.md`, decision 8): a picked export is parsed
 * by the shared core with the importers the Apple apps use (`import.file`, the Swift `CoreImport`), so a WHOOP CSV,
 * an Apple Health export, a Mi Fitness export or another wearable's export reads the same on both platforms. The
 * document is copied into the cache under its own name first, since the importers tell a zip, an XML file and a
 * database apart by the file name.
 */
object CoreImport {
    enum class Kind(val wire: String) { WHOOP("whoop"), APPLE_HEALTH("appleHealth"), XIAOMI("xiaomi"), WEARABLE("wearable") }

    /**
     * The core's import of [uri], or null when this build has no core or [uri] is a folder (the caller then keeps
     * its own path). A failure inside the core is an [ImportSummary.failure] with the core's reason.
     */
    suspend fun importFile(context: Context, uri: Uri, kind: Kind, deviceId: String, label: String): ImportSummary? =
        withContext(Dispatchers.IO) {
            if (!SwiftCore.available || DocumentsContract.isTreeUri(uri)) return@withContext null
            if (!CoreShadow.openStore(context)) return@withContext null
            val dir = File(context.cacheDir, "core-import").apply { deleteRecursively(); mkdirs() }
            val staged = File(dir, safeName(displayName(context, uri) ?: "import"))
            try {
                val input = context.contentResolver.openInputStream(uri)
                    ?: return@withContext ImportSummary.failure(label, "Could not open the chosen file.")
                input.use { src -> staged.outputStream().use { src.copyTo(it) } }
                val args = JSONObject().put("kind", kind.wire).put("path", staged.path).put("deviceId", deviceId)
                val answer = SwiftCore.call("import.file", args.toString())?.let(::JSONObject)
                    ?: return@withContext ImportSummary.failure(label, "The import did not answer.")
                if (answer.has("error")) {
                    return@withContext ImportSummary.failure(label,
                        "Import failed: ${answer.optString("detail", answer.optString("error"))}")
                }
                CoreShadow.noteDataChanged()
                summary(answer, label)
            } finally {
                dir.deleteRecursively()
            }
        }

    internal fun summary(answer: JSONObject, label: String): ImportSummary {
        val countsJson = answer.optJSONObject("counts")
        val counts = countsJson?.keys()?.asSequence()?.associateWith { countsJson.optInt(it) }.orEmpty()
        val first = answer.optString("earliest").takeIf { it.isNotEmpty() && it != "null" }
        val last = answer.optString("latest").takeIf { it.isNotEmpty() && it != "null" }
        val records = answer.optInt("recordCount")
        val span = if (first != null && last != null) " ($first to $last)" else ""
        return ImportSummary(source = label, counts = counts, firstDay = first, lastDay = last,
                             message = "$label: imported $records records$span.")
    }

    private fun displayName(context: Context, uri: Uri): String? = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    }.getOrNull() ?: uri.lastPathSegment?.substringAfterLast('/')

    internal fun safeName(name: String): String =
        name.replace(Regex("[^A-Za-z0-9._ -]"), "_").trim().ifEmpty { "import" }.take(120)
}
