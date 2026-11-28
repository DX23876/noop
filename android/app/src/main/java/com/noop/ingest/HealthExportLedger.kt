package com.noop.ingest

import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.Vo2MaxRecord
import androidx.health.connect.client.records.WeightRecord
import com.noop.core.SwiftCore
import org.json.JSONArray
import org.json.JSONObject

/**
 * Which Health Connect records an export must actually write, from the shared core's ledger
 * (`health.planExports`, the table Apple's `HealthSampleWriter` keeps for Apple Health). A record whose
 * content matches the last write that Health Connect accepted is left alone; a changed one gets a revision
 * above every earlier one, so it replaces the old record. Until 2026-11-26 every pass rewrote all vitals and
 * nights of the 60-day window with a fresh version, about 190 records every 15 minutes.
 */
internal object HealthExportLedger {
    /** One record to export: its id, what it says, and how to build it at a given version. */
    class Entry(val id: String, val fingerprint: String, val build: (Long) -> Record)

    data class Version(val id: String, val revision: Long, val needsSave: Boolean)

    /** How often every record is written again although the ledger says Health Connect holds it. */
    const val FULL_WRITE_INTERVAL_MS = 24L * 60 * 60 * 1000

    /**
     * Whether this export writes every record again. The ledger cannot see what happened inside Health Connect:
     * the wearer clearing NOOP's data there, or a backup restored onto a phone whose Health Connect is empty.
     * Before the ledger every pass rewrote everything and so repaired that by itself; once a day keeps the
     * repair at a small fraction of the old cost. A clock that went backwards counts as due.
     */
    fun fullWriteDue(lastFullWriteMs: Long, nowMs: Long): Boolean =
        lastFullWriteMs <= 0 || nowMs < lastFullWriteMs || nowMs - lastFullWriteMs >= FULL_WRITE_INTERVAL_MS

    /** An entry for [build], or null for a record without an id or of a kind this ledger does not cover. */
    fun entry(build: (Long) -> Record): Entry? {
        val probe = build(0)
        val id = probe.metadata.clientRecordId ?: return null
        val fingerprint = fingerprint(probe) ?: return null
        return Entry(id, fingerprint, build)
    }

    /**
     * What a record says, without its version: the kind, its time and offset and its values. Two records with
     * the same fingerprint would replace each other with nothing changed.
     */
    fun fingerprint(record: Record): String? = when (record) {
        is RestingHeartRateRecord -> "rhr|${record.time.epochSecond}|${record.zoneOffset?.totalSeconds}|${record.beatsPerMinute}"
        is HeartRateVariabilityRmssdRecord ->
            "hrv|${record.time.epochSecond}|${record.zoneOffset?.totalSeconds}|${record.heartRateVariabilityMillis}"
        is OxygenSaturationRecord -> "spo2|${record.time.epochSecond}|${record.zoneOffset?.totalSeconds}|${record.percentage.value}"
        is RespiratoryRateRecord -> "resp|${record.time.epochSecond}|${record.zoneOffset?.totalSeconds}|${record.rate}"
        is Vo2MaxRecord -> "vo2max|${record.time.epochSecond}|${record.zoneOffset?.totalSeconds}|" +
            "${record.vo2MillilitersPerMinuteKilogram}|${record.measurementMethod}"
        is WeightRecord -> "weight|${record.time.epochSecond}|${record.zoneOffset?.totalSeconds}|${record.weight.inKilograms}"
        is SleepSessionRecord -> "sleep|${record.startTime.epochSecond}|${record.startZoneOffset?.totalSeconds}|" +
            "${record.endTime.epochSecond}|${record.endZoneOffset?.totalSeconds}|" +
            record.stages.joinToString(";") { "${it.startTime.epochSecond},${it.endTime.epochSecond},${it.stage}" }
        else -> null
    }

    /** The core's plan for [entries], in order, or null when the core could not answer. */
    fun plan(entries: List<Entry>, call: (String, String) -> String? = SwiftCore::call): List<Version>? {
        if (entries.isEmpty()) return emptyList()
        val items = JSONArray()
        entries.forEach { items.put(JSONObject().put("id", it.id).put("fingerprint", it.fingerprint)) }
        val answer = runCatching { call("health.planExports", JSONObject().put("items", items).toString()) }.getOrNull()
            ?: return null
        val versions = runCatching { JSONObject(answer).getJSONArray("versions") }.getOrNull() ?: return null
        if (versions.length() != entries.size) return null
        return (0 until versions.length()).map { i ->
            val v = versions.getJSONObject(i)
            Version(v.getString("id"), v.getLong("revision"), v.getBoolean("needsSave"))
        }
    }

    /** Marks [versions] as written, after Health Connect accepted them. */
    fun commit(versions: List<Version>, call: (String, String) -> String? = SwiftCore::call) {
        if (versions.isEmpty()) return
        val list = JSONArray()
        versions.forEach { list.put(JSONObject().put("id", it.id).put("revision", it.revision)) }
        runCatching { call("health.commitExports", JSONObject().put("versions", list).toString()) }
    }

    /** Forgets [ids] after their records were deleted from Health Connect, so the same content is written again. */
    fun invalidate(ids: Collection<String>, call: (String, String) -> String? = SwiftCore::call) {
        if (ids.isEmpty()) return
        runCatching { call("health.invalidateExports", JSONObject().put("ids", JSONArray(ids.toList())).toString()) }
    }

    /**
     * The records to insert for [entries] and the versions to commit once they landed. [everything] writes each
     * entry at the revision the plan gives it: a record Health Connect still holds keeps its version, so it is
     * left as it is, and one that went missing is created again. Without a plan from the core every record is
     * written at [fallbackVersion], as before the ledger, so a broken core never stops an export.
     */
    fun changed(
        entries: List<Entry>,
        fallbackVersion: Long,
        plan: List<Version>?,
        everything: Boolean = false,
    ): Pair<List<Record>, List<Version>> {
        if (plan == null) return entries.map { it.build(fallbackVersion) } to emptyList()
        val due = entries.zip(plan).filter { (_, v) -> everything || v.needsSave }
        return due.map { (e, v) -> e.build(v.revision) } to due.map { it.second }
    }
}
