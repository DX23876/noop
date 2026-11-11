package com.noop.ingest

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.units.Mass
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset

/**
 * Fork (DX23876), debug builds only: writes a small, known set of records into Health Connect (seven days of steps,
 * resting heart rate and weigh-ins, the last three nights with stages, a run each other day, heart rate through
 * those runs), so the import of another app can be checked on an emulator. Launched with the extra
 * [EXTRA] from the demo app; the full app (another package) then imports what this wrote, since the importer skips
 * an app's own records. A release build ignores the extra. Analysis migration required: no.
 */
object DebugHealthConnectSeed {
    const val EXTRA = "seed_health_connect"
    private const val TAG = "HcSeed"

    fun seedIfRequested(context: Context, intent: Intent?) {
        if (!com.noop.BuildConfig.DEBUG || intent?.getBooleanExtra(EXTRA, false) != true) return
        CoroutineScope(Dispatchers.IO).launch {
            val n = runCatching { HealthConnectClient.getOrCreate(context).insertRecords(records()).recordIdsList.size }
            Log.i(TAG, n.fold({ "inserted $it records" }, { "failed: ${it.message}" }))
        }
    }

    /** A stable id per record, so seeding twice updates rather than duplicates. */
    private fun meta(id: String) = Metadata(clientRecordId = "noop-seed-$id", clientRecordVersion = 1)

    private fun records(): List<Record> {
        val zone = ZoneId.systemDefault()
        val today = LocalDate.now(zone)
        val out = mutableListOf<Record>()
        fun off(i: Instant): ZoneOffset = zone.rules.getOffset(i)
        for (d in 1..7) {
            val day = today.minusDays(d.toLong())
            val noon = day.atTime(12, 0).atZone(zone).toInstant()
            out += StepsRecord(startTime = noon, startZoneOffset = off(noon), endTime = noon.plusSeconds(3600), endZoneOffset = off(noon),
                               count = 6_000L + d * 500L, metadata = meta("steps-$day"))
            val morning = day.atTime(7, 30).atZone(zone).toInstant()
            out += RestingHeartRateRecord(time = morning, zoneOffset = off(morning), beatsPerMinute = 52L + d, metadata = meta("rhr-$day"))
            out += WeightRecord(time = morning, zoneOffset = off(morning), weight = Mass.kilograms(80.0 - d * 0.1), metadata = meta("weight-$day"))
            if (d % 2 == 0) {
                val runStart = day.atTime(18, 0).atZone(zone).toInstant()
                val runEnd = runStart.plusSeconds(40 * 60)
                out += ExerciseSessionRecord(startTime = runStart, startZoneOffset = off(runStart), endTime = runEnd,
                                             endZoneOffset = off(runEnd), exerciseType = ExerciseSessionRecord.EXERCISE_TYPE_RUNNING,
                                             title = "Seed run", metadata = meta("run-$day"))
                out += HeartRateRecord(startTime = runStart, startZoneOffset = off(runStart), endTime = runEnd, endZoneOffset = off(runEnd),
                    samples = (0 until 40).map { HeartRateRecord.Sample(time = runStart.plusSeconds(it * 60L), beatsPerMinute = 120L + it) },
                    metadata = meta("hr-$day"))
            }
        }
        for (d in 0..2) {
            val wakeDay = today.minusDays(d.toLong())
            val bed = wakeDay.minusDays(1).atTime(23, 0).atZone(zone).toInstant()
            val wake = wakeDay.atTime(7, 0).atZone(zone).toInstant()
            var t = bed
            val stages = mutableListOf<SleepSessionRecord.Stage>()
            val cycle = listOf(SleepSessionRecord.STAGE_TYPE_LIGHT to 40, SleepSessionRecord.STAGE_TYPE_DEEP to 30,
                               SleepSessionRecord.STAGE_TYPE_LIGHT to 10, SleepSessionRecord.STAGE_TYPE_REM to 20)
            while (t < wake) for ((type, minutes) in cycle) {
                val e = minOf(t.plusSeconds(minutes * 60L), wake)
                if (e > t) stages += SleepSessionRecord.Stage(startTime = t, endTime = e, stage = type)
                t = e
            }
            out += SleepSessionRecord(startTime = bed, startZoneOffset = off(bed), endTime = wake, endZoneOffset = off(wake),
                                      title = "Seed night", notes = null, stages = stages, metadata = meta("sleep-$wakeDay"))
        }
        return out
    }
}
