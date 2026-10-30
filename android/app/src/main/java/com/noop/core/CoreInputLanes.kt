package com.noop.core

import android.content.Context
import android.database.Cursor
import android.util.Log
import androidx.sqlite.db.SimpleSQLiteQuery
import com.noop.data.WhoopDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException

/**
 * The input lanes Android still writes to Room first (parity plan 1.3): workouts, platform health days, lab
 * markers, live sessions, imported series, imported days and nights, the wearer's sleep edits and naps, and
 * day ownership. Room stays the classic screens' read copy; the core owns the data. The complete legacy
 * snapshot crosses once, atomically with its marker; after that every change is mirrored by primary key as it
 * ended up in Room, so an insert, an update and a delete take the same path. A mirror that fails marks the
 * lanes for a repair pass, which stages Room again and lets it win.
 */
class CoreInputLanes(private val context: Context, private val db: WhoopDatabase) {
    companion object {
        private const val TAG = "CoreInputLanes"
        private const val PREFS = "forge"
        private const val KEY_REPAIR = "coreInputLanesRepair"
        private const val CHUNK = 500
        private const val COMPUTED = "-noop"
        private val mutex = Mutex()

        /**
         * Whether the core's lanes hold Room's rows in this process: set once [ensure] found them adopted with no
         * repair waiting, cleared while a repair restages them and when a mirror fails. Reads back from the core
         * go by it, so a lane that is empty, half-staged or behind is never shown in place of Room's copy.
         */
        @Volatile
        var ready = false
            private set

        /** Primary keys, in Room's (and GRDB's) column order. */
        val KEYS = linkedMapOf(
            "workout" to listOf("deviceId", "startTs", "sport"),
            "appleDaily" to listOf("deviceId", "day"),
            "labMarker" to listOf("id"),
            "liveSession" to listOf("deviceId", "startTs"),
            "metricSeries" to listOf("deviceId", "day", "key"),
            "dailyMetric" to listOf("deviceId", "day"),
            "sleepSession" to listOf("deviceId", "startTs"),
            "dayOwnership" to listOf("day"),
        )

        /** Columns Room carries and the core does not: a route stays on Android, as Apple keeps routes outside. */
        private val ROOM_ONLY = mapOf("workout" to setOf("routePolyline"))

        /**
         * Mirror failures in this process. [ensure] clears the repair mark only when none came in while it staged:
         * a failure during a repair may concern a write the snapshot already missed, so its mark must survive.
         */
        private val failures = java.util.concurrent.atomic.AtomicLong(0)

        /**
         * Set once a backup restore replaced the core's store file: until the restart that opens it, no repair may
         * be marked, since a repair restages Room's pre-restore rows with `replace` over the restored lanes.
         */
        @Volatile
        private var restored = false

        /**
         * A `.noopbak` restore replaced the core's store: forgets a repair waiting for the next [ensure] (it would
         * write Room's pre-restore snapshot over the restored lanes) and keeps later mirror failures in this
         * process from marking one. Written synchronously, as the wearer restarts the app next.
         */
        fun forgetRepairAfterRestore(context: Context) {
            restored = true
            ready = false
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_REPAIR, false).commit()
        }

        /** Whether a repair waits for the next [ensure]. */
        internal fun repairPending(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_REPAIR, false)

        /** The failures so far, read by [ensure] before it stages. */
        internal fun failureCount(): Long = failures.get()

        /** Clears the repair mark only when no mirror failed since [seen] was read. */
        internal fun mayClearRepair(seen: Long): Boolean = seen == failures.get()

        /**
         * A mirror failed: the lanes are behind Room until a repair restages them, which is marked for the next
         * [ensure] unless a restore replaced the store since (`restored`).
         */
        internal fun noteMirrorFailure(context: Context, table: String, error: Throwable) {
            ready = false
            failures.incrementAndGet()
            if (restored) {
                Log.w(TAG, "mirror of $table failed after a restore; the restored store opens on restart: ${error.message}")
                return
            }
            Log.w(TAG, "mirror of $table failed; repair on next adoption check: ${error.message}")
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_REPAIR, true).apply()
        }

        @androidx.annotation.VisibleForTesting
        internal fun resetRestoreForTest() { restored = false }
    }

    private val prefs get() = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Adopts the legacy snapshot once, or repairs a mirror that fell behind. */
    suspend fun ensure() = withContext(Dispatchers.IO) {
        if (!SwiftCore.available) return@withContext
        mutex.withLock {
            // The restored store opens only after the restart; the open one must not be restaged meanwhile.
            if (restored) return@withLock
            CoreRead.open(context)
            val seen = failureCount()
            val owned = JSONObject(call("lanes.owned", JSONObject())).getBoolean("owned")
            val repair = prefs.getBoolean(KEY_REPAIR, false)
            if (owned && !repair) { ready = true; return@withLock }
            ready = false
            call("lanes.reset", JSONObject())
            // One read transaction, so Room cannot move under the chunked snapshot.
            db.runInTransaction {
                for (table in KEYS.keys) {
                    var offset = 0
                    while (true) {
                        val rows = query("SELECT * FROM $table ORDER BY rowid LIMIT $CHUNK OFFSET $offset", emptyArray(), table)
                        if (rows.length() == 0) break
                        call("lanes.stage", JSONObject().put("table", table).put("rows", rows))
                        offset += CHUNK
                    }
                }
            }
            val moved = JSONObject(call("lanes.commit", JSONObject().put("replace", owned))).optInt("moved")
            // A mirror that failed while this pass staged keeps its mark, and the lanes stay unready until the
            // next pass repairs them again.
            if (!mayClearRepair(seen)) {
                Log.w(TAG, "a mirror failed during the ${if (owned) "repair" else "adoption"}; repairing again next time")
                CoreShadow.noteDataChanged()
                return@withLock
            }
            prefs.edit().putBoolean(KEY_REPAIR, false).apply()
            ready = true
            Log.i(TAG, "input lanes ${if (owned) "repaired" else "adopted"}: $moved rows")
            CoreShadow.noteDataChanged()
        }
    }

    /**
     * Mirrors the rows at [keys] (primary-key values in [KEYS] order) as Room now holds them: present rows are
     * written, missing ones deleted. Kotlin-computed rows are skipped; only the wearer's sleep sessions cross.
     */
    suspend fun mirror(table: String, keys: List<List<Any?>>) = withContext(Dispatchers.IO) {
        if (!SwiftCore.available || keys.isEmpty()) return@withContext
        val keyColumns = KEYS[table] ?: error("not an input lane: $table")
        val wanted = keys.distinct().filter { key ->
            val device = keyColumns.indexOf("deviceId").takeIf { it >= 0 }?.let { key[it] as? String }
            device == null || !device.endsWith(COMPUTED) || table == "sleepSession"
        }
        if (wanted.isEmpty()) return@withContext
        runCatching {
            for (chunk in wanted.chunked(CHUNK / keyColumns.size)) {
                val clause = chunk.joinToString(" OR ") { "(" + keyColumns.joinToString(" AND ") { "$it = ?" } + ")" }
                val rows = query("SELECT * FROM $table WHERE $clause", chunk.flatten().toTypedArray(), table)
                if (rows.length() > 0) call("lanes.put", JSONObject().put("table", table).put("rows", rows))
                val found = (0 until rows.length()).map { i -> keyColumns.map { rows.getJSONObject(i).opt(it) }.map(::comparable) }.toSet()
                for (key in chunk) {
                    if (key.map(::comparable) in found) continue
                    val equals = JSONObject().apply { keyColumns.forEachIndexed { i, c -> put(c, key[i] ?: JSONObject.NULL) } }
                    call("lanes.delete", JSONObject().put("table", table).put("equals", equals))
                }
            }
            CoreShadow.noteDataChanged()
        }.onFailure { markForRepair(table, it) }
    }

    /** The keys of the rows a predicate matches now, read before a range delete or a re-key so it can be mirrored. */
    suspend fun keysWhere(table: String, where: String, args: Array<Any?>): List<List<Any?>> = withContext(Dispatchers.IO) {
        val keyColumns = KEYS[table] ?: error("not an input lane: $table")
        val rows = query("SELECT ${keyColumns.joinToString()} FROM $table WHERE $where", args, table)
        (0 until rows.length()).map { i -> keyColumns.map { rows.getJSONObject(i).opt(it).takeUnless { v -> v == JSONObject.NULL } } }
    }

    private fun markForRepair(table: String, error: Throwable) = noteMirrorFailure(context, table, error)

    /** Longs and whole doubles compare as the same key whichever way the column handed them back. */
    private fun comparable(value: Any?): Any? = when (value) {
        is Number -> value.toDouble()
        JSONObject.NULL -> null
        else -> value
    }

    private fun query(sql: String, args: Array<Any?>, table: String): JSONArray {
        val skip = ROOM_ONLY[table].orEmpty()
        val out = JSONArray()
        db.openHelper.readableDatabase.query(SimpleSQLiteQuery(sql, args)).use { cursor ->
            while (cursor.moveToNext()) {
                val row = JSONObject()
                for (i in 0 until cursor.columnCount) {
                    val name = cursor.getColumnName(i)
                    if (name in skip) continue
                    row.put(name, when (cursor.getType(i)) {
                        Cursor.FIELD_TYPE_INTEGER -> cursor.getLong(i)
                        Cursor.FIELD_TYPE_FLOAT -> cursor.getDouble(i)
                        Cursor.FIELD_TYPE_STRING -> cursor.getString(i)
                        Cursor.FIELD_TYPE_NULL -> JSONObject.NULL
                        else -> throw IOException("blob in input lane $table.$name")
                    })
                }
                out.put(row)
            }
        }
        return out
    }

    private fun call(op: String, args: JSONObject): String {
        val json = SwiftCore.call(op, args.toString()) ?: throw IOException("core unavailable: $op")
        if (JSONObject(json).has("error")) throw IOException("core input lane failed: $op")
        return json
    }
}
