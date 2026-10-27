package com.noop.core

import android.content.Context
import com.noop.data.SecurePrefs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** Platform credentials and lifecycle; paging, decoding, matching and persistence belong to Swift. */
object CoreHevyImport {
    private const val FILE = "noop_hevy_secure_prefs"
    data class Status(val id: String = "", val state: String = "idle", val phase: String = "", val page: Int = 0,
                      val totalPages: Int = 0, val stored: Int = 0, val updated: Int = 0, val deleted: Int = 0,
                      val skipped: Int = 0, val error: String? = null)
    data class Routine(val id: String, val title: String, val exercises: List<String>)
    data class Preview(val token: String, val routines: List<Routine>, val skipped: Int)
    data class Info(val stored: Int, val lastSync: Long)

    private fun credentials(context: Context) = SecurePrefs.of(context, FILE)
    private fun call(op: String, args: JSONObject = JSONObject()): JSONObject =
        if (SwiftCore.available) JSONObject(SwiftCore.call(op, args.toString())) else JSONObject().put("error", "coreUnavailable")

    fun connected(context: Context): Boolean = !credentials(context).getString("api_key", null).isNullOrBlank()

    fun info(context: Context): Info {
        CoreRead.open(context)
        val count = call("hevy.info").getInt("storedWorkouts")
        val last = context.getSharedPreferences("noop_hevy_status", Context.MODE_PRIVATE).getLong("lastSync", 0)
        return Info(count, last)
    }

    /** A rejected key is never saved. Replacing a credential forces a complete read, keeping local history. */
    fun connect(context: Context, key: String): String? = try {
        CoreRead.open(context)
        val trimmed = key.trim()
        val reply = call("hevy.verify", JSONObject().put("key", trimmed))
        if (!reply.optBoolean("ok")) reply.optString("error", "network") else {
            val secure = credentials(context)
            if (secure.getString("api_key", null) != trimmed && !call("hevy.resetSync").optBoolean("ok")) "storeUnavailable"
            else if (secure.edit().putString("api_key", trimmed).commit()) null else "credentialUnavailable"
        }
    } catch (_: Exception) { "credentialUnavailable" }

    suspend fun sync(context: Context, routinesOnly: Boolean = false, onProgress: (Status) -> Unit = {}): Status {
        CoreRead.open(context)
        val key = try { credentials(context).getString("api_key", null) } catch (_: Exception) { null }
            ?: return Status(state = "failed", error = "notConnected")
        val first = try { parse(call("hevy.startSync", JSONObject().put("key", key).put("routinesOnly", routinesOnly))) }
            catch (_: Exception) { return Status(state = "failed", error = "storeUnavailable") }
        if (first.error != null || first.id.isBlank()) return first
        var current = first
        try {
            while (current.state == "running") {
                onProgress(current)
                delay(400)
                current = parse(call("hevy.syncStatus"))
                check(current.id == first.id)
            }
            if (current.state == "completed" && current.skipped == 0 && !routinesOnly) {
                context.getSharedPreferences("noop_hevy_status", Context.MODE_PRIVATE).edit()
                    .putLong("lastSync", System.currentTimeMillis() / 1000).apply()
            }
            return current
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { return Status(state = "failed", error = "storeUnavailable") }
        finally {
            if (current.state == "running") withContext(NonCancellable + Dispatchers.IO) {
                runCatching { call("hevy.cancelSync", JSONObject().put("id", first.id)) }
            }
        }
    }

    fun cancel(id: String) { call("hevy.cancelSync", JSONObject().put("id", id)) }

    fun disconnect(context: Context, forget: Boolean = false): Boolean {
        // Revoking the local credential must work even if the core or its store is unavailable.
        val removed = runCatching { credentials(context).edit().remove("api_key").commit() }.getOrDefault(false)
        val stopped = runCatching { call("hevy.stopSync").optBoolean("ok") }.getOrDefault(false)
        if (!forget) return removed && (stopped || !SwiftCore.available)
        val forgotten = runCatching { call("hevy.forget").optBoolean("ok") }.getOrDefault(false)
        if (forgotten) context.getSharedPreferences("noop_hevy_status", Context.MODE_PRIVATE).edit().clear().apply()
        return removed && forgotten
    }

    fun preview(restSeconds: Int = 120): Preview? = runCatching { parsePreview(call("hevy.routines", JSONObject().put("restSeconds", restSeconds))) }.getOrNull()
    fun importRoutines(preview: Preview, selected: List<String>): Boolean = runCatching {
        call("hevy.importRoutines", JSONObject().put("token", preview.token).put("ids", JSONArray(selected))).optBoolean("ok")
    }.getOrDefault(false)

    internal fun parse(root: JSONObject): Status {
        val state = root.optString("state", "failed")
        if (state !in setOf("idle", "running", "completed", "failed", "cancelled") ||
            (state == "running" && root.optString("id").isBlank())) return Status(state = "failed", error = "decode")
        val summary = root.optJSONObject("summary")
        return Status(root.optString("id"), state, root.optString("phase"),
            root.optInt("page"), root.optInt("totalPages"), root.optInt("storedWorkouts"),
            summary?.optInt("fetchedWorkouts") ?: 0, summary?.optInt("deletedWorkouts") ?: 0,
            summary?.optInt("skipped") ?: 0, root.optString("error").takeIf { it.isNotBlank() && it != "null" })
    }
    internal fun parsePreview(root: JSONObject): Preview {
        val token = root.getString("token")
        val items = root.getJSONArray("routines")
        require(token.isNotBlank())
        val routines = (0 until items.length()).map { index ->
            val r = items.getJSONObject(index); val exercises = r.getJSONArray("exercises")
            Routine(r.getString("id"), r.getString("title"), (0 until exercises.length()).map(exercises::getString))
        }
        require(routines.map { it.id }.distinct().size == routines.size && routines.all { it.id.isNotBlank() })
        return Preview(token, routines, root.getInt("skippedExercises"))
    }
}
