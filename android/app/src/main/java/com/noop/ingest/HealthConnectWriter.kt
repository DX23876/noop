package com.noop.ingest

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.units.Energy
import androidx.health.connect.client.units.Length
import androidx.health.connect.client.units.Percentage
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ui.NoopPrefs
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import kotlin.reflect.KClass

/**
 * OPT-IN writeback: pushes NOOP's on-device computed nightly metrics (resting HR, HRV RMSSD, sleep
 * SpO2, respiratory rate) INTO Health Connect, so other apps can see what the strap measured.
 * Inverse of [HealthConnectImporter]; default OFF (NoopPrefs.hcWriteback), toggled in Data Sources.
 *
 * Two deliberate scope limits:
 *  - **Computed days only** (`repo.days(computedDeviceId)`) — never imported ones. Echoing imported
 *    WHOOP-export or Health-Connect-sourced rows back into HC would duplicate another app's data
 *    (or loop our own import). What NOOP computed from the strap is genuinely ours to contribute.
 *  - **Idempotent by clientRecordId** (`noop-<metric>-<day>`): Health Connect does NOT auto-dedupe
 *    on re-insert the way HealthKit does — without a client id every 15-min recompute would stack
 *    duplicates. With it, HC upserts: same id + higher [Metadata.clientRecordVersion] replaces, so
 *    we stamp the version with the write time and the latest computation always wins.
 */
object HealthConnectWriter {

    /** How far back to write. Recomputation only ever touches recent nights; 60 days is generous. */
    private const val WINDOW_DAYS = 60L

    private val WRITE_RECORDS: List<KClass<out Record>> = listOf(
        RestingHeartRateRecord::class,
        HeartRateVariabilityRmssdRecord::class,
        OxygenSaturationRecord::class,
        RespiratoryRateRecord::class,
        // #528: also share back the strap's raw-derived series + daily totals.
        ActiveCaloriesBurnedRecord::class,
        StepsRecord::class,
        HeartRateRecord::class,
        SleepSessionRecord::class,
    )

    /** The write-permission strings the UI must request before calling [write]. */
    val PERMISSIONS: Set<String> =
        WRITE_RECORDS.map { HealthPermission.getWritePermission(it) }.toSet()

    /**
     * Write the last [WINDOW_DAYS] of computed metrics. Returns the number of records written,
     * 0 when HC is unavailable / nothing computed yet. Assumes [PERMISSIONS] are granted (HC
     * throws SecurityException otherwise — callers wrap in runCatching).
     *
     * [deviceId] must be the registry's ACTIVE strap id (SPINE / #814): a wizard-paired strap banks
     * rows under `whoop-<address>`, so the legacy "my-whoop" default reads empty tables and exports
     * nothing. The default fits only legacy single-WHOOP installs, where the active id resolves to
     * "my-whoop" anyway.
     */
    suspend fun write(context: Context, repo: WhoopRepository, deviceId: String = "my-whoop"): Int {
        if (HealthConnectClient.getSdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) return 0
        val client = HealthConnectClient.getOrCreate(context)

        val cutoff = LocalDate.now().minusDays(WINDOW_DAYS).toString()
        val days = repo.days(repo.computedDeviceId(deviceId)).filter { it.day >= cutoff }

        val zone = ZoneId.systemDefault()
        // Stamp every record in this batch with one version so a later recompute (higher stamp)
        // replaces the whole day consistently.
        val version = System.currentTimeMillis() / 1000

        val records = ArrayList<Record>()
        for (d in days) {
            // Noon local on the metric's day: an unambiguous, stable instant for a daily summary
            // (midnight would straddle the previous night across DST shifts).
            val date = runCatching { LocalDate.parse(d.day) }.getOrNull() ?: continue
            val time = date.atTime(LocalTime.NOON).atZone(zone)
            val instant: Instant = time.toInstant()
            val offset = time.offset

            d.restingHr?.let {
                records.add(RestingHeartRateRecord(
                    time = instant, zoneOffset = offset, beatsPerMinute = it.toLong(),
                    metadata = meta("rhr", d.day, version),
                ))
            }
            d.avgHrv?.let {
                records.add(HeartRateVariabilityRmssdRecord(
                    time = instant, zoneOffset = offset, heartRateVariabilityMillis = it,
                    metadata = meta("hrv", d.day, version),
                ))
            }
            d.spo2Pct?.let {
                records.add(OxygenSaturationRecord(
                    time = instant, zoneOffset = offset, percentage = Percentage(it),
                    metadata = meta("spo2", d.day, version),
                ))
            }
            d.respRateBpm?.let {
                records.add(RespiratoryRateRecord(
                    time = instant, zoneOffset = offset, rate = it,
                    metadata = meta("resp", d.day, version),
                ))
            }
        }

        // #528 — Active Energy + Steps: one interval record per day, riding the same 60-day window.
        // Kept in a SEPARATE list + insert from the vitals above so a revoked steps/energy WRITE
        // permission can't fail the (already-reliable) vitals insert: HC insertRecords is
        // all-or-nothing per call.
        val aggRecords = ArrayList<Record>()
        val aggs = HealthExportPlan.dailyAggregates(
            days.map { HealthExportPlan.DayInput(it.day, it.steps, it.activeKcalEst) },
        ) { day ->
            val date = runCatching { LocalDate.parse(day) }.getOrNull() ?: return@dailyAggregates null
            val s = date.atStartOfDay(zone).toEpochSecond()
            val e = date.plusDays(1).atStartOfDay(zone).toEpochSecond()
            s to e
        }
        for (a in aggs) {
            val start = Instant.ofEpochSecond(a.startEpochSec)
            val end = Instant.ofEpochSecond(a.endEpochSec)
            // Per-endpoint offsets: a day spanning a DST transition has different start/end offsets.
            val offStart = zone.rules.getOffset(start)
            val offEnd = zone.rules.getOffset(end)
            a.activeKcal?.let {
                aggRecords.add(ActiveCaloriesBurnedRecord(
                    startTime = start, startZoneOffset = offStart, endTime = end, endZoneOffset = offEnd,
                    energy = Energy.kilocalories(it),
                    metadata = meta("energy", a.day, version),
                ))
            }
            a.steps?.let {
                aggRecords.add(StepsRecord(
                    startTime = start, startZoneOffset = offStart, endTime = end, endZoneOffset = offEnd,
                    count = it,
                    metadata = meta("steps", a.day, version),
                ))
            }
        }

        // Each export concern inserts independently (own runCatching) so a failure in one — e.g. a
        // revoked per-type WRITE permission — can't suppress the others.
        var total = 0
        if (records.isNotEmpty()) {
            total += runCatching { client.insertRecords(records); records.size }.getOrDefault(0)
        }
        if (aggRecords.isNotEmpty()) {
            total += runCatching { client.insertRecords(aggRecords); aggRecords.size }.getOrDefault(0)
        }
        total += runCatching { writeHeartRate(client, context, repo, deviceId, version) }.getOrDefault(0)
        total += runCatching { writeSleep(client, repo, deviceId) }.getOrDefault(0)
        return total
    }

    private fun meta(metric: String, day: String, version: Long) = Metadata(
        clientRecordId = "noop-$metric-$day",
        clientRecordVersion = version,
    )

    /** Health Connect caps records per insert call; insert in batches to stay well under it. */
    private suspend fun insertChunked(client: HealthConnectClient, records: List<Record>, batch: Int = 1000): Int {
        var n = 0
        records.chunked(batch).forEach { client.insertRecords(it); n += it.size }
        return n
    }

    /**
     * #528 — export NOOP's heart-rate samples (raw [deviceId], not computed) above the persisted
     * frontier. Inside workout/sleep windows the series is kept at full resolution; elsewhere it is
     * decimated to ~1 sample / 30 s so a continuous day doesn't flood Health Connect. The frontier
     * (a single epoch-second cursor in [NoopPrefs]) advances past every sample seen, so each 15-min
     * writeback only emits NEW samples and decimated-away points are never reconsidered.
     */
    private suspend fun writeHeartRate(client: HealthConnectClient, context: Context, repo: WhoopRepository, deviceId: String, version: Long): Int {
        val now = System.currentTimeMillis() / 1000
        val floor = now - WINDOW_DAYS * 86_400
        val frontier = maxOf(NoopPrefs.hcHrFrontier(context), floor)

        val samples = repo.hrSamples(deviceId, from = frontier + 1, to = now, limit = 200_000)
            .map { HealthExportPlan.HrPoint(it.ts, it.bpm) }
        if (samples.isEmpty()) return 0

        // Workout + sleep windows where the full-resolution series matters; everything else decimates.
        val windows = buildList {
            repo.workouts(deviceId, frontier, now).forEach { add(HealthExportPlan.Window(it.startTs, it.endTs)) }
            repo.sleepSessions(deviceId, frontier, now).forEach { add(HealthExportPlan.Window(it.startTs, it.endTs)) }
        }

        val plan = HealthExportPlan.heartRate(samples, windows, frontier)
        if (plan.chunks.isEmpty()) {
            if (plan.newFrontierSec > frontier) NoopPrefs.setHcHrFrontier(context, plan.newFrontierSec)
            return 0
        }

        val zone = ZoneId.systemDefault()
        val records = plan.chunks.map { c ->
            val startTs = c.startSec
            val endTs = if (c.endSec > c.startSec) c.endSec else c.startSec + 1 // HC needs end > start
            val start = Instant.ofEpochSecond(startTs)
            val end = Instant.ofEpochSecond(endTs)
            HeartRateRecord(
                startTime = start, startZoneOffset = zone.rules.getOffset(start),
                endTime = end, endZoneOffset = zone.rules.getOffset(end),
                samples = c.points.map {
                    HeartRateRecord.Sample(time = Instant.ofEpochSecond(it.tsSec), beatsPerMinute = it.bpm.toLong())
                },
                metadata = Metadata(clientRecordId = c.clientId, clientRecordVersion = version),
            )
        }
        val n = insertChunked(client, records)
        NoopPrefs.setHcHrFrontier(context, plan.newFrontierSec)
        return n
    }

    /**
     * #528 — export finalized sleep sessions as a session + AWAKE/SLEEPING stages (no deep/REM/light
     * split yet — only the validated asleep-vs-awake distinction is shared so we don't over-claim the
     * stager's precision). Uses the MERGED view (imported wins, on-device-computed gap-fills) so a
     * strap-only user's locally-computed nights (stored under the "-noop" computed id) are included.
     * The clientRecordId keys off the immutable detected startTs so a re-write upserts in place.
     */
    private suspend fun writeSleep(client: HealthConnectClient, repo: WhoopRepository, deviceId: String): Int {
        val now = System.currentTimeMillis() / 1000
        val floor = now - WINDOW_DAYS * 86_400
        val sessions = repo.sleepSessionsMerged(deviceId, from = floor, to = now)
            .map { HealthExportPlan.SleepInput(it.startTs, it.endTs, it.stagesJSON) }
        val plans = HealthExportPlan.sleepSessions(sessions, now)
        if (plans.isEmpty()) return 0

        val zone = ZoneId.systemDefault()
        val records = plans.map { p ->
            val start = Instant.ofEpochSecond(p.startSec)
            val end = Instant.ofEpochSecond(p.endSec)
            SleepSessionRecord(
                startTime = start, startZoneOffset = zone.rules.getOffset(start),
                endTime = end, endZoneOffset = zone.rules.getOffset(end),
                title = null, notes = null,
                stages = p.stages.map { s ->
                    SleepSessionRecord.Stage(
                        startTime = Instant.ofEpochSecond(s.startSec),
                        endTime = Instant.ofEpochSecond(s.endSec),
                        stage = if (s.asleep) SleepSessionRecord.STAGE_TYPE_SLEEPING
                                else SleepSessionRecord.STAGE_TYPE_AWAKE,
                    )
                },
                metadata = Metadata(clientRecordId = p.clientId, clientRecordVersion = p.endSec),
            )
        }
        return insertChunked(client, records)
    }

    // --- Workout (ExerciseSession) writeback (GPS workouts, v1.71) ---

    /** Write-permission strings for exercise sessions + distance; union into the writeback request. */
    val EXERCISE_PERMISSIONS: Set<String> = setOf(
        HealthPermission.getWritePermission(ExerciseSessionRecord::class),
        HealthPermission.getWritePermission(DistanceRecord::class),
    )

    /** Pure: build the records for one workout (testable without a client). */
    fun buildExerciseRecords(row: WorkoutRow, exerciseType: Int): List<Record> {
        val start = Instant.ofEpochSecond(row.startTs)
        val end = Instant.ofEpochSecond(row.endTs)
        val offset = ZoneId.systemDefault().rules.getOffset(start)
        val out = ArrayList<Record>()
        out.add(
            ExerciseSessionRecord(
                startTime = start, startZoneOffset = offset, endTime = end, endZoneOffset = offset,
                exerciseType = exerciseType, title = row.sport,
                metadata = Metadata(clientRecordId = "noop-workout-${row.startTs}", clientRecordVersion = row.endTs),
            ),
        )
        row.distanceM?.let {
            out.add(
                DistanceRecord(
                    startTime = start, startZoneOffset = offset, endTime = end, endZoneOffset = offset,
                    distance = Length.meters(it),
                    metadata = Metadata(clientRecordId = "noop-workout-dist-${row.startTs}", clientRecordVersion = row.endTs),
                ),
            )
        }
        return out
    }

    /** Insert one workout's records into Health Connect. Opt-in caller; wrap in runCatching. */
    suspend fun writeExercise(context: Context, row: WorkoutRow, exerciseType: Int): Int {
        if (HealthConnectClient.getSdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) return 0
        val recs = buildExerciseRecords(row, exerciseType)
        HealthConnectClient.getOrCreate(context).insertRecords(recs)
        return recs.size
    }
}
