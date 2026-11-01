package com.noop.push

import com.noop.core.CoreDb

import com.noop.data.WhoopDatabase

/** SQL-side upper bound evaluated before Android materializes any unrestricted TEXT value. */
internal object PushSnapshotPreflight {
    // 4 KiB per row conservatively covers maps, entries, boxed scalars and fixed JSON syntax. The
    // remaining budget covers text at 6x its UTF-8 byte length, the maximum JSON string expansion.
    const val FIXED_ROW_OVERHEAD_BYTES = 4 * 1024L
    const val MAX_ESTIMATED_SNAPSHOT_BYTES = 48 * 1024 * 1024L

    fun rowEstimateExpression(columns: List<String>): String = buildString {
        append(FIXED_ROW_OVERHEAD_BYTES)
        columns.forEach { column ->
            append(" + (CASE WHEN $column IS NULL THEN 4 ")
            append("WHEN typeof($column) = 'text' THEN length(CAST($column AS BLOB)) * 6 + 2 ")
            append("WHEN typeof($column) = 'blob' THEN ${MAX_ESTIMATED_SNAPSHOT_BYTES + 1} ")
            append("ELSE 32 END)")
        }
    }

    fun query(table: String, columns: List<String>, predicate: String, orderBy: String): String =
        "SELECT COALESCE(SUM(${rowEstimateExpression(columns)}), 0) FROM " +
            "(SELECT ${columns.joinToString()} FROM $table WHERE $predicate ORDER BY $orderBy LIMIT ?)"
}

internal object PushDeviceDiscovery {
    fun query(supportedSqlTables: List<String>): String = buildString {
        append("SELECT id AS deviceId FROM device WHERE id <> ''")
        supportedSqlTables.distinct().forEach { table ->
            append(" UNION SELECT deviceId FROM $table WHERE deviceId <> ''")
        }
        append(" ORDER BY deviceId")
    }
}

/**
 * Narrow, read-only Room snapshot adapter. SQL identifiers come exclusively from the closed enums below;
 * user/config input is always a bind argument. Every cursor is consumed and closed inside [withTransaction].
 */
class PushDao internal constructor(@Suppress("unused") private val db: WhoopDatabase) : PushSnapshotSource {
    override suspend fun knownDeviceIds(capabilities: PushCapabilities): List<String> {
        val supportedTables = capabilities.appendTables.map(::appendSpec) +
            capabilities.mutableTables.map(::mutableSpec)
        val sql = PushDeviceDiscovery.query(supportedTables.map(TableSpec::sqlName))
        return CoreDb.queryPositional(sql, emptyList()).mapNotNull { row ->
            row.stringOrNull("deviceId")?.takeIf { it.isNotBlank() }
        }
    }

    override suspend fun appendRecordAt(
        table: PushAppendTable,
        deviceId: String,
        rowId: Long,
    ): PushAppendRecord? {
        val spec = appendSpec(table)
        ensureSnapshotBounded(
            PushSnapshotPreflight.query(spec.sqlName, spec.columns, "deviceId = ? AND rowid = ?", "rowid ASC"),
            listOf(deviceId, rowId, 1),
        )
        val sql = "SELECT rowid AS _pushRowId, ${spec.columns.joinToString()} FROM ${spec.sqlName} " +
            "WHERE deviceId = ? AND rowid = ? LIMIT 1"
        return CoreDb.queryPositional(sql, listOf(deviceId, rowId)).firstOrNull()?.appendRecord(spec)
    }

    override suspend fun appendRows(
        table: PushAppendTable,
        deviceId: String,
        afterRowId: Long,
        limit: Int,
    ): List<PushAppendRecord> {
        require(limit in 1..PushProtocol.MAX_RECORDS + 1)
        val spec = appendSpec(table)
        ensureSnapshotBounded(
            PushSnapshotPreflight.query(spec.sqlName, spec.columns, "deviceId = ? AND rowid > ?", "rowid ASC"),
            listOf(deviceId, afterRowId, limit),
        )
        val sql = "SELECT rowid AS _pushRowId, ${spec.columns.joinToString()} FROM ${spec.sqlName} " +
            "WHERE deviceId = ? AND rowid > ? ORDER BY rowid ASC LIMIT ?"
        return CoreDb.queryPositional(sql, listOf(deviceId, afterRowId, limit)).map { it.appendRecord(spec) }
    }

    override suspend fun mutableRows(
        table: PushMutableTable,
        deviceId: String,
        window: PushWindow,
        limit: Int,
    ): List<PushMutableRecord> {
        require(limit in 1..(PushProtocol.MAX_MUTABLE_SNAPSHOT_RECORDS + 1))
        val spec = mutableSpec(table)
        val (predicate, bounds) = when (table) {
            PushMutableTable.DAILY_METRIC, PushMutableTable.JOURNAL ->
                "day >= ? AND day <= ?" to listOf<Any?>(window.fromDay, window.toDay)
            PushMutableTable.SLEEP_SESSION, PushMutableTable.WORKOUT ->
                "startTs >= ? AND startTs < ?" to listOf<Any?>(window.startTsInclusive, window.endTsExclusive)
        }
        val sql = "SELECT ${spec.columns.joinToString()} FROM ${spec.sqlName} " +
            "WHERE deviceId = ? AND $predicate ORDER BY ${spec.keyColumns.joinToString()} ASC LIMIT ?"
        val args = listOf<Any?>(deviceId) + bounds + listOf(limit)
        ensureSnapshotBounded(
            PushSnapshotPreflight.query(
                spec.sqlName,
                spec.columns,
                "deviceId = ? AND $predicate",
                "${spec.keyColumns.joinToString()} ASC",
            ),
            args,
        )
        return CoreDb.queryPositional(sql, args).map { it.mutableRecord(spec) }
    }

    private suspend fun ensureSnapshotBounded(sql: String, args: List<Any?>) {
        val estimate = CoreDb.scalarLong(CoreDb.queryPositional(sql, args)) ?: 0L
        if (estimate > PushSnapshotPreflight.MAX_ESTIMATED_SNAPSHOT_BYTES) {
            throw PushProtocolException("snapshot exceeds local memory limit")
        }
    }

    private fun CoreDb.Row.appendRecord(spec: TableSpec): PushAppendRecord {
        val values = values(spec)
        return PushAppendRecord(
            long("_pushRowId"),
            spec.keyColumns.associateWith(values::get),
            spec.dataColumns.associateWith(values::get),
        )
    }

    private fun CoreDb.Row.mutableRecord(spec: TableSpec): PushMutableRecord {
        val values = values(spec)
        return PushMutableRecord(
            spec.keyColumns.associateWith(values::get),
            spec.dataColumns.associateWith(values::get),
        )
    }

    private fun CoreDb.Row.values(spec: TableSpec): Map<String, Any?> = buildMap {
        for (name in spec.columns) {
            if (!has(name)) throw PushProtocolException("missing column ${spec.sqlName}.$name")
            val value: Any? = when (val v = value(name)) {
                null -> null
                is Int, is Long -> {
                    val n = (v as Number).toLong()
                    if (name in spec.booleanColumns) n != 0L else n
                }
                is Number -> v.toDouble()
                is String -> v
                else -> throw PushProtocolException("unsupported SQLite type in ${spec.sqlName}.$name")
            }
            put(name, value)
        }
    }

    private data class TableSpec(
        val sqlName: String,
        val keyColumns: List<String>,
        val dataColumns: List<String>,
        val booleanColumns: Set<String> = emptySet(),
    ) {
        val columns: List<String> = keyColumns + dataColumns
    }

    private fun appendSpec(table: PushAppendTable): TableSpec = when (table) {
        PushAppendTable.HR_SAMPLE -> HR
        PushAppendTable.RR_INTERVAL -> RR
        PushAppendTable.EVENT -> EVENT
        PushAppendTable.BATTERY -> BATTERY
        PushAppendTable.SPO2_SAMPLE -> SPO2
        PushAppendTable.SKIN_TEMP_SAMPLE -> SKIN_TEMP
        PushAppendTable.RESP_SAMPLE -> RESP
        PushAppendTable.GRAVITY_SAMPLE -> GRAVITY
    }

    private fun mutableSpec(table: PushMutableTable): TableSpec = when (table) {
        PushMutableTable.DAILY_METRIC -> DAILY
        PushMutableTable.SLEEP_SESSION -> SLEEP
        PushMutableTable.WORKOUT -> WORKOUT
        PushMutableTable.JOURNAL -> JOURNAL
    }

    private companion object {
        val HR = TableSpec("hrSample", listOf("ts"), listOf("bpm"))
        val RR = TableSpec(
            "rrInterval",
            listOf("ts", "rrMs", "seq"),
            listOf("ord", "srcChannel", "tsSuspect"),
        )
        val EVENT = TableSpec(
            "event", listOf("ts", "kind"), listOf("payloadJSON"),
        )
        val BATTERY = TableSpec(
            "battery", listOf("ts"), listOf("soc", "mv", "charging"),
            booleanColumns = setOf("charging"),
        )
        val SPO2 = TableSpec(
            "spo2Sample", listOf("ts"), listOf("red", "ir"),
        )
        val SKIN_TEMP = TableSpec(
            "skinTempSample", listOf("ts"), listOf("raw", "aux1Raw", "aux2Raw"),
        )
        val RESP = TableSpec("respSample", listOf("ts"), listOf("raw"))
        val GRAVITY = TableSpec(
            "gravitySample", listOf("ts"), listOf("x", "y", "z", "dynAccel"),
        )
        val DAILY = TableSpec(
            "dailyMetric",
            listOf("day"),
            listOf(
                "totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin",
                "disturbances", "restingHr", "avgHrv", "recovery", "strain", "exerciseCount", "spo2Pct",
                "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "spo2Red", "spo2Ir",
            ),
        )
        val SLEEP = TableSpec(
            "sleepSession",
            listOf("startTs"),
            listOf(
                "endTs", "efficiency", "restingHr", "avgHrv", "stagesJSON",
                "userEdited", "startTsAdjusted", "motionJSON", "sleepStateJSON", "stagingSparse",
            ),
            booleanColumns = setOf("userEdited", "stagingSparse"),
        )
        val WORKOUT = TableSpec(
            "workout",
            listOf("startTs", "sport"),
            listOf(
                "endTs", "source", "durationS", "energyKcal", "avgHr",
                "maxHr", "strain", "distanceM", "zonesJSON", "notes", "routePolyline", "steps",
            ),
        )
        val JOURNAL = TableSpec(
            "journal", listOf("day", "question"), listOf("answeredYes", "notes", "numericValue"),
            booleanColumns = setOf("answeredYes"),
        )
    }
}
