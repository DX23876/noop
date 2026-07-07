package com.noop.testcentre

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager

/**
 * The Android environment-header block (spec section 3.4), bringing Android to the same shape as the iOS
 * IOSDiagnostics. macOS and Android emit almost nothing today; this carries the variables that quietly
 * break a background BLE health app: Doze / battery-optimisation exemption, OEM-kill heuristics, the
 * permission-grant state, the charging state, and the Build identity.
 *
 * TOTAL and best-effort: every probe is guarded so a header build never throws into the export. Degrades
 * gracefully, never fabricates a value it can't read.
 */
object AndroidDiagnostics {

    fun summaryLines(context: Context): List<String> = buildList {
        add("Device: ${Build.MANUFACTURER} ${Build.MODEL}")
        add("Android: ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})")
        add("Battery optimisation: ${batteryOptimisationText(context)}")
        add("OEM background kill: ${oemKillHeuristic(Build.MANUFACTURER)}")
        add("Charging: ${chargingText(context)}")
        add("Permissions: ${permissionsText(context)}")
    }

    /**
     * Strap identity + data-state lines for the debug export. Offline-safe: reads persisted prefs and the
     * canonical "my-whoop" daily spine, so it works from the scheduled background export too. Model,
     * last-known firmware, last-sync, timezone, days of history, and the most recent sleep + recovery day.
     * Best-effort: guarded so it never throws into the export.
     */
    suspend fun strapAndDataLines(context: Context): List<String> = buildList {
        add("─".repeat(40))
        add("Strap & data")
        runCatching {
            val dev = com.noop.ui.NoopPrefs.lastDevice(context)
            add("Model:       ${dev?.second?.displayName ?: "unknown (never paired)"}")
            add("Firmware:    ${com.noop.ui.NoopPrefs.lastFirmware(context) ?: "unknown (connect to record)"}")
            val syncSec = com.noop.ui.NoopPrefs.lastSyncAt(context)
            add("Last sync:   ${if (syncSec > 0L) relTime(System.currentTimeMillis() - syncSec * 1000L) else "never"}")
            add("Timezone:    ${tzLine()}")
            val repo = com.noop.data.WhoopRepository.from(context)
            val days = repo.days("my-whoop")
            add("History:     ${days.size} day rows (my-whoop spine)")
            add("Last sleep:  ${days.lastOrNull { (it.totalSleepMin ?: 0.0) > 0.0 }?.let { "${it.day} · ${it.totalSleepMin?.toInt()} min" } ?: "none"}")
            add("Last recov.: ${days.lastOrNull { it.recovery != null }?.let { "${it.day} · ${it.recovery?.toInt()}%" } ?: "none"}")
        }.onFailure { add("(strap/data state unavailable: ${it.message})") }
    }

    /**
     * Analytics-funnel lines: recompute the REM + skin-temp funnels for the most recent night so a "0% REM"
     * / "skin temp absent" report arrives with the funnel breakdown. BEST-EFFORT and self-reporting — it
     * prints the sample counts it read and says plainly when it can't compute (e.g. a freshly re-added strap
     * whose raw samples aren't yet under the canonical id), so it never fabricates a misleading verdict.
     */
    suspend fun funnelLines(context: Context): List<String> = buildList {
        add("─".repeat(40))
        add("Analytics funnels (latest night, best-effort)")
        runCatching {
            val repo = com.noop.data.WhoopRepository.from(context)
            val id = "my-whoop"
            val nowSec = System.currentTimeMillis() / 1000L
            val session = repo.sleepSessions(id, nowSec - 14L * 86400L, nowSec, 1).lastOrNull()
            if (session == null) {
                add("(no sleep session in the last 14 days to analyze)")
                return@runCatching
            }
            val grav = repo.gravitySamples(id, session.startTs, session.endTs, Int.MAX_VALUE)
            val hr = repo.hrSamples(id, session.startTs, session.endTs, Int.MAX_VALUE)
            val rr = repo.rrIntervals(id, session.startTs, session.endTs, Int.MAX_VALUE)
            val resp = repo.respSamples(id, session.startTs, session.endTs, Int.MAX_VALUE)
            val skin = repo.skinTempSamples(id, session.startTs, session.endTs, Int.MAX_VALUE)
            add("Night ${dayStamp(session.startTs)}: grav=${grav.size} hr=${hr.size} rr=${rr.size} resp=${resp.size} skin=${skin.size}")
            if (grav.isEmpty() && hr.isEmpty()) {
                add("(no raw biometric samples under '$id' for this night — expected on a freshly re-added strap; reconnect + let a history sync run, then re-export)")
                return@runCatching
            }
            com.noop.analytics.SleepStager.remFunnelDiagnostic(session.startTs, session.endTs, grav, hr, rr, resp)
                ?.let { add(it.summary) } ?: add("REM funnel: insufficient motion data (<2 gravity samples)")
            val det = com.noop.analytics.DetectedSleep(
                start = session.startTs, end = session.endTs,
                efficiency = session.efficiency ?: 0.0, stages = emptyList(),
                restingHR = session.restingHr, avgHRV = session.avgHrv,
            )
            val family = if (com.noop.ui.NoopPrefs.lastDevice(context)?.second == com.noop.ble.WhoopModel.WHOOP5_MG)
                com.noop.protocol.DeviceFamily.WHOOP5 else com.noop.protocol.DeviceFamily.WHOOP4
            add(com.noop.analytics.AnalyticsEngine.skinTempFunnel(listOf(det), hr, skin, family).summary)
        }.onFailure { add("(funnels unavailable: ${it.message})") }
    }

    /** Workout & imported-activity source breakdown. The "counted but not shown" bug class (#28: strap
     *  workouts banked under "my-whoop" while the load queried the active strap id; #29: "activity-file"
     *  imports the load path never read) is invisible in a strap log without this. Surfaces the RESOLVED
     *  active deviceId + a per-source STORED workout count + the most-recent workout, so a report reveals
     *  WHERE workouts live vs what the Workouts screen loads. Best-effort. */
    suspend fun workoutSourceLines(context: Context): List<String> = buildList {
        add("─".repeat(40))
        add("Workouts by source")
        runCatching {
            val repo = com.noop.data.WhoopRepository.from(context)
            val now = System.currentTimeMillis() / 1000
            val active = runCatching {
                (context.applicationContext as com.noop.NoopApplication).activeDeviceId
            }.getOrNull() ?: "unknown"
            add("Active deviceId: $active" + if (active == "my-whoop") "" else "  (imports + spine under my-whoop)")
            // Per-source STORED counts; ids de-duped so a single-WHOOP install (active == my-whoop) lists once.
            val ids = listOf(active, "my-whoop", "$active-noop", "my-whoop-noop",
                "activity-file", "lifting", "apple-health", "health-connect").distinct()
            val perSource = ids.map { it to repo.workouts(it, 0L, now) }
            add("Stored: " + perSource.joinToString("  ") { "${it.first}=${it.second.size}" })
            val latest = perSource.flatMap { it.second }.maxByOrNull { it.startTs }
            add(if (latest != null) "Latest: ${dayStamp(latest.startTs)} · ${latest.sport} (${latest.source})" else "Latest: none")
        }.onFailure { add("(workout sources unavailable: ${it.message})") }
    }

    /** Daily-data source breakdown + on-device volume. The active-strap↔"my-whoop" id mismatch strands
     *  DAYS / steps / sleep / recovery the same way it strands workouts (#28), so a "no data / no steps /
     *  0% REM" report needs the same reconciliation: per-source day counts, which metrics are actually
     *  populated over the recent week, and the raw-row footprint. Best-effort. */
    suspend fun dailyDataLines(context: Context): List<String> = buildList {
        add("─".repeat(40))
        add("Daily data by source")
        runCatching {
            val repo = com.noop.data.WhoopRepository.from(context)
            val active = runCatching {
                (context.applicationContext as com.noop.NoopApplication).activeDeviceId
            }.getOrNull() ?: "unknown"
            val ids = listOf(active, "my-whoop", "$active-noop", "my-whoop-noop",
                "apple-health", "health-connect").distinct()
            val dayCounts = ids.map { it to repo.days(it).size }
            add("Days: " + dayCounts.joinToString("  ") { "${it.first}=${it.second}" })
            // Which metrics are actually populated over the recent week on the imported spine.
            val recent = repo.days("my-whoop").takeLast(7)
            if (recent.isNotEmpty()) {
                val n = recent.size
                add("Recent ${n}d (my-whoop): " +
                    "sleep=${recent.count { (it.totalSleepMin ?: 0.0) > 0 }}/$n  " +
                    "recovery=${recent.count { it.recovery != null }}/$n  " +
                    "steps=${recent.count { it.steps != null }}/$n  " +
                    "kcal=${recent.count { it.activeKcalEst != null }}/$n")
            } else add("Recent: no day rows")
            val dv = repo.dataVolumeSnapshot(active)
            add("Volume: rawRows=${dv.dbRows}  importedDays=${dv.importedDays}  workouts=${dv.workouts}")
        }.onFailure { add("(daily data unavailable: ${it.message})") }
    }

    /** Alarm state for the debug export: the configured wake + the last arm's sent-vs-strap-reports (#34), so
     *  a "didn't buzz" report shows whether the strap accepted the time. Reads persisted prefs (written by
     *  WhoopBleClient.armStrapAlarm + the GET_ALARM_TIME readback). Best-effort. */
    fun alarmLines(context: Context): List<String> = buildList {
        add("─".repeat(40))
        add("Alarm")
        runCatching {
            val p = com.noop.ui.NoopPrefs.of(context)
            val on = com.noop.ui.NoopPrefs.smartAlarmEnabled(context)
            val mins = com.noop.ui.NoopPrefs.smartAlarmMinutes(context)
            add("Enabled: ${if (on) "yes" else "no"} · set ${"%02d:%02d".format(mins / 60, mins % 60)}")
            // #3: model + the 5/MG experimental gate (a 5/MG firmware alarm is NOT armed unless it's on).
            if (com.noop.ui.NoopPrefs.lastDevice(context)?.second == com.noop.ble.WhoopModel.WHOOP5_MG) {
                val exp = com.noop.ble.PuffinExperiment.from(context).isEnabled
                add("Model: WHOOP 5.0/MG · experimental: ${if (exp) "on" else "off → firmware alarm NOT armed"}")
            } else {
                add("Model: WHOOP 4.0")
            }
            // #4: strap clock health — a reset/stale clock (the #34 cause) breaks the alarm even when armed.
            val newest = p.getLong("strap.newestRecordTs", 0L)
            if (newest > 0L) {
                val behind = System.currentTimeMillis() / 1000L - newest
                add(if (behind > 3 * 86400L) "Strap clock: ${behind / 86400L}d behind wall (reset/stale — alarm unreliable)"
                    else "Strap clock: OK")
            }
            val sent = p.getLong("alarm.lastArmSentEpoch", 0L)
            if (sent > 0L) {
                val at = p.getLong("alarm.lastArmAt", 0L)
                var line = "Last arm: sent ${alarmStamp(sent)}"
                if (at > 0L) line += " · ${relTime(System.currentTimeMillis() - at)}"
                if (!p.getBoolean("alarm.lastArmConnected", false)) line += " · strap NOT connected (queued)"
                add(line)
                val reported = p.getLong("alarm.lastReportedEpoch", 0L)
                if (reported > 0L) {
                    val mismatch = kotlin.math.abs(reported - sent) > 120
                    add("Strap reports: ${alarmStamp(reported)}" +
                        if (mismatch) "  ⚠️ MISMATCH — strap didn't accept the time" else "  ✓ matches")
                } else add("Strap reports: (no readback)")
            } else add("Last arm: never")
            // #1: did the strap actually fire? (STRAP_DRIVEN_ALARM_EXECUTED)
            val firedAt = p.getLong("alarm.lastFiredAt", 0L)
            add(if (firedAt > 0L) "Last fired: ${relTime(System.currentTimeMillis() - firedAt)}" else "Last fired: never observed")
        }.onFailure { add("(alarm state unavailable: ${it.message})") }
    }

    private fun alarmStamp(epochSec: Long): String = runCatching {
        java.text.SimpleDateFormat("yyyy-MM-dd HH:mm", java.util.Locale.US).format(epochSec * 1000L)
    }.getOrDefault("?")

    /** The DB/prefs-backed diagnostic lines appended to the export header. Suspends (reads the local store);
     *  guarded per-section so it never throws into the export. */
    suspend fun dynamicLines(context: Context): List<String> =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
            strapAndDataLines(context) + funnelLines(context) + workoutSourceLines(context) +
                dailyDataLines(context) + alarmLines(context)
        }

    /** "3h 12m ago" style relative stamp for a positive age in ms. */
    private fun relTime(deltaMs: Long): String {
        if (deltaMs < 60_000L) return "just now"
        val min = deltaMs / 60_000L
        return when {
            min < 60 -> "${min}m ago"
            min < 1440 -> "${min / 60}h ${min % 60}m ago"
            else -> "${min / 1440}d ago"
        }
    }

    private fun tzLine(): String = runCatching {
        val tz = java.util.TimeZone.getDefault()
        val offMin = tz.getOffset(System.currentTimeMillis()) / 60_000
        val a = kotlin.math.abs(offMin)
        "${tz.id} (UTC${if (offMin >= 0) "+" else "-"}${a / 60}:${"%02d".format(a % 60)})"
    }.getOrDefault("unknown")

    private fun dayStamp(epochSec: Long): String = runCatching {
        java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(epochSec * 1000L)
    }.getOrDefault("?")

    /** Doze exemption: an app NOT exempt from battery optimisation is the #1 cause of missed overnight
     *  background work on Android. */
    private fun batteryOptimisationText(context: Context): String = runCatching {
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        when (pm?.isIgnoringBatteryOptimizations(context.packageName)) {
            true -> "exempt (background work allowed)"
            false -> "NOT exempt (Android may kill overnight background BLE)"
            null -> "unknown"
        }
    }.getOrDefault("unknown")

    /** A coarse OEM-kill heuristic by manufacturer (the aggressive-background-kill vendors). Pure and
     *  internal so it unit-tests without a Context (the suite stays Robolectric-free). */
    internal fun oemKillHeuristic(manufacturer: String): String {
        val m = manufacturer.lowercase()
        val aggressive = listOf("xiaomi", "oppo", "vivo", "huawei", "oneplus", "realme", "meizu")
        return if (aggressive.any { m.contains(it) }) "aggressive vendor ($m), whitelist NOOP to keep it alive"
        else "standard"
    }

    /** Charging state from the sticky battery intent / BatteryManager. */
    private fun chargingText(context: Context): String = runCatching {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        when (bm?.isCharging) {
            true -> "yes"
            false -> "no (on battery)"
            null -> "unknown"
        }
    }.getOrDefault("unknown")

    /** Grant state of the permissions a background strap app needs. */
    private fun permissionsText(context: Context): String {
        val checks = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add("BLUETOOTH_CONNECT" to Manifest.permission.BLUETOOTH_CONNECT)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add("POST_NOTIFICATIONS" to Manifest.permission.POST_NOTIFICATIONS)
            add("LOCATION" to Manifest.permission.ACCESS_FINE_LOCATION)
        }
        return checks.joinToString(", ") { (label, perm) ->
            val granted = runCatching {
                context.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED
            }.getOrDefault(false)
            "$label=${if (granted) "granted" else "denied"}"
        }
    }
}
