package com.noop.core

import android.content.Context
import com.noop.NoopApplication
import com.noop.data.JournalEntry
import com.noop.data.MetricSeriesRow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException

/** Exact legacy-row transport. Once ownership is banked, Room is never replayed over this core store. */
class CoreUserInputs(private val context: Context) {
    companion object {
        private val migration = Mutex()
        fun isWater(source: String, key: String) = source == "hydration" && key in listOf("hydration", "hydrationImported")

        /** Blocking adapter for existing JNI screen entry points; callers already run on IO threads. */
        fun ensure(context: Context): Boolean = runCatching {
            val app = context.applicationContext as NoopApplication
            runBlocking { app.repository.ensureSharedJournalHydration() }
        }.isSuccess
    }

    suspend fun ensure(snapshot: suspend () -> Pair<List<JournalEntry>, List<MetricSeriesRow>>) = withContext(Dispatchers.IO) {
        migration.withLock {
            CoreRead.open(context)
            val status = JSONObject(call("input.ownership", JSONObject()))
            if (!status.getBoolean("owned")) {
                val (journal, hydration) = snapshot()
                change("input.adopt", JSONObject().put("journal", JSONArray(journal.map(::journalJSON)))
                    .put("hydration", JSONArray(hydration.map(::waterJSON))))
            }
        }
    }

    suspend fun journal(source: String, from: String, to: String): List<JournalEntry> = withContext(Dispatchers.IO) {
        val rows = JSONArray(call("input.journalRead", JSONObject().put("source", source).put("from", from).put("to", to)))
        (0 until rows.length()).map { rows.getJSONObject(it) }.map {
            JournalEntry(source, it.getString("day"), it.getString("question"), it.getBoolean("answeredYes"),
                if (it.isNull("notes")) null else it.getString("notes"),
                if (it.isNull("numericValue")) null else it.getDouble("numericValue"))
        }
    }

    suspend fun writeJournal(rows: List<JournalEntry>) = withContext(Dispatchers.IO) {
        for ((source, entries) in rows.groupBy { it.deviceId }) {
            change("input.journalWrite", JSONObject().put("source", source).put("rows", JSONArray(entries.map(::journalJSON))))
        }
    }

    suspend fun deleteJournal(source: String, day: String, question: String) = withContext(Dispatchers.IO) {
        change("input.journalDelete", JSONObject().put("source", source).put("day", day).put("question", question))
    }

    suspend fun replaceJournal(source: String, from: String, to: String, rows: List<JournalEntry>) = withContext(Dispatchers.IO) {
        require(rows.all { it.deviceId == source })
        change("input.journalReplace", JSONObject().put("source", source).put("from", from).put("to", to)
            .put("rows", JSONArray(rows.map(::journalJSON))))
    }

    suspend fun water(key: String, from: String, to: String): List<MetricSeriesRow> = withContext(Dispatchers.IO) {
        val rows = JSONArray(call("input.waterRead", JSONObject().put("key", key).put("from", from).put("to", to)))
        (0 until rows.length()).map { rows.getJSONObject(it) }.map {
            MetricSeriesRow("hydration", it.getString("day"), it.getString("key"), it.getDouble("value"))
        }
    }

    suspend fun waterKeys(): List<String> = withContext(Dispatchers.IO) {
        val keys = JSONArray(call("input.waterKeys", JSONObject()))
        (0 until keys.length()).map { keys.getString(it) }
    }

    suspend fun waterCount(key: String): Int = withContext(Dispatchers.IO) {
        JSONObject(call("input.waterCount", JSONObject().put("key", key))).getInt("count")
    }

    suspend fun writeWater(rows: List<MetricSeriesRow>) = withContext(Dispatchers.IO) {
        require(rows.all { isWater(it.deviceId, it.key) })
        change("input.waterWrite", JSONObject().put("rows", JSONArray(rows.map(::waterJSON))))
    }

    suspend fun deleteWater(key: String, day: String? = null) = withContext(Dispatchers.IO) {
        change(if (day == null) "input.waterDeleteSeries" else "input.waterDelete",
            JSONObject().put("key", key).apply { if (day != null) put("day", day) })
    }

    private fun call(op: String, args: JSONObject): String {
        if (!SwiftCore.available) throw IOException("Shared input core unavailable")
        val json = SwiftCore.call(op, args.toString()) ?: throw IOException("Shared input read failed")
        if (json.startsWith("{" ) && JSONObject(json).has("error")) throw IOException("Shared input operation failed: $op")
        return json
    }

    private fun change(op: String, args: JSONObject) {
        if (!JSONObject(call(op, args)).getBoolean("ok")) throw IOException("Shared input change failed: $op")
        CoreShadow.noteDataChanged()
    }

    private fun journalJSON(row: JournalEntry) = JSONObject().put("deviceId", row.deviceId).put("day", row.day)
        .put("question", row.question).put("answeredYes", row.answeredYes)
        .put("notes", row.notes ?: JSONObject.NULL).put("numericValue", row.numericValue ?: JSONObject.NULL)
    private fun waterJSON(row: MetricSeriesRow) = JSONObject().put("day", row.day).put("key", row.key).put("value", row.value)
}
