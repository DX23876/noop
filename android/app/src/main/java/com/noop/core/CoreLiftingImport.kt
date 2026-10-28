package com.noop.core

import android.content.Context
import android.net.Uri
import android.util.Base64
import com.noop.NoopApplication
import com.noop.data.WorkoutRow
import java.io.ByteArrayOutputStream
import java.time.ZoneId
import org.json.JSONObject

/** SAF and byte transport only: Swift parses and stores the complete lifting history. Call on IO. */
object CoreLiftingImport {
    const val MAX_BYTES = 64 * 1024 * 1024
    data class Result(val sessions: Int, val skipped: Int, val error: String?, val workouts: List<WorkoutRow> = emptyList())

    suspend fun read(context: Context, uri: Uri): Result {
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
                val result = parse(SwiftCore.call("training.importLifting", args.toString()))
                if (result.error == null) {
                    // Temporary input projection until parity 1.3 moves the classic reads to the core.
                    // No Kotlin parsing, volume arithmetic or synthetic physiology enters this copy.
                    val repository = (context.applicationContext as NoopApplication).repository
                    repository.upsertDevice("lifting", name = "Lifting log")
                    repository.upsertWorkouts(result.workouts)
                }
                result
            }
        } catch (_: Exception) { Result(0, 0, "importFailed") }
    }

    internal fun parse(json: String?): Result = try {
        val root = JSONObject(json ?: "{}")
        val error = root.optString("error").takeIf { it.isNotBlank() }
        val sessions = root.optInt("sessions", 0)
        val skipped = root.optInt("skipped", 0)
        if (error != null || sessions <= 0 || skipped < 0) Result(0, 0, error ?: "importFailed")
        else {
            val rows = root.getJSONArray("workouts")
            require(rows.length() == sessions)
            val workouts = (0 until rows.length()).map { index ->
                val row = rows.getJSONObject(index)
                require(row.getString("source") == "lifting")
                fun number(key: String): Double? = if (row.has(key) && !row.isNull(key)) row.getDouble(key) else null
                fun text(key: String): String? = if (row.has(key) && !row.isNull(key)) row.getString(key) else null
                WorkoutRow(deviceId = "lifting", startTs = row.getLong("startTs"), endTs = row.getLong("endTs"),
                    sport = row.getString("sport"), source = row.getString("source"), durationS = number("durationS"),
                    energyKcal = number("energyKcal"), avgHr = number("avgHr")?.toInt(), maxHr = number("maxHr")?.toInt(),
                    strain = number("strain"), distanceM = number("distanceM"), zonesJSON = text("zonesJSON"),
                    notes = text("notes"), steps = number("steps")?.toInt())
            }
            Result(sessions, skipped, null, workouts)
        }
    } catch (_: Exception) { Result(0, 0, "importFailed") }
}
