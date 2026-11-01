package com.noop.core

import android.content.Context
import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android without Room (`docs/fork/android/CORE-ONLY-PLAN.md`): the app's data access, run by the
 * shared core against its own store (`sql.query`, `sql.exec`, the Swift `CoreSql`). The statements are the ones
 * Android's Room DAO always ran: Room and GRDB share every table and column name, so they need no translation.
 * Named parameters keep Room's `:name` form, and a collection expands to one placeholder per element.
 */
object CoreDb {
    @Volatile private var appContext: Context? = null

    /** Called once from `NoopApplication.onCreate`, before the first read. */
    fun init(context: Context) { appContext = context.applicationContext }

    class SqlException(message: String) : RuntimeException(message)

    /** One result row, read by column name as Room maps columns to fields. */
    class Row internal constructor(private val columns: Map<String, Int>, private val values: JSONArray) {
        fun has(column: String): Boolean = columns.containsKey(column)
        /** The value as JSON carried it: Int, Long or Double, String, a blob object, or null. */
        fun value(column: String): Any? = raw(column)
        private fun raw(column: String): Any? =
            columns[column]?.let { values.opt(it) }?.takeUnless { it == JSONObject.NULL }
        /** The first column, for a scalar query. */
        fun first(): Any? = values.opt(0)?.takeUnless { it == JSONObject.NULL }

        fun longOrNull(column: String): Long? = number(raw(column))?.toLong()
        fun long(column: String): Long = longOrNull(column) ?: 0L
        fun intOrNull(column: String): Int? = number(raw(column))?.toInt()
        fun int(column: String): Int = intOrNull(column) ?: 0
        fun doubleOrNull(column: String): Double? = number(raw(column))?.toDouble()
        fun double(column: String): Double = doubleOrNull(column) ?: 0.0
        fun floatOrNull(column: String): Float? = number(raw(column))?.toFloat()
        fun float(column: String): Float = floatOrNull(column) ?: 0f
        fun boolOrNull(column: String): Boolean? = number(raw(column))?.let { it.toLong() != 0L }
        fun bool(column: String): Boolean = boolOrNull(column) ?: false
        fun stringOrNull(column: String): String? = raw(column)?.let { if (it is JSONObject) null else it.toString() }
        fun string(column: String): String = stringOrNull(column) ?: ""
        fun blobOrNull(column: String): ByteArray? = blob(raw(column))
        fun blob(column: String): ByteArray = blobOrNull(column) ?: ByteArray(0)
    }

    internal fun number(value: Any?): Number? = when (value) {
        is Number -> value
        is Boolean -> if (value) 1 else 0
        is String -> value.toLongOrNull() ?: value.toDoubleOrNull()
        else -> null
    }

    internal fun blob(value: Any?): ByteArray? = (value as? JSONObject)?.optString("b64")
        ?.let { Base64.decode(it, Base64.NO_WRAP) }

    /** The first column of a scalar answer. */
    fun scalarLong(rows: List<Row>): Long? = rows.firstOrNull()?.first()?.let(::number)?.toLong()
    fun scalarDouble(rows: List<Row>): Double? = rows.firstOrNull()?.first()?.let(::number)?.toDouble()
    fun scalarString(rows: List<Row>): String? = rows.firstOrNull()?.first()?.toString()

    /** Whether [sql] reads (its answer is rows) rather than writes (its answer is a change count). */
    fun isRead(sql: String): Boolean {
        val head = sql.trimStart().take(10).uppercase()
        return head.startsWith("SELECT") || head.startsWith("WITH") || head.startsWith("PRAGMA") ||
            head.startsWith("VALUES")
    }

    /**
     * Room's `:name` placeholders as positional `?`, with the arguments in their order. A collection becomes one
     * placeholder per element (`IN (:ids)`); text inside quotes is left alone.
     */
    fun bind(sql: String, params: Map<String, Any?>): Pair<String, List<Any?>> {
        val out = StringBuilder(sql.length)
        val args = ArrayList<Any?>()
        var i = 0
        var quote: Char? = null
        while (i < sql.length) {
            val c = sql[i]
            if (quote != null) {
                out.append(c)
                if (c == quote) quote = null
                i++
                continue
            }
            if (c == '\'' || c == '"' || c == '`') { quote = c; out.append(c); i++; continue }
            if (c == ':' && i + 1 < sql.length && (sql[i + 1].isLetter() || sql[i + 1] == '_')) {
                var j = i + 1
                while (j < sql.length && (sql[j].isLetterOrDigit() || sql[j] == '_')) j++
                val name = sql.substring(i + 1, j)
                require(params.containsKey(name)) { "no argument for :$name" }
                when (val value = params[name]) {
                    is Collection<*> -> {
                        if (value.isEmpty()) out.append("NULL")
                        else { out.append(List(value.size) { "?" }.joinToString(",")); args.addAll(value) }
                    }
                    is LongArray -> { out.append(List(value.size) { "?" }.joinToString(",").ifEmpty { "NULL" }); value.forEach { args.add(it) } }
                    is IntArray -> { out.append(List(value.size) { "?" }.joinToString(",").ifEmpty { "NULL" }); value.forEach { args.add(it) } }
                    else -> { out.append('?'); args.add(value) }
                }
                i = j
                continue
            }
            out.append(c)
            i++
        }
        return out.toString() to args
    }

    private fun jsonArg(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is ByteArray -> JSONObject().put("b64", Base64.encodeToString(value, Base64.NO_WRAP))
        is Float -> value.toDouble()
        is Enum<*> -> value.name
        else -> value
    }

    private fun args(values: List<Any?>): JSONArray = JSONArray().apply { values.forEach { put(jsonArg(it)) } }

    private fun call(op: String, args: JSONObject): JSONObject {
        val context = appContext ?: throw SqlException("CoreDb not initialised")
        if (!CoreShadow.openStore(context)) throw SqlException("the shared core is not available")
        val answer = SwiftCore.call(op, args.toString()) ?: throw SqlException("no answer from the core")
        val json = JSONObject(answer)
        if (json.has("error")) throw SqlException("${json.optString("error")}: ${json.optString("detail")}")
        return json
    }

    /** The rows a reading statement returns. */
    suspend fun query(sql: String, params: Map<String, Any?> = emptyMap()): List<Row> = withContext(Dispatchers.IO) {
        queryBlocking(sql, params)
    }

    fun queryBlocking(sql: String, params: Map<String, Any?> = emptyMap()): List<Row> {
        val (text, values) = bind(sql, params)
        return queryPositionalBlocking(text, values)
    }

    /** The rows a reading statement with positional `?` arguments returns. */
    suspend fun queryPositional(sql: String, values: List<Any?>): List<Row> = withContext(Dispatchers.IO) {
        queryPositionalBlocking(sql, values)
    }

    fun queryPositionalBlocking(text: String, values: List<Any?>): List<Row> {
        val json = call("sql.query", JSONObject().put("sql", text).put("args", args(values)))
        val names = json.optJSONArray("columns") ?: JSONArray()
        val columns = HashMap<String, Int>(names.length() * 2)
        for (c in 0 until names.length()) columns.putIfAbsent(names.getString(c), c)
        val rows = json.optJSONArray("rows") ?: return emptyList()
        return List(rows.length()) { Row(columns, rows.getJSONArray(it)) }
    }

    /** What a batch of writing statements did, per statement. */
    data class Written(val changes: List<Int>, val rowids: List<Long>) {
        val total: Int get() = changes.sum()
    }

    /** Runs positional statements in one transaction of the core's store; nothing is written on an error. */
    suspend fun execPositional(statements: List<Pair<String, List<Any?>>>): Written = withContext(Dispatchers.IO) {
        execPositionalBlocking(statements)
    }

    fun execPositionalBlocking(statements: List<Pair<String, List<Any?>>>): Written {
        if (statements.isEmpty()) return Written(emptyList(), emptyList())
        val list = JSONArray()
        for ((sql, values) in statements) list.put(JSONObject().put("sql", sql).put("args", args(values)))
        val json = call("sql.exec", JSONObject().put("statements", list))
        val changes = json.optJSONArray("changes") ?: JSONArray()
        val rowids = json.optJSONArray("rowids") ?: JSONArray()
        CoreShadow.noteDataChanged()
        return Written(List(changes.length()) { changes.getInt(it) }, List(rowids.length()) { rowids.getLong(it) })
    }

    /** Runs one statement with Room-style named parameters; its change count. */
    suspend fun exec(sql: String, params: Map<String, Any?> = emptyMap()): Int {
        val (text, values) = bind(sql, params)
        return execPositional(listOf(text to values)).total
    }

    /** Statements per call, so one JSON hand-over stays a few megabytes. */
    private const val BATCH = 500

    /** Inserts or updates many rows, each with its own statement, in transactions of [BATCH]. */
    suspend fun execEach(statements: List<Pair<String, List<Any?>>>): Written {
        val changes = ArrayList<Int>(statements.size)
        val rowids = ArrayList<Long>(statements.size)
        for (chunk in statements.chunked(BATCH)) {
            val written = execPositional(chunk)
            changes.addAll(written.changes)
            rowids.addAll(written.rowids)
        }
        return Written(changes, rowids)
    }

    /** A query re-read whenever the store changed (`CoreShadow.dataRevision`), as Room's observed queries. */
    fun <T> observe(read: suspend () -> T): Flow<T> = CoreShadow.dataRevision.map { read() }.flowOn(Dispatchers.IO)
}
