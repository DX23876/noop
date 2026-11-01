package com.noop.location

import android.content.Context
import java.io.File

/**
 * One accepted GPS fix of a recorded workout: position, the fix's own time and, when the phone has a
 * barometer, its height. The twin of iOS `WorkoutRoutePoint`. The stored polyline on the workout row keeps
 * only latitude and longitude; these points are what lets an export or Health Connect carry real pace and
 * height instead of times spread evenly across the session.
 */
data class RoutePoint(val lat: Double, val lon: Double, val tMs: Long, val altitudeM: Double? = null)

/**
 * The measured points of each recorded route, one small file per workout under `filesDir/route-points`,
 * keyed like iOS `RouteStore` by the row's natural key (start second and sport). A side store rather than a
 * column: the points are written once when a workout ends and only read by an export or a Health Connect
 * write, never by a list or a chart. A missing file is an older workout or one without GPS, and readers fall
 * back to the polyline.
 */
object RoutePointStore {

    private const val DIR = "route-points"

    fun save(context: Context, startTs: Long, sport: String, points: List<RoutePoint>) {
        if (points.size < 2) return
        runCatching {
            val dir = File(context.filesDir, DIR).apply { mkdirs() }
            File(dir, fileName(startTs, sport)).writeText(encode(points))
        }
    }

    fun load(context: Context, startTs: Long, sport: String): List<RoutePoint>? = runCatching {
        val file = File(File(context.filesDir, DIR), fileName(startTs, sport))
        if (file.exists()) decode(file.readText()).takeIf { it.size >= 2 } else null
    }.getOrNull()

    /** The file for one workout. The sport is reduced to letters and digits so any name is a safe path. */
    fun fileName(startTs: Long, sport: String): String =
        "$startTs-${sport.filter { it.isLetterOrDigit() }.lowercase()}.csv"

    /** One line per point: `tMs,lat,lon,altitude` with an empty altitude when none was measured. */
    fun encode(points: List<RoutePoint>): String = buildString {
        for (p in points) {
            append(p.tMs).append(',').append(p.lat).append(',').append(p.lon).append(',')
            p.altitudeM?.let { append(it) }
            append('\n')
        }
    }

    /** The inverse of [encode]. A malformed line is skipped rather than failing the whole route. */
    fun decode(text: String): List<RoutePoint> = text.lineSequence().mapNotNull { line ->
        val parts = line.split(',')
        if (parts.size != 4) return@mapNotNull null
        val tMs = parts[0].toLongOrNull() ?: return@mapNotNull null
        val lat = parts[1].toDoubleOrNull() ?: return@mapNotNull null
        val lon = parts[2].toDoubleOrNull() ?: return@mapNotNull null
        RoutePoint(lat, lon, tMs, parts[3].toDoubleOrNull())
    }.toList()
}
