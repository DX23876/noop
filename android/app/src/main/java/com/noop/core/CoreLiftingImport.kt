package com.noop.core

import android.content.Context
import android.net.Uri
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.time.ZoneId
import org.json.JSONObject

/** SAF and byte transport only: Swift parses and stores the complete lifting history. Call on IO. */
object CoreLiftingImport {
    const val MAX_BYTES = 64 * 1024 * 1024
    data class Result(val sessions: Int, val skipped: Int, val error: String?)

    fun read(context: Context, uri: Uri): Result {
        return try {
            val data = context.contentResolver.openInputStream(uri)?.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    require(output.size() + n <= MAX_BYTES)
                    output.write(buffer, 0, n)
                }
                output.toByteArray()
            } ?: return Result(0, 0, "fileUnavailable")
            CoreRead.open(context)
            if (!SwiftCore.available) Result(0, 0, "coreUnavailable") else {
                val args = JSONObject().put("data", Base64.encodeToString(data, Base64.NO_WRAP))
                    .put("timeZone", ZoneId.systemDefault().id)
                parse(SwiftCore.call("training.importLifting", args.toString()))
            }
        } catch (_: Exception) { Result(0, 0, "importFailed") }
    }

    internal fun parse(json: String?): Result = try {
        val root = JSONObject(json ?: "{}")
        val error = root.optString("error").takeIf { it.isNotBlank() }
        val sessions = root.optInt("sessions", 0)
        val skipped = root.optInt("skipped", 0)
        if (error != null || sessions <= 0 || skipped < 0) Result(0, 0, error ?: "importFailed")
        else Result(sessions, skipped, null)
    } catch (_: Exception) { Result(0, 0, "importFailed") }
}
