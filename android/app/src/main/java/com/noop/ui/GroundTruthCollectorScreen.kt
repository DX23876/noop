package com.noop.ui

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.testcentre.GroundTruthCollector
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Bounded 5/MG raw-data capture. */
@Composable
fun GroundTruthCollectorScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val collector = remember { GroundTruthCollector.from(context) }
    val scope = rememberCoroutineScope()
    val live by vm.live.collectAsStateWithLifecycle()
    val imuStatus by vm.ble.groundTruthImuStatus.collectAsStateWithLifecycle()
    var state by remember { mutableStateOf(collector.snapshot()) }
    var exportingSessionId by remember { mutableStateOf<String?>(null) }
    var sessions by remember { mutableStateOf(collector.sessions()) }
    var latestSensorTs by remember { mutableStateOf<Long?>(null) }
    var nowMs by remember { mutableStateOf(System.currentTimeMillis()) }
    var captureStats by remember { mutableStateOf<Map<String, GroundTruthCollector.CaptureStats>>(emptyMap()) }
    var markerEditor by remember { mutableStateOf<MarkerEditor?>(null) }
    var sessionPendingDelete by remember { mutableStateOf<GroundTruthCollector.SessionSummary?>(null) }
    var confirmDeleteAll by remember { mutableStateOf(false) }

    LaunchedEffect(vm.activeStrapId) {
        while (true) {
            nowMs = System.currentTimeMillis()
            latestSensorTs = vm.activeStrapId.takeIf(String::isNotBlank)?.let { vm.repo.latestHrSampleTs(it) }
            captureStats = withContext(Dispatchers.IO) {
                sessions.associate { it.id to collector.captureStats(it, nowMs) }
            }
            delay(1_000)
        }
    }

    // Re-arm after a BLE reconnect or Android process restart while the manual session is still active.
    LaunchedEffect(state.active, state.sessionId, live.connected) {
        if (state.active && live.connected) state.sessionId?.let(vm.ble::startGroundTruthImuCapture)
    }

    ScreenScaffold(
        title = stringResource(R.string.ground_truth_title),
        subtitle = stringResource(R.string.ground_truth_subtitle),
    ) {
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                val activeSession = sessions.firstOrNull { it.active }
                val activeStats = activeSession?.let { captureStats[it.id] }
                Text(if (activeSession == null) stringResource(R.string.ground_truth_capture_status)
                    else stringResource(R.string.ground_truth_recording, formatDuration(nowMs - activeSession.startedAtMs)),
                    style = NoopType.headline, color = Palette.textPrimary)
                if (activeStats != null) Text(
                    stringResource(R.string.ground_truth_imu_coverage, formatBytes(activeStats.bytes), coverageText(activeStats)),
                    style = NoopType.body,
                    color = if (activeStats.coveredSeconds > 0) Palette.statusPositive else Palette.textSecondary,
                )
                Text(
                    stringResource(when {
                        live.connected && live.bonded -> R.string.ground_truth_band_connected_paired
                        live.connected -> R.string.ground_truth_band_connected_pairing
                        live.scanning -> R.string.ground_truth_band_searching
                        else -> R.string.ground_truth_band_disconnected
                    }),
                    style = NoopType.body,
                    color = if (live.connected) Palette.statusPositive else Palette.statusCritical,
                )
                Text(
                    when {
                        live.backfilling -> stringResource(R.string.ground_truth_history_running, live.syncChunksThisSession)
                        live.lastSyncAt != null -> stringResource(R.string.ground_truth_history_completed, diagnosticTime(live.lastSyncAt!! * 1000))
                        else -> stringResource(R.string.ground_truth_history_none)
                    },
                    style = NoopType.body,
                    color = Palette.textSecondary,
                )
                Text(
                    latestSensorTs?.let { stringResource(R.string.ground_truth_sensors_behind, diagnosticAge(it * 1000)) }
                        ?: stringResource(R.string.ground_truth_sensors_none),
                    style = NoopType.caption,
                    color = Palette.textSecondary,
                )
                Text(
                    stringResource(R.string.ground_truth_realtime_imu, imuStatus.note, imuStatus.packets, imuStatus.bytes,
                        imuStatus.lastPacketAtMs?.let { stringResource(R.string.ground_truth_realtime_last, diagnosticAge(it)) }.orEmpty()),
                    style = NoopType.body,
                    color = if (imuStatus.packets > 0) Palette.statusPositive else Palette.textSecondary,
                )
            }
        }

        if (state.active) {
            NoopButton(
                text = stringResource(R.string.ground_truth_add_marker),
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                onClick = { state.sessionId?.let { markerEditor = MarkerEditor(it, null, nowMs, MARKER_MOMENT, "") } },
            )
            NoopButton(text = stringResource(R.string.ground_truth_stop), kind = NoopButtonKind.Destructive,
                fullWidth = true, onClick = {
                    state = collector.stop(); vm.ble.stopGroundTruthImuCapture(); sessions = collector.sessions()
                })
        } else {
            NoopButton(
                text = stringResource(R.string.ground_truth_start),
                fullWidth = true,
                enabled = vm.activeStrapId.isNotBlank(),
                onClick = {
                    state = collector.start(vm.activeStrapId)
                    sessions = collector.sessions()
                },
            )
        }
        NoopButton(
            text = stringResource(R.string.ground_truth_add_historical),
            kind = NoopButtonKind.Secondary,
            fullWidth = true,
            enabled = !state.active && vm.activeStrapId.isNotBlank(),
            onClick = {
                val end = System.currentTimeMillis()
                collector.createHistoricalSession(vm.activeStrapId, end - 60 * 60 * 1_000L, end)
                sessions = collector.sessions()
            },
        )
        Text(stringResource(R.string.ground_truth_sessions), style = NoopType.title2, color = Palette.textPrimary)
        if (sessions.isEmpty()) {
            Text(stringResource(R.string.ground_truth_no_sessions), style = NoopType.body, color = Palette.textSecondary)
        } else {
            NoopButton(
                text = stringResource(R.string.ground_truth_delete_all),
                kind = NoopButtonKind.Destructive,
                fullWidth = true,
                enabled = sessions.none { it.active },
                onClick = { confirmDeleteAll = true },
            )
            sessions.forEach { session ->
                SessionCard(
                    session = session,
                    latestSensorTs = latestSensorTs,
                    stats = captureStats[session.id],
                    exporting = exportingSessionId == session.id,
                    onComment = { comment ->
                        collector.setComment(session.id, comment)
                        sessions = sessions.map { if (it.id == session.id) it.copy(comment = comment) else it }
                    },
                    onExport = {
                        exportingSessionId = session.id
                        scope.launch {
                            try {
                                collector.share(collector.export(vm.repo, session.id))
                                vm.ble.finishGroundTruthImuCapture(session.id)
                                sessions = collector.sessions()
                            } catch (failure: Throwable) {
                                if (failure is kotlinx.coroutines.CancellationException) throw failure
                                Toast.makeText(context, context.getString(R.string.ground_truth_export_failed,
                                    "${failure.javaClass.simpleName}: ${failure.message ?: "unknown error"}"), Toast.LENGTH_LONG).show()
                            } finally {
                                exportingSessionId = null
                            }
                        }
                    },
                    onDelete = { sessionPendingDelete = session },
                    onAddMarker = { markerEditor = MarkerEditor(session.id, null, session.endedAtMs ?: nowMs, MARKER_MOMENT, "") },
                    onEditMarker = { marker -> markerEditor = MarkerEditor(session.id, marker.id, marker.atMs, marker.type, marker.text) },
                    onEditStart = {
                        pickDateTime(context, session.startedAtMs, EARLIEST_EXPORT_MS,
                            session.endedAtMs ?: session.capturedEndedAtMs ?: session.startedAtMs) { value ->
                            collector.setSessionRange(session.id, value, requireNotNull(session.endedAtMs))
                            sessions = collector.sessions()
                        }
                    },
                    onEditEnd = {
                        pickDateTime(context, requireNotNull(session.endedAtMs), session.startedAtMs,
                            System.currentTimeMillis()) { value ->
                            collector.setSessionRange(session.id, session.startedAtMs, value)
                            sessions = collector.sessions()
                        }
                    },
                )
            }
        }
    }

    sessionPendingDelete?.let { session ->
        AlertDialog(
            onDismissRequest = { sessionPendingDelete = null },
            title = { Text(stringResource(R.string.ground_truth_delete_session_title)) },
            text = { Text(stringResource(R.string.ground_truth_delete_session_message, sessionTimeRange(session))) },
            dismissButton = {
                TextButton(onClick = { sessionPendingDelete = null }) {
                    Text(stringResource(R.string.ground_truth_cancel))
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    vm.ble.finishGroundTruthImuCapture(session.id)
                    collector.deleteSession(session.id)
                    sessions = collector.sessions()
                    state = collector.snapshot()
                    sessionPendingDelete = null
                }) {
                    Text(stringResource(R.string.ground_truth_delete_confirm), color = Palette.statusCritical)
                }
            },
        )
    }

    if (confirmDeleteAll) {
        AlertDialog(
            onDismissRequest = { confirmDeleteAll = false },
            title = { Text(stringResource(R.string.ground_truth_delete_all_title)) },
            text = { Text(stringResource(R.string.ground_truth_delete_all_message, sessions.size)) },
            dismissButton = {
                TextButton(onClick = { confirmDeleteAll = false }) {
                    Text(stringResource(R.string.ground_truth_cancel))
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    sessions.forEach { vm.ble.finishGroundTruthImuCapture(it.id) }
                    collector.deleteAllSessions()
                    sessions = collector.sessions()
                    state = collector.snapshot()
                    confirmDeleteAll = false
                }) {
                    Text(stringResource(R.string.ground_truth_delete_confirm), color = Palette.statusCritical)
                }
            },
        )
    }

    markerEditor?.let { editor ->
        val markerSession = sessions.firstOrNull { it.id == editor.sessionId }
        val markerNowMs = if (markerSession?.active == true) nowMs else markerSession?.endedAtMs ?: nowMs
        AlertDialog(
            onDismissRequest = { markerEditor = null },
            title = { Text(stringResource(if (editor.markerId == null) R.string.ground_truth_add_marker else R.string.ground_truth_edit_marker)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        stringResource(
                            R.string.ground_truth_marker_times,
                            diagnosticTime(editor.atMs),
                            diagnosticTime(markerNowMs),
                        ),
                        style = NoopType.headline,
                    )
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        NoopButton("−10 s", kind = NoopButtonKind.Secondary, modifier = Modifier.weight(1f),
                            onClick = { markerEditor = editor.copy(atMs = editor.atMs - 10_000) })
                        NoopButton(stringResource(R.string.ground_truth_marker_now_button),
                            kind = NoopButtonKind.Secondary, modifier = Modifier.weight(1f),
                            onClick = { markerEditor = editor.copy(atMs = markerNowMs) })
                        NoopButton("+10 s", kind = NoopButtonKind.Secondary, modifier = Modifier.weight(1f),
                            onClick = { markerEditor = editor.copy(atMs = editor.atMs + 10_000) })
                    }
                    listOf(
                        listOf(MARKER_MOMENT to R.string.ground_truth_marker_moment, MARKER_START to R.string.ground_truth_marker_start),
                        listOf(MARKER_END to R.string.ground_truth_marker_end, MARKER_ISSUE to R.string.ground_truth_marker_issue),
                    ).forEach { row ->
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            row.forEach { (type, label) ->
                                NoopButton(stringResource(label),
                                    kind = if (editor.type == type) NoopButtonKind.Primary else NoopButtonKind.Secondary,
                                    modifier = Modifier.weight(1f), onClick = { markerEditor = editor.copy(type = type) })
                            }
                        }
                    }
                    OutlinedTextField(editor.text, { markerEditor = editor.copy(text = it.take(500)) },
                        label = { Text(stringResource(R.string.ground_truth_marker_note)) }, modifier = Modifier.fillMaxWidth(), minLines = 2)
                }
            },
            dismissButton = {
                Row {
                    if (editor.markerId != null) TextButton(onClick = {
                        collector.deleteMarker(editor.sessionId, editor.markerId); sessions = collector.sessions(); markerEditor = null
                    }) { Text(stringResource(R.string.ground_truth_delete_confirm), color = Palette.statusCritical) }
                    TextButton(onClick = { markerEditor = null }) { Text(stringResource(R.string.ground_truth_cancel)) }
                }
            },
            confirmButton = { TextButton(onClick = {
                if (editor.markerId == null) collector.addMarker(editor.sessionId, editor.atMs, editor.type, editor.text)
                else collector.updateMarker(editor.sessionId, GroundTruthCollector.Marker(editor.markerId, editor.atMs, editor.type, editor.text))
                sessions = collector.sessions(); markerEditor = null
            }) { Text(stringResource(R.string.ground_truth_save)) } },
        )
    }
}

@Composable
private fun SessionCard(
    session: GroundTruthCollector.SessionSummary,
    latestSensorTs: Long?,
    stats: GroundTruthCollector.CaptureStats?,
    exporting: Boolean,
    onComment: (String) -> Unit,
    onExport: () -> Unit,
    onDelete: () -> Unit,
    onAddMarker: () -> Unit,
    onEditMarker: (GroundTruthCollector.Marker) -> Unit,
    onEditStart: () -> Unit,
    onEditEnd: () -> Unit,
) {
    val time = remember(session.startedAtMs, session.endedAtMs) { sessionTimeRange(session) }
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            val sensorCovered = session.endedAtMs?.let { end -> latestSensorTs?.times(1000)?.let { it >= end } } == true
            val captureReady = stats?.complete == true
            Text(
                when {
                    session.endedAtMs == null -> stringResource(R.string.ground_truth_recording,
                        stats?.let { coverageText(it) } ?: stringResource(R.string.ground_truth_waiting_imu))
                    captureReady -> stringResource(R.string.ground_truth_ready_complete)
                    stats != null && stats.coveredSeconds > 0 -> stringResource(R.string.ground_truth_ready_missing, stats.missingSeconds)
                    !sensorCovered -> stringResource(R.string.ground_truth_waiting_history, diagnosticTime(requireNotNull(session.endedAtMs)))
                    else -> stringResource(R.string.ground_truth_ready_no_imu)
                },
                style = NoopType.caption,
                color = if (captureReady) Palette.statusPositive else Palette.statusCritical,
            )
            Text(time, style = NoopType.headline, color = Palette.textPrimary)
            Text(stringResource(R.string.ground_truth_duration_size,
                formatDuration((session.endedAtMs ?: System.currentTimeMillis()) - session.startedAtMs), formatBytes(stats?.bytes ?: 0)),
                style = NoopType.caption, color = Palette.textSecondary)
            session.lastExportedAtMs?.let { Text(stringResource(R.string.ground_truth_last_exported, diagnosticTime(it)),
                style = NoopType.caption, color = Palette.statusPositive) }
            if (!session.active) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    NoopButton(
                        text = stringResource(R.string.ground_truth_edit_start),
                        kind = NoopButtonKind.Secondary,
                        modifier = Modifier.weight(1f),
                        onClick = onEditStart,
                    )
                    NoopButton(
                        text = stringResource(R.string.ground_truth_edit_end),
                        kind = NoopButtonKind.Secondary,
                        modifier = Modifier.weight(1f),
                        onClick = onEditEnd,
                    )
                }
            }
            NoopButton(stringResource(R.string.ground_truth_add_marker), kind = NoopButtonKind.Secondary, fullWidth = true, onClick = onAddMarker)
            session.markers.forEach { marker ->
                TextButton(onClick = { onEditMarker(marker) }, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.ground_truth_marker_row, diagnosticTime(marker.atMs),
                        markerTypeLabel(marker.type), marker.text.takeIf(String::isNotBlank)
                            ?.let { stringResource(R.string.ground_truth_marker_note_suffix, it) }.orEmpty()))
                }
            }
            OutlinedTextField(
                value = session.comment,
                onValueChange = onComment,
                label = { Text(stringResource(R.string.ground_truth_comment)) },
                modifier = Modifier.fillMaxWidth(),
                minLines = 2,
                maxLines = 4,
            )
            if (session.deviceId == null) {
                Text(stringResource(R.string.ground_truth_legacy_no_sensors), style = NoopType.caption, color = Palette.textSecondary)
            }
            NoopButton(
                text = if (exporting) stringResource(R.string.ground_truth_exporting) else stringResource(R.string.ground_truth_export),
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                enabled = !session.active && !exporting,
                onClick = onExport,
            )
            NoopButton(
                text = stringResource(R.string.ground_truth_delete_session),
                kind = NoopButtonKind.Destructive,
                fullWidth = true,
                enabled = !session.active && !exporting,
                onClick = onDelete,
            )
        }
    }
}

private fun sessionTimeRange(session: GroundTruthCollector.SessionSummary): String {
    val date = java.text.DateFormat.getDateInstance(java.text.DateFormat.SHORT)
    val time = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT)
    val from = java.util.Date(session.startedAtMs)
    val to = session.endedAtMs?.let { java.util.Date(it) }
    return if (to == null) {
        "${date.format(from)} · ${time.format(from)}–…"
    } else {
        "${date.format(from)} · ${time.format(from)}–${time.format(to)}"
    }
}

private fun pickDateTime(
    context: Context,
    initialMs: Long,
    minimumMs: Long,
    maximumMs: Long,
    onPicked: (Long) -> Unit,
) {
    val initial = java.util.Calendar.getInstance().apply { timeInMillis = initialMs }
    val dateDialog = DatePickerDialog(context, { _, year, month, day ->
        TimePickerDialog(context, { _, hour, minute ->
            val picked = java.util.Calendar.getInstance().apply {
                set(year, month, day, hour, minute, 0)
                set(java.util.Calendar.MILLISECOND, 0)
            }.timeInMillis.coerceIn(minimumMs, maximumMs)
            onPicked(picked)
        }, initial.get(java.util.Calendar.HOUR_OF_DAY), initial.get(java.util.Calendar.MINUTE),
            android.text.format.DateFormat.is24HourFormat(context)).show()
    }, initial.get(java.util.Calendar.YEAR), initial.get(java.util.Calendar.MONTH),
        initial.get(java.util.Calendar.DAY_OF_MONTH))
    dateDialog.datePicker.minDate = minimumMs
    dateDialog.datePicker.maxDate = maximumMs
    dateDialog.show()
}

private fun diagnosticTime(epochMs: Long): String =
    java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault()).format(java.util.Date(epochMs))

private fun diagnosticAge(epochMs: Long): String {
    val seconds = ((System.currentTimeMillis() - epochMs).coerceAtLeast(0L) / 1_000L)
    return when {
        seconds < 60 -> "${seconds}s"
        seconds < 3_600 -> "${seconds / 60}m ${seconds % 60}s"
        else -> "${seconds / 3_600}h ${(seconds % 3_600) / 60}m"
    }
}

private data class MarkerEditor(
    val sessionId: String,
    val markerId: String?,
    val atMs: Long,
    val type: String,
    val text: String,
)

private fun formatDuration(milliseconds: Long): String {
    val seconds = milliseconds.coerceAtLeast(0) / 1_000
    val hours = seconds / 3_600
    val minutes = (seconds % 3_600) / 60
    val tail = seconds % 60
    return if (hours > 0) "%d:%02d:%02d".format(hours, minutes, tail) else "%d:%02d".format(minutes, tail)
}

private fun formatBytes(bytes: Long): String = when {
    bytes >= 1024L * 1024L -> "%.1f MB".format(bytes / (1024.0 * 1024.0))
    bytes >= 1024L -> "%.1f KB".format(bytes / 1024.0)
    else -> "$bytes B"
}

@Composable
private fun coverageText(stats: GroundTruthCollector.CaptureStats): String {
    val percent = if (stats.expectedSeconds == 0) 0.0 else 100.0 * stats.coveredSeconds / stats.expectedSeconds
    val startup = if (stats.startupSeconds > 0) stringResource(R.string.ground_truth_coverage_startup, stats.startupSeconds) else ""
    return stringResource(R.string.ground_truth_coverage, stats.coveredSeconds, stats.expectedSeconds,
        percent, stats.missingSeconds, startup)
}

@Composable
private fun markerTypeLabel(type: String): String = stringResource(when (type.lowercase()) {
    MARKER_START -> R.string.ground_truth_marker_start
    MARKER_END -> R.string.ground_truth_marker_end
    MARKER_ISSUE -> R.string.ground_truth_marker_issue
    else -> R.string.ground_truth_marker_moment
})

private const val MARKER_MOMENT = "moment"
private const val MARKER_START = "start"
private const val MARKER_END = "end"
private const val MARKER_ISSUE = "issue"

private const val EARLIEST_EXPORT_MS = 946_684_800_000L
