package com.noop.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat

/**
 * The runtime permissions a BLE scan needs on this OS version. Android 12+ (API 31) uses the
 * granular Bluetooth permissions; API <= 30 falls back to fine location, which the platform
 * requires before it will hand back BLE scan results.
 */
fun blePermissions(): Array<String> =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    else
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

/**
 * Returns a callback that starts a scan, first requesting the runtime Bluetooth permission if it
 * isn't already granted. This is the single source of truth for "tap a button → scan" across the
 * app (Live, Settings, onboarding), so no screen can forget the gate.
 *
 * Why this exists (issue #1): a button that calls `vm.connect()` directly silently no-ops on
 * Android 12+ when the permission was denied or revoked — `startScan()` throws SecurityException,
 * the BLE layer swallows it into a status note, and no prompt is ever shown. The user taps and
 * nothing happens (the exact Pixel 9 report). Requesting the permission *before* connecting fixes
 * that. On grant the launcher calls [onGranted]; on denial, connect() still surfaces the explanatory
 * status note rather than failing silently.
 *
 * This belongs in the Compose layer, not the ViewModel: only an Activity-scoped launcher can raise
 * the system permission dialog. The ViewModel has no launcher and would just re-introduce the
 * silent no-op.
 */
@Composable
fun rememberRequestScan(onGranted: () -> Unit): () -> Unit {
    val context = LocalContext.current
    val perms = remember { blePermissions() }
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { onGranted() }
    return {
        val granted = perms.all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
        if (granted) onGranted() else launcher.launch(perms)
    }
}

/**
 * The runtime permissions needed to BROADCAST as a BLE peripheral on this OS version. Android 12+
 * (API 31) needs BLUETOOTH_ADVERTISE (to advertise) plus BLUETOOTH_CONNECT (to run the GATT server);
 * API <= 30 used the install-time BLUETOOTH/BLUETOOTH_ADMIN perms, so there's nothing to request.
 */
fun bleAdvertisePermissions(): Array<String> =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
        arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
    else
        emptyArray()

/**
 * Returns a callback that enables HR broadcasting, first requesting BLUETOOTH_ADVERTISE (+ CONNECT) on
 * Android 12+ if they aren't already granted. Mirrors [rememberRequestScan]: the launcher must live in
 * the Compose layer so it can raise the system dialog, and the "Broadcast heart rate" toggle calls this
 * before turning the peripheral on. On grant (or on pre-12, where the perms are install-time) it calls
 * [onGranted]; on denial the toggle stays off and the broadcaster surfaces a status note rather than
 * failing silently.
 */
@Composable
fun rememberRequestAdvertise(onGranted: () -> Unit): () -> Unit {
    val context = LocalContext.current
    val perms = remember { bleAdvertisePermissions() }
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { results ->
        // Enable only if every requested permission was granted; otherwise leave the toggle off.
        if (results.values.all { it }) onGranted()
    }
    return {
        val granted = perms.all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
        if (granted) onGranted() else launcher.launch(perms)
    }
}

/**
 * Requests ACCESS_FINE_LOCATION (needed for GPS-tracked workouts) and reports the outcome. Unlike
 * the BLE permissions, fine location is NOT implicitly granted on Android 12+ — BLE uses the granular
 * Bluetooth permissions there — so a GPS workout must request it explicitly before starting, or
 * `requestLocationUpdates` throws SecurityException and crashes the app. Mirrors [rememberRequestScan];
 * the launcher must live in the Compose layer so it can raise the system dialog. (#101)
 */
@Composable
fun rememberRequestLocation(onResult: (granted: Boolean) -> Unit): () -> Unit {
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted -> onResult(granted) }
    return {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
            == PackageManager.PERMISSION_GRANTED
        ) {
            onResult(true)
        } else {
            launcher.launch(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }
}
