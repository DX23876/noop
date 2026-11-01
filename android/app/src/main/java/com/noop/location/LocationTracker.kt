package com.noop.location

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Looper
import com.noop.analytics.RouteMath
import com.noop.analytics.RouteMath.LatLng
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/** A raw GPS reading before filtering. */
data class RawFix(val lat: Double, val lon: Double, val accuracyM: Float, val tMs: Long)

/**
 * Pure, stateful filter: drops low-accuracy fixes and physically-impossible jumps, returns the
 * accepted [LatLng] or null. Keeps the last accepted fix to gate the next. Unit-tested.
 */
class TrackFilter(
    // 50 m is the realistic consumer-GPS gate during activity (Strava-class apps use ~50 m). The old
    // 30 m gate dropped most fixes on a weak-signal run, so a real 24-min run banked only 2 points and
    // ~38 m of distance (#324). The speed gate below still rejects teleports, so the looser accuracy
    // gate admits legitimate running fixes without letting GPS jumps inflate the track.
    private val maxAccuracyM: Float = 50f,
    private val maxSpeedMps: Double = 12.0, // ~43 km/h; well above running, below GPS teleports
) {
    private var last: RawFix? = null
    fun accept(fix: RawFix): LatLng? {
        if (fix.accuracyM > maxAccuracyM) return null
        val prev = last
        if (prev != null) {
            val dt = (fix.tMs - prev.tMs) / 1000.0
            if (dt > 0) {
                val d = RouteMath.haversineMeters(LatLng(prev.lat, prev.lon), LatLng(fix.lat, fix.lon))
                if (d / dt > maxSpeedMps) return null
            }
        }
        last = fix
        return LatLng(fix.lat, fix.lon)
    }
}

/**
 * The phone's barometer while a GPS workout runs: the latest height from the air pressure, or null on a
 * phone without one. Pressure gives a smooth height change but its absolute level moves with the weather,
 * so the first fix with a sea-level GPS height (Android 14+) anchors it; without one the standard
 * atmosphere stands, which keeps the climb right and the absolute level approximate. The twin of iOS
 * `WorkoutAltimeter`, which uses Apple's own fusion of the two. No barometer means no height at all, never
 * a GPS-only guess.
 */
private class PressureAltimeter(context: Context) : SensorEventListener {
    private val manager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val sensor = manager?.getDefaultSensor(Sensor.TYPE_PRESSURE)
    @Volatile private var pressureAltitudeM: Double? = null
    private var offsetM: Double? = null

    fun start() { sensor?.let { manager?.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL) } }
    fun stop() { runCatching { manager?.unregisterListener(this) } }

    /** The height to store with [loc], anchoring the pressure scale on its first sea-level GPS height. */
    fun altitudeFor(loc: Location): Double? {
        val raw = pressureAltitudeM ?: return null
        if (offsetM == null && Build.VERSION.SDK_INT >= 34 && loc.hasMslAltitude()) {
            offsetM = loc.mslAltitudeMeters - raw
        }
        return raw + (offsetM ?: 0.0)
    }

    override fun onSensorChanged(event: SensorEvent) {
        val hPa = event.values.firstOrNull() ?: return
        if (hPa > 0f) {
            pressureAltitudeM = SensorManager.getAltitude(SensorManager.PRESSURE_STANDARD_ATMOSPHERE, hPa).toDouble()
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
}

/**
 * Wraps platform GPS. The caller should request ACCESS_FINE_LOCATION before starting a GPS workout
 * (see rememberRequestLocation) — unlike BLE, fine location is NOT implicitly granted on Android 12+.
 * Fails SAFE: if the permission isn't held or the GPS provider is unavailable, the stream just ends
 * with no fixes instead of crashing, so the workout still records HR/strain without a route. (#101)
 */
class LocationTracker(private val context: Context) {
    @SuppressLint("MissingPermission")
    // minDistanceM defaults to 0: let the platform deliver every time-based fix (every minIntervalMs)
    // so TrackFilter does the gating. A non-zero platform minDistance compounds with the accuracy gate
    // and suppressed fixes on a weak-signal run, contributing to the under-collected route (#324).
    // Each accepted fix carries its own time and, with a barometer, its height (see [PressureAltimeter]).
    fun stream(minIntervalMs: Long = 2000, minDistanceM: Float = 0f): Flow<RoutePoint> = callbackFlow {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val filter = TrackFilter()
        val altimeter = PressureAltimeter(context).apply { start() }
        val listener = LocationListener { loc: Location ->
            filter.accept(RawFix(loc.latitude, loc.longitude, if (loc.hasAccuracy()) loc.accuracy else 0f, loc.time))
                ?.let { trySend(RoutePoint(it.lat, it.lon, loc.time, altimeter.altitudeFor(loc))) }
        }
        try {
            lm.requestLocationUpdates(
                LocationManager.GPS_PROVIDER, minIntervalMs, minDistanceM, listener, Looper.getMainLooper(),
            )
        } catch (t: Throwable) {
            // SecurityException (ACCESS_FINE_LOCATION not held), IllegalArgumentException (no GPS
            // provider on this device), or an OEM quirk — never propagate out of the collecting
            // coroutine and crash the app. End the route stream cleanly. (#101)
            altimeter.stop()
            close()
            return@callbackFlow
        }
        awaitClose {
            runCatching { lm.removeUpdates(listener) }
            altimeter.stop()
        }
    }
}
