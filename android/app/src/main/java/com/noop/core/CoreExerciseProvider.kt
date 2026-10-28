package com.noop.core

import android.content.Context
import com.noop.data.SecurePrefs
import com.noop.ui.NoopPrefs
import org.json.JSONArray
import org.json.JSONObject

/** Credentials and form preferences are platform storage; Swift produces the selected definitions. */
object CoreExerciseProvider {
    private const val FILE = "noop_exercise_provider_credentials"
    private const val KEY = "api_key"
    const val ENDPOINT = "training.exerciseDB.endpoint"
    const val HEADER = "training.exerciseDB.header"
    data class Defaults(val endpoint: String, val header: String, val attribution: String, val documentation: String)
    data class Choice(val id: String, val title: String, val mode: String, val primary: String?)
    data class Preview(val token: String, val exercises: List<Choice>, val attribution: List<String>)
    data class Result(val preview: Preview? = null, val error: String? = null)
    private fun secure(context: Context) = SecurePrefs.of(context, FILE)
    private fun call(op: String, args: JSONObject = JSONObject()) =
        JSONObject(SwiftCore.call(op, args.toString()) ?: error("coreUnavailable"))

    fun defaults(): Defaults? = runCatching {
        val root = call("provider.defaults")
        Defaults(root.getString("endpoint"), root.getString("header"), root.getString("attribution"), root.getString("documentation"))
    }.getOrNull()
    fun hasKey(context: Context): Boolean = runCatching { !secure(context).getString(KEY, null).isNullOrBlank() }.getOrDefault(false)
    fun forgetKey(context: Context): Boolean = runCatching { secure(context).edit().remove(KEY).commit() }.getOrDefault(false)
    fun invalidate() { runCatching { call("provider.invalidate") } }

    fun load(context: Context, endpoint: String, header: String, suppliedKey: String): Result {
        val key = try {
            val credentials = secure(context)
            val supplied = suppliedKey.trim()
            if (supplied.isNotEmpty()) {
                if (!credentials.edit().putString(KEY, supplied).commit()) return Result(error = "credentialUnavailable")
                supplied
            } else credentials.getString(KEY, null)
        } catch (_: Exception) { return Result(error = "credentialUnavailable") }
        return runCatching {
            CoreRead.open(context)
            NoopPrefs.of(context).edit().putString(ENDPOINT, endpoint).putString(HEADER, header).apply()
            val args = JSONObject().put("endpoint", endpoint).put("header", header)
            key?.let { args.put("key", it) }
            val response = call("provider.preview", args)
            if (response.has("error")) Result(error = response.getString("error")) else Result(preview = parse(response))
        }.getOrElse { Result(error = "invalidResponse") }
    }
    fun accept(preview: Preview, ids: List<String>): Boolean = runCatching {
        call("provider.accept", JSONObject().put("token", preview.token).put("ids", JSONArray(ids))).optBoolean("ok")
    }.getOrDefault(false)

    internal fun parse(root: JSONObject): Preview {
        val token = root.getString("token")
        val rows = root.getJSONArray("exercises")
        val exercises = (0 until rows.length()).map { index ->
            val row = rows.getJSONObject(index)
            Choice(row.getString("id"), row.getString("title"), row.getString("mode"),
                if (row.isNull("primary")) null else row.getString("primary"))
        }
        require(token.isNotBlank() && exercises.map { it.id }.distinct().size == exercises.size)
        val credits = root.getJSONArray("attribution")
        return Preview(token, exercises, (0 until credits.length()).map(credits::getString))
    }
}
