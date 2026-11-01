package com.noop.ui

import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.core.content.FileProvider
import com.noop.analytics.RouteMath
import com.noop.core.SwiftCore
import com.noop.data.WorkoutRow
import com.noop.ingest.RouteExport
import com.noop.location.RoutePointStore
import org.json.JSONArray
import org.json.JSONObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Share a recorded workout route as a GPX/FIT file — the UI-layer wrapper around the pure
 * [com.noop.ingest.RouteExport] builder (which stays Android-free/JVM-testable). Mirrors
 * [LogExport.shareStrapLog]: write the bytes to a shared cache subdir, then hand a FileProvider URI to a
 * chooser. The Swift twin is `WorkoutDetailView.exportRoute`.
 *
 * The file is built by the shared Swift `RouteExporter` (core op `export.route`), so it carries the measured
 * point times and heights from [RoutePointStore] and, in a FIT, the session's heart-rate curve, as on iOS.
 * Without the core the Kotlin [RouteExport] builds the older lat/lon-only file.
 */
object RouteExportShare {

    suspend fun share(
        context: Context,
        format: RouteExport.Format,
        track: List<RouteMath.LatLng>,
        row: WorkoutRow,
    ) {
        runCatching {
            // Named like iOS `WorkoutFileExport`: a file without a track is a workout, not a route.
            val filename = "${if (track.size >= 2) "noop-route" else "noop-workout"}-${row.startTs}.${format.ext}"
            // Build the file AND write it off the main thread — a long route (10k+ points) is a non-trivial
            // string/byte build, and file IO must never block the UI. Only the chooser launch stays on Main.
            val file = withContext(Dispatchers.IO) {
                val out = File(File(context.cacheDir, "exports").apply { mkdirs() }, filename)
                if (!exportThroughCore(context, format, track, row, out)) {
                    val points = track.map { RouteExport.Point(it.lat, it.lon) }
                    val bytes = RouteExport.render(
                        format, points, row.startTs, row.endTs, row.sport,
                        distanceM = row.distanceM, energyKcal = row.energyKcal, avgHr = row.avgHr, maxHr = row.maxHr,
                    )
                    out.writeBytes(bytes)
                }
                out
            }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val mime = if (format == RouteExport.Format.GPX) "application/gpx+xml" else "application/octet-stream"
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, "NOOP workout route")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(send, "Share route"))
        }.onFailure {
            Toast.makeText(context, "Couldn't export the route: ${it.message}", Toast.LENGTH_LONG).show()
        }
    }

    /** Ask the core to write the file; false when it is not loaded or did not write, so the caller falls back. */
    private fun exportThroughCore(
        context: Context,
        format: RouteExport.Format,
        track: List<RouteMath.LatLng>,
        row: WorkoutRow,
        out: File,
    ): Boolean {
        if (!SwiftCore.available) return false
        // Measured points only when they are the same fixes as the polyline the map shows.
        val measured = RoutePointStore.load(context, row.startTs, row.sport)?.takeIf { it.size == track.size }
        val args = JSONObject()
            .put("format", if (format == RouteExport.Format.GPX) "gpx" else "fit")
            .put("path", out.absolutePath)
            .put("startTs", row.startTs).put("endTs", row.endTs)
            .put("sport", row.sport).put("source", row.source)
            .put("lat", JSONArray(track.map { it.lat })).put("lon", JSONArray(track.map { it.lon }))
        row.distanceM?.let { args.put("distanceM", it) }
        row.energyKcal?.let { args.put("energyKcal", it) }
        row.avgHr?.let { args.put("avgHr", it) }
        row.maxHr?.let { args.put("maxHr", it) }
        if (measured != null) {
            args.put("timesMs", JSONArray(measured.map { it.tMs }))
            args.put("altitudes", JSONArray(measured.map { it.altitudeM ?: JSONObject.NULL }))
        }
        val answer = runCatching { SwiftCore.call("export.route", args.toString()) }.getOrNull() ?: return false
        return runCatching { JSONObject(answer).optBoolean("ok") }.getOrDefault(false) && out.length() > 0
    }
}
