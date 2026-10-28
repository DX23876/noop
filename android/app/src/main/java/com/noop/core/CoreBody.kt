package com.noop.core

import android.content.Context
import com.noop.NoopApplication
import com.noop.data.LabMarkerRow
import com.noop.ui.ProfileStore
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 2.3: the Body screen from the shared core (`CoreBody`). Tape and body-fat
 * readings are built by the core and written through the repository's lab-marker lane, so the classic screens and
 * the core hold the same rows; weigh-ins go to the core's own weight lane, as on Apple. Blocking; call off the main
 * thread.
 */
object CoreBody {
    data class Reading(val day: String, val value: Double, val source: String, val id: String?)
    data class Site(val key: String, val label: String, val current: Double?, val change: Double?, val guidance: String?)
    data class Change(val key: String, val label: String, val deltaCm: Double)
    data class Snapshot(
        val weight: List<Reading>, val weighIns: List<Reading>, val bodyFat: List<Reading>, val height: Reading?,
        val measured: List<Site>, val unmeasured: List<Site>, val changes: List<Change>, val weightChangeKg: Double?,
        val navyEstimate: Double?, val navyMissing: List<String>,
    )

    fun snapshot(context: Context, days: Int = 120): Snapshot? {
        if (!SwiftCore.available) return null
        CoreUserInputs.ensure(context)
        val profile = ProfileStore.from(context)
        val equation = when (profile.sex.lowercase()) { "male" -> "male"; "female" -> "female"; else -> "" }
        val json = SwiftCore.call("body.snapshot", JSONObject().put("days", days).put("comparisonDays", 42)
            .put("equation", equation).toString()) ?: return null
        return parse(json)
    }

    /** Writes one measurement session through the lab-marker lane; true when every row landed. */
    suspend fun record(context: Context, values: Map<String, Double>): Boolean {
        if (!SwiftCore.available || values.isEmpty()) return false
        val app = context.applicationContext as NoopApplication
        val json = SwiftCore.call("body.rows", JSONObject().put("values", JSONObject(values))
            .put("deviceId", app.activeDeviceId).toString()) ?: return false
        val rows = runCatching { JSONArray(json) }.getOrNull() ?: return false
        val markers = (0 until rows.length()).map { rows.getJSONObject(it) }.map {
            LabMarkerRow(id = it.getString("id"), deviceId = it.getString("deviceId"), markerKey = it.getString("markerKey"),
                         category = it.getString("category"), day = it.getString("day"), takenAt = it.getLong("takenAt"),
                         value = it.getDouble("value"), unit = it.getString("unit"), source = it.getString("source"),
                         note = if (it.isNull("note")) null else it.optString("note"))
        }
        if (markers.isEmpty()) return false
        return runCatching { app.repository.upsertLabMarkers(markers) }.isSuccess.also { if (it) CoreShadow.noteDataChanged() }
    }

    suspend fun deleteMeasurement(context: Context, id: String): Boolean =
        runCatching { (context.applicationContext as NoopApplication).repository.deleteLabMarker(id) }.getOrDefault(false)
            .also { if (it) CoreShadow.noteDataChanged() }

    fun logWeight(kg: Double): Boolean = change("body.logWeight", JSONObject().put("kg", kg))
    fun deleteWeight(id: String): Boolean = change("body.deleteWeight", JSONObject().put("id", id))

    private fun change(op: String, args: JSONObject): Boolean {
        if (!SwiftCore.available) return false
        val json = SwiftCore.call(op, args.toString()) ?: return false
        return runCatching { JSONObject(json).optBoolean("ok") }.getOrDefault(false).also { if (it) CoreShadow.noteDataChanged() }
    }

    internal fun parse(json: String): Snapshot? {
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return null
        if (o.has("error")) return null
        fun JSONArray?.objects() = if (this == null) emptyList() else (0 until length()).map { getJSONObject(it) }
        fun JSONObject.dbl(k: String): Double? = if (has(k) && !isNull(k)) getDouble(k) else null
        fun JSONObject.str(k: String): String? = if (has(k) && !isNull(k)) getString(k) else null
        fun reading(r: JSONObject) = Reading(r.getString("day"), r.getDouble("value"), r.optString("source"), r.str("id"))
        fun site(s: JSONObject) = Site(s.getString("key"), s.getString("label"), s.dbl("current"), s.dbl("change"), s.str("guidance"))
        val missing = o.optJSONArray("navyMissing")
        return Snapshot(
            weight = o.optJSONArray("weight").objects().map(::reading), weighIns = o.optJSONArray("weighIns").objects().map(::reading),
            bodyFat = o.optJSONArray("bodyFat").objects().map(::reading), height = o.optJSONObject("height")?.let(::reading),
            measured = o.optJSONArray("measured").objects().map(::site), unmeasured = o.optJSONArray("unmeasured").objects().map(::site),
            changes = o.optJSONArray("changes").objects().map { Change(it.getString("key"), it.getString("label"), it.getDouble("deltaCm")) },
            weightChangeKg = o.dbl("weightChangeKg"), navyEstimate = o.dbl("navyEstimate"),
            navyMissing = if (missing == null) emptyList() else (0 until missing.length()).map { missing.getString(it) },
        )
    }
}
