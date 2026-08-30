package com.noop.testcentre

import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.content.FileProvider
import com.noop.BuildConfig
import com.noop.data.WhoopRepository
import com.noop.ingest.RawSensorExport
import com.noop.protocol.Whoop5RawImu
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.UUID

/** App-private, explicitly user-started bounded 5/MG raw-data capture with annotations. */
class GroundTruthCollector private constructor(private val context: Context) {
    data class Snapshot(
        val active: Boolean,
        val sessionId: String?,
        val deviceId: String?,
        val startedAtMs: Long,
        val endedAtMs: Long,
        val exported: Boolean,
    )

    data class SessionSummary(
        val id: String,
        val deviceId: String?,
        val startedAtMs: Long,
        val endedAtMs: Long?,
        val capturedStartedAtMs: Long?,
        val capturedEndedAtMs: Long?,
        val comment: String,
        val active: Boolean,
        val exported: Boolean,
        val lastExportedAtMs: Long?,
        val markers: List<Marker>,
    )

    data class Marker(val id: String, val atMs: Long, val type: String, val text: String)
    data class CaptureStats(
        val bytes: Long,
        val coveredSeconds: Int,
        val expectedSeconds: Int,
        val startupSeconds: Int,
    ) {
        val missingSeconds get() = (expectedSeconds - coveredSeconds).coerceAtLeast(0)
        val complete get() = expectedSeconds > 0 && missingSeconds == 0
    }

    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val directory = File(context.filesDir, "ground-truth").apply { mkdirs() }

    fun captureStats(session: SessionSummary, nowMs: Long = System.currentTimeMillis()): CaptureStats {
        val end = session.endedAtMs ?: nowMs
        val baseFrom = ceilSecond(session.startedAtMs)
        val to = end / 1_000L - 1L
        val raw = ImuSessionFileStore(context).stats(session.id, baseFrom, to)
        val first = raw.firstTs?.takeIf { it <= baseFrom + 1 }
        val from = if (session.capturedStartedAtMs != null) maxOf(baseFrom, first ?: baseFrom) else baseFrom
        val adjusted = if (from == baseFrom) raw.coveredSeconds else
            ImuSessionFileStore(context).stats(session.id, from, to).coveredSeconds
        return CaptureStats(raw.bytes, adjusted, (to - from + 1).coerceAtLeast(0).toInt(),
            (from - baseFrom).coerceAtLeast(0).toInt())
    }

    @Synchronized
    fun snapshot(): Snapshot = Snapshot(
        active = prefs.getBoolean("active", false),
        sessionId = prefs.getString("sessionId", null),
        deviceId = prefs.getString("deviceId", null),
        startedAtMs = prefs.getLong("startedAtMs", 0L),
        endedAtMs = prefs.getLong("endedAtMs", 0L),
        exported = prefs.getBoolean("exported", false),
    )

    @Synchronized
    fun start(deviceId: String, nowMs: Long = System.currentTimeMillis()): Snapshot {
        val id = nowMs.toString()
        prefs.edit()
            .putBoolean("active", true)
            .putBoolean("exported", false)
            .putString("sessionId", id)
            .putString("deviceId", deviceId)
            .putLong("startedAtMs", nowMs)
            .putString(sessionDeviceKey(id), deviceId)
            .putLong(sessionStartKey(id), nowMs)
            .putBoolean(sessionExportedKey(id), false)
            .putBoolean(sessionCaptureKey(id), true)
            .apply()
        append(id, event(nowMs, "start").put("strap_device_id", deviceId))
        ImuSessionFileStore(context).start(id, deviceId, nowMs)
        return snapshot()
    }

    @Synchronized
    fun setComment(sessionId: String, comment: String) {
        prefs.edit().putString(sessionCommentKey(sessionId), comment.take(4_000)).apply()
    }

    @Synchronized
    fun sessions(): List<SessionSummary> {
        val current = snapshot()
        return directory.listFiles { file -> file.name.startsWith("session-") && file.name.endsWith(".jsonl") }
            .orEmpty()
            .mapNotNull { file ->
                val id = file.name.removePrefix("session-").removeSuffix(".jsonl")
                val rows = runCatching {
                    file.useLines { lines ->
                        lines.filter { it.isNotBlank() }
                            .mapNotNull { line -> runCatching { JSONObject(line) }.getOrNull() }
                            .toList()
                    }
                }.getOrNull() ?: return@mapNotNull null
                val first = rows.firstOrNull() ?: return@mapNotNull null
                val isCurrent = current.sessionId == id
                val physicalStart = prefs.getLong(sessionStartKey(id), first.optLong("at_ms"))
                val capturedEnd = rows.lastOrNull { it.optString("kind") == "stop" }?.optLong("at_ms")
                val hasCapture = prefs.getBoolean(sessionCaptureKey(id), false)
                SessionSummary(
                    id = id,
                    deviceId = prefs.getString(sessionDeviceKey(id), null)
                        ?: first.optString("strap_device_id").takeIf(String::isNotBlank)
                        ?: current.deviceId.takeIf { isCurrent },
                    startedAtMs = prefs.getLong(sessionUsedStartKey(id), physicalStart),
                    endedAtMs = capturedEnd?.let { prefs.getLong(sessionUsedEndKey(id), it) },
                    capturedStartedAtMs = physicalStart.takeIf { hasCapture },
                    capturedEndedAtMs = capturedEnd.takeIf { hasCapture },
                    comment = prefs.getString(sessionCommentKey(id), "").orEmpty(),
                    active = isCurrent && current.active,
                    exported = prefs.getBoolean(sessionExportedKey(id), isCurrent && current.exported),
                    lastExportedAtMs = prefs.getLong(sessionLastExportKey(id), 0L).takeIf { it > 0 },
                    markers = rows.filter { it.optString("kind") == KIND_MARKER }.map { row ->
                        Marker(row.optString("marker_id"), row.optLong("at_ms"),
                            row.optString("marker_type", "moment"), row.optString("text"))
                    }.sortedBy(Marker::atMs),
                )
            }
            .sortedByDescending { it.startedAtMs }
    }

    /** Delete one completed capture and all app-private files and metadata belonging to it. */
    @Synchronized
    fun deleteSession(sessionId: String): Boolean {
        val current = snapshot()
        if (current.active && current.sessionId == sessionId) return false
        if (sessions().none { it.id == sessionId }) return false

        val payloadFiles = listOf(File(context.cacheDir, "logs/noop-5mg-raw-$sessionId.zip"))
        // Each step aborts on the first failure, so a delete is all-or-nothing from the user's side:
        // whatever survives is still owned by a session that is still listed, never orphaned. That
        // relies on deleteFiles() being idempotent - a missing directory reads as success - so the
        // retry re-runs the earlier steps cleanly.
        val imuStore = ImuSessionFileStore(context)
        if (!imuStore.deleteFiles(sessionId)) return false
        if (!payloadFiles.all { file -> !file.exists() || file.delete() }) return false
        imuStore.remove(sessionId)
        // The event file is also the durable session index. Delete it last so any earlier failure
        // leaves the session visible and the explicit delete action retryable.
        if (eventFile(sessionId).exists() && !eventFile(sessionId).delete()) return false

        prefs.edit()
            .remove(sessionDeviceKey(sessionId))
            .remove(sessionStartKey(sessionId))
            .remove(sessionEndKey(sessionId))
            .remove(sessionCommentKey(sessionId))
            .remove(sessionExportedKey(sessionId))
            .remove(sessionLastExportKey(sessionId))
            .remove(sessionUsedStartKey(sessionId))
            .remove(sessionUsedEndKey(sessionId))
            .remove(sessionCaptureKey(sessionId))
            .apply {
                if (current.sessionId == sessionId) clearCurrentSession()
            }
            .apply()
        return true
    }

    /** Trim the analysis/export interval without rewriting the physical capture provenance. */
    @Synchronized
    fun setSessionRange(sessionId: String, fromMs: Long, toMs: Long): Boolean {
        val session = sessions().firstOrNull { it.id == sessionId } ?: return false
        if (session.active || fromMs <= 0 || fromMs > toMs || toMs - fromMs > MAX_RANGE_MS) return false
        prefs.edit().putLong(sessionUsedStartKey(sessionId), fromMs)
            .putLong(sessionUsedEndKey(sessionId), toMs).apply()
        val deviceId = session.deviceId ?: return false
        ImuSessionFileStore(context).register(sessionId, deviceId, fromMs, toMs)
        return true
    }

    @Synchronized
    fun createHistoricalSession(deviceId: String, fromMs: Long, toMs: Long): SessionSummary? {
        if (fromMs <= 0 || fromMs > toMs || toMs - fromMs > MAX_RANGE_MS) return null
        val id = System.currentTimeMillis().toString()
        prefs.edit().putString(sessionDeviceKey(id), deviceId).putLong(sessionStartKey(id), fromMs)
            .putLong(sessionEndKey(id), toMs).putLong(sessionUsedStartKey(id), fromMs)
            .putLong(sessionUsedEndKey(id), toMs).putBoolean(sessionCaptureKey(id), false).apply()
        append(id, event(fromMs, "start").put("strap_device_id", deviceId))
        append(id, event(toMs, "stop"))
        ImuSessionFileStore(context).register(id, deviceId, fromMs, toMs)
        return sessions().firstOrNull { it.id == id }
    }

    @Synchronized
    fun addMarker(sessionId: String, atMs: Long, type: String, text: String): Marker? {
        val session = sessions().firstOrNull { it.id == sessionId } ?: return null
        val end = session.endedAtMs ?: System.currentTimeMillis()
        val marker = Marker(UUID.randomUUID().toString(), atMs.coerceIn(session.startedAtMs, end),
            type.take(40), text.take(500))
        append(sessionId, JSONObject().apply {
            put("at_ms", marker.atMs); put("kind", KIND_MARKER); put("marker_id", marker.id)
            put("marker_type", marker.type); put("text", marker.text)
        })
        return marker
    }

    @Synchronized
    fun updateMarker(sessionId: String, marker: Marker): Boolean {
        val session = sessions().firstOrNull { it.id == sessionId } ?: return false
        val end = session.endedAtMs ?: System.currentTimeMillis()
        return rewriteEvents(sessionId) { rows -> rows.map { row ->
            if (row.optString("kind") == KIND_MARKER && row.optString("marker_id") == marker.id)
                JSONObject(row.toString()).apply {
                    put("at_ms", marker.atMs.coerceIn(session.startedAtMs, end))
                    put("marker_type", marker.type.take(40)); put("text", marker.text.take(500))
                } else row
        }}
    }

    @Synchronized
    fun deleteMarker(sessionId: String, markerId: String): Boolean = rewriteEvents(sessionId) { rows ->
        rows.filterNot { it.optString("kind") == KIND_MARKER && it.optString("marker_id") == markerId }
    }

    private fun rewriteEvents(sessionId: String, transform: (List<JSONObject>) -> List<JSONObject>): Boolean {
        val file = eventFile(sessionId); if (!file.isFile) return false
        val rows = file.useLines { it.filter(String::isNotBlank).map(::JSONObject).toList() }
        val content = transform(rows).joinToString("\n", postfix = "\n") { it.toString() }
        val staged = File(file.parentFile, ".${file.name}.tmp")
        return runCatching {
            staged.writeText(content)
            check(staged.renameTo(file)) { "Could not commit marker edit" }
        }.onFailure { staged.delete() }.isSuccess
    }

    /** Delete every completed capture. Active captures are deliberately retained. */
    @Synchronized
    fun deleteAllSessions(): Int {
        val completedIds = sessions().filterNot(SessionSummary::active).map(SessionSummary::id)
        return completedIds.count(::deleteSession)
    }

    @Synchronized
    fun stop(nowMs: Long = System.currentTimeMillis()): Snapshot {
        val before = snapshot()
        if (!before.active || before.sessionId == null) return before
        append(before.sessionId, event(nowMs, "stop"))
        ImuSessionFileStore(context).complete(before.sessionId, nowMs)
        prefs.edit().putBoolean("active", false).putLong("endedAtMs", nowMs)
            .putLong(sessionEndKey(before.sessionId), nowMs)
            .apply()
        return snapshot()
    }

    suspend fun export(repo: WhoopRepository, sessionId: String? = null): File = withContext(Dispatchers.IO) {
        val snap = snapshot()
        val id = sessionId ?: requireNotNull(snap.sessionId) { "No ground-truth session has been recorded" }
        val summary = sessions().firstOrNull { it.id == id } ?: error("Ground-truth session is missing")
        require(!summary.active) { "Stop the session before exporting" }
        val deviceId = summary.deviceId
        val source = eventFile(id)
        require(source.isFile) { "Ground-truth event file is missing" }
        val events = source.useLines { lines ->
            lines.filter { it.isNotBlank() }
                .mapNotNull { line -> runCatching { JSONObject(line) }.getOrNull() }
                .toList()
        }
        val endMs = summary.endedAtMs ?: events.lastOrNull()?.optLong("at_ms") ?: summary.startedAtMs
        // Export the complete bounded interval; markers are optional annotations.
        val sensorFrom = ceilSecond(summary.startedAtMs)
        val sensorTo = endMs / 1_000L - 1L
        val imuSegments = if (deviceId == null || sensorFrom > sensorTo) emptyList() else
            ImuSessionFileStore(context).exportSegments(id, sensorFrom, sensorTo)
        val fullFrom = sensorFrom
        val fullTo = endMs / 1_000L - 1L
        // A live capture can only produce its first complete one-second frame after startup.
        // Historical windows must still cover the exact requested start.
        val firstImuTs = imuSegments.minOfOrNull { it.startTs }?.takeIf { it <= fullFrom + 1 }
        val coverageFrom = if (summary.capturedStartedAtMs != null) maxOf(fullFrom, firstImuTs ?: fullFrom)
            else fullFrom
        val imuComplete = covers(imuSegments, coverageFrom, fullTo)
        val outDir = File(context.cacheDir, "logs").apply { mkdirs() }
        val zip = File(outDir, "noop-5mg-raw-$id.zip")
        ZipOutputStream(zip.outputStream().buffered()).use { out ->
            var v18Count: Int
            out.putNextEntry(ZipEntry("v18-aux.csv"))
            out.bufferedWriterNoClose().use { writer ->
                v18Count = writeV18AuxCsv(writer, repo, deviceId.orEmpty(), sensorFrom, sensorTo)
                writer.flush()
            }
            out.closeEntry()

            var rawCounts: Map<String, Int>
            out.putNextEntry(ZipEntry("raw-sensors.csv"))
            out.bufferedWriterNoClose().use { writer ->
                rawCounts = RawSensorExport.writeCsv(writer, repo, deviceId.orEmpty(), sensorFrom, sensorTo)
                writer.flush()
            }
            out.closeEntry()

            val sensorAvailable = imuSegments.isNotEmpty() || v18Count > 0 || rawCounts.values.any { it > 0 }
            out.putNextEntry(ZipEntry("meta.json"))
            out.writerEntry(JSONObject().apply {
                put("schema_version", 3)
                put("capture_kind", "whoop_5mg_raw_data")
                put("session_id", id)
                if (deviceId != null) put("device_id", deviceId)
                put("sensor_export_available", sensorAvailable)
                put("imu_100hz_segment_count", imuSegments.size)
                put("imu_100hz_complete", imuComplete)
                put("imu_100hz_required_start_ts", coverageFrom)
                put("imu_100hz_required_end_ts", fullTo)
                put("imu_100hz_startup_seconds", (coverageFrom - fullFrom).coerceAtLeast(0))
                put("imu_100hz_coverage", org.json.JSONArray().apply {
                    imuSegments.forEach { segment -> put(JSONObject().apply {
                        put("file", segment.name); put("start_ts", segment.startTs); put("end_ts", segment.endTs)
                        put("sample_count", segment.sampleCount)
                    }) }
                })
                put("started_at_ms", summary.startedAtMs)
                put("ended_at_ms", endMs)
                summary.capturedStartedAtMs?.let { put("captured_started_at_ms", it) }
                summary.capturedEndedAtMs?.let { put("captured_ended_at_ms", it) }
                put("comment", summary.comment)
                put("markers", org.json.JSONArray().apply {
                    summary.markers.filter { it.atMs in summary.startedAtMs..endMs }.forEach { marker -> put(JSONObject().apply {
                    put("id", marker.id); put("at_ms", marker.atMs); put("type", marker.type); put("text", marker.text)
                }) } })
                put("device_family", "Android")
                put("app_version", BuildConfig.VERSION_NAME)
            }.toString(2))

            out.putNextEntry(ZipEntry("events.jsonl"))
            out.writerEntry(eventsJsonl(publicEvents(events, summary.startedAtMs, endMs, deviceId)))

            out.putNextEntry(ZipEntry("events.csv"))
            out.writerEntry(eventsCsv(publicEvents(events, summary.startedAtMs, endMs, deviceId)))

            for (segment in imuSegments) {
                out.putNextEntry(ZipEntry("imu/${segment.name}"))
                out.write(segment.data)
                out.closeEntry()
            }
        }
        val exportedAt = System.currentTimeMillis()
        prefs.edit().putBoolean(sessionExportedKey(id), true).putLong(sessionLastExportKey(id), exportedAt).apply()
        if (id == snap.sessionId) prefs.edit().putBoolean("exported", true).apply()
        zip
    }

    fun share(file: File) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
            type = "application/zip"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, "NOOP 5/MG raw-data session")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }, "Export raw-data session").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun covers(chunks: List<ImuSessionFileStore.ExportSegment>, from: Long, to: Long): Boolean {
        if (from > to) return false
        var cursor = from
        for (chunk in chunks.sortedBy { it.startTs }) {
            val start = chunk.startTs; val end = chunk.endTs
            if (chunk.sampleCount < (end - start + 1) * ImuSessionFileStore.SAMPLE_RATE) continue
            if (start > cursor) return false
            if (end >= cursor) cursor = end + 1
            if (cursor > to) return true
        }
        return cursor > to
    }

    private fun ceilSecond(epochMs: Long): Long = (epochMs + 999L) / 1_000L

    private fun eventFile(id: String) = File(directory, "session-$id.jsonl")
    private fun append(id: String, value: JSONObject) = eventFile(id).appendText(value.toString() + "\n")

    private fun event(atMs: Long, kind: String) = JSONObject().apply { put("at_ms", atMs); put("kind", kind) }

    private fun publicEvents(events: List<JSONObject>, fromMs: Long, toMs: Long, deviceId: String?): List<JSONObject> =
        buildList {
            add(event(fromMs, "start").apply { deviceId?.let { put("strap_device_id", it) } })
            events.filter { it.optString("kind") == KIND_MARKER && it.optLong("at_ms") in fromMs..toMs }
                .forEach { source -> add(JSONObject().apply {
                    put("at_ms", source.optLong("at_ms")); put("kind", KIND_MARKER)
                    put("marker_id", source.optString("marker_id")); put("marker_type", source.optString("marker_type"))
                    put("text", source.optString("text"))
                }) }
            add(event(toMs, "stop"))
        }.sortedBy { it.optLong("at_ms") }

    private fun eventsJsonl(events: List<JSONObject>) = events.joinToString("\n", postfix = "\n")

    private fun eventsCsv(events: List<JSONObject>): String = buildString {
        append("at_ms,unix_s,kind,marker_id,marker_type,text\n")
        for (e in events) append(listOf(
            e.optLong("at_ms"), e.optLong("at_ms") / 1_000L, e.optString("kind"),
            e.optString("marker_id"), e.optString("marker_type"), e.optString("text"),
        ).joinToString(",") { csv(it.toString()) }).append('\n')
    }

    private fun csv(value: String): String = if (value.any { it == ',' || it == '"' || it == '\n' })
        "\"${value.replace("\"", "\"\"")}\"" else value

    private suspend fun writeV18AuxCsv(
        out: java.io.Writer,
        repo: WhoopRepository,
        deviceId: String,
        from: Long,
        to: Long,
    ): Int {
        out.write(
            "unix_s,record_index,rr_count,cardiac_flags,hr_quality_flags,heart_rate_alt,rr_packed," +
                "cardiac_status,step_cadence,status_word,status_word_1,status_word_2,aux_byte_82," +
                "optical_baseline_a,optical_baseline_b,optical_amp_a,optical_amp_b,unknown_f32_bits\n",
        )
        if (from > to || deviceId.isBlank()) return 0
        val seconds = (to - from + 1L).coerceIn(1L, 86_400L).toInt()
        val rows = repo.v18AuxSamples(deviceId, from, to, seconds)
        for (row in rows) {
            out.write((listOf(row.ts) + row.slotValues.map { it ?: "" }).joinToString(","))
            out.write("\n")
        }
        return rows.size
    }

    private fun android.content.SharedPreferences.Editor.clearCurrentSession() = apply {
        remove("active")
        remove("exported")
        remove("sessionId")
        remove("deviceId")
        remove("startedAtMs")
        remove("endedAtMs")
    }

    private fun sessionDeviceKey(id: String) = "session.$id.deviceId"
    private fun sessionStartKey(id: String) = "session.$id.startedAtMs"
    private fun sessionEndKey(id: String) = "session.$id.endedAtMs"
    private fun sessionCommentKey(id: String) = "session.$id.comment"
    private fun sessionExportedKey(id: String) = "session.$id.exported"
    private fun sessionLastExportKey(id: String) = "session.$id.lastExportedAtMs"
    private fun sessionUsedStartKey(id: String) = "session.$id.usedStartedAtMs"
    private fun sessionUsedEndKey(id: String) = "session.$id.usedEndedAtMs"
    private fun sessionCaptureKey(id: String) = "session.$id.hasRealtimeCapture"

    private fun ZipOutputStream.writerEntry(text: String) {
        write(text.toByteArray(Charsets.UTF_8)); closeEntry()
    }

    /** A Writer whose close only flushes, because closing it must not close the surrounding ZIP. */
    private fun ZipOutputStream.bufferedWriterNoClose() = object : java.io.OutputStreamWriter(this, Charsets.UTF_8) {
        override fun close() = flush()
    }.buffered()

    companion object {
        private const val KIND_MARKER = "marker"
        private const val PREFS = "noop_ground_truth_collector"
        private const val MAX_RANGE_MS = 7L * 24 * 60 * 60 * 1_000

        fun from(context: Context) = GroundTruthCollector(context.applicationContext)
    }
}
